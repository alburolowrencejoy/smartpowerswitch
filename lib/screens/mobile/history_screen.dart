import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_xlsio/xlsio.dart' as xlsio;

import '../../theme/app_colors.dart';
import '../../theme/app_fonts.dart';
import '../../theme/app_text_styles.dart';
import '../../theme/institute_colors.dart';
import '../../services/history_clock.dart';
import '../../services/rate_timeline.dart';
import '../../services/forecast_models.dart';
import '../../utils/last_seen.dart';
import '../../widgets/app_bottom_sheet.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_segmented_control.dart';
import '../../widgets/app_top_bar.dart';
import '../../widgets/outline_icon_box.dart';
import '../../widgets/range_calendar.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import '../web/analytics/analytics_data.dart';
import '../web/analytics/analytics_filter.dart';
import '../web/analytics/breakdown_panel.dart';
import '../web/history_trend_panel.dart';
import '../web/web_trend_chart.dart';

/// The mobile "Analytics" screen (Usage + Forecast tabs). Ported from the web
/// Analytics screen (`lib/screens/web/history_screen_web.dart` and its
/// `analytics/` folder) per
/// `lib/Claude outputs/SmartSwitch-Mobile-Redesign-Handoff.md` §4.6/§4.7/§5.
///
/// Reuses the web's non-widget analytics models/logic directly:
/// [AnalyticsFilter], [DeviceMeta], [UsageRow], [parseDaily]/[applyFilter]/
/// [bucketize]/[groupSum]/[dailySeries] (`analytics/analytics_data.dart`,
/// `analytics/analytics_filter.dart`), and the ARIMA/backtest forecaster
/// (`services/forecast_models.dart`). Also reuses two self-contained web
/// widgets verbatim: [HistoryTrendPanel] (History section) and
/// [WebTrendChart] (consumption-trend / forecast charts) -- both work fine
/// embedded in a phone-width column and are explicitly listed as reusable in
/// the handoff. [BreakdownPanel]'s *content* is reused for the mobile
/// breakdown bottom sheet (see [_openBreakdown]); the web's
/// `showBreakdownPanel` entry point itself is NOT reused because it opens a
/// desktop right-side drawer, not a bottom sheet.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.showBackButton = true});

  /// Whether the screen's own [AppTopBar] shows a back chevron. Defaults to
  /// `true` (the standalone `/history` pushed-route case, see main.dart) --
  /// pass `false` when this is embedded as a tab (e.g. the dashboard's
  /// Analytics tab), matching the convention already used by
  /// [BuildingFloorScreen]'s `showBackButton` param.
  final bool showBackButton;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  // ── Institute theming / session ────────────────────────────────────────
  // This screen is a standalone pushed route (see main.dart's '/history'
  // route), so role/institute are hydrated directly from the signed-in
  // user's own record, mirroring dashboard_screen.dart's pattern.
  String _role = 'faculty';
  String? _institute;

  bool get _isInstituteAdmin => _role == 'institute_admin';

  /// Non-null only for an institute admin with an institute assigned --
  /// per handoff §5, their Analytics is locked to their own building.
  String? get _lockCode {
    if (!_isInstituteAdmin) return null;
    final code = _institute?.trim();
    return (code == null || code.isEmpty) ? null : code;
  }

  InstitutePalette get _palette =>
      InstituteTheme.resolve(_role, _institute).palette;

  /// Forces [f.buildings] to exactly `[_lockCode]` when this session is
  /// locked to an institute; a no-op for a campus admin.
  AnalyticsFilter _lockApplied(AnalyticsFilter f) {
    final lock = _lockCode;
    if (lock == null) return f;
    if (f.buildings.length == 1 && f.buildings.first == lock) return f;
    return f.copyWith(buildings: [lock]);
  }

  Future<void> _hydrateSessionFromAuth() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final snap =
          await FirebaseDatabase.instance.ref('users/${user.uid}').get();
      final data = snap.value;
      if (data is! Map) return;
      final map = Map<String, dynamic>.from(data);
      final role = (map['role'] as String?) ?? 'faculty';
      final institute = (map['institute'] as String?)?.trim();
      if (!mounted) return;
      setState(() {
        _role = role;
        _institute = institute;
        _filter = _lockApplied(_filter);
      });
    } catch (_) {
      // Keep existing role defaults if role hydration fails.
    }
  }

  // ── Analytics filter state ─────────────────────────────────────────────
  AnalyticsFilter _filter = AnalyticsFilter.defaults;
  int _tabIndex = 0; // 0 = Usage, 1 = Forecast
  bool _trendBars = false;
  int? _trendSelected;
  int? _forecastSelected;

  /// 0/1/2 = Institutes/Rooms/Devices for a campus admin; an institute
  /// admin never sees "Institutes" (handoff §5), so their segmented control
  /// only has Rooms(0)/Devices(1) and this is offset by +1 when read.
  int _topSegment = 0;
  String _compareModel = 'xgboost';

  // ── Firebase-backed data ────────────────────────────────────────────────
  Map<String, DeviceMeta> _meta = {};
  Map<String, String> _buildingNames = {};
  Map<String, int> _buildingFloors = {};
  double _electricityRate = 11.52;

  // Kept for the Excel export only (legacy `history/{daily,weekly,monthly,
  // yearly}` aggregate buckets -- a different, older aggregation than the
  // per-device `history/daily/*/devices` node the rest of this screen reads
  // via [parseDaily]). See the class doc and the final report for why both
  // still coexist.
  Map<String, double> _utilityTotals = {};
  Map<String, double> _buildingTotals = {};
  int _onlineCount = 0;
  int _offlineCount = 0;
  bool _exporting = false;

  Object? _historyDailyRaw;
  Set<String> _deletedDaily = const {};

  Object? _rowsCacheSrc;
  Map<String, DeviceMeta>? _rowsCacheMeta;
  Set<String>? _rowsCacheDeleted;
  Object? _rowsCacheRateLog;
  double? _rowsCacheRate;
  List<UsageRow> _rowsCache = const [];

  /// Every parsed `history/daily` row (all dates, all devices), cached so
  /// repeated calls within one build don't re-walk the raw snapshot.
  List<UsageRow> get _allRows {
    final src = _historyDailyRaw;
    if (!identical(src, _rowsCacheSrc) ||
        !identical(_meta, _rowsCacheMeta) ||
        !identical(_deletedDaily, _rowsCacheDeleted) ||
        !identical(_rateLog.value, _rowsCacheRateLog) ||
        _electricityRate != _rowsCacheRate) {
      _rowsCacheSrc = src;
      _rowsCacheMeta = _meta;
      _rowsCacheDeleted = _deletedDaily;
      _rowsCacheRateLog = _rateLog.value;
      _rowsCacheRate = _electricityRate;
      _rowsCache = parseDaily(src, _meta,
          rates: RateHistory.instance.timeline(_electricityRate),
          deleted: _deletedDaily);
    }
    return _rowsCache;
  }

  bool _isLoading = true;
  String? _errorText;
  Timer? _loadTimeoutTimer;
  bool _postLoadErrorNotified = false;
  StreamSubscription? _combinedSub;
  StreamSubscription<DatabaseEvent>? _predictionsSub;

  Map<String, dynamic> _remoteModels = {};
  bool _remoteModelsLoaded = false;

  bool _isPermissionDenied(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') ||
        text.contains('permission_denied');
  }

  @override
  void initState() {
    super.initState();
    _hydrateSessionFromAuth();
    _listenAll();
    _listenPredictions();
    _rateLog.addListener(_onRateLog);
    _startLoadTimeoutTimer();
  }

  /// Past rates, so records without a stored cost are priced at their own
  /// day's rate rather than today's.
  final ValueListenable<Object?> _rateLog = RateHistory.instance.log;
  void _onRateLog() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _combinedSub?.cancel();
    _predictionsSub?.cancel();
    _loadTimeoutTimer?.cancel();
    _rateLog.removeListener(_onRateLog);
    super.dispose();
  }

  void _startLoadTimeoutTimer() {
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted || !_isLoading) return;
      setState(() {
        _isLoading = false;
        _errorText =
            'Taking too long to load analytics. Check your connection.';
      });
    });
  }

  void _retryLoad() {
    _combinedSub?.cancel();
    _loadTimeoutTimer?.cancel();
    setState(() {
      _errorText = null;
      _isLoading = true;
      _postLoadErrorNotified = false;
    });
    _listenAll();
    _startLoadTimeoutTimer();
  }

  void _handleLoadError(Object error) {
    if (!mounted) return;
    debugPrint('[Analytics] Listen error: $error');
    _loadTimeoutTimer?.cancel();
    if (_isLoading) {
      setState(() {
        _isLoading = false;
        _errorText = _isPermissionDenied(error)
            ? 'You do not have permission to view analytics.'
            : 'Failed to load analytics.';
      });
    } else if (!_postLoadErrorNotified) {
      _postLoadErrorNotified = true;
      TopToast.show(context, 'Lost connection to live analytics data.',
          isError: true);
    }
  }

  /// Combines every Firebase path this screen needs into one sticky-merge
  /// stream (a transient null on any single path can never blank out data
  /// already loaded this session) -- same shape as the pre-redesign version
  /// of this screen and `history_screen_web.dart`'s `_listenAll`.
  void _listenAll() {
    _combinedSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('devices').onValue,
      FirebaseDatabase.instance.ref('buildings').onValue,
      FirebaseDatabase.instance.ref('settings/electricityRate').onValue,
      FirebaseDatabase.instance.ref('history/daily').onValue,
      FirebaseDatabase.instance.ref('history/deleted/daily').onValue,
    ]).listen((events) {
      if (!mounted) return;
      _loadTimeoutTimer?.cancel();
      try {
        setState(() {
          _applyListenAllEvents(events);
        });
      } catch (error, stack) {
        // Any unexpected data shape thrown from inside the setState above
        // (e.g. a field that doesn't parse the way we expect) must never
        // leave the screen stuck on its loading skeleton forever -- fail
        // visibly with the same retryable error path a stream-level error
        // uses, instead of a silent permanent freeze. See the class doc on
        // `_listenAll` / the report for the concrete case this guards
        // against.
        debugPrint('[Analytics] _listenAll setState threw: $error\n$stack');
        _handleLoadError(error);
      }
    }, onError: _handleLoadError);
  }

  /// The body of the combined listener's `onData` callback, split out of
  /// [_listenAll] only so it can be wrapped in a try/catch there -- this
  /// must be called from inside a `setState(() { ... })`.
  void _applyListenAllEvents(List<DatabaseEvent> events) {
    final devicesRaw = events[0].snapshot.value;
    if (devicesRaw is Map) {
      final data = Map<String, dynamic>.from(devicesRaw);
      _meta = DeviceMeta.parseAll(data);
      final utilityTotals = <String, double>{};
      final buildingTotals = <String, double>{};
      int online = 0, offline = 0;
      data.forEach((id, val) {
        if (val is! Map) return;
        final device = Map<String, dynamic>.from(val);
        final utility = (device['utility'] ?? 'Unknown').toString();
        final building = (device['building'] ?? 'Unknown').toString();
        final kwh = (device['kwh'] ?? 0.0) as num;
        utilityTotals[utility] = (utilityTotals[utility] ?? 0) + kwh.toDouble();
        buildingTotals[building] =
            (buildingTotals[building] ?? 0) + kwh.toDouble();
        final isOnline = isRecentlySeen(device['last_seen']);
        isOnline ? online++ : offline++;
      });
      _utilityTotals = utilityTotals;
      _buildingTotals = buildingTotals;
      _onlineCount = online;
      _offlineCount = offline;
    } else if (_isLoading) {
      _meta = {};
      _utilityTotals = {};
      _buildingTotals = {};
      _onlineCount = 0;
      _offlineCount = 0;
    }

    final buildingsRaw = events[1].snapshot.value;
    if (buildingsRaw is Map) {
      final data = Map<String, dynamic>.from(buildingsRaw);
      final names = <String, String>{};
      final floors = <String, int>{};
      data.forEach((code, val) {
        if (val is! Map) return;
        final b = Map<String, dynamic>.from(val);
        names[code.toString()] = (b['name'] ?? code).toString();
        floors[code.toString()] = int.tryParse('${b['floors'] ?? 1}') ?? 1;
      });
      _buildingNames = names;
      _buildingFloors = floors;
    } else if (_isLoading) {
      _buildingNames = {};
      _buildingFloors = {};
    }

    final rateRaw = events[2].snapshot.value;
    if (rateRaw is num) {
      _electricityRate = rateRaw.toDouble();
    } else if (_isLoading) {
      _electricityRate = 11.52;
    }

    _historyDailyRaw = events[3].snapshot.value;

    final deletedRaw = events[4].snapshot.value;
    if (deletedRaw is Map) {
      _deletedDaily =
          Set<String>.from(Map<String, dynamic>.from(deletedRaw).keys);
    } else if (_isLoading) {
      _deletedDaily = const {};
    }

    _isLoading = false;
    _errorText = null;
    _postLoadErrorNotified = false;
  }

  /// XGBoost / LSTM, trained daily by the Python job and published to
  /// `history/predictions/models` -- loaded independently of the main
  /// combined listener (matches `web_forecast_cards.dart`'s
  /// `ForecastComparison`), so a slow/failed load here only affects the
  /// Forecast tab's "Compare with" column, not the whole screen.
  void _listenPredictions() {
    _predictionsSub = FirebaseDatabase.instance
        .ref('history/predictions/models')
        .onValue
        .listen((e) {
      if (!mounted) return;
      try {
        setState(() {
          final v = e.snapshot.value;
          _remoteModels = v is Map ? Map<String, dynamic>.from(v) : {};
          _remoteModelsLoaded = true;
        });
      } catch (error, stack) {
        // Same reasoning as `_listenAll`: a throw from inside this onData
        // callback (as opposed to a stream-level error) is not caught by
        // `onError` below. Without this, an unexpected shape under
        // `history/predictions/models` would leave the Forecast tab's
        // "Compare with" column stuck on "Loading…" forever instead of
        // degrading to "Not trained yet" once loaded is (correctly) true.
        debugPrint(
            '[Analytics] _listenPredictions setState threw: $error\n$stack');
        if (mounted) setState(() => _remoteModelsLoaded = true);
      }
    }, onError: (_) {
      if (mounted) setState(() => _remoteModelsLoaded = true);
    });
  }

  // ── Scope / building helpers ────────────────────────────────────────────

  String _buildingName(String code) =>
      _buildingNames[code] ?? (code.isEmpty ? code : '$code Building');

  /// Buildings offered in the Scope sheet: the campus defaults first, then
  /// any other code seen in `buildings` or a device.
  List<String> _scopeBuildingCodes() {
    final codes = <String>[...kDefaultBuildings];
    for (final c in [
      ..._buildingNames.keys,
      ..._meta.values.map((m) => m.building)
    ]) {
      if (c.isNotEmpty && !codes.contains(c)) codes.add(c);
    }
    return codes;
  }

  bool _metaInScope(DeviceMeta m, AnalyticsFilter f) {
    if (f.buildings.isNotEmpty && !f.buildings.contains(m.building)) {
      return false;
    }
    if (f.floor > 0 && m.floor != f.floor) return false;
    if (f.room.isNotEmpty && m.room != f.room) return false;
    if (f.device.isNotEmpty && m.id != f.device) return false;
    if (f.utilities.isNotEmpty && !f.utilities.contains(m.utility)) {
      return false;
    }
    return true;
  }

  List<DeviceMeta> _devicesInScope(AnalyticsFilter f) =>
      _meta.values.where((m) => _metaInScope(m, f)).toList();

  String _scopeLabel(AnalyticsFilter f) {
    if (f.buildings.isEmpty) return 'All buildings';
    final code = f.buildings.first;
    final name = _buildingName(code);
    if (f.device.isNotEmpty) return f.device;
    if (f.room.isNotEmpty) return '$code · ${f.room}';
    if (f.floor > 0) return '$name · Floor ${f.floor}';
    return name;
  }

  // ── Formatting ───────────────────────────────────────────────────────────

  String _fmtNumber(double v, int decimals) {
    final neg = v < 0;
    final s = v.abs().toStringAsFixed(decimals);
    final parts = s.split('.');
    final whole = parts[0]
        .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    final out = decimals > 0 ? '$whole.${parts[1]}' : whole;
    return neg ? '-$out' : out;
  }

  String _fmtKwh(double v) => _fmtNumber(v, v.abs() < 100 ? 1 : 0);
  String _fmtMoney(double v) => '₱${_fmtNumber(v, 0)}';

  bool _isCost(AnalyticsFilter f) => f.metric == ValueMetric.cost;

  /// Formats [v], already in the filter's metric (₱ or kWh). Costs come
  /// from the stored per-record costs, never kWh x today's rate.
  String _val(double v, AnalyticsFilter f) =>
      _isCost(f) ? '₱${_fmtNumber(v, 0)}' : _fmtKwh(v);

  double _metric(Iterable<UsageRow> rows, AnalyticsFilter f) =>
      _isCost(f) ? sumCost(rows) : sumKwh(rows);

  double _bucketValue(Bucket b, AnalyticsFilter f) =>
      _isCost(f) ? b.cost : b.kwh;

  /// "₱11.52 per kWh" -- the average of the rates [rows] were billed at,
  /// which differs from today's rate when the range spans a rate change.
  String _avgRateCaption(List<UsageRow> rows) {
    final kwh = sumKwh(rows);
    final rate = kwh > 0 ? sumCost(rows) / kwh : _electricityRate;
    final same = (rate - _electricityRate).abs() < 0.005;
    return '₱${rate.toStringAsFixed(2)} ${same ? 'per kWh' : 'avg per kWh'}';
  }

  String _unit(AnalyticsFilter f) => _isCost(f) ? '' : 'kWh';

  // ── Active-filter chips (handoff §4.6, mirrors preview `activeChips`) ──

  void _clearAndApply(AnalyticsFilter Function(AnalyticsFilter) mutate) {
    setState(() {
      _filter = _lockApplied(mutate(_filter).withValidGroup());
      _trendSelected = null;
    });
  }

  List<(String, VoidCallback)> _activeChips(AnalyticsFilter f) {
    final chips = <(String, VoidCallback)>[];
    if (f.range != RangePreset.last30) {
      chips.add((
        f.rangeName,
        () => _clearAndApply((c) => c.withRange(RangePreset.last30))
      ));
    }
    if (!f.isDefaultGroup) {
      chips.add((
        f.group.label,
        () => _clearAndApply((c) => c.copyWith(group: suggestedGroup(c.days)))
      ));
    }
    final showScopeChip = _lockCode == null
        ? f.buildings.isNotEmpty
        : (f.floor > 0 || f.room.isNotEmpty || f.device.isNotEmpty);
    if (showScopeChip) {
      chips
          .add((_scopeLabel(f), () => _clearAndApply((c) => c.clearedScope())));
    }
    if (f.hasUtility) {
      chips.add((
        f.utilityName,
        () => _clearAndApply((c) => c.copyWith(utilities: const []))
      ));
    }
    if (f.dayType != DayType.all) {
      chips.add((
        f.dayType == DayType.weekday ? 'Weekdays' : 'Weekends',
        () => _clearAndApply((c) => c.copyWith(dayType: DayType.all)),
      ));
    }
    if (f.compare != CompareMode.off) {
      chips.add((
        f.compare == CompareMode.previous
            ? 'vs previous period'
            : 'vs last year',
        () => _clearAndApply((c) => c.copyWith(compare: CompareMode.off)),
      ));
    }
    if (f.metric != ValueMetric.kwh) {
      chips.add((
        'Cost (₱)',
        () => _clearAndApply((c) => c.copyWith(metric: ValueMetric.kwh))
      ));
    }
    return chips;
  }

  void _resetAll() {
    setState(() {
      _filter = _lockApplied(AnalyticsFilter.defaults);
      _trendSelected = null;
    });
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Column(children: [
            // Skipped when embedded directly as the dashboard's Analytics
            // tab -- the parent shell already shows an equivalent top bar
            // just above this screen (see class doc on `showBackButton`).
            if (widget.showBackButton)
              AppTopBar(
                title: 'Analytics',
                subtitle: _lockCode != null
                    ? '${_buildingName(_lockCode!)} energy and forecast'
                    : 'Energy and forecast',
                showBackButton: widget.showBackButton,
                showInstituteLine: _lockCode != null,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: AppSegmentedControl(
                segments: const [
                  AppSegment(label: 'Usage'),
                  AppSegment(label: 'Forecast'),
                ],
                selectedIndex: _tabIndex,
                onChanged: (i) => setState(() => _tabIndex = i),
              ),
            ),
            Expanded(
              child: _errorText != null
                  ? _buildError()
                  : ScreenSkeleton(
                      isLoading: _isLoading,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
                        child: _tabIndex == 0
                            ? _buildUsageTab()
                            : _buildForecastTab(),
                      ),
                    ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
                color: Colors.white, border: Border.all(color: AppColors.hairline), borderRadius: BorderRadius.circular(20)),
            child: Icon(Icons.wifi_off_rounded, size: 34, color: _palette.mid),
          ),
          const SizedBox(height: 16),
          Text('Cannot load analytics',
              style: AppTextStyles.title.copyWith(color: AppColors.ink)),
          const SizedBox(height: 8),
          Text(_errorText ?? 'Something went wrong.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
          const SizedBox(height: 16),
          AppPrimaryButton(
              label: 'Retry', icon: Icons.refresh, onPressed: _retryLoad),
        ]),
      ),
    );
  }

  // ── Shared header (period title + Filters + chips) ─────────────────────

  Widget _buildHeader(String title, String sub) {
    final chips = _activeChips(_filter);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: AppTextStyles.titleLg.copyWith(color: AppColors.ink)),
            const SizedBox(height: 2),
            Text(sub,
                style:
                    AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
          ]),
        ),
        const SizedBox(width: 12),
        _FiltersButton(
            count: chips.length, onTap: _openFiltersHub, palette: _palette),
      ]),
      if (chips.isNotEmpty) ...[
        const SizedBox(height: 12),
        Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final c in chips)
                AppRemovableChip(
                    label: c.$1, onRemove: c.$2, palette: _palette),
              AppTextButton(
                  label: 'Clear all', onPressed: _resetAll, palette: _palette),
            ]),
      ],
      const SizedBox(height: 8),
    ]);
  }

  // ══════════════════════════════ Usage tab ══════════════════════════════

  Widget _buildUsageTab() {
    final f = _filter;
    final today = dateOnly(HistoryClock.instance.now());
    final span = f.span(today);
    final compareSpan = f.compareSpan(today);
    final rows = applyFilter(f, _allRows, span);
    final compareRows =
        compareSpan == null ? null : applyFilter(f, _allRows, compareSpan);
    final total = _metric(rows, f);
    final compareTotal = compareRows == null ? null : _metric(compareRows, f);
    final ds = _devicesInScope(f);

    final header = _buildHeader(
      f.rangeName,
      '${spanText(span)} · ${_scopeLabel(f)}${f.hasUtility ? ' · ${f.utilityName}' : ''}',
    );

    if (ds.isEmpty || total == 0) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        header,
        const SizedBox(height: 24),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(children: [
              Text('No data for these filters',
                  style: AppTextStyles.subtitle.copyWith(color: AppColors.ink)),
              const SizedBox(height: 6),
              Text('Try a wider range or fewer filters.',
                  style:
                      AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
              const SizedBox(height: 16),
              AppOutlineButton(
                  label: 'Clear filters',
                  onPressed: _resetAll,
                  palette: _palette),
            ]),
          ),
        ),
      ]);
    }

    final allowedDays = _allowedDaysIn(span, f);
    final compareAllowedDays =
        compareSpan == null ? 0 : _allowedDaysIn(compareSpan, f);
    final online = ds.where((d) => d.online).length;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      header,
      const SizedBox(height: 4),
      _buildSummaryBlock(f, rows, total, compareTotal, allowedDays,
          compareAllowedDays, ds, online),
      const SizedBox(height: 28),
      _buildTrendSection(f, span, compareSpan, rows, compareRows),
      const SizedBox(height: 28),
      _buildUtilitySection(f, rows, total),
      const SizedBox(height: 28),
      _buildTopConsumingSection(f, rows, total),
      const SizedBox(height: 28),
      HistoryTrendPanel(palette: _palette, instituteCode: _lockCode, days: 10),
      const SizedBox(height: 24),
      AppOutlineButton(
        label: _exporting ? 'Exporting…' : 'Export to Excel',
        icon: Icons.download_outlined,
        onPressed: _exporting ? null : _exportOrganizedXlsx,
        palette: _palette,
        expand: true,
      ),
    ]);
  }

  int _allowedDaysIn(DateTimeRange span, AnalyticsFilter f) {
    var n = 0;
    for (var d = span.start;
        !d.isAfter(span.end);
        d = DateTime(d.year, d.month, d.day + 1)) {
      if (f.dayAllowed(d)) n++;
    }
    return n;
  }

  /// [expand] wraps the box in [Expanded] for use inside a [Row]; pass false
  /// when it sits directly in the scrolling [Column], where an [Expanded]
  /// gets unbounded height and fails layout (blanking the whole tab).
  Widget _statBox(String label, String value, String caption,
      {bool expand = true}) {
    final box = Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _palette.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: AppTextStyles.caption.copyWith(color: AppColors.inkMuted)),
        const SizedBox(height: 4),
        Text(value,
            style: AppTextStyles.subtitle.copyWith(color: AppColors.ink)),
        const SizedBox(height: 2),
        Text(caption,
            style: AppTextStyles.captionSmall
                .copyWith(color: AppColors.inkMuted)),
      ]),
    );
    return expand ? Expanded(child: box) : box;
  }

  Widget _deltaRow(double cur, double? prev,
      {bool upBad = true, String? placeholder}) {
    if (prev == null) {
      return Text(placeholder ?? 'Turn on Compare to see the change',
          style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted));
    }
    final pct = prev == 0 ? 0.0 : (cur - prev) / prev * 100;
    final flat = pct.abs() < 0.05;
    final up = pct > 0;
    final bad = upBad ? up : !up;
    final color = flat
        ? AppColors.inkMuted
        : (bad ? AppColors.warningText : AppColors.successText);
    final arrow = flat ? '●' : (up ? '▲' : '▼');
    final vs =
        _filter.compare == CompareMode.lastYear ? 'last year' : 'previous';
    return Text.rich(TextSpan(children: [
      TextSpan(
        text: flat ? '$arrow 0.0%' : '$arrow ${pct.abs().toStringAsFixed(1)}%',
        style: AppTextStyles.bodySm
            .copyWith(color: color, fontWeight: FontWeight.w700),
      ),
      TextSpan(
          text: ' vs $vs',
          style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
    ]));
  }

  Widget _buildSummaryBlock(
    AnalyticsFilter f,
    List<UsageRow> rows,
    double total,
    double? compareTotal,
    int allowedDays,
    int compareAllowedDays,
    List<DeviceMeta> ds,
    int online,
  ) {
    final cost = _isCost(f);
    final big = cost ? _fmtMoney(total) : _fmtKwh(total);
    final dailyAvg = allowedDays > 0 ? total / allowedDays : 0.0;
    final compareDailyAvg = (compareTotal != null && compareAllowedDays > 0)
        ? compareTotal / compareAllowedDays
        : null;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _palette.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(cost ? 'Total cost' : 'Total energy',
            style: AppTextStyles.caption.copyWith(color: AppColors.inkMuted)),
        const SizedBox(height: 4),
        Text.rich(TextSpan(children: [
          TextSpan(
              text: big,
              style:
                  AppTextStyles.displayTabular.copyWith(color: AppColors.ink)),
          if (!cost)
            TextSpan(
                text: ' kWh',
                style:
                    AppTextStyles.subtitle.copyWith(color: AppColors.inkMuted)),
        ])),
        const SizedBox(height: 6),
        _deltaRow(total, compareTotal),
        const SizedBox(height: 16),
        // IntrinsicHeight gives the stretch a finite height -- inside the
        // SingleChildScrollView a bare stretch Row gets infinite height.
        IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _statBox(
            cost ? 'Energy' : 'Cost',
            cost
                ? '${_fmtKwh(sumKwh(rows))} kWh'
                : _fmtMoney(sumCost(rows)),
            _avgRateCaption(rows),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _palette.line),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Daily average',
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.inkMuted)),
                    const SizedBox(height: 4),
                    Text('${_val(dailyAvg, f)} ${_unit(f)}',
                        style: AppTextStyles.subtitle
                            .copyWith(color: AppColors.ink)),
                    const SizedBox(height: 2),
                    compareDailyAvg != null
                        ? _deltaRow(dailyAvg, compareDailyAvg)
                        : Text('$allowedDays days counted',
                            style: AppTextStyles.captionSmall
                                .copyWith(color: AppColors.inkMuted)),
                  ]),
            ),
          ),
        ])),
        const SizedBox(height: 10),
        _statBox('Devices online', '$online of ${ds.length}',
            '${ds.length - online} offline now',
            expand: false),
      ]),
    );
  }

  Widget _sectionHead(String title, String? sub, {Widget? trailing}) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: AppTextStyles.title.copyWith(color: AppColors.ink)),
          if (sub != null) ...[
            const SizedBox(height: 2),
            Text(sub,
                style:
                    AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
          ],
        ]),
      ),
      if (trailing != null) trailing,
    ]);
  }

  Widget _buildTrendSection(
    AnalyticsFilter f,
    DateTimeRange span,
    DateTimeRange? compareSpan,
    List<UsageRow> rows,
    List<UsageRow>? compareRows,
  ) {
    final cost = _isCost(f);
    final buckets = bucketize(f, rows, span, f.group);
    final compareBuckets = compareSpan == null
        ? null
        : bucketize(f, compareRows ?? const [], compareSpan, f.group);
    final noun = switch (f.group) {
      GroupBy.daily => 'day',
      GroupBy.weekly => 'week',
      GroupBy.monthly => 'month',
      GroupBy.hourly => 'hour',
    };
    final points = [
      for (final b in buckets)
        TrendPoint(
            b.label,
            '${b.tooltipLabel} · ${_val(_bucketValue(b, f), f)}${cost ? '' : ' kWh'}',
            _bucketValue(b, f))
    ];
    final compareValues = compareBuckets == null
        ? null
        : [
            for (var i = 0; i < points.length; i++)
              i < compareBuckets.length
                  ? _bucketValue(compareBuckets[i], f)
                  : 0.0
          ];
    final sel = (_trendSelected != null && _trendSelected! < buckets.length)
        ? _trendSelected
        : null;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionHead(
        'Consumption trend',
        '${cost ? '₱' : 'kWh'} per $noun',
        trailing: SizedBox(
          width: 140,
          child: AppSegmentedControl(
            segments: const [
              AppSegment(label: 'Line'),
              AppSegment(label: 'Bar')
            ],
            selectedIndex: _trendBars ? 1 : 0,
            onChanged: (i) => setState(() => _trendBars = i == 1),
            palette: _palette,
          ),
        ),
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.fromLTRB(8, 16, 12, 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _palette.line),
        ),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          WebTrendChart(
            points: points,
            bars: _trendBars,
            color: _palette.mid,
            height: 210,
            compare: compareValues,
            selected: sel,
            onSelect: (i) => setState(() => _trendSelected = i),
          ),
          if (compareSpan != null) ...[
            const SizedBox(height: 4),
            Wrap(spacing: 16, runSpacing: 4, children: [
              _legendItem(
                  _palette.mid, false, 'This period · ${spanText(span)}'),
              _legendItem(const Color(0xFF8A9A90), true,
                  '${f.compare == CompareMode.lastYear ? 'Last year' : 'Previous period'} · ${spanText(compareSpan)}'),
            ]),
          ],
          const SizedBox(height: 10),
          _buildTrendReadout(f, buckets, compareBuckets, sel, noun, cost),
        ]),
      ),
      if (compareSpan == null) ...[
        const SizedBox(height: 10),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openFilterSheet('more'),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _palette.line),
            ),
            child: Row(children: [
              Icon(Icons.compare_arrows, size: 20, color: _palette.dark),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Compare with the previous period or last year',
                    style:
                        AppTextStyles.bodySm.copyWith(color: AppColors.inkMid)),
              ),
              const Icon(Icons.chevron_right,
                  size: 20, color: AppColors.inkMuted),
            ]),
          ),
        ),
      ],
    ]);
  }

  Widget _legendItem(Color color, bool dashed, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
          width: 16,
          height: 10,
          child: CustomPaint(painter: _LegendLinePainter(color, dashed))),
      const SizedBox(width: 6),
      Text(label,
          style:
              AppTextStyles.captionSmall.copyWith(color: AppColors.inkMuted)),
    ]);
  }

  Widget _buildTrendReadout(AnalyticsFilter f, List<Bucket> buckets,
      List<Bucket>? compareBuckets, int? sel, String noun, bool cost) {
    if (sel == null) {
      return Row(children: [
        const Icon(Icons.touch_app_outlined,
            size: 18, color: AppColors.inkMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text("Tap the chart to see a $noun's value",
              style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
        ),
      ]);
    }
    final b = buckets[sel];
    final cmp = (compareBuckets != null && sel < compareBuckets.length)
        ? compareBuckets[sel]
        : null;
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(b.tooltipLabel,
              style: AppTextStyles.captionSmall
                  .copyWith(color: AppColors.inkMuted)),
          Text('${_val(_bucketValue(b, f), f)} ${_unit(f)}',
              style: AppTextStyles.subtitle.copyWith(color: AppColors.ink)),
        ]),
      ),
      if (cmp != null) ...[
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                _filter.compare == CompareMode.lastYear
                    ? 'Last year'
                    : 'Previous',
                style: AppTextStyles.captionSmall
                    .copyWith(color: AppColors.inkMuted)),
            Text('${_val(_bucketValue(cmp, f), f)} ${_unit(f)}',
                style:
                    AppTextStyles.subtitle.copyWith(color: AppColors.inkMuted)),
          ]),
        ),
        _deltaRow(_bucketValue(b, f), _bucketValue(cmp, f)),
      ],
    ]);
  }

  Widget _buildUtilitySection(
      AnalyticsFilter f, List<UsageRow> rows, double total) {
    final cost = _isCost(f);
    final totals = <String, double>{
      for (final u in kUtilities)
        u: _metric(rows.where((r) => r.utility == u), f),
    };
    final parts =
        ['AC', 'Outlets', 'Lights'].where((u) => (totals[u] ?? 0) > 0).toList();
    if (parts.isEmpty) return const SizedBox.shrink();
    const colors = {
      'Lights': Color(0xFF1A5C35),
      'Outlets': Color(0xFF2E9E52),
      'AC': Color(0xFF6ECB8A),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionHead('By utility', 'Share of ${cost ? 'cost' : 'energy'}'),
      const SizedBox(height: 12),
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 12,
          child: Row(children: [
            for (final u in parts) ...[
              Expanded(
                  flex: ((totals[u] ?? 0) * 1000).round().clamp(1, 1000000),
                  child: ColoredBox(color: colors[u]!)),
            ]
          ]),
        ),
      ),
      const SizedBox(height: 4),
      for (final u in parts)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: _palette.line))),
          child: Row(children: [
            Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                    color: colors[u], borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 10),
            Expanded(
              child: Text(u == 'AC' ? 'Air conditioning' : u,
                  style: AppTextStyles.subtitle.copyWith(color: AppColors.ink)),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(
                  '${total <= 0 ? 0 : ((totals[u] ?? 0) / total * 100).round()}%',
                  style: AppTextStyles.subtitle.copyWith(color: AppColors.ink)),
              Text('${_val(totals[u] ?? 0, f)} ${_unit(f)}',
                  style: AppTextStyles.captionSmall
                      .copyWith(color: AppColors.inkMuted)),
            ]),
          ]),
        ),
    ]);
  }

  Widget _buildTopConsumingSection(
      AnalyticsFilter f, List<UsageRow> rows, double total) {
    final showInstitutes = _lockCode == null;
    final segment = showInstitutes
        ? _topSegment
        : _topSegment + 1; // 0=inst,1=rooms,2=devices

    String Function(UsageRow) keyFn;
    if (segment == 0) {
      keyFn = (r) => r.building;
    } else if (segment == 1) {
      keyFn = (r) => r.roomKey;
    } else {
      keyFn = (r) => r.deviceId;
    }
    final scoped =
        segment == 0 ? rows : rows.where((r) => r.deviceId.isNotEmpty);
    final grouped = groupSum(scoped, keyFn, cost: _isCost(f)).take(5).toList();
    final tmax = grouped.isEmpty ? 1.0 : grouped.first.value;

    final segments = showInstitutes
        ? const [
            AppSegment(label: 'Institutes'),
            AppSegment(label: 'Rooms'),
            AppSegment(label: 'Devices')
          ]
        : const [AppSegment(label: 'Rooms'), AppSegment(label: 'Devices')];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionHead(
          'Top consuming',
          segment == 0
              ? 'Tap an institute for its breakdown'
              : 'Highest first'),
      const SizedBox(height: 12),
      AppSegmentedControl(
        segments: segments,
        selectedIndex: _topSegment,
        onChanged: (i) => setState(() => _topSegment = i),
        palette: _palette,
      ),
      const SizedBox(height: 12),
      if (grouped.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text('Nothing to show for this scope.',
              style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
        )
      else
        for (var i = 0; i < grouped.length; i++)
          _topConsumingRow(f, segment, i, grouped[i], tmax, total, rows),
    ]);
  }

  Widget _topConsumingRow(
      AnalyticsFilter f,
      int segment,
      int index,
      MapEntry<String, double> entry,
      double tmax,
      double total,
      List<UsageRow> rows) {
    late Widget lead;
    late String title;
    late String sub;
    VoidCallback? onTap;

    if (segment == 0) {
      final code = entry.key;
      lead = OutlineIconBox(
        icon: code == 'ADMIN' ? Icons.account_balance : Icons.apartment,
        palette: InstituteColors.forCode(code),
      );
      title = _buildingName(code);
      sub = '${total <= 0 ? 0 : (entry.value / total * 100).round()}% of total';
      onTap = () => _openBreakdown(BreakdownKind.building, code, rows, total);
    } else if (segment == 1) {
      final parts = entry.key.split('|');
      final building = parts.isNotEmpty ? parts[0] : '';
      final floor = parts.length > 1 ? parts[1] : '';
      final room = parts.length > 2 ? parts[2] : entry.key;
      lead = Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: Colors.white, border: Border.all(color: AppColors.hairline), borderRadius: BorderRadius.circular(12)),
        child: Text('${index + 1}',
            style: TextStyle(
                fontFamily: AppFonts.family,
                fontWeight: FontWeight.w700,
                color: _palette.dark)),
      );
      title = room;
      sub = _lockCode != null
          ? 'Floor $floor · ${total <= 0 ? 0 : (entry.value / total * 100).round()}% of ${_buildingName(_lockCode!)}'
          : _buildingName(building);
      onTap = () => _openBreakdown(BreakdownKind.room, entry.key, rows, total);
    } else {
      final dv = _meta[entry.key];
      lead = OutlineIconBox(
        icon: dv == null
            ? Icons.power
            : dv.utility == 'AC'
                ? Icons.ac_unit
                : dv.utility == 'Lights'
                    ? Icons.lightbulb_outline
                    : Icons.power,
        palette: _palette,
      );
      title =
          '${dv?.utility == 'AC' ? 'Aircon' : (dv?.utility ?? 'Device')} · ${dv?.room ?? ''}';
      sub =
          '${dv?.building ?? ''} · ${dv == null ? 'Unknown' : (dv.relay ? 'On now' : 'Off now')}';
      onTap =
          null; // Device-detail navigation left to device_detail_screen.dart's owner; see report.
    }

    final pct = tmax <= 0 ? 0 : (entry.value / tmax * 100).round();
    final row = Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: _palette.line))),
      child: Row(children: [
        lead,
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.subtitle.copyWith(color: AppColors.ink)),
            Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.captionSmall
                    .copyWith(color: AppColors.inkMuted)),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 6,
                child: Stack(children: [
                  Container(color: AppColors.skeleton),
                  FractionallySizedBox(
                      widthFactor: (pct / 100).clamp(0, 1).toDouble(),
                      child: Container(color: _palette.mid)),
                ]),
              ),
            ),
          ]),
        ),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_val(entry.value, f),
              style: AppTextStyles.subtitle.copyWith(color: AppColors.ink)),
          Text(_unit(f),
              style: AppTextStyles.captionSmall
                  .copyWith(color: AppColors.inkMuted)),
        ]),
        if (onTap != null) ...[
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, size: 18, color: AppColors.inkMuted),
        ],
      ]),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }

  // ── Breakdown bottom sheet (reuses BreakdownPanel's content) ────────────

  void _openBreakdown(
      BreakdownKind kind, String id, List<UsageRow> rows, double cardTotal) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
      builder: (ctx) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BreakdownPanel(
          kind: kind,
          id: id,
          rangeName: _filter.rangeName,
          rows: rows,
          cardTotal: cardTotal,
          devices: _meta,
          buildingNames: _buildingNames,
          rate: _electricityRate,
          palette: _palette,
          onClose: () => Navigator.of(ctx).pop(),
          onOpenDevice: null,
        ),
      ),
    );
  }

  // ═══════════════════════════ Forecast tab ══════════════════════════════

  Widget _buildForecastTab() {
    final f = _filter;
    final today = dateOnly(HistoryClock.instance.now());
    final yesterday = today.subtract(const Duration(days: 1));
    final days = f.days;
    final horizon = days <= 10 ? 7 : (days <= 45 ? 30 : 90);
    final scoped = f.hasScope || (f.hasUtility && f.utilities.length < 3);

    final series = dailySeries(f, _allRows, yesterday);
    final daily = series.values;

    final header = _buildHeader('Next $horizon days',
        'From ${_fmtDate(today)} · ${_scopeLabel(f)} · based on history to ${_fmtDate(yesterday)}');

    final window = daily.length > 90 ? daily.sublist(daily.length - 90) : daily;
    final arima = _arimaModel(window, horizon);
    final compareKey = scoped ? null : _compareModel;
    final compareColor = compareKey == 'lstm'
        ? const Color(0xFFA15208)
        : const Color(0xFF2E669E);
    final compareModel = compareKey == null
        ? null
        : _remoteModel(compareKey, compareKey == 'lstm' ? 'LSTM' : 'XGBoost',
            compareColor, horizon, !scoped);

    final best = _bestModel(arima, compareModel);
    final arimaTotal =
        (arima.values ?? const []).fold<double>(0, (a, b) => a + b);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      header,
      const SizedBox(height: 4),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _palette.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Expected energy',
                style:
                    AppTextStyles.caption.copyWith(color: AppColors.inkMuted)),
            if (best == 'arima') ...[
              const SizedBox(width: 6),
              Text('★ ARIMA · best',
                  style: AppTextStyles.captionSmall.copyWith(
                      color: AppColors.warningText,
                      fontWeight: FontWeight.w700)),
            ],
          ]),
          const SizedBox(height: 4),
          Text.rich(TextSpan(children: [
            TextSpan(
                text: _fmtKwh(arimaTotal),
                style: AppTextStyles.displayTabular
                    .copyWith(color: AppColors.ink)),
            TextSpan(
                text: ' kWh',
                style:
                    AppTextStyles.subtitle.copyWith(color: AppColors.inkMuted)),
          ])),
          const SizedBox(height: 4),
          Text.rich(TextSpan(children: [
            TextSpan(
                text: 'About ',
                style:
                    AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
            TextSpan(
                text: _fmtMoney(arimaTotal * _electricityRate),
                style: AppTextStyles.bodySm.copyWith(
                    color: AppColors.ink, fontWeight: FontWeight.w700)),
            TextSpan(
                text:
                    ' on the bill at ₱${_electricityRate.toStringAsFixed(2)} per kWh',
                style:
                    AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
          ])),
        ]),
      ),
      const SizedBox(height: 28),
      _sectionHead(scoped ? 'Forecast model' : 'Compare models',
          scoped ? 'ARIMA for this scope' : 'ARIMA against one other model'),
      const SizedBox(height: 12),
      if (scoped)
        _noteBox(
          _lockCode != null
              ? 'XGBoost and LSTM are trained on campus totals only, so ARIMA is the forecast for ${_buildingName(_lockCode!)}.'
              : 'XGBoost and LSTM are trained on the whole campus. Clear the building and utility filters to compare them.',
        )
      else
        AppSegmentedControl(
          segments: const [
            AppSegment(label: 'XGBoost'),
            AppSegment(label: 'LSTM')
          ],
          selectedIndex: _compareModel == 'lstm' ? 1 : 0,
          onChanged: (i) =>
              setState(() => _compareModel = i == 1 ? 'lstm' : 'xgboost'),
          palette: _palette,
        ),
      const SizedBox(height: 12),
      _buildForecastChart(arima, compareModel, today, horizon),
      const SizedBox(height: 28),
      _buildForecastComparison(arima, compareModel, arimaTotal, horizon, best),
      const SizedBox(height: 24),
      _noteBox(
        'How to read this. Error is MAPE, the average % a model missed by over the last 14 days. '
        'Lower is better. The forecast length follows your time range: up to 10 days → 7, up to 45 → 30, longer → 90.',
        icon: Icons.help_outline,
      ),
    ]);
  }

  Widget _noteBox(String text, {IconData icon = Icons.info_outline}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _palette.line),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: _palette.dark),
        const SizedBox(width: 10),
        Expanded(
            child: Text(text,
                style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid))),
      ]),
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String _fmtDate(DateTime d) => '${_months[d.month - 1]} ${d.day}';

  _ModelResult _arimaModel(List<double> window, int horizon) {
    if (window.length < 2) {
      return const _ModelResult(
          key: 'arima',
          name: 'ARIMA',
          unavailable: 'Needs at least 2 days of daily history.');
    }
    return _ModelResult(
      key: 'arima',
      name: 'ARIMA',
      values: arimaForecast(window, horizon),
      error: backtest(window, (y, h) => arimaForecast(y, h)),
    );
  }

  _ModelResult _remoteModel(
      String key, String name, Color color, int horizon, bool applies) {
    if (!applies) {
      return _ModelResult(
        key: key,
        name: name,
        color: color,
        unavailable:
            '$name is trained on campus-wide totals only. Clear the Scope and '
            'Utility filters to compare it with ARIMA.',
      );
    }
    if (!_remoteModelsLoaded) {
      return _ModelResult(
          key: key, name: name, color: color, unavailable: 'Loading…');
    }
    final raw = _remoteModels[key];
    if (raw is! Map || raw['values'] is! List) {
      return _ModelResult(
        key: key,
        name: name,
        color: color,
        unavailable:
            'Not trained yet. The daily training job publishes it once there are '
            'at least 35 days of history.',
      );
    }
    final values = [
      for (final v in raw['values'] as List) v is num ? v.toDouble() : 0.0
    ];
    final gen = raw['generated_at'];
    return _ModelResult(
      key: key,
      name: name,
      color: color,
      values: values.take(horizon).toList(),
      error: ForecastError.fromMap(raw['backtest']),
      trainedAt:
          gen is num ? DateTime.fromMillisecondsSinceEpoch(gen.toInt()) : null,
    );
  }

  String _bestModel(_ModelResult arima, _ModelResult? compare) {
    var best = 'arima';
    final bestMape = arima.error?.mape;
    if (compare?.error != null && compare?.values != null) {
      if (bestMape == null || compare!.error!.mape < bestMape) {
        best = compare!.key;
      }
    }
    return best;
  }

  Widget _buildForecastChart(
      _ModelResult arima, _ModelResult? compare, DateTime today, int horizon) {
    final values = arima.values;
    if (values == null) {
      return Container(
        height: 200,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _palette.line)),
        child: Text(arima.unavailable ?? 'Not available.',
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
      );
    }
    final points = [
      for (var i = 0; i < values.length; i++)
        TrendPoint(
            _fmtDate(today.add(Duration(days: i + 1))),
            '${_fmtDate(today.add(Duration(days: i + 1)))} · ${values[i].toStringAsFixed(1)} kWh',
            values[i])
    ];
    final compareValues = compare?.values;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 16, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _palette.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        WebTrendChart(
          points: points,
          bars: false,
          color: _palette.dark,
          height: 220,
          compare:
              compareValues != null && compareValues.length == points.length
                  ? compareValues
                  : null,
          compareColor: compare?.color ?? const Color(0xFF8A9A90),
          selected: _forecastSelected,
          onSelect: (i) => setState(() => _forecastSelected = i),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 16, runSpacing: 4, children: [
          _legendItem(_palette.dark, false, 'ARIMA · next $horizon days'),
          if (compare != null && compare.values != null)
            _legendItem(compare.color ?? const Color(0xFF8A9A90), true,
                '${compare.name} · same days'),
        ]),
      ]),
    );
  }

  Widget _buildForecastComparison(_ModelResult arima, _ModelResult? compare,
      double arimaTotal, int horizon, String best) {
    if (compare == null || compare.values == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionHead('ARIMA details', 'Next $horizon days'),
        const SizedBox(height: 12),
        _modelColumn(arima, arimaTotal, true),
      ]);
    }
    final compareTotal = compare.values!.fold<double>(0, (a, b) => a + b);
    final pctDiff =
        arimaTotal <= 0 ? 0.0 : (compareTotal - arimaTotal) / arimaTotal * 100;
    final errDiff = (compare.error?.mape ?? 0) - (arima.error?.mape ?? 0);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionHead('Side by side', 'Next $horizon days'),
      const SizedBox(height: 12),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: _modelColumn(arima, arimaTotal, best == 'arima')),
        const SizedBox(width: 12),
        Expanded(
            child: _modelColumn(compare, compareTotal, best == compare.key)),
      ]),
      const SizedBox(height: 16),
      _noteBox(
        '${compare.name} expects ${pctDiff.abs().toStringAsFixed(1)}% ${pctDiff >= 0 ? 'more' : 'less'} '
        'energy than ARIMA (${pctDiff >= 0 ? '+' : '−'}${_fmtMoney((compareTotal - arimaTotal).abs() * _electricityRate)}). '
        'Its error is ${errDiff.abs().toStringAsFixed(1)} points ${errDiff >= 0 ? 'higher' : 'lower'}, so '
        '${best == 'arima' ? 'ARIMA stays' : '${compare.name} looks like'} the better guess.',
        icon: Icons.insights_outlined,
      ),
    ]);
  }

  Widget _modelColumn(_ModelResult m, double total, bool isBest) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: isBest ? _palette.dark : _palette.line,
            width: isBest ? 1.5 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                  color: m.color ?? _palette.dark,
                  borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 8),
          Expanded(
              child: Text(m.name,
                  style:
                      AppTextStyles.subtitle.copyWith(color: AppColors.ink))),
          if (isBest)
            const Text('★',
                style: TextStyle(
                    color: AppColors.warningText, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 10),
        _mrow('Energy', '${_fmtKwh(total)} kWh'),
        _mrow('Est. bill', _fmtMoney(total * _electricityRate)),
        _mrow('Error',
            m.error == null ? '—' : '${m.error!.mape.toStringAsFixed(1)}%'),
        _mrow('Trained', m.trainedAt == null ? '—' : _ago(m.trainedAt!)),
      ]),
    );
  }

  Widget _mrow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label,
              style: AppTextStyles.captionSmall
                  .copyWith(color: AppColors.inkMuted)),
          Text(value,
              style: AppTextStyles.bodySm
                  .copyWith(color: AppColors.ink, fontWeight: FontWeight.w700)),
        ]),
      );

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inHours < 1) return '<1h ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  // ══════════════════════════ Filter sheets ══════════════════════════════

  void _openFiltersHub() {
    final f = _filter;
    final rows = [
      ('range', Icons.date_range, 'Time range', f.rangeName),
      ('group', Icons.bar_chart, 'Group by', f.group.label),
      ('scope', Icons.apartment, 'Scope', _scopeLabel(f)),
      ('util', Icons.bolt, 'Utility', f.utilityName),
      (
        'more',
        Icons.tune,
        'Compare & more',
        (f.compare != CompareMode.off
                ? (f.compare == CompareMode.previous
                    ? 'vs previous period'
                    : 'vs last year')
                : 'No comparison') +
            (f.dayType != DayType.all
                ? ' · ${f.dayType == DayType.weekday ? 'Weekdays' : 'Weekends'}'
                : '') +
            (f.metric == ValueMetric.cost ? ' · Cost' : ''),
      ),
    ];
    showAppBottomSheet(
      context,
      builder: (ctx) => BottomSheetScaffold(
        title: 'Filters',
        palette: _palette,
        headerAction: AppTextButton(
            label: 'Clear all',
            onPressed: () {
              Navigator.pop(ctx);
              _resetAll();
            },
            palette: _palette),
        body: Column(children: [
          for (final r in rows)
            InkWell(
              onTap: () {
                Navigator.pop(ctx);
                _openFilterSheet(r.$1);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: _palette.line))),
                child: Row(children: [
                  OutlineIconBox(icon: r.$2, palette: _palette),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r.$3,
                              style: AppTextStyles.caption
                                  .copyWith(color: AppColors.inkMuted)),
                          Text(r.$4,
                              style: AppTextStyles.subtitle
                                  .copyWith(color: AppColors.ink)),
                        ]),
                  ),
                  const Icon(Icons.chevron_right, color: AppColors.inkMuted),
                ]),
              ),
            ),
        ]),
        footer: AppPrimaryButton(
            label: 'Done',
            onPressed: () => Navigator.pop(ctx),
            palette: _palette,
            expand: true),
      ),
    );
  }

  void _openFilterSheet(String kind) {
    showAppBottomSheet<AnalyticsFilter>(
      context,
      builder: (ctx) => _FilterSheetBody(
        kind: kind,
        initial: _filter,
        palette: _palette,
        lockCode: _lockCode,
        lockedBuildingName:
            _lockCode == null ? null : _buildingName(_lockCode!),
        buildingCodes: _scopeBuildingCodes(),
        buildingFloors: _buildingFloors,
        devicesFor: (code, floor, room) => _meta.values
            .where((m) =>
                m.building == code &&
                (floor == 0 || m.floor == floor) &&
                (room.isEmpty || m.room == room))
            .toList(),
        roomsFor: (code, floor) => {
          for (final m in _meta.values)
            if (m.building == code &&
                (floor == 0 || m.floor == floor) &&
                m.room.isNotEmpty)
              m.room,
        }.toList()
          ..sort(),
      ),
    ).then((result) {
      if (result == null) return;
      setState(() {
        _filter = _lockApplied(result.withValidGroup());
        _trendSelected = null;
      });
    });
  }

  // ── Excel export (unchanged behavior from the pre-redesign screen; reads
  // the legacy `history/{daily,weekly,monthly,yearly}` aggregate node fresh
  // via `.get()`, independent of the per-device model used above) ─────────

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  Map<String, dynamic> _pickRangeNode(
      Map<String, dynamic> root, String targetRange) {
    final direct = root[targetRange];
    if (direct is Map) {
      final directMap = Map<String, dynamic>.from(direct);
      if (_matchingKeyCount(directMap, targetRange) > 0) return directMap;
    }
    return <String, dynamic>{};
  }

  int _matchingKeyCount(Map<String, dynamic> node, String range) {
    int count = 0;
    for (final k in node.keys) {
      if (_isExpectedKeyForRange(k, range)) count++;
    }
    return count;
  }

  bool _isExpectedKeyForRange(String key, String range) {
    switch (range) {
      case 'daily':
        return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(key);
      case 'weekly':
        return RegExp(r'^\d{4}-W\d{2}$').hasMatch(key);
      case 'monthly':
        return RegExp(r'^\d{4}-\d{2}$').hasMatch(key);
      case 'yearly':
        return RegExp(r'^\d{4}$').hasMatch(key);
      default:
        return false;
    }
  }

  DateTime? _rawEntryTimestamp(Map<String, dynamic> entry, String fallbackKey) {
    final rawTs = entry['ts'] ?? entry['last_update'] ?? entry['timestamp'];
    if (rawTs is num) return DateTime.fromMillisecondsSinceEpoch(rawTs.toInt());
    if (rawTs is String) {
      final asInt = int.tryParse(rawTs);
      if (asInt != null) return DateTime.fromMillisecondsSinceEpoch(asInt);
      return DateTime.tryParse(rawTs);
    }
    final prefix = fallbackKey.contains('_')
        ? fallbackKey.substring(0, fallbackKey.indexOf('_'))
        : fallbackKey;
    final keyTs = int.tryParse(prefix);
    if (keyTs != null) return DateTime.fromMillisecondsSinceEpoch(keyTs);
    return null;
  }

  String _rangeLabel(DateTime timestamp, String rangeKey) {
    switch (rangeKey) {
      case 'daily':
        return '${timestamp.year}-${_pad(timestamp.month)}-${_pad(timestamp.day)}';
      case 'weekly':
        return '${timestamp.year}-W${_pad(_isoWeek(timestamp))}';
      case 'monthly':
        return '${timestamp.year}-${_pad(timestamp.month)}';
      case 'yearly':
        return '${timestamp.year}';
      default:
        return '${timestamp.year}-${_pad(timestamp.month)}-${_pad(timestamp.day)}';
    }
  }

  List<Map<String, dynamic>> _parseRangeEntries(
      Map<String, dynamic> root, String rangeKey,
      [Set<String>? deleted]) {
    final deletedEntries = deleted ?? const <String>{};
    final directRangeNode = root[rangeKey];
    final hasDirectRangeNode = directRangeNode is Map &&
        _matchingKeyCount(
                Map<String, dynamic>.from(directRangeNode), rangeKey) >
            0;
    final data = hasDirectRangeNode
        ? Map<String, dynamic>.from(directRangeNode)
        : _pickRangeNode(root, rangeKey);
    final list = <Map<String, dynamic>>[];

    data.forEach((key, val) {
      if (val is! Map) return;
      if (deletedEntries.contains(key)) return;
      final entry = Map<String, dynamic>.from(val);
      list.add({
        'label': key,
        'kwh': _asDouble(entry['kwh'] ?? entry['total_kwh']),
        'cost': _asDouble(entry['cost'] ?? entry['total_cost']),
      });
    });

    if (list.isNotEmpty || hasDirectRangeNode) {
      list.sort(
          (a, b) => a['label'].toString().compareTo(b['label'].toString()));
      return list;
    }

    final rawRoot = root['raw'];
    if (rawRoot is! Map) return list;

    final grouped = <String, Map<String, dynamic>>{};
    final rawMap = Map<String, dynamic>.from(rawRoot);

    rawMap.forEach((key, val) {
      if (val is! Map) return;
      final entry = Map<String, dynamic>.from(val);
      final timestamp = _rawEntryTimestamp(entry, key.toString());
      if (timestamp == null) return;
      final label = _rangeLabel(timestamp, rangeKey);
      final kwh = _asDouble(entry['kwh']);
      final cost = _asDouble(entry['cost']);
      final bucket = grouped.putIfAbsent(
          label, () => {'label': label, 'kwh': 0.0, 'cost': 0.0});
      bucket['kwh'] = (bucket['kwh'] as double) + kwh;
      bucket['cost'] = (bucket['cost'] as double) + cost;
    });

    final groupedList = grouped.values.toList()
      ..sort((a, b) => a['label'].toString().compareTo(b['label'].toString()));
    return groupedList;
  }

  String _levelIndicator(double value, double average) {
    if (average <= 0) return 'Low';
    if (value >= average * 1.20) return 'High';
    if (value >= average * 0.85) return 'Normal';
    return 'Low';
  }

  String _trendIndicator(double value, double? previousValue) {
    if (previousValue == null) return 'Baseline';
    if (previousValue == 0)
      return value > 0 ? 'Increasing (+100.0%)' : 'Stable (0.0%)';
    final deltaPct = ((value - previousValue) / previousValue) * 100;
    if (deltaPct >= 5) return 'Increasing (+${deltaPct.toStringAsFixed(1)}%)';
    if (deltaPct <= -5) return 'Decreasing (${deltaPct.toStringAsFixed(1)}%)';
    return 'Stable (${deltaPct.toStringAsFixed(1)}%)';
  }

  String _clusterAnalysis(String level, String trend) {
    final levelText = level == 'High'
        ? 'High consumption cluster'
        : level == 'Normal'
            ? 'Moderate consumption cluster'
            : 'Lower consumption cluster';
    final trendText = trend.startsWith('Increasing')
        ? 'with rising usage vs previous cluster'
        : trend.startsWith('Decreasing')
            ? 'with decreasing usage vs previous cluster'
            : 'with stable usage vs previous cluster';
    return '$levelText $trendText.';
  }

  Future<void> _exportOrganizedXlsx() async {
    setState(() => _exporting = true);

    try {
      final snapshot = await FirebaseDatabase.instance.ref('history').get();
      final raw = snapshot.value;
      if (raw is! Map) {
        if (mounted) TopToast.threshold(context, 'No history data to export.');
        return;
      }

      final historyRoot = Map<String, dynamic>.from(raw);

      const exportRanges = ['daily', 'weekly', 'monthly', 'yearly'];
      final exportDeletedSnapshots = await Future.wait(exportRanges.map(
          (range) =>
              FirebaseDatabase.instance.ref('history/deleted/$range').get()));
      final deletedMap = <String, Set<String>>{};
      for (var i = 0; i < exportRanges.length; i++) {
        final deleted = <String>{};
        final value = exportDeletedSnapshots[i].value;
        if (value is Map) deleted.addAll(Map<String, dynamic>.from(value).keys);
        deletedMap[exportRanges[i]] = deleted;
      }

      final clustered = <String, List<Map<String, dynamic>>>{
        'yearly': _parseRangeEntries(
            historyRoot, 'yearly', deletedMap['yearly'] ?? {}),
        'monthly': _parseRangeEntries(
            historyRoot, 'monthly', deletedMap['monthly'] ?? {}),
        'weekly': _parseRangeEntries(
            historyRoot, 'weekly', deletedMap['weekly'] ?? {}),
        'daily':
            _parseRangeEntries(historyRoot, 'daily', deletedMap['daily'] ?? {}),
      };

      final hasData = clustered.values.any((list) => list.isNotEmpty);
      if (!hasData) {
        if (mounted) TopToast.threshold(context, 'No history data to export.');
        return;
      }

      final workbook = xlsio.Workbook();

      xlsio.Style makeStyle(String name,
          {bool bold = false, String? bg, String? fg}) {
        final style = workbook.styles.add(name);
        style.bold = bold;
        if (bg != null) style.backColor = bg;
        if (fg != null) style.fontColor = fg;
        return style;
      }

      final titleStyle =
          makeStyle('title_style', bold: true, bg: '#1A5C35', fg: '#FFFFFF');
      final headerStyle =
          makeStyle('header_style', bold: true, bg: '#2E9E52', fg: '#FFFFFF');
      final redStyle = makeStyle('red_indicator_style',
          bold: true, bg: '#C0392B', fg: '#FFFFFF');
      final amberStyle = makeStyle('amber_indicator_style',
          bold: true, bg: '#F5B041', fg: '#1F2937');
      final greenStyle = makeStyle('green_indicator_style',
          bold: true, bg: '#1E8449', fg: '#FFFFFF');
      final blueStyle = makeStyle('blue_indicator_style',
          bold: true, bg: '#2874A6', fg: '#FFFFFF');

      void writeRow(xlsio.Worksheet sheet, int row, List<String> values,
          {xlsio.Style? style}) {
        for (var c = 0; c < values.length; c++) {
          final range = sheet.getRangeByIndex(row, c + 1);
          range.setText(values[c]);
          if (style != null) range.cellStyle = style;
        }
      }

      void autoFitRange(xlsio.Worksheet sheet, int startCol, int endCol) {
        for (var c = startCol; c <= endCol; c++) {
          sheet.autoFitColumn(c);
        }
      }

      final now = DateTime.now();
      final generatedAt =
          '${now.year}-${_pad(now.month)}-${_pad(now.day)} ${_pad(now.hour)}:${_pad(now.minute)}';

      final overview = workbook.worksheets[0];
      overview.name = 'Overview';
      var r = 1;
      writeRow(overview, r++, ['SmartPowerSwitch Organized Energy Report'],
          style: titleStyle);
      writeRow(overview, r++, ['Generated', generatedAt]);
      writeRow(overview, r++, ['']);
      writeRow(
          overview,
          r++,
          [
            'Range',
            'Clusters',
            'Total kWh',
            'Total Cost (PHP)',
            'Avg kWh/Cluster',
            'Peak Cluster',
            'Peak kWh'
          ],
          style: headerStyle);

      for (final key in ['yearly', 'monthly', 'weekly', 'daily']) {
        final entries = clustered[key] ?? const <Map<String, dynamic>>[];
        if (entries.isEmpty) {
          writeRow(overview, r++, [
            _capitalizeFirst(key),
            '0',
            '0.00',
            '0.00',
            '0.00',
            '-',
            '0.00'
          ]);
          continue;
        }
        final totalKwh =
            entries.fold<double>(0.0, (sum, e) => sum + (e['kwh'] as double));
        final totalCost =
            entries.fold<double>(0.0, (sum, e) => sum + (e['cost'] as double));
        final avgKwh = totalKwh / entries.length;
        final peak = entries.reduce(
            (a, b) => (a['kwh'] as double) >= (b['kwh'] as double) ? a : b);

        writeRow(overview, r++, [
          _capitalizeFirst(key),
          '${entries.length}',
          totalKwh.toStringAsFixed(2),
          totalCost.toStringAsFixed(2),
          avgKwh.toStringAsFixed(2),
          peak['label'].toString(),
          (peak['kwh'] as double).toStringAsFixed(2),
        ]);
      }

      writeRow(overview, r++, ['']);
      writeRow(overview, r++, ['Indicator Legend'], style: headerStyle);
      final redLegendRow = r;
      writeRow(overview, r++, ['High', 'High consumption']);
      final amberLegendRow = r;
      writeRow(overview, r++, ['Normal', 'Moderate consumption']);
      final greenLegendRow = r;
      writeRow(overview, r++, ['Low', 'Lower consumption']);
      final blueLegendRow = r;
      writeRow(overview, r++,
          ['Increasing/Decreasing/Stable', 'Trend versus previous cluster']);
      overview.getRangeByIndex(redLegendRow, 1).cellStyle = redStyle;
      overview.getRangeByIndex(amberLegendRow, 1).cellStyle = amberStyle;
      overview.getRangeByIndex(greenLegendRow, 1).cellStyle = greenStyle;
      overview.getRangeByIndex(blueLegendRow, 1).cellStyle = blueStyle;
      writeRow(overview, r++, ['']);
      writeRow(overview, r++, ['Device Status'], style: headerStyle);
      writeRow(overview, r++, ['Online Devices', '$_onlineCount']);
      writeRow(overview, r++, ['Offline Devices', '$_offlineCount']);
      autoFitRange(overview, 1, 7);

      for (final key in ['yearly', 'monthly', 'weekly', 'daily']) {
        final entries = clustered[key] ?? const <Map<String, dynamic>>[];
        final sheetName = '${_capitalizeFirst(key)} Data';
        final sheet = workbook.worksheets.addWithName(sheetName);
        var row = 1;

        writeRow(sheet, row++, ['${_capitalizeFirst(key)} Cluster Report'],
            style: titleStyle);
        writeRow(sheet, row++, ['Generated', generatedAt]);
        writeRow(sheet, row++, ['']);

        if (entries.isEmpty) {
          writeRow(sheet, row++, ['No data available.']);
          continue;
        }

        final totalKwh =
            entries.fold<double>(0.0, (sum, e) => sum + (e['kwh'] as double));
        final totalCost =
            entries.fold<double>(0.0, (sum, e) => sum + (e['cost'] as double));
        final avgKwh = totalKwh / entries.length;
        final peak = entries.reduce(
            (a, b) => (a['kwh'] as double) >= (b['kwh'] as double) ? a : b);

        writeRow(sheet, row++, ['Cluster count', '${entries.length}']);
        writeRow(
            sheet, row++, ['Total energy (kWh)', totalKwh.toStringAsFixed(2)]);
        writeRow(
            sheet, row++, ['Total cost (PHP)', totalCost.toStringAsFixed(2)]);
        writeRow(sheet, row++,
            ['Average energy per cluster (kWh)', avgKwh.toStringAsFixed(2)]);
        writeRow(sheet, row++, ['Peak cluster', peak['label'].toString()]);
        writeRow(sheet, row++, ['']);
        writeRow(
            sheet,
            row++,
            [
              'Cluster',
              'Energy (kWh)',
              'Cost (PHP)',
              'Share (%)',
              'Level Indicator',
              'Trend Indicator',
              'Cluster Analysis'
            ],
            style: headerStyle);

        double? previousKwh;
        for (final entry in entries) {
          final kwh = entry['kwh'] as double;
          final cost = entry['cost'] as double;
          final share = totalKwh == 0 ? 0.0 : (kwh / totalKwh) * 100;
          final level = _levelIndicator(kwh, avgKwh);
          final trend = _trendIndicator(kwh, previousKwh);
          final analysis = _clusterAnalysis(level, trend);

          writeRow(sheet, row++, [
            entry['label'].toString(),
            kwh.toStringAsFixed(2),
            cost.toStringAsFixed(2),
            share.toStringAsFixed(2),
            level,
            trend,
            analysis,
          ]);

          final indicatorRow = row - 1;
          final levelCell = sheet.getRangeByIndex(indicatorRow, 5);
          final trendCell = sheet.getRangeByIndex(indicatorRow, 6);
          if (level == 'High') levelCell.cellStyle = redStyle;
          if (level == 'Normal') levelCell.cellStyle = amberStyle;
          if (level == 'Low') levelCell.cellStyle = greenStyle;
          if (trend != 'Baseline') trendCell.cellStyle = blueStyle;

          previousKwh = kwh;
        }

        autoFitRange(sheet, 1, 7);
        sheet.getRangeByIndex(1, 7, row, 7).columnWidth = 52;
      }

      final buildingsSheet = workbook.worksheets.addWithName('Buildings');
      var br = 1;
      writeRow(buildingsSheet, br++, ['Building Breakdown'], style: titleStyle);
      writeRow(buildingsSheet, br++, ['Institute', 'Energy (kWh)'],
          style: headerStyle);
      final sortedBuildings = _buildingTotals.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in sortedBuildings) {
        writeRow(buildingsSheet, br++, [e.key, e.value.toStringAsFixed(2)]);
      }
      autoFitRange(buildingsSheet, 1, 2);

      final utilitiesSheet = workbook.worksheets.addWithName('Utilities');
      var ur = 1;
      writeRow(utilitiesSheet, ur++, ['Utility Breakdown'], style: titleStyle);
      writeRow(utilitiesSheet, ur++, ['Utility', 'Energy (kWh)'],
          style: headerStyle);
      final sortedUtilities = _utilityTotals.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in sortedUtilities) {
        writeRow(utilitiesSheet, ur++, [e.key, e.value.toStringAsFixed(2)]);
      }
      autoFitRange(utilitiesSheet, 1, 2);

      final bytes = workbook.saveAsStream();
      workbook.dispose();

      final xlsxName =
          'SmartPowerSwitch_Organized_Report_${now.year}-${_pad(now.month)}-${_pad(now.day)}_${_pad(now.hour)}-${_pad(now.minute)}.xlsx';

      await Share.shareXFiles(
        [
          XFile.fromData(
            Uint8List.fromList(bytes),
            mimeType:
                'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            name: xlsxName,
          )
        ],
        subject: 'SmartPowerSwitch Organized Energy Report',
      );
    } catch (e) {
      if (mounted) TopToast.error(context, 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
  int _isoWeek(DateTime date) {
    final startOfYear = DateTime(date.year, 1, 1);
    final firstMonday = startOfYear.weekday;
    final dayOfYear = date.difference(startOfYear).inDays + 1;
    final weekNumber = ((dayOfYear + firstMonday - 2) / 7).ceil();
    return weekNumber < 1 ? 1 : weekNumber;
  }

  String _capitalizeFirst(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();
}

// ═══════════════════════════ Small helper widgets ═══════════════════════

class _ModelResult {
  final String key;
  final String name;
  final Color? color;
  final List<double>? values;
  final ForecastError? error;
  final DateTime? trainedAt;
  final String? unavailable;

  const _ModelResult({
    required this.key,
    required this.name,
    this.color,
    this.values,
    this.error,
    this.trainedAt,
    this.unavailable,
  });
}

class _FiltersButton extends StatelessWidget {
  const _FiltersButton(
      {required this.count, required this.onTap, required this.palette});

  final int count;
  final VoidCallback onTap;
  final InstitutePalette palette;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFB9D6C3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.tune, size: 20, color: palette.dark),
          const SizedBox(width: 6),
          Text('Filters',
              style: AppTextStyles.label.copyWith(color: palette.dark)),
          if (count > 0) ...[
            const SizedBox(width: 6),
            Container(
              constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
              padding: const EdgeInsets.symmetric(horizontal: 5),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: palette.dark,
                  borderRadius: BorderRadius.circular(999)),
              child: Text('$count',
                  style: const TextStyle(
                      fontFamily: AppFonts.family,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ),
          ],
        ]),
      ),
    );
  }
}

