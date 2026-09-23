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
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import 'web_forecast_cards.dart';
import 'web_theme.dart';
import 'web_trend_chart.dart';

/// The desktop "Analytics" section: Daily / Monthly totals, the last 30
/// days (or 6 months) as a line or bar trend, ARIMA vs XGBoost / LSTM
/// forecasts, top utility/building, and the organized Excel export. [HistoryScreen] itself is untouched -- this is
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
      _deletedEntries = deletedMap[_range] ?? {};
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
    setState(() => _range = key);
    _deletedEntries.clear();
    _listenAll();
  }

  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  List<Map<String, dynamic>> _dailyHistoryEntries() {
    return _parseRangeEntries(
      _historyRoot,
      'daily',
      _deletedEntriesByRange['daily'] ?? const {},
    );
  }

  DateTime? _tryParseDailyLabel(String label) => DateTime.tryParse(label);

  static const _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  static const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// The trend window: the last 30 days (Daily) or 6 months (Monthly)
  /// ending at the newest entry that isn't in the future. Missing days or
  /// months count as 0 so the axis stays evenly spaced. Stray old entries
  /// (e.g. from a device with an unset clock) fall outside the window.
  List<({DateTime date, double kwh})> _trendWindow() {
    final monthly = _range == 'monthly';
    final entries = _parseRangeEntries(
        _historyRoot, _range, _deletedEntriesByRange[_range] ?? {});
    final today = _dateOnly(DateTime.now());
    final byDate = <DateTime, double>{};
    for (final e in entries) {
      final label = e['label'].toString();
      final d = DateTime.tryParse(monthly ? '$label-01' : label);
      if (d == null || d.isAfter(today)) continue;
      byDate[_dateOnly(d)] = (byDate[_dateOnly(d)] ?? 0) + (e['kwh'] as double);
    }
    if (byDate.isEmpty) return const [];
    final last = byDate.keys.reduce((a, b) => a.isAfter(b) ? a : b);
    final count = monthly ? 6 : 30;
    return [
      for (var i = count - 1; i >= 0; i--)
        (() {
          final d = monthly
              ? DateTime(last.year, last.month - i, 1)
              : DateTime(last.year, last.month, last.day - i);
          return (date: d, kwh: byDate[d] ?? 0.0);
        })(),
    ];
  }

  String _windowLabel(List<({DateTime date, double kwh})> w) {
    if (_range != 'monthly') return 'Last 30 days';
    if (w.isEmpty) return 'Last 6 months';
    final a = w.first.date, b = w.last.date;
    return a.year == b.year
        ? '${_monthNames[a.month - 1]} – ${_monthNames[b.month - 1]} ${b.year}'
        : '${_monthNames[a.month - 1]} ${a.year} – ${_monthNames[b.month - 1]} ${b.year}';
  }

  List<TrendPoint> _trendPoints(List<({DateTime date, double kwh})> w) {
    final monthly = _range == 'monthly';
    return [
      for (final p in w)
        TrendPoint(
          monthly
              ? _monthNames[p.date.month - 1]
              : '${_monthNames[p.date.month - 1]} ${p.date.day}',
          monthly
              ? '${_monthNames[p.date.month - 1]} ${p.date.year} · ${p.kwh.toStringAsFixed(1)} kWh'
              : '${_monthNames[p.date.month - 1]} ${p.date.day} · ${_dayNames[p.date.weekday - 1]} · ${p.kwh.toStringAsFixed(1)} kWh',
          p.kwh,
        ),
    ];
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
    final window = _trendWindow();
    final windowLabel = _windowLabel(window);
    final totalKwh = window.fold<double>(0, (a, p) => a + p.kwh);
    final deviceTotal = _onlineCount + _offlineCount;
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: ScreenSkeleton(
      isLoading: _isLoading,
      child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Analytics',
                style: TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textDark)),
            const SizedBox(width: 12),
            _livePill(),
          ]),
          const SizedBox(height: 4),
          const Text('Energy analytics and forecast',
              style: TextStyle(fontSize: 14, color: WebColors.muted)),
          const SizedBox(height: 18),
          if (_errorText != null)
            _buildLoadError()
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _rangeTabs(),
                const SizedBox(width: 12),
                _softChip(windowLabel),
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
            const SizedBox(height: 18),
            _equalRow([
              _statCard(
                icon: Icons.bolt_rounded,
                value: _fmtNumber(totalKwh, decimals: 1),
                unit: 'kWh',
                label: 'Total energy',
                caption: windowLabel,
              ),
              _statCard(
                icon: Icons.payments_outlined,
                value: '₱${_fmtNumber(totalKwh * _electricityRate)}',
                label: 'Total cost',
                caption: 'At ₱${_electricityRate.toStringAsFixed(2)} per kWh',
              ),
              _statCard(
                icon: Icons.wifi_tethering_rounded,
                value: '$_onlineCount / $deviceTotal',
                label: 'Device status',
                caption: 'Online now',
              ),
            ]),
            const SizedBox(height: 20),
            _trendCard(window),
            const SizedBox(height: 20),
            _buildForecasts(),
            if (_utilityTotals.isNotEmpty || _buildingTotals.isNotEmpty) ...[
              const SizedBox(height: 16),
              _equalRow([
                if (_utilityTotals.isNotEmpty) _buildTopUtilityCard(),
                if (_buildingTotals.isNotEmpty) _buildTopBuildingCard(),
              ]),
            ],
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
            color: _palette.pale, borderRadius: BorderRadius.circular(20)),
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

  Widget _softChip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
            color: _palette.pale.withAlpha(200),
            borderRadius: BorderRadius.circular(9)),
        child: Text(text,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: _palette.dark)),
      );

  /// Segmented pill: a white "thumb" on the selected option.
  Widget _segmented(
      Map<String, String> options, String selected, ValueChanged<String> onTap) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
          color: _palette.pale.withAlpha(170),
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

  Widget _rangeTabs() => _segmented(
        const {'daily': 'Daily', 'monthly': 'Monthly'},
        _range == 'monthly' ? 'monthly' : 'daily',
        (k) {
          if (k != _range) _setRange(k);
        },
      );

  Widget _statCard({
    required IconData icon,
    required String value,
    String? unit,
    required String label,
    required String caption,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(22)),
      ),
      child: Row(children: [
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
              color: _palette.pale.withAlpha(200), shape: BoxShape.circle),
          child: Icon(icon, color: _palette.dark, size: 24),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: value,
                    style: const TextStyle(
                        fontFamily: 'Outfit',
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: WebColors.ink)),
                if (unit != null)
                  TextSpan(
                      text: ' $unit',
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: WebColors.mid)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(label,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: WebColors.ink)),
            Text(caption,
                style: const TextStyle(fontSize: 12.5, color: WebColors.muted)),
          ]),
        ),
      ]),
    );
  }

  Widget _trendCard(List<({DateTime date, double kwh})> window) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(22)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Consumption Trend',
                  style: TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: WebColors.ink)),
              SizedBox(height: 2),
              Text('kWh over time (realtime) · hover for values',
                  style: TextStyle(fontSize: 13, color: WebColors.muted)),
            ]),
          ),
          _segmented(const {'line': 'Line', 'bar': 'Bar'}, _trendChartType,
              (k) => setState(() => _trendChartType = k)),
        ]),
        const SizedBox(height: 16),
        if (window.isEmpty)
          const SizedBox(
            height: 200,
            child: Center(
              child: Text('No data yet',
                  style: TextStyle(fontSize: 14, color: WebColors.muted)),
            ),
          )
        else
          WebTrendChart(
            points: _trendPoints(window),
            bars: _trendChartType == 'bar',
            color: AppColors.greenMid,
          ),
      ]),
    );
  }

  /// ARIMA (left) and a model picker (right) over the daily history.
  Widget _buildForecasts() {
    final daily = _dailyHistoryEntries();
    return ForecastComparison(
      palette: _palette,
      daily: [for (final e in daily) (e['kwh'] as num).toDouble()],
      lastDate: daily.isEmpty
          ? null
          : _tryParseDailyLabel(daily.last['label'].toString()),
      rate: _electricityRate,
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
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textDark)),
                Text('${e.value.toStringAsFixed(1)} kWh',
                    style: TextStyle(
                        fontSize: 13,
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
                            fontSize: 11,
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
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.textDark)),
                          Text('${e.value.toStringAsFixed(1)} kWh',
                              style: TextStyle(
                                  fontSize: 13,
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
}
