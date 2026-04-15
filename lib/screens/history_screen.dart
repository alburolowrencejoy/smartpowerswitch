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

  final List<Map<String, String>> _ranges = [
    {'key': 'daily', 'label': 'Daily'},
    {'key': 'weekly', 'label': 'Weekly'},
    {'key': 'monthly', 'label': 'Monthly'},
    {'key': 'yearly', 'label': 'Yearly'},
  ];

  StreamSubscription? _devicesSub;
  StreamSubscription? _historySub;

  List<Map<String, dynamic>> _historyData = [];

  Map<String, double> _utilityTotals = {};
  Map<String, double> _buildingTotals = {};
  int _onlineCount = 0;
  int _offlineCount = 0;

  @override
  void initState() {
    super.initState();
    _listenDevices();
    _listenHistory();
  }

  @override
  void dispose() {
    _devicesSub?.cancel();
    _historySub?.cancel();
    super.dispose();
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
    _historySub =
        FirebaseDatabase.instance.ref('history').onValue.listen((event) {
      final raw = event.snapshot.value;
      if (raw == null) {
        if (mounted) setState(() => _historyData = []);
        return;
      }

      final root = Map<String, dynamic>.from(raw as Map);
      final data = _pickRangeNode(root, _range);
      final List<Map<String, dynamic>> list = [];

      data.forEach((key, val) {
        if (val is! Map) return;
        final entry = Map<String, dynamic>.from(val);
        list.add({
          'label': key,
          'kwh': (entry['kwh'] ?? 0.0) as num,
          'cost': (entry['cost'] ?? 0.0) as num,
        });
      });

      list.sort((a, b) => a['label'].compareTo(b['label']));
      if (mounted) setState(() => _historyData = list);
    });
  }

  Map<String, dynamic> _pickRangeNode(
      Map<String, dynamic> root, String targetRange) {
    final direct = root[targetRange];
    if (direct is Map) {
      final directMap = Map<String, dynamic>.from(direct);
      if (_matchingKeyCount(directMap, targetRange) > 0) return directMap;
    }

    final keys = ['daily', 'weekly', 'monthly', 'yearly'];
    String bestKey = targetRange;
    int bestScore = -1;

    for (final k in keys) {
      final node = root[k];
      if (node is! Map) continue;
      final map = Map<String, dynamic>.from(node);
      final score = _matchingKeyCount(map, targetRange);
      if (score > bestScore) {
        bestScore = score;
        bestKey = k;
      }
    }

    final best = root[bestKey];
    return best is Map ? Map<String, dynamic>.from(best) : <String, dynamic>{};
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
    _listenHistory();
  }

  double get _totalKwh =>
      _historyData.fold(0, (s, d) => s + (d['kwh'] as num).toDouble());
  double get _totalCost =>
      _historyData.fold(0, (s, d) => s + (d['cost'] as num).toDouble());
  double get _maxKwh => _historyData.isEmpty
      ? 1
      : _historyData.fold(
          0.0,
          (m, d) => (d['kwh'] as num).toDouble() > m
              ? (d['kwh'] as num).toDouble()
              : m);

  // ── CSV Export ───────────────────────────────────────────────────────────────
  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  List<Map<String, dynamic>> _parseRangeEntries(
      Map<String, dynamic> root, String rangeKey) {
    final data = _pickRangeNode(root, rangeKey);
    final list = <Map<String, dynamic>>[];

    data.forEach((key, val) {
      if (val is! Map) return;
      final entry = Map<String, dynamic>.from(val);
      list.add({
        'label': key,
        'kwh': _asDouble(entry['kwh'] ?? entry['total_kwh']),
        'cost': _asDouble(entry['cost'] ?? entry['total_cost']),
      });
    });

    list.sort((a, b) => a['label'].toString().compareTo(b['label'].toString()));
    return list;
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
      final clustered = <String, List<Map<String, dynamic>>>{
        'yearly': _parseRangeEntries(historyRoot, 'yearly'),
        'monthly': _parseRangeEntries(historyRoot, 'monthly'),
        'weekly': _parseRangeEntries(historyRoot, 'weekly'),
        'daily': _parseRangeEntries(historyRoot, 'daily'),
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
    return Container(
      height: 44,
      decoration: BoxDecoration(
          color: AppColors.greenPale, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: _ranges.map((r) {
          final isSelected = _range == r['key'];
          return Expanded(
            child: GestureDetector(
              onTap: () => _setRange(r['key']!),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.greenDark : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(r['label']!,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color:
                              isSelected ? Colors.white : AppColors.textMid)),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSummaryRow() {
    return Row(children: [
      Expanded(
          child: _summaryCard(
              'Total kWh', '${_totalKwh.toStringAsFixed(1)} kWh', Icons.bolt)),
      const SizedBox(width: 12),
      Expanded(
          child: _summaryCard('Total Cost',
              '₱ ${_totalCost.toStringAsFixed(0)}', Icons.payments_outlined)),
    ]);
  }

  Widget _summaryCard(String label, String value, IconData icon) {
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
        Text(label,
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
      ]),
    );
  }

  Widget _buildLineChart() {
    final canSwitchChart = _historyData.length > 1;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.greenMid.withAlpha(26)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Consumption Trend',
                    style: TextStyle(
                        fontFamily: 'Outfit',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark)),
                SizedBox(height: 4),
                Text('kWh over time (realtime)',
                    style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
              ],
            ),
          ),
          if (canSwitchChart) ...[
            _chartTypeButton('line', Icons.show_chart),
            const SizedBox(width: 6),
            _chartTypeButton('bar', Icons.bar_chart),
          ],
        ]),
        const SizedBox(height: 20),
        _historyData.isEmpty
            ? const Center(
                child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 30),
                    child: Text('No data yet',
                        style: TextStyle(
                            fontSize: 13, color: AppColors.textMuted))))
            : SizedBox(
                height: 160,
                child: CustomPaint(
                  painter: _trendChartType == 'bar'
                      ? _BarChartPainter(
                          data: _historyData
                              .map((d) => (d['kwh'] as num).toDouble())
                              .toList(),
                          maxKwh: _maxKwh,
                        )
                      : _LineChartPainter(
                          data: _historyData
                              .map((d) => (d['kwh'] as num).toDouble())
                              .toList(),
                          maxKwh: _maxKwh,
                        ),
                  child: Container(),
                ),
              ),
        const SizedBox(height: 8),
        if (_historyData.isNotEmpty)
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(_historyData.first['label'],
                style:
                    const TextStyle(fontSize: 9, color: AppColors.textMuted)),
            if (_historyData.length > 2)
              Text(_historyData[_historyData.length ~/ 2]['label'],
                  style:
                      const TextStyle(fontSize: 9, color: AppColors.textMuted)),
            Text(_historyData.last['label'],
                style:
                    const TextStyle(fontSize: 9, color: AppColors.textMuted)),
          ]),
      ]),
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

  _LineChartPainter({required this.data, required this.maxKwh});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
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

    final stepX = size.width / (data.length - 1);

    Offset off(int i) {
      final x = i * stepX;
      final y = size.height - (data[i] / safeMaxKwh) * size.height;
      return Offset(x, y.clamp(0.0, size.height));
    }

    final gridPaint = Paint()
      ..color = const Color(0xFF2E9E52).withAlpha(20)
      ..strokeWidth = 1;
    for (int i = 1; i < 4; i++) {
      final y = size.height * i / 4;
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

    for (int i = 0; i < data.length; i++) {
      canvas.drawCircle(
          off(i),
          3.5,
          Paint()
            ..color = const Color(0xFF1A5C35)
            ..style = PaintingStyle.fill);
      canvas.drawCircle(
          off(i),
          3.5,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(_LineChartPainter old) =>
      old.data != data || old.maxKwh != maxKwh;
}

class _BarChartPainter extends CustomPainter {
  final List<double> data;
  final double maxKwh;

  _BarChartPainter({required this.data, required this.maxKwh});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;
    final safeMaxKwh = maxKwh <= 0 ? 1.0 : maxKwh;

    final gridPaint = Paint()
      ..color = const Color(0xFF2E9E52).withAlpha(20)
      ..strokeWidth = 1;
    for (int i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final slotWidth = size.width / data.length;
    final barWidth = (slotWidth * 0.62).clamp(2.0, 18.0);
    final barPaint = Paint()..color = const Color(0xFF2E9E52);

    for (int i = 0; i < data.length; i++) {
      final normalized = (data[i] / safeMaxKwh).clamp(0.0, 1.0);
      final barHeight = normalized * size.height;
      final left = i * slotWidth + (slotWidth - barWidth) / 2;
      final top = size.height - barHeight;

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, barWidth, barHeight),
        const Radius.circular(4),
      );
      canvas.drawRRect(rect, barPaint);
    }
  }

  @override
  bool shouldRepaint(_BarChartPainter old) =>
      old.data != data || old.maxKwh != maxKwh;
}