class _LegendLinePainter extends CustomPainter {
  final Color color;
  final bool dashed;
  _LegendLinePainter(this.color, this.dashed);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final y = size.height / 2;
    if (!dashed) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      return;
    }
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(
          Offset(x, y), Offset((x + 4).clamp(0, size.width), y), paint);
      x += 7;
    }
  }

  @override
  bool shouldRepaint(covariant _LegendLinePainter old) =>
      old.color != color || old.dashed != dashed;
}

/// Radio-style option row used by the time-range / group-by filter sheets.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.selected,
    required this.label,
    this.caption,
    this.trailing,
    this.disabled = false,
    this.onTap,
    required this.palette,
  });

  final bool selected;
  final String label;
  final String? caption;
  final Widget? trailing;
  final bool disabled;
  final VoidCallback? onTap;
  final InstitutePalette palette;

  @override
  Widget build(BuildContext context) {
    final content = Opacity(
      opacity: disabled ? 0.45 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? palette.dark : AppColors.inkMuted),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                    child: Text(label,
                        style: AppTextStyles.subtitle
                            .copyWith(color: AppColors.ink))),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ]),
              if (caption != null) ...[
                const SizedBox(height: 2),
                Text(caption!,
                    style: AppTextStyles.captionSmall
                        .copyWith(color: AppColors.inkMuted)),
              ],
            ]),
          ),
        ]),
      ),
    );
    return disabled ? content : InkWell(onTap: onTap, child: content);
  }
}

