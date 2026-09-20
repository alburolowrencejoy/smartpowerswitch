import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_xlsio/xlsio.dart' as xlsio;
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../utils/placeholder_data.dart';
import '../../widgets/multi_month_range_picker.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import '../../widgets/trend_chart_painters.dart';

/// The desktop "Analytics" section: the full History screen's data and
/// actions (range switching, trend chart with tap-to-inspect, forecast,
/// device status, top utility/building, per-entry delete, organized Excel
/// export) laid out as a grid of cards instead of [HistoryScreen]'s
/// single stacked column. [HistoryScreen] itself is untouched -- this is
/// an independent widget with its own Firebase listeners so the mobile
/// screen's behavior can never be affected by desktop changes.
class HistoryScreenWeb extends StatefulWidget {
  const HistoryScreenWeb({super.key});

  @override
  State<HistoryScreenWeb> createState() => _HistoryScreenWebState();
}

class _HistoryScreenWebState extends State<HistoryScreenWeb> {
  String _range = 'daily';
  String _trendChartType = 'line';
  bool _exporting = false;
  String? _deletingHistoryKey;

  /// Which of Week/Month/Year is shown by the combined granularity dropdown
  /// -- tracked separately from [_range] so the dropdown keeps showing the
  /// last-picked granularity even while the Daily tab is active.
  String _lastGranularity = 'weekly';

  /// Committed Daily date range (from the calendar range picker). `null`
  /// means "no range applied yet" -- Daily behaves exactly as before,
  /// showing every daily entry.
  DateTimeRange? _dailyRange;

  final List<Map<String, String>> _ranges = [
    {'key': 'daily', 'label': 'Daily'},
    {'key': 'weekly', 'label': 'Weekly'},
    {'key': 'monthly', 'label': 'Monthly'},
    {'key': 'yearly', 'label': 'Yearly'},
  ];

  /// True until the combined stream's first emission. Never reverts to
  /// true afterwards -- a fresh instance of this screen is the only
  /// legitimate reset.
  bool _isLoading = true;
  String? _errorText;
  bool _hasLoadedOnce = false;

  static const Duration _loadTimeout = Duration(seconds: 15);
  Timer? _timeoutTimer;

  StreamSubscription? _combinedSub;

  /// Backs the trend chart's horizontal scroll (see [_buildLineChart]) so
  /// an explicit, always-visible [Scrollbar] can be attached to it -- the
  /// chart can render far wider than the card when there's a lot of
  /// history, and without a persistent visible affordance there was no
  /// indication (beyond a mouse wheel/trackpad swipe) that it scrolls at
  /// all.
  final ScrollController _chartScrollController = ScrollController();

