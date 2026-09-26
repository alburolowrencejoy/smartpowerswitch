import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_xlsio/xlsio.dart' as xlsio;
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import 'analytics/analytics_data.dart';
import 'analytics/analytics_filter.dart';
import 'analytics/analytics_filter_bar.dart';
import 'analytics/analytics_focus.dart';
import 'analytics/analytics_ui.dart';
import 'analytics/breakdown_panel.dart';
import 'analytics/utility_donut.dart';
import 'analytics/year_comparison.dart';
import 'web_forecast_cards.dart';
import 'history_trend_panel.dart';
import 'web_theme.dart';
import 'web_trend_chart.dart';
import '../../theme/app_fonts.dart';
import '../../services/history_clock.dart';
import '../../services/rate_timeline.dart';

/// Opens the device detail screen for a device.
typedef OpenDeviceCallback = void Function(
    String deviceId, String utility, String building, String room, int floor);

/// The desktop "Analytics" section: a filter bar (time range, grouping,
/// scope, utility, more), stat cards, the consumption trend, ARIMA vs
/// XGBoost / LSTM forecasts, the utility donut and top-consumers list with
/// click-through breakdowns, and the organized Excel export.
/// [HistoryScreen] itself is untouched -- this is an independent widget with
/// its own Firebase listeners so the mobile screen's behavior can never be
/// affected by desktop changes.
class HistoryScreenWeb extends StatefulWidget {
  /// Opens a device from the breakdown drawer / top-devices list.
  final OpenDeviceCallback? onOpenDevice;

  /// Set by a link (e.g. on the dashboard) to scroll to one section.
  final AnalyticsFocus? focus;

  const HistoryScreenWeb({super.key, this.onOpenDevice, this.focus});

  @override
  State<HistoryScreenWeb> createState() => _HistoryScreenWebState();
}

class _HistoryScreenWebState extends State<HistoryScreenWeb> {
  /// Survives this widget being disposed (switching tabs, opening a device
  /// from a breakdown), so the filters are still set when the user returns.
  static AnalyticsFilter _savedFilter = AnalyticsFilter.defaults;

  AnalyticsFilter _filter = _savedFilter.withValidGroup();

  /// The deleted-entries path of [_listenAll]; Analytics always reads the
  /// daily history now that the filter bar replaced the Daily/Monthly tabs.
  final String _range = 'daily';
  String _trendChartType = 'line';

  // ── Filtered range data (history/daily, queried by date key) ──────────
  StreamSubscription<DatabaseEvent>? _rangeSub;
  StreamSubscription<DatabaseEvent>? _compareSub;
  StreamSubscription<DatabaseEvent>? _buildingsSub;
  String? _rangeKey;
  String? _compareKey;
  Object? _rangeRaw;
  Object? _compareRaw;
  bool _rangeLoaded = false;
  Map<String, DeviceMeta> _meta = {};
  Map<String, BuildingInfo> _buildingInfo = {};

  // Forecast input, parsed from the full daily history and cached.
  Object? _fcSource;
  Set<String>? _fcDeleted;
  Map<String, DeviceMeta>? _fcMeta;
  List<UsageRow> _fcRows = const [];
  bool _exporting = false;

  /// True until the combined stream's first emission. Never reverts to
  /// true afterwards -- a fresh instance of this screen is the only
  /// legitimate reset.
  bool _isLoading = true;
  String? _errorText;
  bool _hasLoadedOnce = false;

  static const Duration _loadTimeout = Duration(seconds: 15);
  Timer? _timeoutTimer;

  StreamSubscription? _combinedSub;

  Map<String, dynamic> _historyRoot = {};
  Map<String, Set<String>> _deletedEntriesByRange = {
    'daily': {},
    'weekly': {},
    'monthly': {},
    'yearly': {},
  };

  Map<String, double> _utilityTotals = {};
  Map<String, double> _buildingTotals = {};
  int _onlineCount = 0;
  int _offlineCount = 0;
  double _electricityRate = 11.5;

  // ── Institute theming ──────────────────────────────────────────────────
  // This screen has no role/institute constructor params (it's pushed from
  // dashboard_web.dart with no arguments -- see DashboardWeb's IndexedStack),
  // so role/institute are hydrated directly from the signed-in user's own
  // record, mirroring mobile history_screen.dart's _hydrateSessionFromAuth.
  String _role = 'faculty';
  String? _institute;

