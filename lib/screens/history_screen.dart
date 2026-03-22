import 'dart:async';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../theme/app_colors.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String _range = 'daily';
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
    _historySub = FirebaseDatabase.instance
        .ref('history/$_range')
        .onValue
        .listen((event) {
      final raw = event.snapshot.value;
      if (raw == null) {
        if (mounted) setState(() => _historyData = []);
        return;
      }

      final data = Map<String, dynamic>.from(raw as Map);
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
  Future<void> _exportCsv() async {
    if (_historyData.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No data to export.')));
      return;
    }

    setState(() => _exporting = true);

    try {
      final rangeLabel =
          _ranges.firstWhere((r) => r['key'] == _range)['label']!;
      final now = DateTime.now();
      final timestamp = '${now.year}-${_pad(now.month)}-${_pad(now.day)}_'
          '${_pad(now.hour)}-${_pad(now.minute)}';

      // ── Build CSV rows ──────────────────────────────────────────
      final List<List<dynamic>> rows = [];

      // Title row
      rows.add(['SmartPowerSwitch — Energy Report']);
      rows.add(['Institution', 'Davao del Norte State College']);
      rows.add(['Report Range', rangeLabel]);
      rows.add([
        'Generated',
        '${now.year}-${_pad(now.month)}-${_pad(now.day)} '
            '${_pad(now.hour)}:${_pad(now.minute)}'
      ]);
      rows.add([]); // blank line

      // History header
      rows.add(['Period', 'Energy (kWh)', 'Cost (₱)']);

      // History data
      for (final d in _historyData) {
        rows.add([
          d['label'],
          (d['kwh'] as num).toStringAsFixed(2),
          (d['cost'] as num).toStringAsFixed(2),
        ]);
      }

      // Totals
      rows.add([]);
      rows.add([
        'TOTAL',
        _totalKwh.toStringAsFixed(2),
        _totalCost.toStringAsFixed(2)
      ]);
      rows.add([]);

      // Building breakdown
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

      // Utility breakdown
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

      // Device status
      rows.add(['Device Status']);
      rows.add(['Online Devices', '$_onlineCount']);
      rows.add(['Offline Devices', '$_offlineCount']);

      // Convert to CSV string
      final csvData = const ListToCsvConverter().convert(rows);

      // Save to temp file
      final dir = await getTemporaryDirectory();
      final fileName = 'SmartPowerSwitch_${rangeLabel}_$timestamp.csv';
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(csvData);

      // Share
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/csv')],
        subject: 'SmartPowerSwitch Energy Report — $rangeLabel',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

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
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.greenMid.withAlpha(26)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Consumption Trend',
            style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        const SizedBox(height: 4),
        const Text('kWh over time (realtime)',
            style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
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
                  painter: _LineChartPainter(
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
        ..._historyData.take(10).map((d) => Container(
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
        child: Row(children: [
          const Icon(Icons.info_outline, size: 14, color: AppColors.greenMid),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Exports ${_ranges.firstWhere((r) => r['key'] == _range)['label']} '
              'history with building & utility breakdown.',
              style: const TextStyle(fontSize: 11, color: AppColors.textMid),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      SizedBox(
        width: double.infinity,
        height: 50,
        child: ElevatedButton.icon(
          onPressed: _exporting ? null : _exportCsv,
          icon: _exporting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : const Icon(Icons.download_outlined,
                  size: 18, color: Colors.white),
          label: Text(
            _exporting ? 'Generating...' : 'Export as CSV',
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
      final y = size.height - (data[i] / maxKwh) * size.height;
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