typedef _DevicesFor = List<DeviceMeta> Function(
    String building, int floor, String room);
typedef _RoomsFor = List<String> Function(String building, int floor);

/// One filter sheet's body (time range / group by / scope / utility / more).
/// Edits a local draft; `Navigator.pop(draft)` on Apply, `pop(null)` on
/// Cancel -- mirrors the preview's "edit a draft, Apply commits" pattern.
class _FilterSheetBody extends StatefulWidget {
  const _FilterSheetBody({
    required this.kind,
    required this.initial,
    required this.palette,
    required this.lockCode,
    required this.lockedBuildingName,
    required this.buildingCodes,
    required this.buildingFloors,
    required this.devicesFor,
    required this.roomsFor,
  });

  final String kind;
  final AnalyticsFilter initial;
  final InstitutePalette palette;
  final String? lockCode;
  final String? lockedBuildingName;
  final List<String> buildingCodes;
  final Map<String, int> buildingFloors;
  final _DevicesFor devicesFor;
  final _RoomsFor roomsFor;

  @override
  State<_FilterSheetBody> createState() => _FilterSheetBodyState();
}

class _FilterSheetBodyState extends State<_FilterSheetBody> {
  late AnalyticsFilter _draft = widget.initial;

  String get _title => switch (widget.kind) {
        'range' => 'Time range',
        'group' => 'Group by',
        'scope' => 'Scope',
        'util' => 'Utility',
        _ => 'More filters',
      };

