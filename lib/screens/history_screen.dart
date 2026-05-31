import 'dart:async';
import 'dart:typed_data';
import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_xlsio/xlsio.dart' as xlsio;
import '../theme/app_colors.dart';
import '../widgets/top_toast.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String _range = 'daily';
  String _trendChartType = 'line';
  bool _exporting = false;
  String? _deletingHistoryKey;
  int? _chartSelectedIndex;
  // selection is handled via dropdown or tap; hover/magnify removed

  final List<Map<String, String>> _ranges = [
    {'key': 'daily', 'label': 'Daily'},
    {'key': 'weekly', 'label': 'Weekly'},
    {'key': 'monthly', 'label': 'Monthly'},
    {'key': 'yearly', 'label': 'Yearly'},
  ];

  StreamSubscription? _devicesSub;
  StreamSubscription? _historySub;
  StreamSubscription? _deletedSub;
  StreamSubscription? _settingsSub;

  Map<String, dynamic> _historyRoot = {};
  List<Map<String, dynamic>> _historyData = [];
  Set<String> _deletedEntries = {}; // Tracks deleted tombstones for current range
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

  @override
  void initState() {
    super.initState();
    _listenDevices();
    _listenHistory();
    _listenSettings();
  }

  @override
  void dispose() {
    _devicesSub?.cancel();
    _historySub?.cancel();
    _deletedSub?.cancel();
    _settingsSub?.cancel();
    super.dispose();
  }

  double _electricityRate = 11.5;

  void _listenSettings() {
    _settingsSub = FirebaseDatabase.instance
        .ref('settings/electricityRate')
        .onValue
        .listen((event) {
      final rate = (event.snapshot.value as num?)?.toDouble() ?? 11.5;
      if (mounted) setState(() => _electricityRate = rate);
    }, onError: (_) {});
  }

  void _listenDevices() {
    _devicesSub =
        FirebaseDatabase.instance.ref('devices').onValue.listen((event) {
      final raw = event.snapshot.value;
      if (raw == null) return;

      final data = Map<String, dynamic>.from(raw as Map);
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

      if (mounted) {
        setState(() {
          _utilityTotals = utilityTotals;
          _buildingTotals = buildingTotals;
          _onlineCount = online;
          _offlineCount = offline;
        });
      }
    });
  }

  void _listenHistory() {
    _historySub?.cancel();
    _deletedSub?.cancel();

    _deletedSub = FirebaseDatabase.instance
        .ref('history/deleted/$_range')
        .onValue
        .listen((event) {
          final deleted = <String>{};
          if (event.snapshot.value is Map) {
            final map = Map<String, dynamic>.from(event.snapshot.value as Map);
            deleted.addAll(map.keys);
          }
          if (mounted) {
            setState(() {
              _deletedEntries = deleted;
              _deletedEntriesByRange[_range] = deleted;
            });
          }
          _updateHistoryDisplay();
        });

    _historySub = FirebaseDatabase.instance.ref('history').onValue.listen((event) {
      _updateHistoryDisplay();
    });
  }
  
  Future<void> _updateHistoryDisplay() async {
    if (!mounted) return;
    final snapshot = await FirebaseDatabase.instance.ref('history').get();
    if (snapshot.value is! Map) {
      if (mounted) {
        setState(() {
          _historyRoot = {};
          _historyData = [];
        });
      }
      return;
    }

    final root = Map<String, dynamic>.from(snapshot.value as Map);
    final deletedMap = <String, Set<String>>{};
    for (final range in ['daily', 'weekly', 'monthly', 'yearly']) {
      final deletedSnapshot =
          await FirebaseDatabase.instance.ref('history/deleted/$range').get();
      final deleted = <String>{};
      if (deletedSnapshot.value is Map) {
        final map = Map<String, dynamic>.from(deletedSnapshot.value as Map);
        deleted.addAll(map.keys);
      }
      deletedMap[range] = deleted;
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
      _historyData = list;
      if (_chartSelectedIndex != null &&
          (_chartSelectedIndex! < 0 || _chartSelectedIndex! >= _historyData.length)) {
        _chartSelectedIndex = null;
      }
    });
  }

  Map<String, dynamic> _pickRangeNode(
      Map<String, dynamic> root, String targetRange) {
    final direct = root[targetRange];
    if (direct is Map) {
      final directMap = Map<String, dynamic>.from(direct);
      if (_matchingKeyCount(directMap, targetRange) > 0) return directMap;
    }

    // Do not fall back to another range bucket here.
    // If the requested bucket is missing or malformed, the caller will
    // fall back to raw history grouping instead of borrowing another range.
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
      _chartSelectedIndex = null;
    });
    _deletedEntries.clear();
    _listenHistory();
  }

  void _updateChartSelection(Offset localPosition, Size size) {
    if (_historyData.isEmpty || size.width <= 0 || size.height <= 0) {
      return;
    }

    final index = _trendChartType == 'bar'
        ? _indexForBarPosition(localPosition.dx, size.width)
        : _indexForLinePosition(localPosition.dx, size.width);

    if (index == null) return;
    if (_chartSelectedIndex == index) return;
    setState(() => _chartSelectedIndex = index);
  }

  int? _indexForLinePosition(double x, double width) {
    if (_historyData.length < 2) return null;
    final stepX = width / (_historyData.length - 1);
    if (stepX <= 0) return null;
    final index = (x / stepX).round().clamp(0, _historyData.length - 1);
    return index;
  }

  int? _indexForBarPosition(double x, double width) {
    if (_historyData.isEmpty) return null;
    final slotWidth = width / _historyData.length;
    if (slotWidth <= 0) return null;
    final index = (x / slotWidth).floor().clamp(0, _historyData.length - 1);
    return index;
  }

  String _chartSelectionTitle() {
    if (_chartSelectedIndex == null ||
        _chartSelectedIndex! < 0 ||
        _chartSelectedIndex! >= _historyData.length) {
      return 'Tap or hover a point';
    }

    final entry = _historyData[_chartSelectedIndex!];
    final label = entry['label'].toString();
    final kwh = (entry['kwh'] as num).toDouble();

    final rangeLabel = switch (_range) {
      'daily' => 'Day',
      'weekly' => 'Week',
      'monthly' => 'Month',
      'yearly' => 'Year',
      _ => 'Period',
    };

    return '$rangeLabel: $label · ${kwh.toStringAsFixed(2)} kWh';
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
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _deletingHistoryKey = label);

    try {
      await FirebaseDatabase.instance
          .ref('history/$_range/$label')
          .remove();

      await FirebaseDatabase.instance
          .ref('history/deleted/$_range/$label')
          .set(true);

      if (mounted) {
        TopToast.threshold(context, 'Deleted ${_capitalizeFirst(_range)} history.');
      }
      _listenHistory();
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

    // Removed unused total getters (_totalKwh, _totalCost) — totals are
    // computed via _currentPeriodTotals() or by folding over _historyData
    // where needed.

  /// Compute totals for the currently-selected range but limited to the
  /// "current period" (today / this week / this month / this year).
  Map<String, double> _currentPeriodTotals() {
    final entries = _parseRangeEntries(
      _historyRoot,
      _range,
      _deletedEntriesByRange[_range] ?? {},
    );

    if (entries.isEmpty) return {'kwh': 0.0, 'cost': 0.0};

    final now = DateTime.now();
    final currentLabel = _rangeLabel(now, _range);

    final filtered = entries.where((e) {
      final label = e['label'].toString();
      if (_range == 'monthly') {
        // monthly labels are YYYY-MM, keep any label within current month
        return label.startsWith(currentLabel);
      }
      // daily, weekly, yearly labels should match exactly
      return label == currentLabel;
    }).toList();

    final kwh = filtered.fold<double>(0.0, (s, e) => s + (e['kwh'] as double));
    final cost = filtered.fold<double>(0.0, (s, e) => s + (e['cost'] as double));
    return {'kwh': kwh, 'cost': cost};
  }

  String _currentPeriodLabel() {
    switch (_range) {
      case 'daily':
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
      return List<double>.filled(horizon, history.first < 0 ? 0.0 : history.first);
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

    final actualValues = dailyEntries
        .map((entry) => (entry['kwh'] as num).toDouble())
        .toList();
    final actualLabels = dailyEntries
        .map((entry) => entry['label'].toString())
        .toList();

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

    final predictedKwh = forecastValues.fold<double>(0.0, (sum, value) => sum + value);
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

  // ── CSV Export ───────────────────────────────────────────────────────────────
  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  List<Map<String, dynamic>> _parseRangeEntries(
      Map<String, dynamic> root, String rangeKey, [Set<String> deleted = const {}]) {
    final directRangeNode = root[rangeKey];
    final hasDirectRangeNode = directRangeNode is Map &&
      _matchingKeyCount(Map<String, dynamic>.from(directRangeNode), rangeKey) > 0;
    final data = hasDirectRangeNode
      ? Map<String, dynamic>.from(directRangeNode)
      : _pickRangeNode(root, rangeKey);
    final list = <Map<String, dynamic>>[];

    data.forEach((key, val) {
      if (val is! Map) return;
      // Skip deleted entries
      if (deleted.contains(key)) return;
      
      final entry = Map<String, dynamic>.from(val);
      list.add({
        'label': key,
        'kwh': _asDouble(entry['kwh'] ?? entry['total_kwh']),
        'cost': _asDouble(entry['cost'] ?? entry['total_cost']),
      });
    });

    if (list.isNotEmpty || hasDirectRangeNode) {
      list.sort((a, b) => a['label'].toString().compareTo(b['label'].toString()));
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

      final bucket = grouped.putIfAbsent(label, () => {
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

  // ignore: unused_element
  ({String fileName, String csvData, bool hasData}) _createCsvPayload(
      Map<String, dynamic> historyRoot) {
    final now = DateTime.now();
    final timestamp = '${now.year}-${_pad(now.month)}-${_pad(now.day)}_'
        '${_pad(now.hour)}-${_pad(now.minute)}';

    final clustered = <String, List<Map<String, dynamic>>>{
      'daily': _parseRangeEntries(historyRoot, 'daily'),
      'weekly': _parseRangeEntries(historyRoot, 'weekly'),
      'monthly': _parseRangeEntries(historyRoot, 'monthly'),
      'yearly': _parseRangeEntries(historyRoot, 'yearly'),
    };
    final hasData = clustered.values.any((list) => list.isNotEmpty);

    final List<List<dynamic>> rows = [];
    rows.add(['SmartPowerSwitch Energy Report']);
    rows.add(['Institution', 'Davao del Norte State College']);
    rows.add(['Report Scope', 'Clustered daily, weekly, monthly, yearly']);
    rows.add([
      'Generated',
      '${now.year}-${_pad(now.month)}-${_pad(now.day)} '
          '${_pad(now.hour)}:${_pad(now.minute)}'
    ]);
    rows.add([]);
    rows.add(['Indicator Legend']);
    rows.add(['RED_HIGH', 'High consumption']);
    rows.add(['AMBER_NORMAL', 'Moderate consumption']);
    rows.add(['GREEN_LOW', 'Lower consumption']);
    rows.add(['BLUE_UP/DOWN/STABLE', 'Trend versus previous cluster']);
    rows.add([]);

    final orderedRanges = [
      {'key': 'yearly', 'label': 'Yearly'},
      {'key': 'monthly', 'label': 'Monthly'},
      {'key': 'weekly', 'label': 'Weekly'},
      {'key': 'daily', 'label': 'Daily'},
    ];

    for (final range in orderedRanges) {
      final key = range['key']!;
      final label = range['label']!;
      final entries = clustered[key] ?? const <Map<String, dynamic>>[];

      rows.add(['$label Cluster']);
      if (entries.isEmpty) {
        rows.add(['No data available for $label cluster.']);
        rows.add([]);
        continue;
      }

      final totalKwh =
          entries.fold<double>(0.0, (sum, e) => sum + (e['kwh'] as double));
      final totalCost =
          entries.fold<double>(0.0, (sum, e) => sum + (e['cost'] as double));
      final avgKwh = entries.isEmpty ? 0.0 : totalKwh / entries.length;
      final peak = entries.reduce(
          (a, b) => (a['kwh'] as double) >= (b['kwh'] as double) ? a : b);

      rows.add(['Cluster count', entries.length]);
      rows.add(['Total energy (kWh)', totalKwh.toStringAsFixed(2)]);
      rows.add(['Total cost (PHP)', totalCost.toStringAsFixed(2)]);
      rows.add(['Average energy per cluster (kWh)', avgKwh.toStringAsFixed(2)]);
      rows.add(['Peak cluster', peak['label'], (peak['kwh'] as double).toStringAsFixed(2)]);
      rows.add([]);

      rows.add([
        'Cluster',
        'Energy (kWh)',
        'Cost (PHP)',
        'Share (%)',
        'Level Indicator',
        'Trend Indicator',
        'Cluster Analysis'
      ]);

      double? previousKwh;
      for (final entry in entries) {
        final kwh = entry['kwh'] as double;
        final cost = entry['cost'] as double;
        final share = totalKwh == 0 ? 0.0 : (kwh / totalKwh) * 100;
        final level = _levelIndicator(kwh, avgKwh);
        final trend = _trendIndicator(kwh, previousKwh);
        final analysis = _clusterAnalysis(level, trend);

        rows.add([
          entry['label'],
          kwh.toStringAsFixed(2),
          cost.toStringAsFixed(2),
          share.toStringAsFixed(2),
          level,
          trend,
          analysis,
        ]);

        previousKwh = kwh;
      }

      rows.add([]);
    }

    if (_buildingTotals.isNotEmpty) {
      rows.add(['Building Breakdown']);
      rows.add(['Institute', 'Energy (kWh)']);
      final sortedBuildings = _buildingTotals.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in sortedBuildings) {
        rows.add([e.key, e.value.toStringAsFixed(2)]);
      }
      rows.add([]);
    }

    if (_utilityTotals.isNotEmpty) {
      rows.add(['Utility Breakdown']);
      rows.add(['Utility', 'Energy (kWh)']);
      final sortedUtilities = _utilityTotals.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in sortedUtilities) {
        rows.add([e.key, e.value.toStringAsFixed(2)]);
      }
      rows.add([]);
    }

    rows.add(['Device Status']);
    rows.add(['Online Devices', '$_onlineCount']);
    rows.add(['Offline Devices', '$_offlineCount']);

    final csvData = const ListToCsvConverter().convert(rows);
    final fileName = 'SmartPowerSwitch_Clustered_Report_$timestamp.csv';
    return (fileName: fileName, csvData: csvData, hasData: hasData);
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
      
      // Fetch deleted entries for all ranges
      final deletedMap = <String, Set<String>>{};
      for (final range in ['daily', 'weekly', 'monthly', 'yearly']) {
        final deletedSnapshot = 
            await FirebaseDatabase.instance.ref('history/deleted/$range').get();
        final deleted = <String>{};
        if (deletedSnapshot.value is Map) {
          final map = Map<String, dynamic>.from(deletedSnapshot.value as Map);
          deleted.addAll(map.keys);
        }
        deletedMap[range] = deleted;
      }
      
      final clustered = <String, List<Map<String, dynamic>>>{
        'yearly': _parseRangeEntries(historyRoot, 'yearly', deletedMap['yearly'] ?? {}),
        'monthly': _parseRangeEntries(historyRoot, 'monthly', deletedMap['monthly'] ?? {}),
        'weekly': _parseRangeEntries(historyRoot, 'weekly', deletedMap['weekly'] ?? {}),
        'daily': _parseRangeEntries(historyRoot, 'daily', deletedMap['daily'] ?? {}),
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
      writeRow(overview, r++, [
        'Range',
        'Clusters',
        'Total kWh',
        'Total Cost (PHP)',
        'Avg kWh/Cluster',
        'Peak Cluster',
        'Peak kWh'
      ], style: headerStyle);

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
      writeRow(
          overview, r++, ['Increasing/Decreasing/Stable', 'Trend versus previous cluster']);
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
        writeRow(sheet, row++, ['Total energy (kWh)', totalKwh.toStringAsFixed(2)]);
        writeRow(sheet, row++, ['Total cost (PHP)', totalCost.toStringAsFixed(2)]);
        writeRow(sheet, row++, ['Average energy per cluster (kWh)', avgKwh.toStringAsFixed(2)]);
        writeRow(sheet, row++, ['Peak cluster', peak['label'].toString()]);
        writeRow(sheet, row++, ['']);
        writeRow(sheet, row++, [
          'Cluster',
          'Energy (kWh)',
          'Cost (PHP)',
          'Share (%)',
          'Level Indicator',
          'Trend Indicator',
          'Cluster Analysis'
        ], style: headerStyle);

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
        // Keep analysis column readable after auto-fit.
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

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(children: [
          _buildHeader(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildRangeSelector(),
                    const SizedBox(height: 20),
                    _buildSummaryRow(),
                    const SizedBox(height: 20),
                    _buildLineChart(),
                    const SizedBox(height: 20),
                    _buildPredictionCard(),
                    const SizedBox(height: 20),
                    _buildDeviceStatusCard(),
                    const SizedBox(height: 20),
                    _buildTopUtilityCard(),
                    const SizedBox(height: 20),
                    _buildTopBuildingCard(),
                    const SizedBox(height: 20),
                    _buildHistoryList(),
                    const SizedBox(height: 20),
                    _buildExportButton(),
                  ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      decoration: const BoxDecoration(
        color: AppColors.greenDark,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(38),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.arrow_back_ios_new,
                color: Colors.white, size: 16),
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Text('Energy Analytics',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(38),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(children: [
            Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                    color: AppColors.greenLight, shape: BoxShape.circle)),
            const SizedBox(width: 5),
            const Text('Live',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.white,
                    fontWeight: FontWeight.w600)),
          ]),
        ),
      ]),
    );
  }

  Widget _buildRangeSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 52,
          decoration: BoxDecoration(
              color: AppColors.greenPale,
              borderRadius: BorderRadius.circular(12)),
          child: Row(
            children: _ranges.asMap().entries.map((entry) {
              final index = entry.key;
              final r = entry.value;
              final isSelected = _range == r['key'];
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    index == 0 ? 6 : 3,
                    6,
                    index == _ranges.length - 1 ? 6 : 3,
                    6,
                  ),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _setRange(r['key']!),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected ? AppColors.greenDark : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              r['label']!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: isSelected ? Colors.white : AppColors.textMid,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Builder(builder: (btnContext) {
                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown: (details) => _showRangeDropdown(
                                btnContext,
                                r['key']!,
                                details.globalPosition,
                              ),
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: Center(
                                  child: Icon(
                                    Icons.arrow_drop_down,
                                    size: 20,
                                    color: isSelected ? Colors.white : AppColors.textMid,
                                  ),
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),

        // Accordion replaced by dropdown menu anchored to the button.
      ],
    );
  }

  Future<void> _showRangeDropdown(BuildContext btnContext, String rangeKey, Offset globalTap) async {
    final entries = _parseRangeEntries(
      _historyRoot,
      rangeKey,
      _deletedEntriesByRange[rangeKey] ?? {},
    );
    if (entries.isEmpty) return;

    final overlay = Overlay.of(btnContext).context.findRenderObject() as RenderBox?;
    final btnBox = btnContext.findRenderObject() as RenderBox?;
    if (overlay == null || btnBox == null) return;

    final btnTopLeft = btnBox.localToGlobal(Offset.zero, ancestor: overlay);
    final top = btnTopLeft.dy + btnBox.size.height;
    final bottom = overlay.size.height - top;

    final rawMenuWidth = btnBox.size.width + 24;
    final menuWidth = rawMenuWidth.clamp(160.0, overlay.size.width - 40.0);

    // Ensure the menu is positioned so it does not overflow the screen to the left.
    double desiredLeft = btnTopLeft.dx;
    // If there's not enough space to the right of the button, try aligning the menu to the button's right edge.
    if (desiredLeft + menuWidth > overlay.size.width - 12.0) {
      desiredLeft = btnTopLeft.dx + btnBox.size.width - menuWidth;
    }
    // Clamp into visible area with a small margin.
    desiredLeft = desiredLeft.clamp(12.0, overlay.size.width - menuWidth - 12.0);

    final adjustedRight = overlay.size.width - desiredLeft - menuWidth;
    final adjustedPosition = RelativeRect.fromLTRB(desiredLeft, top, adjustedRight, bottom);

    final selected = await showMenu<int>(
      context: btnContext,
      position: adjustedPosition,
      items: List.generate(entries.length, (i) {
        final label = entries[i]['label'].toString();
        return PopupMenuItem<int>(
          value: i,
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
    );

    if (selected == null) return;

    setState(() {
      _range = rangeKey;
      _historyData = entries;
      _chartSelectedIndex = selected;
    });
    _listenHistory();
  }

  Widget _buildSummaryRow() {
    final totals = _currentPeriodTotals();
    final periodLabel = _currentPeriodLabel();
    return Row(children: [
      Expanded(
        child: _summaryCard('', '${totals['kwh']!.toStringAsFixed(1)} kWh', Icons.bolt, subtitle: periodLabel)),
      const SizedBox(width: 12),
      Expanded(
        child: _summaryCard('', '₱ ${totals['cost']!.toStringAsFixed(0)}', Icons.payments_outlined, subtitle: periodLabel)),
    ]);
  }

  Widget _summaryCard(String label, String value, IconData icon, {String? subtitle}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.greenMid.withAlpha(26)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: AppColors.greenMid),
        const SizedBox(height: 10),
        Text(value,
          style: const TextStyle(
            fontFamily: 'Outfit',
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.textDark)),
        if (label.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(label,
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
        ],
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle,
              style: const TextStyle(fontSize: 11, color: AppColors.textMid)),
        ],
      ]),
    );
  }

  Widget _buildLineChart() {
    final canSwitchChart = _historyData.length > 1;
    final yAxisLabels = _chartYAxisLabels();
    final chartMaxKwh = _chartMaxForRange(_range);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.greenMid.withAlpha(26)),
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
                      style: TextStyle(fontSize: 11, color: AppColors.textMuted),
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
          _historyData.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 30),
                    child: Text(
                      'No data yet',
                      style: TextStyle(fontSize: 13, color: AppColors.textMuted),
                    ),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final chartWidth = (_historyData.length * 54.0)
                        .clamp(constraints.maxWidth, constraints.maxWidth * 2.8)
                        .toDouble();
                    final chartSize = Size(chartWidth, 160);
                    final values = _historyData
                        .map((d) => (d['kwh'] as num).toDouble())
                        .toList();
                    return Column(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 38,
                              height: 160,
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
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapDown: (details) => _updateChartSelection(
                                    details.localPosition,
                                    chartSize,
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(14),
                                    child: SizedBox(
                                      width: chartWidth,
                                      height: 160,
                                      child: CustomPaint(
                                        painter: _trendChartType == 'bar'
                                            ? _BarChartPainter(
                                                data: values,
                                                maxKwh: chartMaxKwh,
                                                selectedIndex: _chartSelectedIndex,
                                              )
                                            : _LineChartPainter(
                                                data: values,
                                                maxKwh: chartMaxKwh,
                                                selectedIndex: _chartSelectedIndex,
                                              ),
                                        child: Container(),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          child: Container(
                            key: ValueKey(_chartSelectedIndex ?? -1),
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: _chartSelectedIndex == null
                                  ? AppColors.greenPale.withAlpha(90)
                                  : AppColors.greenDark.withAlpha(18),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _chartSelectedIndex == null
                                    ? AppColors.greenMid.withAlpha(36)
                                    : AppColors.greenDark.withAlpha(60),
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _chartSelectionTitle(),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: _chartSelectedIndex == null
                                        ? AppColors.textMuted
                                        : AppColors.greenDark,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Pinch to zoom, drag to pan, hover or tap a point',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: AppColors.textMuted.withAlpha(210),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
          const SizedBox(height: 8),
          if (_historyData.isNotEmpty)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _historyData.first['label'],
                  style: const TextStyle(fontSize: 9, color: AppColors.textMuted),
                ),
                if (_historyData.length > 2)
                  Text(
                    _historyData[_historyData.length ~/ 2]['label'],
                    style: const TextStyle(fontSize: 9, color: AppColors.textMuted),
                  ),
                Text(
                  _historyData.last['label'],
                  style: const TextStyle(fontSize: 9, color: AppColors.textMuted),
                ),
              ],
            ),
        ],
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
        border: Border.all(color: AppColors.greenMid.withAlpha(26)),
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
                color: AppColors.greenPale.withAlpha(70),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.greenMid.withAlpha(28)),
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
                    ? series.actualValues.sublist(series.actualValues.length - 90)
                    : series.actualValues;
                final chartWidth = constraints.maxWidth;
                const chartHeight = 180.0;
                // Force the predictive chart vertical range to 0 - 150
                const chartMaxFixed = 150.0;
                final safeMax = chartMaxFixed;

                return Column(
                  children: [
                    SizedBox(
                      width: chartWidth,
                      height: chartHeight,
                          child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: CustomPaint(
                          painter: _ForecastChartPainter(
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
                        _forecastLegendDot('Actual', const Color(0xFF2E9E52)),
                        _forecastLegendDot('Forecast', const Color(0xFFF59E0B)),
                        Text(
                          'Rate: ₱ ${_electricityRate.toStringAsFixed(2)}/kWh',
                          style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
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
        color: AppColors.greenPale.withAlpha(65),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.greenMid.withAlpha(28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.greenDark),
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
        Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
      ],
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
          color: isSelected ? AppColors.greenDark : AppColors.greenPale,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: isSelected
                  ? AppColors.greenDark
                  : AppColors.greenMid.withAlpha(80)),
        ),
        child: Icon(
          icon,
          size: 14,
          color: isSelected ? Colors.white : AppColors.greenDark,
        ),
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
        border: Border.all(color: AppColors.greenMid.withAlpha(26)),
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
    if (_utilityTotals.isEmpty) return const SizedBox();
    final sorted = _utilityTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxVal = sorted.first.value;
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
        border: Border.all(color: AppColors.greenMid.withAlpha(26)),
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
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.greenDark)),
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
    if (_buildingTotals.isEmpty) return const SizedBox();
    final sorted = _buildingTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxVal = sorted.first.value;
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
        border: Border.all(color: AppColors.greenMid.withAlpha(26)),
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
                  color: i == 0 ? AppColors.greenDark : AppColors.greenPale,
                  shape: BoxShape.circle,
                ),
                child: Center(
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
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.greenDark)),
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
    if (_historyData.isEmpty) return const SizedBox();
    final latestFirst = [..._historyData]
      ..sort((a, b) => b['label'].toString().compareTo(a['label'].toString()));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Breakdown',
            style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        const SizedBox(height: 12),
        ...latestFirst.take(10).map((d) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.greenMid.withAlpha(20)),
              ),
              child: Row(children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                      color: AppColors.greenPale,
                      borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.calendar_today,
                      size: 16, color: AppColors.greenDark),
                ),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(d['label'],
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textDark))),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${(d['kwh'] as num).toStringAsFixed(1)} kWh',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.greenDark)),
                  Text('₱ ${(d['cost'] as num).toStringAsFixed(2)}',
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textMuted)),
                ]),
                const SizedBox(width: 8),
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
            )),
      ],
    );
  }

  // ── Export Button ─────────────────────────────────────────────────────────────

  Widget _buildExportButton() {
    return Column(children: [
      // Info box
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.greenPale,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.greenMid.withAlpha(51)),
        ),
        child: const Row(children: [
          Icon(Icons.info_outline, size: 14, color: AppColors.greenMid),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Exports an organized workbook clustered by yearly, monthly, weekly, and daily data.',
              style: TextStyle(fontSize: 11, color: AppColors.textMid),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      SizedBox(
        width: double.infinity,
        height: 50,
        child: ElevatedButton.icon(
          onPressed: _exporting ? null : _exportOrganizedXlsx,
          icon: _exporting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : const Icon(Icons.download_outlined,
                  size: 18, color: Colors.white),
          label: Text(
            _exporting ? 'Generating...' : 'Export Organized Excel (.xlsx)',
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.greenDark,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    ]);
  }
}

// ── Line Chart CustomPainter ──────────────────────────────────────────────────

class _LineChartPainter extends CustomPainter {
  final List<double> data;
  final double maxKwh;
  final int? selectedIndex;
  _LineChartPainter({
    required this.data,
    required this.maxKwh,
    required this.selectedIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final safeMaxKwh = maxKwh <= 0 ? 1.0 : maxKwh;

    final linePaint = Paint()
      ..color = const Color(0xFF2E9E52)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFF2E9E52).withAlpha(80),
          const Color(0xFF2E9E52).withAlpha(0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    final stepX = data.length < 2 ? 0.0 : size.width / (data.length - 1);

    Offset off(int i) {
      final x = data.length == 1 ? size.width / 2 : i * stepX;
      final y = size.height - (data[i] / safeMaxKwh) * size.height;
      return Offset(x, y.clamp(0.0, size.height));
    }

    final gridPaint = Paint()
      ..color = const Color(0xFF2E9E52).withAlpha(20)
      ..strokeWidth = 1;
    for (int i = 1; i < 5; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final fillPath = Path();
    fillPath.moveTo(0, size.height);
    fillPath.lineTo(off(0).dx, off(0).dy);
    for (int i = 1; i < data.length; i++) {
      final prev = off(i - 1);
      final curr = off(i);
      final cp1 = Offset((prev.dx + curr.dx) / 2, prev.dy);
      final cp2 = Offset((prev.dx + curr.dx) / 2, curr.dy);
      fillPath.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, curr.dx, curr.dy);
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();
    canvas.drawPath(fillPath, fillPaint);

    if (data.length >= 2) {
      final linePath = Path();
      linePath.moveTo(off(0).dx, off(0).dy);
      for (int i = 1; i < data.length; i++) {
        final prev = off(i - 1);
        final curr = off(i);
        final cp1 = Offset((prev.dx + curr.dx) / 2, prev.dy);
        final cp2 = Offset((prev.dx + curr.dx) / 2, curr.dy);
        linePath.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, curr.dx, curr.dy);
      }
      canvas.drawPath(linePath, linePaint);
    } else {
      canvas.drawLine(
        Offset(off(0).dx, size.height),
        off(0),
        linePaint,
      );
    }

    // Highlight selected point only; keep all other points invisible.
    if (selectedIndex != null && selectedIndex! >= 0 && selectedIndex! < data.length) {
      final p = off(selectedIndex!);
      canvas.drawCircle(
          p,
          6.0,
          Paint()
            ..color = const Color(0xFF2874A6)
            ..style = PaintingStyle.fill);
      canvas.drawCircle(
          p,
          6.0,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
  }
  @override
  bool shouldRepaint(_LineChartPainter old) =>
      old.data != data || old.maxKwh != maxKwh || old.selectedIndex != selectedIndex;
}

class _BarChartPainter extends CustomPainter {
  final List<double> data;
  final double maxKwh;
  final int? selectedIndex;
  _BarChartPainter({
    required this.data,
    required this.maxKwh,
    required this.selectedIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;
    final safeMaxKwh = maxKwh <= 0 ? 1.0 : maxKwh;

    final gridPaint = Paint()
      ..color = const Color(0xFF2E9E52).withAlpha(20)
      ..strokeWidth = 1;
    for (int i = 1; i < 5; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final slotWidth = size.width / data.length;
    final barWidth = (slotWidth * 0.62).clamp(2.0, 18.0);

    for (int i = 0; i < data.length; i++) {
      final normalized = (data[i] / safeMaxKwh).clamp(0.0, 1.0);
      final barHeight = normalized * size.height;
      final left = i * slotWidth + (slotWidth - barWidth) / 2;
      final top = size.height - barHeight;

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, barWidth, barHeight),
        const Radius.circular(4),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = const Color(0xFF2E9E52),
      );
    }

    // Highlight selected bar if any
    if (selectedIndex != null && selectedIndex! >= 0 && selectedIndex! < data.length) {
      final idx = selectedIndex!;
      final slotWidth = size.width / data.length;
      final barWidth = (slotWidth * 0.62).clamp(2.0, 18.0);
      final normalized = (data[idx] / safeMaxKwh).clamp(0.0, 1.0);
      final barHeight = normalized * size.height;
      final left = idx * slotWidth + (slotWidth - barWidth) / 2;
      final top = size.height - barHeight;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, barWidth, barHeight),
        const Radius.circular(4),
      );
      canvas.drawRRect(
        rect,
        Paint()..color = const Color(0xFF2874A6),
      );
    }
  }
  @override
  bool shouldRepaint(_BarChartPainter old) =>
      old.data != data || old.maxKwh != maxKwh || old.selectedIndex != selectedIndex;
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

class _ForecastChartPainter extends CustomPainter {
  final List<double> actualData;
  final List<double> forecastData;
  final double maxKwh;

  _ForecastChartPainter({
    required this.actualData,
    required this.forecastData,
    required this.maxKwh,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (actualData.isEmpty) return;

    final safeMaxKwh = maxKwh <= 0 ? 1.0 : maxKwh;
    final allData = <double>[...actualData, ...forecastData];
    final totalCount = allData.length;
    final stepX = totalCount < 2 ? 0.0 : size.width / (totalCount - 1);

    Offset off(int i) {
      final x = totalCount == 1 ? size.width / 2 : i * stepX;
      final y = size.height - (allData[i] / safeMaxKwh) * size.height;
      return Offset(x, y.clamp(0.0, size.height));
    }

    final gridPaint = Paint()
      ..color = const Color(0xFF2E9E52).withAlpha(18)
      ..strokeWidth = 1;
    for (int i = 1; i < 5; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final boundaryIndex = actualData.length - 1;
    if (boundaryIndex >= 0) {
      final boundaryX = off(boundaryIndex).dx;
      canvas.drawLine(
        Offset(boundaryX, 0),
        Offset(boundaryX, size.height),
        Paint()
          ..color = const Color(0xFFF59E0B).withAlpha(60)
          ..strokeWidth = 1,
      );
    }

    if (actualData.length >= 2) {
      final actualPath = Path()..moveTo(off(0).dx, off(0).dy);
      for (int i = 1; i < actualData.length; i++) {
        final prev = off(i - 1);
        final curr = off(i);
        final cp1 = Offset((prev.dx + curr.dx) / 2, prev.dy);
        final cp2 = Offset((prev.dx + curr.dx) / 2, curr.dy);
        actualPath.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, curr.dx, curr.dy);
      }

      final fillPath = Path()
        ..moveTo(off(0).dx, size.height)
        ..lineTo(off(0).dx, off(0).dy);
      for (int i = 1; i < actualData.length; i++) {
        final prev = off(i - 1);
        final curr = off(i);
        final cp1 = Offset((prev.dx + curr.dx) / 2, prev.dy);
        final cp2 = Offset((prev.dx + curr.dx) / 2, curr.dy);
        fillPath.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, curr.dx, curr.dy);
      }
      fillPath
        ..lineTo(off(actualData.length - 1).dx, size.height)
        ..close();

      canvas.drawPath(
        fillPath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF2E9E52).withAlpha(70),
              const Color(0xFF2E9E52).withAlpha(0),
            ],
          ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
      );
      canvas.drawPath(
        actualPath,
        Paint()
          ..color = const Color(0xFF2E9E52)
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    } else {
      canvas.drawCircle(
        off(0),
        4.0,
        Paint()..color = const Color(0xFF2E9E52),
      );
    }

    if (forecastData.isNotEmpty) {
      final forecastPath = Path();
      final startIndex = actualData.length - 1;
      forecastPath.moveTo(off(startIndex).dx, off(startIndex).dy);
      for (int i = actualData.length; i < allData.length; i++) {
        final prev = off(i - 1);
        final curr = off(i);
        final cp1 = Offset((prev.dx + curr.dx) / 2, prev.dy);
        final cp2 = Offset((prev.dx + curr.dx) / 2, curr.dy);
        forecastPath.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, curr.dx, curr.dy);
      }
      canvas.drawPath(
        forecastPath,
        Paint()
          ..color = const Color(0xFFF59E0B)
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );

      canvas.drawCircle(
        off(actualData.length - 1),
        4.5,
        Paint()..color = const Color(0xFFF59E0B),
      );
    }
  }

  @override
  bool shouldRepaint(_ForecastChartPainter old) =>
      old.actualData != actualData ||
      old.forecastData != forecastData ||
      old.maxKwh != maxKwh;
}
