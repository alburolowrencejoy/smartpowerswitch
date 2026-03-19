import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../theme/app_colors.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int    _selectedIndex = 0;
  String _role          = 'faculty';
  String _userName      = '';
  bool   _roleLoaded    = false;

  final List<Map<String, dynamic>> _buildings = [
    {'code': 'IC',    'name': 'Institute of Computing',                    'floors': 2},
    {'code': 'ILEGG', 'name': 'Institute of Leadership & Good Governance', 'floors': 2},
    {'code': 'ITED',  'name': 'Institute of Teachers Education',           'floors': 2},
    {'code': 'IAAS',  'name': 'Institute of Aquatic Science',              'floors': 1},
    {'code': 'ADMIN', 'name': 'Administrator Building',                    'floors': 1},
  ];

  double              _totalKwh             = 0;
  double              _totalCostPhp         = 0;
  double              _electricityRate      = 11.5;
  int                 _assignedDevices      = 0;  // from master_devices
  int                 _unassignedDevices    = 0;  // from master_devices
  Map<String, int>    _buildingDeviceCounts = {};  // from master_devices
  Map<String, double> _buildingEnergy       = {};  // from devices node
  Map<String, double> _utilityTotals        = {};  // from devices node
  String              _analyticsRange       = 'daily';
  List<Map<String, dynamic>> _historyData   = [];

  StreamSubscription? _masterSub;
  StreamSubscription? _devicesSub;
  StreamSubscription? _rateSub;
  StreamSubscription? _historySub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_roleLoaded) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map<String, dynamic>) {
        _role     = args['role'] as String? ?? 'faculty';
        _userName = args['name'] as String? ?? '';
      }
      _roleLoaded = true;
      _listenToMasterDevices();
      _listenToEnergyData();
      _listenToRate();
      _listenToHistory();
    }
  }

  @override
  void dispose() {
    _masterSub?.cancel();
    _devicesSub?.cancel();
    _rateSub?.cancel();
    _historySub?.cancel();
    super.dispose();
  }

  // ── Count assigned/unassigned from master_devices ─────────────
  void _listenToMasterDevices() {
    _masterSub = FirebaseDatabase.instance
        .ref('master_devices')
        .onValue
        .listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;
      if (raw == null) {
        setState(() {
          _assignedDevices = 0;
          _unassignedDevices = 0;
          _buildingDeviceCounts = {};
        });
        return;
      }

      final data = Map<String, dynamic>.from(raw as Map);
      int assigned = 0;
      int unassigned = 0;
      Map<String, int> bCounts = {};

      data.forEach((id, val) {
        if (val is! Map) return;
        final device     = Map<String, dynamic>.from(val);
        final assignedTo = (device['assignedTo'] ?? '').toString();

        if (assignedTo.isNotEmpty) {
          assigned++;
          // assignedTo format: "IC/1/Comlab 1"
          final parts = assignedTo.split('/');
          if (parts.isNotEmpty) {
            bCounts[parts[0]] = (bCounts[parts[0]] ?? 0) + 1;
          }
        } else {
          unassigned++;
        }
      });

      setState(() {
        _assignedDevices      = assigned;
        _unassignedDevices    = unassigned;
        _buildingDeviceCounts = bCounts;
      });
    });
  }

  // ── Energy data from devices node (ESP32 writes here) ─────────
  void _listenToEnergyData() {
    _devicesSub = FirebaseDatabase.instance
        .ref('devices')
        .onValue
        .listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;
      if (raw == null) {
        setState(() {
          _totalKwh = 0; _totalCostPhp = 0;
          _buildingEnergy = {}; _utilityTotals = {};
        });
        return;
      }

      final data = Map<String, dynamic>.from(raw as Map);
      double totalKwh = 0;
      Map<String, double> bEnergy = {};
      Map<String, double> uTotals = {};

      data.forEach((id, val) {
        if (val is! Map) return;
        final device   = Map<String, dynamic>.from(val);
        final building = (device['building'] ?? '').toString();
        final utility  = (device['utility']  ?? '').toString();
        final kwh      = (device['kwh']      ?? 0.0) as num;

        if (building.isNotEmpty) {
          bEnergy[building] = (bEnergy[building] ?? 0) + kwh.toDouble();
          totalKwh          += kwh.toDouble();
        }
        final normalizedUtility = _capitalizeFirst(utility);
        if (normalizedUtility.isNotEmpty) {
          uTotals[normalizedUtility] = (uTotals[normalizedUtility] ?? 0) + kwh.toDouble();
        }
      });

      setState(() {
        _totalKwh       = totalKwh;
        _totalCostPhp   = totalKwh * _electricityRate;
        _buildingEnergy = bEnergy;
        _utilityTotals  = uTotals;
      });
    });
  }

  void _listenToRate() {
    _rateSub = FirebaseDatabase.instance
        .ref('settings/electricityRate')
        .onValue
        .listen((event) {
      if (!mounted) return;
      final rate = (event.snapshot.value as num?)?.toDouble() ?? 11.5;
      setState(() { _electricityRate = rate; _totalCostPhp = _totalKwh * rate; });
    });
  }

  void _listenToHistory() {
    _historySub?.cancel();
    _historySub = FirebaseDatabase.instance
        .ref('history/$_analyticsRange')
        .onValue
        .listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;
      if (raw == null) { setState(() => _historyData = []); return; }

      final data = Map<String, dynamic>.from(raw as Map);
      final List<Map<String, dynamic>> list = [];

      data.forEach((key, val) {
        if (val is! Map) return;
        final entry = Map<String, dynamic>.from(val);
        list.add({
          'label': key,
          'kwh':   (entry['total_kwh']  ?? 0.0) as num,
          'cost':  (entry['total_cost'] ?? 0.0) as num,
        });
      });

      list.sort((a, b) => a['label'].compareTo(b['label']));
      setState(() => _historyData = list);
    });
  }

  void _setAnalyticsRange(String range) {
    setState(() => _analyticsRange = range);
    _listenToHistory();
  }

  double get _maxKwh => _historyData.isEmpty ? 1
      : _historyData.fold(0.0, (m, d) =>
          (d['kwh'] as num).toDouble() > m ? (d['kwh'] as num).toDouble() : m);

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/login');
  }

  String _capitalizeFirst(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

  String _energyLevel(String code) {
    final kwh = _buildingEnergy[code] ?? 0;
    if (kwh > 100) return 'HIGH';
    if (kwh > 50)  return 'MID';
    return 'LOW';
  }

  Color _energyColor(String code) {
    switch (_energyLevel(code)) {
      case 'HIGH': return const Color(0xFFD64A4A);
      case 'MID':  return const Color(0xFFE8922A);
      default:     return AppColors.greenMid;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(children: [
          _buildTopBar(),
          Expanded(
            child: IndexedStack(
              index: _selectedIndex,
              children: [
                _buildHomeTab(),
                _buildMapTab(),
                _buildAnalyticsTab(),
              ],
            ),
          ),
        ]),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      color: AppColors.greenDark,
      child: Row(children: [
        Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
              color: AppColors.greenMid, borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.bolt, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text('SmartPowerSwitch',
              style: TextStyle(fontFamily: 'Outfit', fontSize: 16,
                  fontWeight: FontWeight.w600, color: Colors.white)),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: _role == 'admin'
                ? AppColors.greenLight.withAlpha(51)
                : Colors.white.withAlpha(26),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _role == 'admin'
                  ? AppColors.greenLight.withAlpha(102)
                  : Colors.white.withAlpha(51),
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_role == 'admin' ? Icons.star : Icons.person,
                size: 11,
                color: _role == 'admin' ? AppColors.greenLight : Colors.white),
            const SizedBox(width: 4),
            Text(_role == 'admin' ? 'Admin' : 'Faculty',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                    color: _role == 'admin' ? AppColors.greenLight : Colors.white)),
          ]),
        ),
        IconButton(
          icon: const Icon(Icons.notifications_outlined, color: Colors.white, size: 22),
          onPressed: () => Navigator.pushNamed(context, '/notifications'),
        ),
        if (_role == 'admin')
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white, size: 22),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        IconButton(
          icon: const Icon(Icons.logout, color: Colors.white, size: 20),
          onPressed: _logout,
        ),
      ]),
    );
  }

  Widget _buildHomeTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _buildGreeting(),
        const SizedBox(height: 20),
        _buildEnergyCards(),
        const SizedBox(height: 24),
        Row(children: [
          const Text('Campus Buildings',
              style: TextStyle(fontFamily: 'Outfit', fontSize: 16,
                  fontWeight: FontWeight.w600, color: AppColors.textDark)),
          const Spacer(),
          Text('${_buildings.length} buildings',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
        ]),
        const SizedBox(height: 12),
        ..._buildings.map(_buildBuildingCard),
      ]),
    );
  }

  Widget _buildGreeting() {
    final hour     = DateTime.now().hour;
    final greeting = hour < 12 ? 'Good morning'
        : hour < 17 ? 'Good afternoon' : 'Good evening';
    return Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(greeting, style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
        Text(_userName.isNotEmpty ? _userName : 'User',
            style: const TextStyle(fontFamily: 'Outfit', fontSize: 22,
                fontWeight: FontWeight.w700, color: AppColors.textDark)),
      ])),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.greenPale,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.greenMid.withAlpha(60)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 7, height: 7,
              decoration: const BoxDecoration(
                  color: AppColors.greenMid, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          const Text('Live', style: TextStyle(fontSize: 11,
              fontWeight: FontWeight.w600, color: AppColors.greenDark)),
        ]),
      ),
    ]);
  }

  Widget _buildEnergyCards() {
    return Column(children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.greenDark, Color(0xFF1E7A42)],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [BoxShadow(color: AppColors.greenDark.withAlpha(77),
              blurRadius: 20, offset: const Offset(0, 8))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Total Energy Today',
              style: TextStyle(fontSize: 12, color: Color(0xB3C2EDD0))),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_totalKwh.toStringAsFixed(1),
                style: const TextStyle(fontFamily: 'Outfit', fontSize: 40,
                    fontWeight: FontWeight.w700, color: Colors.white)),
            const Padding(padding: EdgeInsets.only(bottom: 6, left: 6),
                child: Text('kWh', style: TextStyle(fontSize: 14,
                    color: AppColors.greenLight, fontWeight: FontWeight.w500))),
          ]),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              _miniStat('Est. Cost',  '₱ ${_totalCostPhp.toStringAsFixed(2)}'),
              _vertDivider(),
              _miniStat('Assigned',   '$_assignedDevices devices'),
              _vertDivider(),
              _miniStat('Unassigned', '$_unassignedDevices devices'),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _statCard('Voltage',      '220 V', Icons.electrical_services, AppColors.greenMid)),
        const SizedBox(width: 10),
        Expanded(child: _statCard('Frequency',    '60 Hz', Icons.waves,               AppColors.greenLight)),
        const SizedBox(width: 10),
        Expanded(child: _statCard('Power Factor', '0.98',  Icons.speed,               AppColors.greenPale,
            textColor: AppColors.greenDark)),
      ]),
    ]);
  }

  Widget _vertDivider() => Container(
      width: 1, height: 28, margin: const EdgeInsets.symmetric(horizontal: 10),
      color: Colors.white.withAlpha(30));

  Widget _miniStat(String label, String value) {
    return Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: Color(0x99C2EDD0))),
      const SizedBox(height: 2),
      Text(value, style: const TextStyle(fontSize: 12,
          fontWeight: FontWeight.w600, color: Colors.white)),
    ]));
  }

  Widget _statCard(String label, String value, IconData icon, Color bg,
      {Color textColor = Colors.white}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: textColor.withAlpha(204)),
        const SizedBox(height: 8),
        Text(value, style: TextStyle(fontFamily: 'Outfit', fontSize: 15,
            fontWeight: FontWeight.w700, color: textColor)),
        Text(label, style: TextStyle(fontSize: 10, color: textColor.withAlpha(179))),
      ]),
    );
  }

  Widget _buildBuildingCard(Map<String, dynamic> building) {
    final code    = building['code'] as String;
    final level   = _energyLevel(code);
    final color   = _energyColor(code);
    final devices = _buildingDeviceCounts[code] ?? 0;

    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/building', arguments: {
        'buildingCode': code,
        'buildingName': building['name'],
        'floors':       building['floors'],
        'role':         _role,
      }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.greenMid.withAlpha(31)),
        ),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
                color: AppColors.greenPale, borderRadius: BorderRadius.circular(12)),
            child: Center(child: Text(code,
                style: const TextStyle(fontFamily: 'Outfit', fontSize: 10,
                    fontWeight: FontWeight.w700, color: AppColors.greenDark))),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(building['name'],
                style: const TextStyle(fontSize: 13,
                    fontWeight: FontWeight.w600, color: AppColors.textDark)),
            const SizedBox(height: 2),
            Text(
              '${building['floors']} ${building['floors'] == 1 ? 'floor' : 'floors'} · $devices devices',
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ])),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: color.withAlpha(26),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: color.withAlpha(77)),
              ),
              child: Text(level, style: TextStyle(fontSize: 10,
                  fontWeight: FontWeight.w700, color: color)),
            ),
            const SizedBox(height: 3),
            Text('${(_buildingEnergy[code] ?? 0).toStringAsFixed(1)} kWh',
                style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
          ]),
          const SizedBox(width: 6),
          const Icon(Icons.chevron_right, color: AppColors.textMuted, size: 18),
        ]),
      ),
    );
  }

  Widget _buildMapTab() {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          width: 72, height: 72,
          decoration: BoxDecoration(
            color: AppColors.greenPale,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.greenMid.withAlpha(60)),
          ),
          child: const Icon(Icons.map_outlined, size: 36, color: AppColors.greenDark),
        ),
        const SizedBox(height: 16),
        const Text('Campus Map',
            style: TextStyle(fontFamily: 'Outfit', fontSize: 18,
                fontWeight: FontWeight.w700, color: AppColors.textDark)),
        const SizedBox(height: 6),
        const Text('Coming soon',
            style: TextStyle(fontSize: 13, color: AppColors.textMuted)),
      ]),
    );
  }

  Widget _buildAnalyticsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Analytics',
            style: TextStyle(fontFamily: 'Outfit', fontSize: 22,
                fontWeight: FontWeight.w700, color: AppColors.textDark)),
        const SizedBox(height: 4),
        const Text('Realtime energy insights',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
        const SizedBox(height: 20),
        _buildRangeSelector(),
        const SizedBox(height: 20),
        _buildLineChart(),
        const SizedBox(height: 16),
        _buildDeviceStatusCard(),
        const SizedBox(height: 16),
        _buildTopUtilityCard(),
        const SizedBox(height: 16),
        _buildTopBuildingCard(),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity, height: 50,
          child: OutlinedButton.icon(
            onPressed: () => Navigator.pushNamed(context, '/history'),
            icon: const Icon(Icons.history, size: 18),
            label: const Text('View Full History'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.greenDark,
              side: const BorderSide(color: AppColors.greenMid, width: 1.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildRangeSelector() {
    final ranges = [
      {'key': 'daily',   'label': 'Daily'},
      {'key': 'weekly',  'label': 'Weekly'},
      {'key': 'monthly', 'label': 'Monthly'},
      {'key': 'yearly',  'label': 'Yearly'},
    ];
    return Container(
      height: 42,
      decoration: BoxDecoration(
          color: AppColors.greenPale, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: ranges.map((r) {
          final isSelected = _analyticsRange == r['key'];
          return Expanded(
            child: GestureDetector(
              onTap: () => _setAnalyticsRange(r['key']!),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.greenDark : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(child: Text(r['label']!,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                        color: isSelected ? Colors.white : AppColors.textMuted))),
              ),
            ),
          );
        }).toList(),
      ),
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
        Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Consumption Trend',
                style: TextStyle(fontFamily: 'Outfit', fontSize: 14,
                    fontWeight: FontWeight.w600, color: AppColors.textDark)),
            SizedBox(height: 2),
            Text('kWh over time · realtime',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
          ])),
          Container(width: 8, height: 8,
              decoration: const BoxDecoration(
                  color: AppColors.greenMid, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          const Text('Live', style: TextStyle(fontSize: 10,
              fontWeight: FontWeight.w600, color: AppColors.greenMid)),
        ]),
        const SizedBox(height: 20),
        _historyData.isEmpty
            ? const Center(child: Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Text('No data yet',
                    style: TextStyle(fontSize: 13, color: AppColors.textMuted))))
            : SizedBox(
                height: 160,
                child: CustomPaint(
                  painter: _LineChartPainter(
                    data: _historyData.map((d) => (d['kwh'] as num).toDouble()).toList(),
                    maxKwh: _maxKwh,
                  ),
                  child: Container(),
                ),
              ),
        if (_historyData.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(_historyData.first['label'],
                style: const TextStyle(fontSize: 9, color: AppColors.textMuted)),
            if (_historyData.length > 2)
              Text(_historyData[_historyData.length ~/ 2]['label'],
                  style: const TextStyle(fontSize: 9, color: AppColors.textMuted)),
            Text(_historyData.last['label'],
                style: const TextStyle(fontSize: 9, color: AppColors.textMuted)),
          ]),
        ],
      ]),
    );
  }

  Widget _buildDeviceStatusCard() {
    final total      = _assignedDevices + _unassignedDevices;
    final assignedPct = total == 0 ? 0.0 : _assignedDevices / total;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.greenMid.withAlpha(26)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Device Status',
            style: TextStyle(fontFamily: 'Outfit', fontSize: 14,
                fontWeight: FontWeight.w600, color: AppColors.textDark)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _statusBadge('Assigned',   _assignedDevices,   AppColors.greenMid, Icons.check_circle_outline)),
          const SizedBox(width: 12),
          Expanded(child: _statusBadge('Unassigned', _unassignedDevices, AppColors.warning,  Icons.device_unknown_outlined)),
        ]),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: assignedPct, minHeight: 8,
            backgroundColor: AppColors.warning.withAlpha(40),
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.greenMid),
          ),
        ),
        const SizedBox(height: 6),
        Text('${(assignedPct * 100).toStringAsFixed(0)}% devices assigned',
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
          Text('$count', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
              color: color, fontFamily: 'Outfit')),
          Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
        ]),
      ]),
    );
  }

  Widget _buildTopUtilityCard() {
    if (_utilityTotals.isEmpty) return const SizedBox();
    final sorted = _utilityTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxVal = sorted.first.value;
    final Map<String, Color> colors = {
      'Lights':  AppColors.greenMid,
      'Outlets': const Color(0xFFE8922A),
      'AC':      const Color(0xFF2196F3),
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
            style: TextStyle(fontFamily: 'Outfit', fontSize: 14,
                fontWeight: FontWeight.w600, color: AppColors.textDark)),
        const SizedBox(height: 16),
        ...sorted.map((e) {
          final pct   = maxVal == 0 ? 0.0 : e.value / maxVal;
          final color = colors[e.key] ?? AppColors.greenMid;
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Row(children: [
                  Container(width: 10, height: 10,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Text(e.key, style: const TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w500, color: AppColors.textDark)),
                ]),
                Text('${e.value.toStringAsFixed(1)} kWh',
                    style: const TextStyle(fontSize: 12,
                        fontWeight: FontWeight.w600, color: AppColors.greenDark)),
              ]),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: pct, minHeight: 7,
                  backgroundColor: color.withAlpha(25),
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
    if (_buildingDeviceCounts.isEmpty) return const SizedBox();
    final sorted = _buildingDeviceCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxVal = sorted.first.value;
    final List<Color> barColors = [
      AppColors.greenDark, AppColors.greenMid, AppColors.greenLight,
      const Color(0xFF2196F3), const Color(0xFFE8922A),
    ];
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.greenMid.withAlpha(26)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Devices per Institute',
            style: TextStyle(fontFamily: 'Outfit', fontSize: 14,
                fontWeight: FontWeight.w600, color: AppColors.textDark)),
        const SizedBox(height: 16),
        ...sorted.asMap().entries.map((entry) {
          final i     = entry.key;
          final e     = entry.value;
          final pct   = maxVal == 0 ? 0.0 : e.value / maxVal;
          final color = barColors[i % barColors.length];
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(children: [
              Container(
                width: 24, height: 24,
                decoration: BoxDecoration(
                  color: i == 0 ? AppColors.greenDark : AppColors.greenPale,
                  shape: BoxShape.circle,
                ),
                child: Center(child: Text('${i + 1}',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: i == 0 ? Colors.white : AppColors.greenDark))),
              ),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(e.key, style: const TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w500, color: AppColors.textDark)),
                  Text('${e.value} devices',
                      style: const TextStyle(fontSize: 12,
                          fontWeight: FontWeight.w600, color: AppColors.greenDark)),
                ]),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: pct, minHeight: 7,
                    backgroundColor: color.withAlpha(25),
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

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(15),
            blurRadius: 16, offset: const Offset(0, -4))],
      ),
      child: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (i) => setState(() => _selectedIndex = i),
        backgroundColor: Colors.white,
        selectedItemColor: AppColors.greenDark,
        unselectedItemColor: AppColors.textMuted,
        selectedLabelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 11),
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_outlined),
              activeIcon: Icon(Icons.dashboard),
              label: 'Dashboard'),
          BottomNavigationBarItem(
              icon: Icon(Icons.map_outlined),
              activeIcon: Icon(Icons.map),
              label: 'Map'),
          BottomNavigationBarItem(
              icon: Icon(Icons.bar_chart_outlined),
              activeIcon: Icon(Icons.bar_chart),
              label: 'Analytics'),
        ],
      ),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  final List<double> data;
  final double maxKwh;

  _LineChartPainter({required this.data, required this.maxKwh});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;

    final linePaint = Paint()
      ..color = AppColors.greenMid
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [AppColors.greenMid.withAlpha(80), AppColors.greenMid.withAlpha(0)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    final stepX = size.width / (data.length - 1);

    Offset off(int i) {
      final x = i * stepX;
      final y = size.height - (data[i] / maxKwh) * size.height;
      return Offset(x, y.clamp(0.0, size.height));
    }

    final gridPaint = Paint()
      ..color = AppColors.greenMid.withAlpha(20)
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
      canvas.drawCircle(off(i), 3.5,
          Paint()..color = AppColors.greenDark..style = PaintingStyle.fill);
      canvas.drawCircle(off(i), 3.5,
          Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(_LineChartPainter old) =>
      old.data != data || old.maxKwh != maxKwh;
}