  InstitutePalette get _palette =>
      InstituteTheme.resolve(_role, _institute).palette;

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
      });
    } catch (_) {
      // Keep existing role defaults if role hydration fails.
    }
  }

  @override
  void initState() {
    super.initState();
    _hydrateSessionFromAuth();
    _listenAll();
    _listenBuildings();
    _listenRange();
    widget.focus?.addListener(_scrollToFocus);
    RateHistory.instance.log.addListener(_onRateLog);
    // A link may have asked for a section before this page existed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocus());
  }

  @override
  void didUpdateWidget(covariant HistoryScreenWeb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focus != widget.focus) {
      oldWidget.focus?.removeListener(_scrollToFocus);
      widget.focus?.addListener(_scrollToFocus);
    }
  }

  // ── Jump to a section (links from the dashboard) ─────────────────────

  final _sectionKeys = {
    for (final s in AnalyticsSection.values) s: GlobalKey(),
  };

  /// Utilities and Top Consuming share one row, so they share its key.
  GlobalKey _keyFor(AnalyticsSection s) => _sectionKeys[
      s == AnalyticsSection.institutes ? AnalyticsSection.utilities : s]!;

  bool _scrolling = false;

  /// Scrolls to [HistoryScreenWeb.focus]'s section once it has been laid
  /// out (data may still be loading, so it waits up to ~3s), then clears
  /// the request.
  Future<void> _scrollToFocus() async {
    final focus = widget.focus;
    final section = focus?.value;
    if (section == null || _scrolling) return;
    _scrolling = true;
    try {
      for (var i = 0; i < 180 && mounted; i++) {
        await WidgetsBinding.instance.endOfFrame;
        final ctx = _keyFor(section).currentContext;
        if (ctx != null && ctx.mounted) {
          await Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeInOutCubic,
          );
          break;
        }
      }
    } finally {
      _scrolling = false;
      if (focus?.value == section) focus?.value = null;
    }
  }

  @override
  void dispose() {
    widget.focus?.removeListener(_scrollToFocus);
    RateHistory.instance.log.removeListener(_onRateLog);
    _timeoutTimer?.cancel();
    _combinedSub?.cancel();
    _rangeSub?.cancel();
    _compareSub?.cancel();
    _buildingsSub?.cancel();
    super.dispose();
  }

  // ── Filters ────────────────────────────────────────────────────────────

  void _setFilter(AnalyticsFilter f) {
    final next = f.withValidGroup();
    _savedFilter = next;
    setState(() {
      _filter = next;
      _listenRange();
    });
  }

  /// Building names and floor counts for the Scope panel and labels.
  void _listenBuildings() {
    _buildingsSub = FirebaseDatabase.instance.ref('buildings').onValue.listen(
        (e) {
      final raw = e.snapshot.value;
      final out = <String, BuildingInfo>{};
      if (raw is Map) {
        raw.forEach((code, v) {
          if (v is! Map) return;
          out[code.toString()] = BuildingInfo(
            code.toString(),
            (v['name'] ?? code).toString(),
            int.tryParse('${v['floors'] ?? 1}') ?? 1,
          );
        });
      }
      if (mounted) setState(() => _buildingInfo = out);
    }, onError: (_) {});
  }

  /// Queries only the selected dates of `history/daily` (and the compare
  /// period, if any). Re-subscribes only when those dates change.
  void _listenRange() {
    final today = HistoryClock.instance.now();
    final span = _filter.span(today);
    final key = '${dayKey(span.start)}..${dayKey(span.end)}';
    if (key != _rangeKey) {
      _rangeKey = key;
      _rangeSub?.cancel();
      // Callers rebuild right after (or this is initState).
      _rangeLoaded = false;
      _rangeSub = FirebaseDatabase.instance
          .ref('history/daily')
          .orderByKey()
          .startAt(dayKey(span.start))
          .endAt(dayKey(span.end))
          .onValue
          .listen((e) {
        if (!mounted) return;
        setState(() {
          _rangeRaw = e.snapshot.value;
          _rangeLoaded = true;
        });
      }, onError: (_) {
        if (mounted) setState(() => _rangeLoaded = true);
      });
    }

    final cs = _filter.compareSpan(today);
    final ck = cs == null ? null : '${dayKey(cs.start)}..${dayKey(cs.end)}';
    if (ck != _compareKey) {
      _compareKey = ck;
      _compareSub?.cancel();
      _compareSub = null;
      _compareRaw = null;
      if (cs != null) {
        _compareSub = FirebaseDatabase.instance
            .ref('history/daily')
            .orderByKey()
            .startAt(dayKey(cs.start))
            .endAt(dayKey(cs.end))
            .onValue
            .listen((e) {
          if (mounted) setState(() => _compareRaw = e.snapshot.value);
        }, onError: (_) {});
      }
    }
  }

  /// Clears the error state, resets the loading flag, and re-attaches the
  /// combined listener from scratch.
  void _retry() {
    setState(() {
      _errorText = null;
      _isLoading = true;
    });
    _timeoutTimer?.cancel();
    _combinedSub?.cancel();
    _listenAll();
  }

  // ── Data (ported from HistoryScreen, unchanged behavior) ─────────────────

  /// Combines this screen's 4 Firebase paths (electricity rate, devices,
  /// the active range's deleted-entries list, and the history root) into
  /// one subscription with a sticky merge, so a transient null/empty
  /// snapshot never blanks data that already loaded once. Re-created
  /// whenever [_range] changes since the deleted-entries path depends on it.
  void _listenAll() {
    _combinedSub?.cancel();
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(_loadTimeout, () {
      if (!mounted || _hasLoadedOnce) return;
      setState(() {
        _isLoading = false;
        _errorText =
            'Loading is taking too long. Check your connection and try again.';
      });
    });

    _combinedSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('settings/electricityRate').onValue,
      FirebaseDatabase.instance.ref('devices').onValue,
      FirebaseDatabase.instance.ref('history/deleted/$_range').onValue,
      FirebaseDatabase.instance.ref('history').onValue,
    ]).listen((events) {
      if (!mounted) return;
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      setState(() {
        _applyRate(events[0].snapshot.value);
        _applyDevices(events[1].snapshot.value);
        _applyDeleted(events[2].snapshot.value);
        _hasLoadedOnce = true;
        _isLoading = false;
        _errorText = null;
      });
      _updateHistoryDisplay();
    }, onError: (Object error) {
      if (!mounted || _hasLoadedOnce) return;
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      final text = error.toString().toLowerCase();
      final denied = text.contains('permission-denied') ||
          text.contains('permission_denied') ||
          text.contains('permission');
      setState(() {
        _isLoading = false;
        _errorText = denied
            ? 'You do not have permission to view analytics.'
            : 'Failed to load analytics.';
      });
    });
  }

  void _applyRate(Object? raw) {
    final rate = (raw as num?)?.toDouble();
    if (rate == null) return;
    _electricityRate = rate;
  }

  void _applyDevices(Object? raw) {
    if (raw is! Map) return;

    final data = Map<String, dynamic>.from(raw);
    final Map<String, double> utilityTotals = {};
    final Map<String, double> buildingTotals = {};
    int online = 0, offline = 0;

    data.forEach((id, val) {
      if (val is! Map) return;
      final device = Map<String, dynamic>.from(val);
      final utility = (device['utility'] ?? 'Unknown').toString();
      final building = (device['building'] ?? 'Unknown').toString();
      final kwh = (device['kwh'] ?? 0.0) as num;
      final lastSeen = device['last_seen'];
      final isOnline = lastSeen != null &&
          lastSeen != 0 &&
          DateTime.now()
                  .difference(
                      DateTime.fromMillisecondsSinceEpoch(lastSeen as int))
                  .inMinutes <
              2;

      utilityTotals[utility] = (utilityTotals[utility] ?? 0) + kwh.toDouble();
      buildingTotals[building] =
          (buildingTotals[building] ?? 0) + kwh.toDouble();
      isOnline ? online++ : offline++;
    });

    _utilityTotals = utilityTotals;
    _buildingTotals = buildingTotals;
    _meta = DeviceMeta.parseAll(data);
    _onlineCount = online;
    _offlineCount = offline;
  }

  void _applyDeleted(Object? raw) {
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      final deleted = Set<String>.from(map.keys);
      _deletedEntriesByRange[_range] = deleted;
    } else if (_isLoading) {
      _deletedEntriesByRange[_range] = {};
    }
  }

  Future<void> _updateHistoryDisplay() async {
    if (!mounted) return;
    final snapshot = await FirebaseDatabase.instance.ref('history').get();
    if (snapshot.value is! Map) {
      // A transient null read (reconnect blip) must never blank a history
      // view that already loaded once -- only accept "no data" before the
      // first successful load.
      if (mounted && _isLoading) {
        setState(() => _historyRoot = {});
      }
      return;
    }

    final root = Map<String, dynamic>.from(snapshot.value as Map);
    const ranges = ['daily', 'weekly', 'monthly', 'yearly'];
    final deletedSnapshots = await Future.wait(ranges.map((range) =>
        FirebaseDatabase.instance.ref('history/deleted/$range').get()));
    final deletedMap = <String, Set<String>>{};
    for (var i = 0; i < ranges.length; i++) {
      final deleted = <String>{};
      final value = deletedSnapshots[i].value;
      if (value is Map) {
        deleted.addAll(Map<String, dynamic>.from(value).keys);
      }
      deletedMap[ranges[i]] = deleted;
    }

    if (!mounted) return;
    setState(() {
      _historyRoot = root;
      _deletedEntriesByRange = deletedMap;
    });
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

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
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
          label,
          () => {
                'label': label,
                'kwh': 0.0,
                'cost': 0.0,
              });
      bucket['kwh'] = (bucket['kwh'] as double) + kwh;
      bucket['cost'] = (bucket['cost'] as double) + cost;
    });

    final groupedList = grouped.values.toList()
      ..sort((a, b) => a['label'].toString().compareTo(b['label'].toString()));
    return groupedList;
  }

  DateTime? _rawEntryTimestamp(Map<String, dynamic> entry, String fallbackKey) {
    final rawTs = entry['ts'] ?? entry['last_update'] ?? entry['timestamp'];
    if (rawTs is num) {
      return DateTime.fromMillisecondsSinceEpoch(rawTs.toInt());
    }
    if (rawTs is String) {
      final asInt = int.tryParse(rawTs);
      if (asInt != null) {
        return DateTime.fromMillisecondsSinceEpoch(asInt);
      }
      return DateTime.tryParse(rawTs);
    }

    final prefix = fallbackKey.contains('_')
        ? fallbackKey.substring(0, fallbackKey.indexOf('_'))
        : fallbackKey;
    final keyTs = int.tryParse(prefix);
    if (keyTs != null) {
      return DateTime.fromMillisecondsSinceEpoch(keyTs);
    }
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

  String _levelIndicator(double value, double average) {
    if (average <= 0) return 'Low';
    if (value >= average * 1.20) return 'High';
    if (value >= average * 0.85) return 'Normal';
    return 'Low';
  }

  String _trendIndicator(double value, double? previousValue) {
    if (previousValue == null) return 'Baseline';
    if (previousValue == 0) {
      return value > 0 ? 'Increasing (+100.0%)' : 'Stable (0.0%)';
    }
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
        if (mounted) {
          TopToast.threshold(context, 'No history data to export.');
        }
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
        if (value is Map) {
          deleted.addAll(Map<String, dynamic>.from(value).keys);
        }
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
        if (mounted) {
          TopToast.threshold(context, 'No history data to export.');
        }
        return;
      }

      final workbook = xlsio.Workbook();

      xlsio.Style makeStyle(
        String name, {
        bool bold = false,
        String? bg,
        String? fg,
      }) {
        final style = workbook.styles.add(name);
        style.bold = bold;
        if (bg != null) style.backColor = bg;
        if (fg != null) style.fontColor = fg;
        return style;
      }

      final titleStyle = makeStyle(
        'title_style',
        bold: true,
        bg: '#1A5C35',
        fg: '#FFFFFF',
      );
      final headerStyle = makeStyle(
        'header_style',
        bold: true,
        bg: '#2E9E52',
        fg: '#FFFFFF',
      );
      final redStyle = makeStyle(
        'red_indicator_style',
        bold: true,
        bg: '#C0392B',
        fg: '#FFFFFF',
      );
      final amberStyle = makeStyle(
        'amber_indicator_style',
        bold: true,
        bg: '#F5B041',
        fg: '#1F2937',
      );
      final greenStyle = makeStyle(
        'green_indicator_style',
        bold: true,
        bg: '#1E8449',
        fg: '#FFFFFF',
      );
      final blueStyle = makeStyle(
        'blue_indicator_style',
        bold: true,
        bg: '#2874A6',
        fg: '#FFFFFF',
      );

      void writeRow(
        xlsio.Worksheet sheet,
        int row,
        List<String> values, {
        xlsio.Style? style,
      }) {
        for (var c = 0; c < values.length; c++) {
          final range = sheet.getRangeByIndex(row, c + 1);
          range.setText(values[c]);
          if (style != null) {
            range.cellStyle = style;
          }
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
      if (mounted) {
        TopToast.error(context, 'Export failed: $e');
      }
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

  // ── Build (desktop grid layout) ───────────────────────────────────────────

  /// Days of history a scope needs before it gets a forecast.
  static const _forecastMinDays = 28;

  /// The full daily history as rows (for the forecasts), reparsed only when
  /// the history, deleted entries or device list change.
  List<UsageRow> _forecastRows() {
    final src = _historyRoot['daily'];
    final deleted = _deletedEntriesByRange['daily'] ?? const <String>{};
    if (!identical(src, _fcSource) ||
        !identical(deleted, _fcDeleted) ||
        !identical(_meta, _fcMeta)) {
      _fcSource = src;
      _fcDeleted = deleted;
      _fcMeta = _meta;
      _fcRows = parseDaily(src, _meta, rates: _rates, deleted: deleted);
    }
    return _fcRows;
  }

  String _buildingName(String code) =>
      _buildingInfo[code]?.name ??
      (code == 'ADMIN' ? 'Admin Building' : '$code Building');

  /// Buildings offered in the Scope panel: the campus defaults first, then
  /// any other code from the `buildings` node or a device.
  List<BuildingInfo> _scopeBuildings() {
    final codes = <String>[...kDefaultBuildings];
    for (final c in [
      ..._buildingInfo.keys,
      ..._meta.values.map((m) => m.building),
    ]) {
      if (c.isNotEmpty && !codes.contains(c)) codes.add(c);
    }
    return [
      for (final c in codes)
        _buildingInfo[c] ?? BuildingInfo(c, _buildingName(c), 1)
    ];
  }

  bool _metaInScope(DeviceMeta m) {
    final f = _filter;
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

  int _allowedDays(DateTimeRange span) {
    var n = 0;
    for (var d = span.start;
        !d.isAfter(span.end);
        d = DateTime(d.year, d.month, d.day + 1)) {
      if (_filter.dayAllowed(d)) n++;
    }
    return n;
  }

  bool get _asCost => _filter.metric == ValueMetric.cost;
  /// Past rates, so records without a stored cost are priced at their own
  /// day's rate rather than today's.
  RateTimeline get _rates => RateHistory.instance.timeline(_electricityRate);
  void _onRateLog() {
    if (mounted) setState(() {});
  }

  /// A bucket in the "Show values as" metric: its stored cost or its kWh.
  double _bucketValue(Bucket b) => _asCost ? b.cost : b.kwh;

  /// A value already in the "Show values as" metric.
  String _fmtValue(double v) => _asCost
      ? '₱${_fmtNumber(v, decimals: 2)}'
      : '${_fmtNumber(v, decimals: 1)} kWh';

  @override
  Widget build(BuildContext context) {
    final f = _filter;
    final today = dateOnly(HistoryClock.instance.now());
    final span = f.span(today);
    final deleted = _deletedEntriesByRange['daily'] ?? const <String>{};
    final rows =
        applyFilter(f, parseDaily(_rangeRaw, _meta, rates: _rates, deleted: deleted), span);
    final cmpSpan = f.compareSpan(today);
    final cmpRows = cmpSpan == null
        ? null
        : applyFilter(
            f, parseDaily(_compareRaw, _meta, rates: _rates, deleted: deleted), cmpSpan);
    final empty = _rangeLoaded && rows.isEmpty;

    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: ScreenSkeleton(
        isLoading: _isLoading,
        child: Builder(builder: (context) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  const Text('Analytics',
                      style: TextStyle(
                          fontFamily: AppFonts.family,
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textDark)),
                  const SizedBox(width: 12),
                  _livePill(),
                  const Spacer(),
                  _exportButton(),
                ]),
                const SizedBox(height: 4),
                const Text('Energy analytics and forecast',
                    style: TextStyle(fontSize: 14, color: WebColors.muted)),
                const SizedBox(height: 22),
                if (_errorText != null)
                  _buildLoadError()
                else ...[
                  AnalyticsFilterBar(
                    filter: f,
                    onChanged: _setFilter,
                    buildings: _scopeBuildings(),
                    devices: _meta,
                  ),
                  const SizedBox(height: 22),
                  if (!_rangeLoaded)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          minHeight: 3,
                          color: _palette.mid,
                          backgroundColor: _palette.pale.withAlpha(90),
                        ),
                      ),
                    ),
                  if (empty)
                    _emptyState()
                  else ...[
                    _statGrid(rows, cmpRows, span, cmpSpan),
                    const SizedBox(height: 22),
                    KeyedSubtree(
                      key: _keyFor(AnalyticsSection.trend),
                      child: _trendCard(rows, cmpRows, span, cmpSpan),
                    ),
                  ],
                  const SizedBox(height: 22),
                  KeyedSubtree(
                    key: _keyFor(AnalyticsSection.forecast),
                    child: _buildForecasts(today),
                  ),
                  if (!empty) ...[
                    const SizedBox(height: 22),
                    KeyedSubtree(
                      key: _keyFor(AnalyticsSection.utilities),
                      child: _bottomRow(context, rows, span),
                    ),
                  ],
                  const SizedBox(height: 22),
                  _panel(
                    title: 'Year comparison',
                    subtitle:
                        '${_asCost ? '₱' : 'kWh'} per month for two years · follows the scope, utility and day filters',
                    body: YearComparison(
                      rows: _forecastRows(),
                      filter: f,
                      palette: _palette,
                      today: today,
                    ),
                  ),
                  const SizedBox(height: 22),
                  KeyedSubtree(
                    key: _keyFor(AnalyticsSection.history),
                    child: HistoryTrendPanel(palette: _palette),
                  ),
                ],
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _exportButton() => SizedBox(
        height: 42,
        child: OutlinedButton.icon(
          onPressed: _exporting ? null : _exportOrganizedXlsx,
          icon: _exporting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.download_outlined, size: 18),
          label: Text(_exporting ? 'Generating...' : 'Export Excel'),
          style: OutlinedButton.styleFrom(
              foregroundColor: _palette.dark,
              side: BorderSide(color: _palette.mid, width: 1.5),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12))),
        ),
      );

  Widget _buildLoadError() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: WebColors.outline),
      ),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                  color: Colors.white, border: Border.all(color: WebColors.outline),
                  borderRadius: BorderRadius.circular(20)),
              child: Icon(Icons.cloud_off_outlined,
                  size: 34, color: _palette.mid)),
          const SizedBox(height: 16),
          const Text('Cannot load analytics',
              style: TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark)),
          const SizedBox(height: 8),
          Text(_errorText ?? 'Something went wrong.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: WebColors.muted)),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh, color: Colors.white, size: 18),
            label: const Text('Retry', style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
                backgroundColor: _palette.dark,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
          ),
        ]),
      ),
    );
  }

  /// Shown instead of the stats, trend and top lists when the filters
  /// leave no data.
  Widget _emptyState() {
    final f = _filter;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      decoration: AnalyticsUi.card(_palette),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
              color: Colors.white, border: Border.all(color: WebColors.outline),
              borderRadius: BorderRadius.circular(18)),
          child: Icon(Icons.filter_alt_off_outlined,
              size: 30, color: _palette.dark),
        ),
        const SizedBox(height: 16),
        const Text('No data for these filters',
            style: TextStyle(
                fontFamily: AppFonts.family,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: WebColors.ink)),
        const SizedBox(height: 6),
        Text(
          'Nothing was recorded for ${f.scopeName} · ${f.utilityName} '
          '(${f.rangeName.toLowerCase().startsWith('last') ? f.rangeName.toLowerCase() : f.rangeName}'
          '${f.dayType == DayType.all ? '' : ', ${f.dayType.label.toLowerCase()}'}). '
          'Try a longer time range or a wider scope.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, color: WebColors.muted),
        ),
        const SizedBox(height: 18),
        ElevatedButton(
          onPressed: f.isDefault
              ? null
              : () => _setFilter(AnalyticsFilter.defaults),
          style: ElevatedButton.styleFrom(
            backgroundColor: _palette.dark,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('Reset filters'),
        ),
      ]),
    );
  }

  // ── Preview-style header, stats and trend ─────────────────────────────

  String _fmtNumber(double v, {int decimals = 0}) {
    final fixed = v.toStringAsFixed(decimals);
    final parts = fixed.split('.');
    final whole = parts[0].replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
    return parts.length > 1 ? '$whole.${parts[1]}' : whole;
  }

  Widget _livePill() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: Colors.white, border: Border.all(color: WebColors.outline), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 7,
              height: 7,
              decoration:
                  BoxDecoration(color: _palette.mid, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text('Live',
              style: TextStyle(
                  fontSize: 13,
                  color: _palette.dark,
                  fontWeight: FontWeight.w600)),
        ]),
      );

  /// Segmented pill: a white "thumb" on the selected option.
  Widget _segmented(
      Map<String, String> options, String selected, ValueChanged<String> onTap) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
          color: WebColors.track,
          borderRadius: BorderRadius.circular(11)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final e in options.entries)
          Material(
            color: e.key == selected ? Colors.white : Colors.transparent,
            elevation: e.key == selected ? 1 : 0,
            shadowColor: Colors.black26,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onTap(e.key),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                child: Text(e.value,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: e.key == selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: e.key == selected
                            ? _palette.dark
                            : WebColors.mid)),
              ),
            ),
          ),
      ]),
    );
  }

  /// "▲ 12.3% vs previous period". Energy going up is shown in red.
  Widget? _delta(double current, double? previous, {bool upIsBad = true}) {
    if (previous == null) return null;
    final vs = _filter.compare == CompareMode.lastYear
        ? 'last year'
        : 'previous period';
    if (previous <= 0) {
      return Text('No data for the $vs',
          style: const TextStyle(fontSize: 12, color: WebColors.muted));
    }
    final pct = (current - previous) / previous * 100;
    final flat = pct.abs() < 0.05;
    final up = pct > 0;
    final color = flat
        ? WebColors.muted
        : (up == upIsBad ? AnalyticsUi.danger : _palette.dark);
    return Text.rich(
      TextSpan(children: [
        TextSpan(
            text: flat
                ? '● 0.0%'
                : '${up ? '▲' : '▼'} ${pct.abs().toStringAsFixed(1)}%',
            style: TextStyle(fontWeight: FontWeight.w700, color: color)),
        TextSpan(text: ' vs $vs'),
      ]),
      style: const TextStyle(fontSize: 12, color: WebColors.muted),
    );
  }

  Widget _statGrid(List<UsageRow> rows, List<UsageRow>? cmp,
      DateTimeRange span, DateTimeRange? cmpSpan) {
    final f = _filter;
    final total = sumKwh(rows);
    final days = _allowedDays(span);
    final avg = days == 0 ? 0.0 : total / days;
    final cTotal = cmp == null ? null : sumKwh(cmp);
    final cost = sumCost(rows);
    final cCost = cmp == null ? null : sumCost(cmp);
    final avgRate = total > 0 ? cost / total : _electricityRate;
    final cDays = cmpSpan == null ? 0 : _allowedDays(cmpSpan);
    final cAvg = cTotal == null ? null : (cDays == 0 ? 0.0 : cTotal / cDays);
    final scoped = _meta.values.where(_metaInScope).toList();
    final online = scoped.where((m) => m.online).length;
    int reporting(List<UsageRow> r) => r
        .where((x) => x.deviceId.isNotEmpty && x.kwh > 0)
        .map((x) => x.deviceId)
        .toSet()
        .length;
    final rep = reporting(rows);

    final cards = [
      _statCard(
        icon: Icons.bolt_rounded,
        value: _fmtNumber(total, decimals: 1),
        unit: 'kWh',
        label: 'Total energy',
        caption: f.rangeName,
        delta: _delta(total, cTotal),
      ),
      _statCard(
        icon: Icons.payments_outlined,
        value: '₱${_fmtNumber(cost)}',
        label: 'Total cost',
        caption: (avgRate - _electricityRate).abs() < 0.005
            ? 'At ₱${_electricityRate.toStringAsFixed(2)} per kWh'
            : 'At rates recorded · ₱${avgRate.toStringAsFixed(2)} avg per kWh',
        delta: _delta(cost, cCost),
      ),
      _statCard(
        icon: Icons.show_chart_rounded,
        value: _fmtNumber(avg, decimals: 1),
        unit: 'kWh',
        label: 'Daily average',
        caption:
            '$days ${f.dayType == DayType.all ? 'day' : f.dayType.label.toLowerCase().replaceAll('s', '')}${days == 1 ? '' : 's'}',
        delta: _delta(avg, cAvg),
      ),
      _statCard(
        icon: Icons.wifi_tethering_rounded,
        value: '$online / ${scoped.length}',
        label: 'Devices online',
        caption: cmp == null ? 'Online now' : '$rep reported usage',
        delta: cmp == null
            ? null
            : _delta(rep.toDouble(), reporting(cmp).toDouble(),
                upIsBad: false),
      ),
    ];
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= kWebWideContent) return _equalRow(cards);
      if (c.maxWidth < 560) {
        return Column(children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(height: 16),
            cards[i],
          ],
        ]);
      }
      return Column(children: [
        _equalRow(cards.sublist(0, 2)),
        const SizedBox(height: 16),
        _equalRow(cards.sublist(2)),
      ]);
    });
  }

  Widget _statCard({
    required IconData icon,
    required String value,
    String? unit,
    required String label,
    required String caption,
    Widget? delta,
  }) {
    // Narrow cards (4 in a row on a ~1150px window) get a smaller icon and
    // number so the value still fits.
    return LayoutBuilder(builder: (context, c) {
    final compact = c.maxWidth < 250;
    return Container(
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: WebColors.outline),
      ),
      child: Row(children: [
        Container(
          width: compact ? 40 : 52,
          height: compact ? 40 : 52,
          decoration: BoxDecoration(
              color: Colors.white, border: Border.all(color: WebColors.outline), shape: BoxShape.circle),
          child: Icon(icon, color: _palette.dark, size: compact ? 20 : 24),
        ),
        SizedBox(width: compact ? 10 : 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: value,
                    style: TextStyle(
                        fontFamily: AppFonts.family,
                        fontSize: compact ? 22 : 26,
                        fontWeight: FontWeight.w700,
                        color: WebColors.ink)),
                if (unit != null)
                  TextSpan(
                      text: ' $unit',
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: WebColors.muted)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(label,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: WebColors.ink)),
            Text(caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: WebColors.muted)),
            if (delta != null) ...[
              const SizedBox(height: 4),
              delta,
            ],
          ]),
        ),
      ]),
    );
    });
  }

  /// A card with the preview's panel header (title, subtitle, trailing).
  Widget _panel({
    required String title,
    String? subtitle,
    Widget? trailing,
    required Widget body,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
      decoration: AnalyticsUi.card(_palette),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(
                      fontFamily: AppFonts.family,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: WebColors.ink)),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(subtitle,
                    style:
                        const TextStyle(fontSize: 13, color: WebColors.muted)),
              ],
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing],
        ]),
        const SizedBox(height: 18),
        body,
      ]),
    );
  }

  Widget _trendCard(List<UsageRow> rows, List<UsageRow>? cmpRows,
      DateTimeRange span, DateTimeRange? cmpSpan) {
    final f = _filter;
    final buckets = bucketize(f, rows, span, f.group);
    final cb = cmpSpan == null
        ? null
        : bucketize(f, cmpRows ?? const [], cmpSpan, f.group);
    final points = [
      for (var i = 0; i < buckets.length; i++)
        TrendPoint(
          buckets[i].label,
          '${buckets[i].tooltipLabel} · ${_fmtValue(_bucketValue(buckets[i]))}'
          '${cb != null && i < cb.length ? '\nEarlier: ${_fmtValue(_bucketValue(cb[i]))}' : ''}',
          _bucketValue(buckets[i]),
        ),
    ];
    final compare = cb == null
        ? null
        : [
            for (var i = 0; i < math.min(cb.length, buckets.length); i++)
              _bucketValue(cb[i])
          ];
    final noun = switch (f.group) {
      GroupBy.hourly => 'hour',
      GroupBy.daily => 'day',
      GroupBy.weekly => 'week',
      GroupBy.monthly => 'month',
    };
    return _panel(
      title: 'Consumption Trend',
      subtitle:
          '${_asCost ? 'Cost (₱)' : 'kWh'} per $noun · ${f.rangeName} · hover for values',
      trailing: _segmented(const {'line': 'Line', 'bar': 'Bar'},
          _trendChartType, (k) => setState(() => _trendChartType = k)),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (buckets.isEmpty)
          const SizedBox(
            height: 200,
            child: Center(
              child: Text('No data yet',
                  style: TextStyle(fontSize: 14, color: WebColors.muted)),
            ),
          )
        else
          WebTrendChart(
            points: points,
            bars: _trendChartType == 'bar',
            color: AppColors.greenMid,
            compare: compare,
            compareColor: WebColors.muted,
          ),
        if (cmpSpan != null) ...[
          const SizedBox(height: 14),
          Wrap(spacing: 16, runSpacing: 6, children: [
            _legend(false, AppColors.greenMid,
                'This period · ${spanText(span)}'),
            _legend(
                true,
                WebColors.muted,
                '${f.compare == CompareMode.lastYear ? 'Last year' : 'Previous period'} · ${spanText(cmpSpan)}'),
          ]),
        ],
      ]),
    );
  }

  Widget _legend(bool dashed, Color color, String text) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: 20,
        child: dashed
            ? Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                for (var i = 0; i < 3; i++)
                  Container(width: 5, height: 2.5, color: color),
              ])
            : Container(height: 2.5, color: color),
      ),
      const SizedBox(width: 6),
      Text(text, style: const TextStyle(fontSize: 12.5, color: WebColors.muted)),
    ]);
  }

  /// ARIMA (left) and a model picker (right). Uses only the scope and
  /// utility filters, and always trains on the full history up to
  /// yesterday; the horizon follows the selected range.
  Widget _buildForecasts(DateTime today) {
    final f = _filter;
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    final series = dailySeries(f, _forecastRows(), yesterday);
    final days = f.days;
    final horizon = days <= 10 ? 7 : (days <= 45 ? 30 : 90);
    final enough = series.daysWithData >= _forecastMinDays;
    final scoped = f.hasScope || f.hasUtility;
    return ForecastComparison(
      palette: _palette,
      daily: series.values,
      lastDate: series.last ?? yesterday,
      rate: _electricityRate,
      horizon: horizon,
      remoteModelsApply: !scoped,
      unavailableReason: enough
          ? null
          : 'Not enough data for a forecast. '
              '${scoped ? 'This scope has' : 'There are'} ${series.daysWithData} '
              'day${series.daysWithData == 1 ? '' : 's'} of history; a '
              'forecast needs at least $_forecastMinDays.',
    );
  }

  /// Lays out [cards] in one row that always divides the full row width
  /// evenly between them (rather than a [Wrap] of fixed widths, which left
  /// large, uneven gaps depending on how much space was left over) and
  /// stretches every card in the row to match the tallest one.
  Widget _equalRow(List<Widget> cards) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(width: 16),
            Expanded(child: cards[i]),
          ],
        ],
      ),
    );
  }

  // ── Top Consuming cards + breakdown drawer ────────────────────────────

  Widget _bottomRow(
      BuildContext ctx, List<UsageRow> rows, DateTimeRange span) {
    final a = _utilityCard(ctx, rows);
    final b = _topCard(ctx, rows, span);
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < kWebWideContent) {
        return Column(children: [a, const SizedBox(height: 22), b]);
      }
      return IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: a),
          const SizedBox(width: 22),
          Expanded(child: b),
        ]),
      );
    });
  }

  void _openBreakdown(
      BuildContext ctx, BreakdownKind kind, String id, List<UsageRow> rows) {
    final open = widget.onOpenDevice;
    showBreakdownPanel(
      ctx,
      kind: kind,
      id: id,
      rangeName: _filter.rangeName,
      rows: rows,
      cardTotal: sumKwh(rows),
      devices: _meta,
      buildingNames: {for (final b in _scopeBuildings()) b.code: b.name},
      rate: _electricityRate,
      onOpenDevice: open == null
          ? null
          : (m) => open(m.id, m.utility, m.building, m.room, m.floor),
    );
  }

  Widget _progress(double frac, Color color) => ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(
          value: frac.clamp(0.0, 1.0),
          minHeight: 6,
          backgroundColor: AnalyticsUi.track,
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      );

  /// A clickable row with a hover state and a › icon.
  Widget _bdRow({
    required String semantic,
    required VoidCallback? onTap,
    required Widget label,
    required String value,
    required double frac,
    required Color color,
  }) {
    return HoverRegion(
      semanticLabel: semantic,
      onTap: onTap,
      builder: (context, hovered) => Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: hovered ? _palette.pale.withAlpha(89) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: DefaultTextStyle.merge(
                style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: WebColors.ink),
                child: label,
              ),
            ),
            const SizedBox(width: 8),
            Text(value,
                style: const TextStyle(fontSize: 13, color: WebColors.muted)),
            if (onTap != null) ...[
              const SizedBox(width: 8),
              Text('›',
                  style: TextStyle(
                      fontSize: 16,
                      height: 1,
                      fontWeight: FontWeight.w700,
                      color: hovered ? _palette.dark : WebColors.muted)),
            ],
          ]),
          const SizedBox(height: 6),
          _progress(frac, color),
        ]),
      ),
    );
  }

  Widget _code(String c) => Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: _palette.pale.withAlpha(153),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(c,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: _palette.dark)),
      );

  Widget _utilityCard(BuildContext ctx, List<UsageRow> rows) {
    final groups = groupSum(rows, (r) => r.utility, cost: _asCost)
        .where((e) => e.value > 0)
        .toList();
    final total = _asCost ? sumCost(rows) : sumKwh(rows);
    return _panel(
      title: 'Top Consuming Utilities',
      subtitle:
          "${_filter.rangeName} · click a utility to see what's behind it",
      body: groups.isEmpty
          ? const Text('No usage in this range.',
              style: TextStyle(fontSize: 14, color: WebColors.muted))
          : Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              UtilityDonut(
                data: [for (final g in groups) MapEntry(g.key, g.value)],
                centerValue: _asCost
                    ? '₱${_fmtNumber(total)}'
                    : total.toStringAsFixed(1),
                centerCaption: _asCost ? 'cost' : 'kWh',
                onTap: (u) =>
                    _openBreakdown(ctx, BreakdownKind.utility, u, rows),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(children: [
                  for (final g in groups)
                    _bdRow(
                      semantic: 'See breakdown for ${g.key}',
                      onTap: () =>
                          _openBreakdown(ctx, BreakdownKind.utility, g.key, rows),
                      label: Row(children: [
                        Container(
                          width: 10,
                          height: 10,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                              color: AnalyticsUi.utilityColor(g.key),
                              borderRadius: BorderRadius.circular(3)),
                        ),
                        Flexible(
                          child: Text(
                              '${g.key} (${total <= 0 ? 0 : (g.value / total * 100).round()}%)',
                              overflow: TextOverflow.ellipsis),
                        ),
                      ]),
                      value: _fmtValue(g.value),
                      frac: total <= 0 ? 0 : g.value / total,
                      color: AnalyticsUi.utilityColor(g.key),
                    ),
                ]),
              ),
            ]),
    );
  }

  /// Institutes by default, rooms when one building is selected, devices
  /// when a room or device is selected.
  Widget _topCard(BuildContext ctx, List<UsageRow> rows, DateTimeRange span) {
    final f = _filter;
    final mode = f.buildings.length != 1
        ? _TopMode.institutes
        : (f.room.isEmpty && f.device.isEmpty
            ? _TopMode.rooms
            : _TopMode.devices);
    final perDevice = rows.where((r) => r.deviceId.isNotEmpty);
    final groups = switch (mode) {
      _TopMode.institutes => groupSum(rows, (r) => r.building, cost: _asCost),
      _TopMode.rooms =>
        groupSum(perDevice, (r) => r.roomKey, cost: _asCost),
      _TopMode.devices =>
        groupSum(perDevice, (r) => r.deviceId, cost: _asCost),
    }
        .where((e) => e.value > 0)
        .take(mode == _TopMode.institutes ? 50 : 10)
        .toList();
    final max = groups.isEmpty ? 0.0 : groups.first.value;
    // Load levels stay on kWh even when values are shown as cost.
    final kwhBy = _asCost
        ? {for (final e in groupSum(rows, (r) => r.building)) e.key: e.value}
        : {for (final g in groups) g.key: g.value};

    // HIGH / MID / LOW, the dashboard's 100 / 50 kWh-a-month thresholds
    // scaled to the length of the range.
    final scale = spanDays(span) / 30;
    Color levelColor(double kwh) => kwh >= 100 * scale
        ? AnalyticsUi.high
        : kwh >= 50 * scale
            ? AnalyticsUi.warn
            : const Color(0xFF2E9E52);

    final title = switch (mode) {
      _TopMode.institutes => 'Top Consuming Institutes',
      _TopMode.rooms => 'Top Consuming Rooms',
      _TopMode.devices => 'Top Consuming Devices',
    };
    final hint = mode == _TopMode.devices
        ? 'click one to open it'
        : "click one to see what's behind it";

    return _panel(
      title: title,
      subtitle: '${f.rangeName}, ${_asCost ? '₱' : 'kWh'} · $hint',
      body: groups.isEmpty
          ? const Text('No usage in this range.',
              style: TextStyle(fontSize: 14, color: WebColors.muted))
          : Column(children: [
              for (final g in groups)
                switch (mode) {
                  _TopMode.institutes => _bdRow(
                      semantic: 'See breakdown for ${_buildingName(g.key)}',
                      onTap: g.key.isEmpty
                          ? null
                          : () => _openBreakdown(
                              ctx, BreakdownKind.building, g.key, rows),
                      label: Row(children: [
                        _code(g.key.isEmpty ? '—' : g.key),
                        Flexible(
                          child: Text(
                              g.key.isEmpty
                                  ? 'Unassigned'
                                  : _buildingName(g.key),
                              overflow: TextOverflow.ellipsis),
                        ),
                      ]),
                      value: _fmtValue(g.value),
                      frac: max <= 0 ? 0 : g.value / max,
                      color: levelColor(kwhBy[g.key] ?? 0),
                    ),
                  _TopMode.rooms => () {
                      final parts = g.key.split('|');
                      final room = parts.length > 2 && parts[2].isNotEmpty
                          ? parts[2]
                          : 'No room';
                      return _bdRow(
                        semantic: 'See breakdown for $room',
                        onTap: () => _openBreakdown(
                            ctx, BreakdownKind.room, g.key, rows),
                        label: Text.rich(TextSpan(children: [
                          TextSpan(text: room),
                          TextSpan(
                              text: '  · Floor ${parts.length > 1 ? parts[1] : '?'}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w400,
                                  color: WebColors.muted)),
                        ])),
                        value: _fmtValue(g.value),
                        frac: max <= 0 ? 0 : g.value / max,
                        color: _palette.mid,
                      );
                    }(),
                  _TopMode.devices => () {
                      final m = _meta[g.key];
                      final open = widget.onOpenDevice;
                      return _bdRow(
                        semantic: 'Open ${g.key}',
                        onTap: m == null || open == null
                            ? null
                            : () => open(
                                m.id, m.utility, m.building, m.room, m.floor),
                        label: Text.rich(TextSpan(children: [
                          TextSpan(text: g.key),
                          if (m != null)
                            TextSpan(
                                text: '  · ${m.utility} · ${m.room}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w400,
                                    color: WebColors.muted)),
                        ])),
                        value: _fmtValue(g.value),
                        frac: max <= 0 ? 0 : g.value / max,
                        color: AnalyticsUi.utilityColor(m?.utility ?? ''),
                      );
                    }(),
                },
            ]),
    );
  }
}

/// What the "Top Consuming" card lists.
enum _TopMode { institutes, rooms, devices }