  void _clearThis() {
    setState(() {
      switch (widget.kind) {
        case 'range':
          _draft = _draft.withRange(RangePreset.last30);
        case 'group':
          _draft = _draft.copyWith(group: suggestedGroup(_draft.days));
        case 'scope':
          _draft = _draft.clearedScope();
          if (widget.lockCode != null) {
            _draft = _draft.copyWith(buildings: [widget.lockCode!]);
          }
        case 'util':
          _draft = _draft.copyWith(utilities: const []);
        default:
          _draft = _draft.copyWith(
              dayType: DayType.all,
              compare: CompareMode.off,
              metric: ValueMetric.kwh);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return BottomSheetScaffold(
      title: _title,
      palette: widget.palette,
      headerAction: AppTextButton(
          label: 'Clear', onPressed: _clearThis, palette: widget.palette),
      body: _body(),
      footer: BottomSheetFooter(
        palette: widget.palette,
        onCancel: () => Navigator.pop(context),
        onApply: () => Navigator.pop(context, _draft),
      ),
    );
  }

  Widget _body() {
    switch (widget.kind) {
      case 'range':
        return _rangeBody();
      case 'group':
        return _groupBody();
      case 'scope':
        return _scopeBody();
      case 'util':
        return _utilBody();
      default:
        return _moreBody();
    }
  }

  Widget _rangeBody() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final p in RangePreset.values)
        _OptionRow(
          palette: widget.palette,
          selected: _draft.range == p,
          label: p.label,
          caption: p == RangePreset.custom
              ? null
              : spanText(presetSpan(p, HistoryClock.instance.now())),
          onTap: () => setState(() {
            _draft = _draft.withRange(p, from: _draft.from, to: _draft.to);
          }),
        ),
      if (_draft.range == RangePreset.custom) ...[
        const SizedBox(height: 8),
        _calendar(),
      ],
    ]);
  }

  Widget _calendar() {
    final today = dateOnly(HistoryClock.instance.now());
    return Column(children: [
      RangeCalendar(
        initialStart: _draft.from,
        initialEnd: _draft.to,
        onRangeChanged: (r) {
          if (r == null) return;
          final start = r.start.isAfter(today) ? today : r.start;
          final end = r.end.isAfter(today) ? today : r.end;
          setState(() {
            _draft = _draft.withRange(RangePreset.custom, from: start, to: end);
          });
        },
        onDaySelected: (d) {
          if (d == null) return;
          final day = d.isAfter(today) ? today : d;
          setState(() => _draft =
              _draft.withRange(RangePreset.custom, from: day, to: day));
        },
      ),
      const SizedBox(height: 8),
      Text(
        _draft.from != null
            ? '${spanText(_draft.span())} · ${_draft.days} days'
            : 'Tap a start day, then an end day',
        style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted),
      ),
    ]);
  }

  Widget _groupBody() {
    final days = _draft.days;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final g in GroupBy.values)
        _OptionRow(
          palette: widget.palette,
          selected: _draft.group == g,
          label: g.label,
          disabled: !groupAllowed(g, days),
          caption: groupAllowed(g, days) ? null : groupDisabledReason(g),
          trailing: g == suggestedGroup(days)
              ? Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: widget.palette.line)),
                  child: Text('Suggested',
                      style: AppTextStyles.captionSmall
                          .copyWith(color: widget.palette.dark)),
                )
              : null,
          onTap: () => setState(() => _draft = _draft.copyWith(group: g)),
        ),
    ]);
  }

  Widget _scopeBody() {
    if (widget.lockCode != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: Colors.white,
              
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: widget.palette.line)),
          child: Row(children: [
            Icon(Icons.lock_outline, size: 18, color: widget.palette.dark),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Showing ${widget.lockedBuildingName} only. Narrow down by floor, room or device.',
                style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        ..._floorRoomDevice(widget.lockCode!),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Building',
          style: AppTextStyles.label.copyWith(color: AppColors.ink)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        AppFilterChip(
          label: 'All buildings',
          selected: _draft.buildings.isEmpty,
          palette: widget.palette,
          onTap: () => setState(() => _draft = _draft
              .copyWith(buildings: const [], floor: 0, room: '', device: '')),
        ),
        for (final code in widget.buildingCodes)
          AppFilterChip(
            label: code,
            selected: _draft.buildings.contains(code),
            palette: widget.palette,
            onTap: () => setState(() => _draft = _draft
                .copyWith(buildings: [code], floor: 0, room: '', device: '')),
          ),
      ]),
      if (_draft.buildings.isNotEmpty) ...[
        const SizedBox(height: 16),
        ..._floorRoomDevice(_draft.buildings.first),
      ] else ...[
        const SizedBox(height: 12),
        Text('Pick one building to narrow down to a floor, room or device.',
            style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
      ],
    ]);
  }

  List<Widget> _floorRoomDevice(String code) {
    final floors = widget.buildingFloors[code] ?? 1;
    final rooms = widget.roomsFor(code, _draft.floor);
    final devicesInRoom = widget.devicesFor(code, _draft.floor, _draft.room);
    return [
      Text('Floor', style: AppTextStyles.label.copyWith(color: AppColors.ink)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        AppFilterChip(
          label: 'All floors',
          selected: _draft.floor == 0,
          palette: widget.palette,
          onTap: () => setState(
              () => _draft = _draft.copyWith(floor: 0, room: '', device: '')),
        ),
        for (var i = 1; i <= floors; i++)
          AppFilterChip(
            label: 'Floor $i',
            selected: _draft.floor == i,
            palette: widget.palette,
            onTap: () => setState(
                () => _draft = _draft.copyWith(floor: i, room: '', device: '')),
          ),
      ]),
      const SizedBox(height: 16),
      Text('Room', style: AppTextStyles.label.copyWith(color: AppColors.ink)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        AppFilterChip(
          label: 'All rooms',
          selected: _draft.room.isEmpty,
          palette: widget.palette,
          onTap: () =>
              setState(() => _draft = _draft.copyWith(room: '', device: '')),
        ),
        for (final room in rooms)
          AppFilterChip(
            label: room,
            selected: _draft.room == room,
            palette: widget.palette,
            onTap: () => setState(
                () => _draft = _draft.copyWith(room: room, device: '')),
          ),
      ]),
      const SizedBox(height: 16),
      Text('Device', style: AppTextStyles.label.copyWith(color: AppColors.ink)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        AppFilterChip(
          label: 'All devices',
          selected: _draft.device.isEmpty,
          palette: widget.palette,
          onTap: () => setState(() => _draft = _draft.copyWith(device: '')),
        ),
        for (final d in devicesInRoom)
          AppFilterChip(
            label:
                '${d.utility == 'AC' ? 'Aircon' : d.utility}${_draft.room.isEmpty ? ' · ${d.room}' : ''}',
            selected: _draft.device == d.id,
            palette: widget.palette,
            onTap: () => setState(() => _draft = _draft.copyWith(device: d.id)),
          ),
      ]),
    ];
  }

  Widget _utilBody() {
    return Wrap(spacing: 8, runSpacing: 8, children: [
      AppFilterChip(
        label: 'All utilities',
        selected: _draft.utilities.isEmpty,
        palette: widget.palette,
        onTap: () =>
            setState(() => _draft = _draft.copyWith(utilities: const [])),
      ),
      for (final u in kUtilities)
        AppFilterChip(
          label: u,
          icon: u == 'AC'
              ? Icons.ac_unit
              : (u == 'Lights' ? Icons.lightbulb_outline : Icons.power),
          selected: _draft.utilities.contains(u),
          palette: widget.palette,
          onTap: () => setState(() {
            final list = [..._draft.utilities];
            if (list.contains(u)) {
              list.remove(u);
            } else {
              list.add(u);
            }
            _draft = _draft.copyWith(
                utilities: list.length == kUtilities.length ? const [] : list);
          }),
        ),
    ]);
  }

  Widget _seg<T>(String label, List<(T, String)> options, T value,
      ValueChanged<T> onChanged) {
    final index = options.indexWhere((o) => o.$1 == value);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AppTextStyles.label.copyWith(color: AppColors.ink)),
      const SizedBox(height: 8),
      AppSegmentedControl(
        segments: [for (final o in options) AppSegment(label: o.$2)],
        selectedIndex: index < 0 ? 0 : index,
        onChanged: (i) => onChanged(options[i].$1),
        palette: widget.palette,
      ),
      const SizedBox(height: 16),
    ]);
  }

  Widget _moreBody() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _seg<DayType>(
          'Day type',
          const [
            (DayType.all, 'All days'),
            (DayType.weekday, 'Weekdays'),
            (DayType.weekend, 'Weekends'),
          ],
          _draft.dayType,
          (v) => setState(() => _draft = _draft.copyWith(dayType: v))),
      Text('Time of day',
          style: AppTextStyles.label.copyWith(color: AppColors.ink)),
      const SizedBox(height: 8),
      Opacity(
        opacity: 0.5,
        child: IgnorePointer(
          child: AppSegmentedControl(
            segments: const [
              AppSegment(label: 'All day'),
              AppSegment(label: 'Class hours'),
              AppSegment(label: 'After hours'),
            ],
            selectedIndex: 0,
            onChanged: (_) {},
            palette: widget.palette,
          ),
        ),
      ),
      const SizedBox(height: 6),
      Text(
          'Class hours are 7:00 AM to 6:00 PM. Needs hourly readings; daily totals only for now.',
          style:
              AppTextStyles.captionSmall.copyWith(color: AppColors.inkMuted)),
      const SizedBox(height: 16),
      _seg<CompareMode>(
          'Compare with',
          const [
            (CompareMode.off, 'Off'),
            (CompareMode.previous, 'Previous'),
            (CompareMode.lastYear, 'Last year'),
          ],
          _draft.compare,
          (v) => setState(() => _draft = _draft.copyWith(compare: v))),
      if (_draft.compare != CompareMode.off) ...[
        Builder(builder: (context) {
          final cs = _draft.compareSpan();
          return Text(
            cs == null ? '' : '${spanText(_draft.span())} vs ${spanText(cs)}',
            style:
                AppTextStyles.captionSmall.copyWith(color: AppColors.inkMuted),
          );
        }),
        const SizedBox(height: 16),
      ],
      _seg<ValueMetric>(
          'Show values as',
          const [
            (ValueMetric.kwh, 'kWh'),
            (ValueMetric.cost, 'Cost (₱)'),
          ],
          _draft.metric,
          (v) => setState(() => _draft = _draft.copyWith(metric: v))),
    ]);
  }
}