  Map<String, dynamic> _historyRoot = {};
  List<Map<String, dynamic>> _historyData = [];
  Set<String> _deletedEntries = {};
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
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _combinedSub?.cancel();
    _chartScrollController.dispose();
    super.dispose();
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
    _onlineCount = online;
    _offlineCount = offline;
  }

  void _applyDeleted(Object? raw) {
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      final deleted = Set<String>.from(map.keys);
      _deletedEntries = deleted;
      _deletedEntriesByRange[_range] = deleted;
    } else if (_isLoading) {
      _deletedEntries = {};
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
        setState(() {
          _historyRoot = {};
          _historyData = [];
        });
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

    final list = _parseRangeEntries(
      root,
      _range,
      deletedMap[_range] ?? _deletedEntries,
    );

    if (!mounted) return;
    setState(() {
      _historyRoot = root;
      _deletedEntriesByRange = deletedMap;
      _deletedEntries = deletedMap[_range] ?? {};
      // The chart always shows the full trend for the active range -- a
      // Daily calendar pick highlights itself *within* that trend instead
      // of narrowing the dataset (see _dailyHighlightIndices/_buildLineChart
      // and _breakdownListData, which is the one place that still scopes
      // down to the picked day/range).
      _historyData = list;
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

  void _setRange(String key) {
    setState(() {
      _range = key;
      if (key != 'daily') {
        _lastGranularity = key;
      } else {
        // Switching to Daily from the funnel menu's "Daily" entry is a
        // quick reset to the plain full daily trend -- any day/range picked
        // via the calendar icon is cleared along with it.
        _dailyRange = null;
      }
    });
    _deletedEntries.clear();
    _listenAll();
  }

  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Scopes [entries] down to [_dailyRange] (inclusive), when one has been
  /// applied via the calendar range picker. Every other range key, and
  /// Daily with no range applied, passes [entries] through unchanged.
  ///
  /// This is used for the summary totals cards and the breakdown list
  /// below the chart -- NOT the trend chart itself, which always shows the
  /// full daily trend and only highlights the picked day/range within it
  /// (see [_dailyHighlightIndices]).
  List<Map<String, dynamic>> _applyDailyRangeFilter(
      List<Map<String, dynamic>> entries) {
    if (_range != 'daily' || _dailyRange == null) return entries;
    final start = _dateOnly(_dailyRange!.start);
    final end = _dateOnly(_dailyRange!.end);
    return entries.where((e) {
      final d = DateTime.tryParse(e['label'].toString());
      if (d == null) return false;
      final dd = _dateOnly(d);
      return !dd.isBefore(start) && !dd.isAfter(end);
    }).toList();
  }

  /// The breakdown list below the chart still scopes down to the picked
  /// Daily range (unlike the chart, which stays unfiltered and just
  /// highlights the selection -- see [_dailyHighlightIndices]).
  List<Map<String, dynamic>> _breakdownListData() =>
      _applyDailyRangeFilter(_historyData);

  /// Locates the picked Daily day/range within the *full* [_historyData]
  /// list so the trend chart can highlight it in place instead of
  /// filtering the dataset down to it. Returns `(null, null)` when Daily
  /// has no range applied, or when literally no entry in [_historyData]
  /// falls inside the picked range.
  ///
  /// This scans for *any* entry whose date falls within
  /// `[_dailyRange.start, _dailyRange.end]` inclusive, rather than
  /// requiring an exact-label match at the two boundary days -- a picked
  /// range's start/end days frequently have no recorded entry themselves
  /// (e.g. a weekend with no usage, or a device offline that day) even
  /// though days strictly between them do. Matching only the boundaries
  /// silently dropped the highlight entirely in that case, which is what
  /// made a selected range look like it never reflected in the chart at
  /// all. [startIndex]/[endIndex] are the first/last matching entries,
  /// mirroring how the picker itself lets the two ends fall on whichever
  /// days actually have data.
  (int?, int?) _dailyHighlightIndices() {
    if (_range != 'daily' || _dailyRange == null) return (null, null);
    final start = _dateOnly(_dailyRange!.start);
    final end = _dateOnly(_dailyRange!.end);
    int? startIndex;
    int? endIndex;
    for (var i = 0; i < _historyData.length; i++) {
      final d = DateTime.tryParse(_historyData[i]['label'].toString());
      if (d == null) continue;
      final dd = _dateOnly(d);
      if (dd.isBefore(start) || dd.isAfter(end)) continue;
      startIndex ??= i;
      endIndex = i;
    }
    return (startIndex, endIndex);
  }

  /// The earliest/latest first-of-month across every daily history entry,
  /// so the calendar range picker's grid mirrors how far back real data
  /// actually goes instead of a hardcoded month count. Falls back to just
  /// the current month if there's no daily data yet, and always includes
  /// the current month so "today" is always reachable.
  (DateTime, DateTime) _dailyMonthSpan() {
    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month, 1);
    final dailyEntries = _dailyHistoryEntries();
    if (dailyEntries.isEmpty) return (currentMonth, currentMonth);

    DateTime? earliest;
    DateTime? latest;
    for (final entry in dailyEntries) {
      final d = DateTime.tryParse(entry['label'].toString());
      if (d == null) continue;
      final monthStart = DateTime(d.year, d.month, 1);
      if (earliest == null || monthStart.isBefore(earliest)) {
        earliest = monthStart;
      }
      if (latest == null || monthStart.isAfter(latest)) {
        latest = monthStart;
      }
    }
    earliest ??= currentMonth;
    latest ??= currentMonth;
    if (currentMonth.isAfter(latest)) latest = currentMonth;
    if (currentMonth.isBefore(earliest)) earliest = currentMonth;
    return (earliest, latest);
  }

  String _fmtShortDate(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  Future<void> _deleteHistoryEntry(String label) async {
    if (_deletingHistoryKey != null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete history?'),
        content: Text(
          'This will delete the ${_capitalizeFirst(_range)} record for $label.',
        ),
        actions: [
          // Bug fix: neither button had an explicit style, so their resting
          // color fell back to the app-wide seed-green ColorScheme.primary
          // (main.dart) instead of this viewer's institute theme / the
          // Cancel/Delete convention every other confirm dialog in this
          // codebase already follows (AppColors.textMuted / AppColors.error).
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete',
                style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _deletingHistoryKey = label);

    try {
      await FirebaseDatabase.instance.ref('history/$_range/$label').remove();

      await FirebaseDatabase.instance
          .ref('history/deleted/$_range/$label')
          .set(true);

      if (mounted) {
        TopToast.threshold(
            context, 'Deleted ${_capitalizeFirst(_range)} history.');
      }
      _listenAll();
    } catch (e) {
      if (mounted) {
        TopToast.error(context, 'Delete failed: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _deletingHistoryKey = null);
      }
    }
  }

  Map<String, double> _currentPeriodTotals() {
    final entries = _parseRangeEntries(
      _historyRoot,
      _range,
      _deletedEntriesByRange[_range] ?? {},
    );

    if (entries.isEmpty) return {'kwh': 0.0, 'cost': 0.0};

    // A Daily range applied via the calendar picker sums every day inside
    // it, the same way Weekly/Monthly/Yearly summary cards already show one
    // aggregated total for their whole active period.
    if (_range == 'daily' && _dailyRange != null) {
      final filtered = _applyDailyRangeFilter(entries);
      final kwh =
          filtered.fold<double>(0.0, (s, e) => s + (e['kwh'] as double));
      final cost =
          filtered.fold<double>(0.0, (s, e) => s + (e['cost'] as double));
      return {'kwh': kwh, 'cost': cost};
    }

    final now = DateTime.now();
    final currentLabel = _rangeLabel(now, _range);

    final filtered = entries.where((e) {
      final label = e['label'].toString();
      if (_range == 'monthly') {
        return label.startsWith(currentLabel);
      }
      return label == currentLabel;
    }).toList();

    final kwh = filtered.fold<double>(0.0, (s, e) => s + (e['kwh'] as double));
    final cost =
        filtered.fold<double>(0.0, (s, e) => s + (e['cost'] as double));
    return {'kwh': kwh, 'cost': cost};
  }

  String _currentPeriodLabel() {
    switch (_range) {
      case 'daily':
        if (_dailyRange != null) {
          final start = _dailyRange!.start;
          final end = _dailyRange!.end;
          if (_dateOnly(start) == _dateOnly(end)) {
            return _fmtShortDate(start);
          }
          return '${_fmtShortDate(start)} - ${_fmtShortDate(end)}';
        }
        return 'Today';
      case 'weekly':
        return 'This week';
      case 'monthly':
        return 'This month';
      case 'yearly':
        return 'This year';
      default:
        return '';
    }
  }

  double _chartMaxForRange(String range) {
    switch (range) {
      case 'daily':
        return 50.0;
      case 'weekly':
        return 100.0;
      case 'monthly':
        return 150.0;
      case 'yearly':
        return 1000.0;
      default:
        return 100.0;
    }
  }

  String _formatAxisTick(double value) {
    final rounded = value.roundToDouble();
    if ((value - rounded).abs() < 0.001) {
      return rounded.toInt().toString();
    }
    return value.toStringAsFixed(1);
  }

  List<String> _chartYAxisLabels() {
    final max = _chartMaxForRange(_range);
    const segments = 5;
    final step = max / segments;
    return List<String>.generate(
      segments + 1,
      (i) => _formatAxisTick(max - (step * i)),
    );
  }

  List<Map<String, dynamic>> _dailyHistoryEntries() {
    return _parseRangeEntries(
      _historyRoot,
      'daily',
      _deletedEntriesByRange['daily'] ?? const {},
    );
  }

  List<double> _forecastValues(List<double> history, int horizon) {
    if (history.isEmpty) return List<double>.filled(horizon, 0.0);
    if (history.length == 1) {
      return List<double>.filled(
          horizon, history.first < 0 ? 0.0 : history.first);
    }

    final n = history.length.toDouble();
    final meanX = (n - 1) / 2.0;
    final meanY = history.fold<double>(0.0, (sum, value) => sum + value) / n;
    double numerator = 0.0;
    double denominator = 0.0;

    for (var i = 0; i < history.length; i++) {
      final dx = i - meanX;
      final dy = history[i] - meanY;
      numerator += dx * dy;
      denominator += dx * dx;
    }

    final slope = denominator == 0 ? 0.0 : numerator / denominator;
    final intercept = meanY - slope * meanX;

    return List<double>.generate(horizon, (i) {
      final x = history.length + i;
      final value = intercept + slope * x;
      return value < 0 ? 0.0 : value;
    });
  }

  double _averageRateFromEntries(List<Map<String, dynamic>> entries) {
    double totalKwh = 0.0;
    double totalCost = 0.0;

    for (final entry in entries) {
      totalKwh += (entry['kwh'] as num).toDouble();
      totalCost += (entry['cost'] as num).toDouble();
    }

    if (totalKwh <= 0) return 0.0;
    return totalCost / totalKwh;
  }

  DateTime? _tryParseDailyLabel(String label) => DateTime.tryParse(label);

  String _formatDailyLabel(DateTime date) =>
      '${date.year}-${_pad(date.month)}-${_pad(date.day)}';

  _PredictionSeries? _buildPredictionSeries() {
    final dailyEntries = _dailyHistoryEntries();
    if (dailyEntries.isEmpty) return null;

    final actualValues =
        dailyEntries.map((entry) => (entry['kwh'] as num).toDouble()).toList();
    final actualLabels =
        dailyEntries.map((entry) => entry['label'].toString()).toList();

    final regressionWindow = actualValues.length > 90
        ? actualValues.sublist(actualValues.length - 90)
        : actualValues;
    final forecastValues = _forecastValues(regressionWindow, 30);

    final lastLabel = actualLabels.isNotEmpty ? actualLabels.last : null;
    final lastDate = lastLabel == null ? null : _tryParseDailyLabel(lastLabel);
    final forecastLabels = <String>[];
    if (lastDate != null) {
      for (var i = 1; i <= forecastValues.length; i++) {
        forecastLabels.add(_formatDailyLabel(lastDate.add(Duration(days: i))));
      }
    }

    final predictedKwh =
        forecastValues.fold<double>(0.0, (sum, value) => sum + value);
    final averageRate = _averageRateFromEntries(dailyEntries);
    final predictedBill = predictedKwh * _electricityRate;

    return _PredictionSeries(
      actualValues: actualValues,
      actualLabels: actualLabels,
      forecastValues: forecastValues,
      forecastLabels: forecastLabels,
      predictedKwh: predictedKwh,
      predictedBill: predictedBill,
      averageRate: averageRate,
    );
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

  @override
  Widget build(BuildContext context) {
    final periodTotals = _currentPeriodTotals();
    final periodLabel = _currentPeriodLabel();
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: ScreenSkeleton(
      isLoading: _isLoading,
      child: SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Analytics',
                        style: TextStyle(
                            fontFamily: 'Outfit',
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textDark)),
                    SizedBox(height: 4),
                    Text('Energy analytics, forecast, and history',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textMuted)),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _palette.pale,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                      width: 7,
                      height: 7,
                      decoration:
                          BoxDecoration(color: _palette.mid, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text('Live',
                      style: TextStyle(
                          fontSize: 11,
                          color: _palette.dark,
                          fontWeight: FontWeight.w600)),
                ]),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_errorText != null)
            _buildLoadError()
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildRangeSelector(),
                const Spacer(),
                SizedBox(
                  height: 46,
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
                            borderRadius: BorderRadius.circular(14))),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _equalRow([
              _summaryCard('${periodTotals['kwh']!.toStringAsFixed(1)} kWh',
                  Icons.bolt, periodLabel),
              _summaryCard('₱ ${periodTotals['cost']!.toStringAsFixed(0)}',
                  Icons.payments_outlined, periodLabel),
              _buildDeviceStatusCard(),
            ]),
            const SizedBox(height: 20),
            _buildLineChart(),
            const SizedBox(height: 20),
            _buildPredictionCard(),
            if (_utilityTotals.isNotEmpty || _buildingTotals.isNotEmpty) ...[
              const SizedBox(height: 16),
              _equalRow([
                if (_utilityTotals.isNotEmpty) _buildTopUtilityCard(),
                if (_buildingTotals.isNotEmpty) _buildTopBuildingCard(),
              ]),
            ],
            const SizedBox(height: 20),
            _buildHistoryList(),
          ],
        ],
      ),
      ),
      ),
    );
  }

  Widget _buildLoadError() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                  color: _palette.pale,
                  borderRadius: BorderRadius.circular(20)),
              child: Icon(Icons.cloud_off_outlined,
                  size: 34, color: _palette.mid)),
          const SizedBox(height: 16),
          const Text('Cannot load analytics',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark)),
          const SizedBox(height: 8),
          Text(_errorText ?? 'Something went wrong.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
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

  /// Top-level Daily / Week-Month-Year selector. Only two elements now:
  /// Daily (arrow opens the calendar range picker) and a combined dropdown
  /// for whichever of Week/Month/Year is active (tap the body to switch
  /// granularity, arrow still opens the existing capped specific-period
  /// list for that granularity).
  /// Icon-only toolbar: a calendar icon (opens the Daily calendar range
  /// picker) and a funnel/sort icon (opens the Week/Month/Year granularity
  /// menu). Both keep the rounded-pill card look used elsewhere in this
  /// row, just without text labels -- each carries a [Tooltip] so they
  /// stay discoverable.
  Widget _buildRangeSelector() {
    return Container(
      height: 52,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
          color: _palette.pale, borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildDailyIconButton(),
          const SizedBox(width: 6),
          _buildGranularityIconButton(),
        ],
      ),
    );
  }

  Widget _buildDailyIconButton() {
    final isSelected = _range == 'daily';
    return Builder(builder: (btnContext) {
      return Tooltip(
        message: 'Daily -- pick a date or date range',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _showDailyRangePicker(btnContext),
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isSelected ? _palette.dark : AppColors.cardBg,
              borderRadius: BorderRadius.circular(8),
              border: isSelected
                  ? null
                  : Border.all(color: _palette.mid.withAlpha(60)),
            ),
            child: Icon(
              Icons.calendar_month,
              size: 20,
              color: isSelected ? Colors.white : _palette.dark,
            ),
          ),
        ),
      );
    });
  }

  Widget _buildGranularityIconButton() {
    final isSelected = _range != 'daily';
    final activeKey = isSelected ? _range : _lastGranularity;
    final label =
        _ranges.firstWhere((r) => r['key'] == activeKey, orElse: () => _ranges[1])['label']!;
    return Builder(builder: (btnContext) {
      return Tooltip(
        message: 'Daily / Week / Month / Year -- currently $label. '
            'Right-click to pick a specific $label period.',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _showGranularityMenu(btnContext),
          onSecondaryTap: () =>
              _showRangeDropdown(btnContext, activeKey, Offset.zero),
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isSelected ? _palette.dark : AppColors.cardBg,
              borderRadius: BorderRadius.circular(8),
              border: isSelected
                  ? null
                  : Border.all(color: _palette.mid.withAlpha(60)),
            ),
            child: Icon(
              Icons.filter_list,
              size: 20,
              color: isSelected ? Colors.white : _palette.dark,
            ),
          ),
        ),
      );
    });
  }

  /// Opens the menu that lets the user pick which granularity (Daily /
  /// Week / Month / Year) is active -- this is the "single dropdown" that
  /// replaced the three always-visible Weekly/Monthly/Yearly segments.
  /// Picking "Daily" here is a quick reset to the plain full daily trend
  /// (see [_setRange]); picking a specific day/range within Daily is still
  /// the calendar icon's job.
  Future<void> _showGranularityMenu(BuildContext btnContext) async {
    final overlay =
        Overlay.of(btnContext).context.findRenderObject() as RenderBox?;
    final btnBox = btnContext.findRenderObject() as RenderBox?;
    if (overlay == null || btnBox == null) return;

    final btnTopLeft = btnBox.localToGlobal(Offset.zero, ancestor: overlay);
    final top = btnTopLeft.dy + btnBox.size.height;
    final bottom = overlay.size.height - top;
    final menuWidth = btnBox.size.width.clamp(140.0, overlay.size.width - 40.0);
    var desiredLeft = btnTopLeft.dx;
    desiredLeft =
        desiredLeft.clamp(12.0, overlay.size.width - menuWidth - 12.0);
    final adjustedRight = overlay.size.width - desiredLeft - menuWidth;
    final position =
        RelativeRect.fromLTRB(desiredLeft, top, adjustedRight, bottom);

    final selected = await showMenu<String>(
      context: btnContext,
      position: position,
      items: _ranges.map((r) {
        final selectedItem = r['key'] == _range;
        return PopupMenuItem<String>(
          value: r['key'],
          child: SizedBox(
            width: menuWidth,
            child: Row(
              children: [
                Icon(
                  selectedItem ? Icons.check : null,
                  size: 16,
                  color: _palette.dark,
                ),
                const SizedBox(width: 8),
                Text(r['label']!, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
        );
      }).toList(),
    );

    if (selected == null) return;
    _setRange(selected);
  }

  /// Opens the multi-month calendar range picker for the Daily tab (see
  /// [MultiMonthRangePicker]). Nothing is applied until "Apply" is pressed;
  /// closing the dialog any other way leaves the current Daily view
  /// untouched.
  Future<void> _showDailyRangePicker(BuildContext btnContext) async {
    final (earliestMonth, latestMonth) = _dailyMonthSpan();
    DateTimeRange? localPending = _dailyRange;

    final result = await showDialog<_DailyRangeDialogResult>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(builder: (context, setDialogState) {
          return Dialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 700,
                maxHeight: MediaQuery.of(context).size.height - 64,
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Select a date range',
                            style: TextStyle(
                              fontFamily: 'Outfit',
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textDark,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: () => Navigator.pop(dialogContext),
                        ),
                      ],
                    ),
                    Text(
                      localPending == null
                          ? 'Click a day to select just that day, or double-click to start a range (double-click another day to finish it).'
                          : (_dateOnly(localPending!.start) ==
                                  _dateOnly(localPending!.end)
                              ? 'Day: ${_fmtShortDate(localPending!.start)}'
                              : 'Range: ${_fmtShortDate(localPending!.start)} - ${_fmtShortDate(localPending!.end)}'),
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      child: MultiMonthRangePicker(
                        earliestMonth: earliestMonth,
                        latestMonth: latestMonth,
                        initialStart: _dailyRange?.start,
                        initialEnd: _dailyRange?.end,
                        onPendingChanged: (range) =>
                            setDialogState(() => localPending = range),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        // Bug fix: neither button had an explicit style, so
                        // their resting color fell back to the app-wide
                        // seed-green ColorScheme.primary (main.dart) instead
                        // of this viewer's institute theme.
                        TextButton(
                          onPressed: () => Navigator.pop(
                            dialogContext,
                            const _DailyRangeDialogResult(null),
                          ),
                          child: Text('Show all days',
                              style: TextStyle(color: _palette.dark)),
                        ),
                        const SizedBox(width: 4),
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('Cancel',
                              style: TextStyle(color: AppColors.textMuted)),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: localPending == null
                              ? null
                              : () => Navigator.pop(
                                    dialogContext,
                                    _DailyRangeDialogResult(localPending),
                                  ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _palette.dark,
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Apply'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        });
      },
    );

    if (result == null) return;

    setState(() {
      _range = 'daily';
      _dailyRange = result.range;
      // The chart always shows the full daily trend (see
      // _dailyHighlightIndices) -- refresh _historyData to the full list in
      // case _range was something else (weekly/monthly/yearly) before this
      // picker was opened.
      _historyData = _parseRangeEntries(
        _historyRoot,
        'daily',
        _deletedEntriesByRange['daily'] ?? {},
      );
    });
    // Keep the deleted-entries listener in sync with the active range, same
    // as switching tabs/granularity does.
    _listenAll();
  }

  Future<void> _showRangeDropdown(
      BuildContext btnContext, String rangeKey, Offset globalTap) async {
    final entries = _parseRangeEntries(
      _historyRoot,
      rangeKey,
      _deletedEntriesByRange[rangeKey] ?? {},
    );
    if (entries.isEmpty) return;

    final overlay =
        Overlay.of(btnContext).context.findRenderObject() as RenderBox?;
    final btnBox = btnContext.findRenderObject() as RenderBox?;
    if (overlay == null || btnBox == null) return;

    final btnTopLeft = btnBox.localToGlobal(Offset.zero, ancestor: overlay);
    final top = btnTopLeft.dy + btnBox.size.height;
    final bottom = overlay.size.height - top;

    final rawMenuWidth = btnBox.size.width + 24;
    final menuWidth = rawMenuWidth.clamp(160.0, overlay.size.width - 40.0);

    double desiredLeft = btnTopLeft.dx;
    if (desiredLeft + menuWidth > overlay.size.width - 12.0) {
      desiredLeft = btnTopLeft.dx + btnBox.size.width - menuWidth;
    }
    desiredLeft =
        desiredLeft.clamp(12.0, overlay.size.width - menuWidth - 12.0);

    final adjustedRight = overlay.size.width - desiredLeft - menuWidth;
    final adjustedPosition =
        RelativeRect.fromLTRB(desiredLeft, top, adjustedRight, bottom);

    // Cap how many menu items get built. A long-running system can
    // accumulate hundreds/thousands of periods, and building one
    // PopupMenuItem per entry with no limit froze the UI. Entries are
    // already sorted ascending, so the tail is the most recent ones.
    const maxMenuItems = 60;
    final showTruncated = entries.length > maxMenuItems;
    final offset = showTruncated ? entries.length - maxMenuItems : 0;
    final visibleEntries = showTruncated ? entries.sublist(offset) : entries;

    final selected = await showMenu<int>(
      context: btnContext,
      position: adjustedPosition,
      items: [
        if (showTruncated)
          PopupMenuItem<int>(
            enabled: false,
            child: SizedBox(
              width: menuWidth,
              child: Center(
                child: Text(
                  'Showing latest $maxMenuItems of ${entries.length}',
                  style:
                      const TextStyle(fontSize: 11, color: AppColors.textMuted),
                ),
              ),
            ),
          ),
        ...List.generate(visibleEntries.length, (i) {
          final label = visibleEntries[i]['label'].toString();
          return PopupMenuItem<int>(
            value: offset + i,
            child: SizedBox(
              width: menuWidth,
              child: Center(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          );
        }),
      ],
    );

    if (selected == null) return;

    setState(() {
      _range = rangeKey;
      _historyData = entries;
    });
    _listenAll();
  }

  Widget _summaryCard(String value, IconData icon, String subtitle) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: _palette.mid.withAlpha(26),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: _palette.mid),
        ),
        const SizedBox(height: 14),
        Text(value,
            style: const TextStyle(
                fontFamily: 'Outfit',
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppColors.textDark)),
        const SizedBox(height: 4),
        Text(subtitle,
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
      ]),
    );
  }

  Widget _buildLineChart() {
    final chartDataLoading = _historyData.isEmpty && _isLoading;
    final chartData =
        chartDataLoading ? placeholderHistoryList() : _historyData;
    final canSwitchChart = chartData.length > 1;
    final yAxisLabels = _chartYAxisLabels();
    final chartMaxKwh = _chartMaxForRange(_range);
    final (int?, int?) dailyHighlight =
        chartDataLoading ? (null, null) : _dailyHighlightIndices();
    final dailyHighlightStart = dailyHighlight.$1;
    final dailyHighlightEnd = dailyHighlight.$2;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Consumption Trend',
                      style: TextStyle(
                        fontFamily: 'Outfit',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'kWh over time (realtime)',
                      style:
                          TextStyle(fontSize: 11, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              if (canSwitchChart) ...[
                _chartTypeButton('line', Icons.show_chart),
                const SizedBox(width: 6),
                _chartTypeButton('bar', Icons.bar_chart),
              ],
            ],
          ),
          const SizedBox(height: 20),
          chartData.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 30),
                    child: Text(
                      'No data yet',
                      style:
                          TextStyle(fontSize: 13, color: AppColors.textMuted),
                    ),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final chartWidth = (chartData.length * 54.0)
                        .clamp(constraints.maxWidth, constraints.maxWidth * 2.8)
                        .toDouble();
                    final values = chartData
                        .map((d) => (d['kwh'] as num).toDouble())
                        .toList();
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 38,
                          height: 200,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: yAxisLabels
                                .map(
                                  (label) => Text(
                                    label,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Scrollbar(
                            controller: _chartScrollController,
                            thumbVisibility: true,
                            trackVisibility: true,
                            child: SingleChildScrollView(
                              controller: _chartScrollController,
                              scrollDirection: Axis.horizontal,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: SizedBox(
                                  width: chartWidth,
                                  height: 200,
                                  child: CustomPaint(
                                    painter: _trendChartType == 'bar'
                                        ? BarChartPainter(
                                            data: values,
                                            maxKwh: chartMaxKwh,
                                            highlightStartIndex:
                                                dailyHighlightStart,
                                            highlightEndIndex:
                                                dailyHighlightEnd,
                                            highlightColor: AppColors.warning,
                                          )
                                        : LineChartPainter(
                                            data: values,
                                            maxKwh: chartMaxKwh,
                                            highlightStartIndex:
                                                dailyHighlightStart,
                                            highlightEndIndex:
                                                dailyHighlightEnd,
                                            highlightColor: AppColors.warning,
                                          ),
                                    child: Container(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
          const SizedBox(height: 8),
          if (chartData.isNotEmpty)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  chartData.first['label'],
                  style:
                      const TextStyle(fontSize: 9, color: AppColors.textMuted),
                ),
                if (chartData.length > 2)
                  Text(
                    chartData[chartData.length ~/ 2]['label'],
                    style: const TextStyle(
                        fontSize: 9, color: AppColors.textMuted),
                  ),
                Text(
                  chartData.last['label'],
                  style:
                      const TextStyle(fontSize: 9, color: AppColors.textMuted),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _chartTypeButton(String type, IconData icon) {
    final isSelected = _trendChartType == type;
    return GestureDetector(
      onTap: () {
        if (_trendChartType == type) return;
        setState(() => _trendChartType = type);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? _palette.dark : _palette.pale,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: isSelected
                  ? _palette.dark
                  : _palette.mid.withAlpha(80)),
        ),
        child: Icon(
          icon,
          size: 14,
          color: isSelected ? Colors.white : _palette.dark,
        ),
      ),
    );
  }

  Widget _buildPredictionCard() {
    final series = _buildPredictionSeries();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Next Month Prediction',
            style: TextStyle(
              fontFamily: 'Outfit',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textDark,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            series == null
                ? 'Waiting for daily RTDB history data.'
                : 'Forecast derived from live daily history in RTDB.',
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
          const SizedBox(height: 20),
          if (series == null || series.actualValues.length < 2)
            Container(
              height: 160,
              width: double.infinity,
              decoration: BoxDecoration(
                color: _palette.pale.withAlpha(70),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _palette.mid.withAlpha(28)),
              ),
              child: const Center(
                child: Text(
                  'Need at least 2 daily points to forecast',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            )
          else ...[
            LayoutBuilder(
              builder: (context, constraints) {
                final actualWindow = series.actualValues.length > 90
                    ? series.actualValues
                        .sublist(series.actualValues.length - 90)
                    : series.actualValues;
                final chartWidth = constraints.maxWidth;
                const chartHeight = 180.0;
                const chartMaxFixed = 150.0;
                const safeMax = chartMaxFixed;

                return Column(
                  children: [
                    SizedBox(
                      width: chartWidth,
                      height: chartHeight,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: CustomPaint(
                          painter: ForecastChartPainter(
                            actualData: actualWindow,
                            forecastData: series.forecastValues,
                            maxKwh: safeMax,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _miniForecastStat(
                            'Projected 30-day kWh',
                            series.predictedKwh.toStringAsFixed(2),
                            Icons.bolt,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _miniForecastStat(
                            'Estimated bill',
                            '₱ ${series.predictedBill.toStringAsFixed(2)}',
                            Icons.payments_outlined,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Semantic: paired against the fixed amber "Forecast"
                        // dot immediately after -- communicates the actual-vs-
                        // forecast data series, not brand chrome. Deliberately
                        // NOT retheme'd (matches mobile history_screen.dart).
                        _forecastLegendDot('Actual', AppColors.greenMid),
                        _forecastLegendDot('Forecast', const Color(0xFFF59E0B)),
                        Text(
                          'Rate: ₱ ${_electricityRate.toStringAsFixed(2)}/kWh',
                          style: const TextStyle(
                              fontSize: 10, color: AppColors.textMuted),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _miniForecastStat(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _palette.pale.withAlpha(65),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _palette.mid.withAlpha(28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: _palette.dark),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontFamily: 'Outfit',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textDark,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _forecastLegendDot(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label,
            style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
      ],
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

  Widget _buildDeviceStatusCard() {
    final total = _onlineCount + _offlineCount;
    final onlinePct = total == 0 ? 0.0 : _onlineCount / total;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Device Status',
            style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
              // Semantic: paired against AppColors.warning for the "Offline"
              // badge below -- communicates online/offline device state, not
              // brand chrome. Deliberately NOT retheme'd (matches mobile
              // history_screen.dart).
              child: _statusBadge(
                  'Online', _onlineCount, AppColors.greenMid, Icons.wifi)),
          const SizedBox(width: 12),
          Expanded(
              child: _statusBadge(
                  'Offline', _offlineCount, AppColors.warning, Icons.wifi_off)),
        ]),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: onlinePct,
            minHeight: 8,
            backgroundColor: AppColors.warning.withAlpha(50),
            // Semantic: same online/offline pairing as the badges above.
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.greenMid),
          ),
        ),
        const SizedBox(height: 6),
        Text('${(onlinePct * 100).toStringAsFixed(0)}% devices online',
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
      ]),
    );
  }

  Widget _statusBadge(String label, int count, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(50)),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$count',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontFamily: 'Outfit')),
          Text(label,
              style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
        ]),
      ]),
    );
  }

  Widget _buildTopUtilityCard() {
    if (_utilityTotals.isEmpty) return const SizedBox.shrink();
    final sorted = _utilityTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxVal = sorted.first.value;
    // Semantic: fixed categorical color-coding to visually distinguish
    // utility types from each other on this chart, not institute brand
    // chrome -- deliberately NOT retheme'd (default-to-institute here would
    // make different utility categories harder to tell apart, not easier).
    // Matches mobile history_screen.dart.
    final Map<String, Color> utilityColors = {
      'Lights': AppColors.greenMid,
      'Outlets': AppColors.greenLight,
      'AC': AppColors.greenDark,
    };
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Top Consuming Utilities',
            style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        const SizedBox(height: 16),
        ...sorted.map((e) {
          final pct = maxVal == 0 ? 0.0 : e.value / maxVal;
          final color = utilityColors[e.key] ?? AppColors.greenMid;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(e.key,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textDark)),
                Text('${e.value.toStringAsFixed(1)} kWh',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _palette.dark)),
              ]),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 8,
                  backgroundColor: color.withAlpha(30),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
            ]),
          );
        }),
      ]),
    );
  }

  Widget _buildTopBuildingCard() {
    if (_buildingTotals.isEmpty) return const SizedBox.shrink();
    final sorted = _buildingTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxVal = sorted.first.value;
    // Semantic: this card ranks *other* institutes/buildings by energy use
    // (not the viewer's own institute), so a rank-position gradient is used
    // instead of the viewer's resolved brand palette -- tinting institute B's
    // bar with institute A's viewer color would be actively misleading.
    // Deliberately NOT retheme'd (matches mobile history_screen.dart).
    final List<Color> barColors = [
      AppColors.greenDark,
      AppColors.greenMid,
      AppColors.greenLight,
      AppColors.greenPale.withAlpha(200),
      Colors.teal.shade400,
    ];
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Top Consuming Institutes',
            style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        const SizedBox(height: 16),
        ...sorted.asMap().entries.map((entry) {
          final i = entry.key;
          final e = entry.value;
          final pct = maxVal == 0 ? 0.0 : e.value / maxVal;
          final color = barColors[i % barColors.length];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  // Semantic: rank-position color, same reasoning as
                  // barColors above -- NOT retheme'd.
                  color: i == 0 ? AppColors.greenDark : AppColors.greenPale,
                  shape: BoxShape.circle,
                ),
                child: Center(
                    // Semantic: rank-position color, same reasoning as
                    // barColors above -- NOT retheme'd.
                    child: Text('${i + 1}',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color:
                                i == 0 ? Colors.white : AppColors.greenDark))),
              ),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(e.key,
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.textDark)),
                          Text('${e.value.toStringAsFixed(1)} kWh',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: _palette.dark)),
                        ]),
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: pct,
                        minHeight: 7,
                        backgroundColor: color.withAlpha(30),
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                      ),
                    ),
                  ])),
            ]),
          );
        }),
      ]),
    );
  }

  Widget _buildHistoryList() {
    final breakdownData = _breakdownListData();
    final listData = breakdownData.isEmpty && _isLoading
        ? placeholderHistoryList()
        : breakdownData;
    if (listData.isEmpty) return const SizedBox.shrink();
    final latestFirst = [...listData]
      ..sort((a, b) => b['label'].toString().compareTo(a['label'].toString()));
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Breakdown',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark)),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, constraints) {
            final crossAxisCount = constraints.maxWidth >= 900 ? 2 : 1;
            final entries = latestFirst.take(10).toList();
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: crossAxisCount == 2 ? 5.6 : 5.0,
              ),
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final d = entries[i];
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _palette.mid.withAlpha(20)),
                  ),
                  child: Row(children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                          color: _palette.pale,
                          borderRadius: BorderRadius.circular(8)),
                      child: Icon(Icons.calendar_today,
                          size: 16, color: _palette.dark),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Text(d['label'],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: AppColors.textDark))),
                    Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('${(d['kwh'] as num).toStringAsFixed(1)} kWh',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _palette.dark)),
                          Text('₱ ${(d['cost'] as num).toStringAsFixed(2)}',
                              style: const TextStyle(
                                  fontSize: 11, color: AppColors.textMuted)),
                        ]),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Delete history',
                      onPressed: _deletingHistoryKey == d['label']
                          ? null
                          : () => _deleteHistoryEntry(d['label'].toString()),
                      icon: _deletingHistoryKey == d['label']
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.delete_outline,
                              size: 18, color: AppColors.offline),
                    ),
                  ]),
                );
              },
            );
          }),
        ],
      ),
    );
  }
}

/// Result of the Daily calendar range dialog. Distinguishes "Apply/Show all
/// days pressed" (an instance of this class, possibly wrapping a `null`
/// range to mean "show everything") from "dialog dismissed without a
/// decision" (the `showDialog` future resolving to `null` itself), so
/// cancelling never changes what's currently displayed.
class _DailyRangeDialogResult {
  final DateTimeRange? range;
  const _DailyRangeDialogResult(this.range);
}

class _PredictionSeries {
  _PredictionSeries({
    required this.actualValues,
    required this.actualLabels,
    required this.forecastValues,
    required this.forecastLabels,
    required this.predictedKwh,
    required this.predictedBill,
    required this.averageRate,
  });

  final List<double> actualValues;
  final List<String> actualLabels;
  final List<double> forecastValues;
  final List<String> forecastLabels;
  final double predictedKwh;
  final double predictedBill;
  final double averageRate;
}
