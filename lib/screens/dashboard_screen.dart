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

  double              _totalKwh      = 0;
  double              _totalCostPhp  = 0;
  int                 _onlineDevices = 0;
  final int           _totalDevices  = 24;
  Map<String, double> _buildingEnergy = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_roleLoaded) {
      // Get role passed from login screen — this is instant, no async needed
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map<String, dynamic>) {
        _role     = args['role'] as String? ?? 'faculty';
        _userName = args['name'] as String? ?? '';
      }
      _roleLoaded = true;
      _listenToReadings();
    }
  }

  void _listenToReadings() {
    FirebaseDatabase.instance.ref('readings').onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) return;

      double totalKwh = 0;
      int    online   = 0;
      final  Map<String, double> bEnergy = {};

      data.forEach((deviceId, val) {
        if (val is Map) {
          final kwh = (val['energy'] as num?)?.toDouble() ?? 0;
          totalKwh += kwh;
          if ((val['status'] as String?) == 'online') online++;
        }
      });

      // Read building device assignments to calculate per-building energy
      FirebaseDatabase.instance.ref('buildings').get().then((bSnap) {
        if (!mounted) return;
        final bData = bSnap.value as Map<dynamic, dynamic>?;
        bData?.forEach((bCode, bVal) {
          if (bVal is Map) {
            double bKwh = 0;
            final floorData = bVal['floorData'] as Map?;
            floorData?.forEach((floor, fVal) {
              if (fVal is Map) {
                final devices = fVal['devices'] as Map?;
                devices?.forEach((devId, _) {
                  final reading = data[devId];
                  if (reading is Map) {
                    bKwh += (reading['energy'] as num?)?.toDouble() ?? 0;
                  }
                });
              }
            });
            bEnergy[bCode.toString()] = bKwh;
          }
        });
        setState(() => _buildingEnergy = bEnergy);
      });

      setState(() {
        _totalKwh      = totalKwh;
        _totalCostPhp  = totalKwh * 11.5;
        _onlineDevices = online;
      });
    });
  }

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/login');
  }

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
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: IndexedStack(
                index: _selectedIndex,
                children: [
                  _buildHomeTab(),
                  const Center(child: Text('Map — coming soon')),
                ],
              ),
            ),
          ],
        ),
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
              color: AppColors.greenMid,
              borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.bolt, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text('SmartPowerSwitch',
              style: TextStyle(fontFamily: 'Outfit', fontSize: 16,
                  fontWeight: FontWeight.w600, color: Colors.white)),
        ),
        // Role badge
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
            Icon(
              _role == 'admin' ? Icons.star : Icons.person,
              size: 11,
              color: _role == 'admin' ? AppColors.greenLight : Colors.white,
            ),
            const SizedBox(width: 4),
            Text(
              _role == 'admin' ? 'Admin' : 'Faculty',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  color: _role == 'admin'
                      ? AppColors.greenLight
                      : Colors.white),
            ),
          ]),
        ),
        IconButton(
          icon: const Icon(Icons.notifications_outlined,
              color: Colors.white, size: 22),
          onPressed: () => Navigator.pushNamed(context, '/notifications'),
        ),
        // Settings only for admin
        if (_role == 'admin')
          IconButton(
            icon: const Icon(Icons.settings_outlined,
                color: Colors.white, size: 22),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildGreeting(),
          const SizedBox(height: 20),
          _buildEnergyCards(),
          const SizedBox(height: 24),
          _buildSectionTitle('Campus Buildings',
              trailing: '${_buildings.length} buildings'),
          const SizedBox(height: 12),
          ..._buildings.map(_buildBuildingCard),
        ],
      ),
    );
  }

  Widget _buildGreeting() {
    final hour     = DateTime.now().hour;
    final greeting = hour < 12 ? 'Good morning'
        : hour < 17 ? 'Good afternoon' : 'Good evening';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(greeting,
            style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
        Row(children: [
          Expanded(
            child: Text(
              _userName.isNotEmpty ? _userName : 'User',
              style: const TextStyle(fontFamily: 'Outfit', fontSize: 22,
                  fontWeight: FontWeight.w700, color: AppColors.textDark),
            ),
          ),
        ]),
      ],
    );
  }

  Widget _buildEnergyCards() {
    return Column(children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.greenDark,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(
              color: AppColors.greenDark.withAlpha(77),
              blurRadius: 20, offset: const Offset(0, 8))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Total Energy Today',
              style: TextStyle(fontSize: 12, color: Color(0xB3C2EDD0))),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_totalKwh.toStringAsFixed(1),
                style: const TextStyle(fontFamily: 'Outfit', fontSize: 36,
                    fontWeight: FontWeight.w700, color: Colors.white)),
            const Padding(
              padding: EdgeInsets.only(bottom: 6, left: 4),
              child: Text('kWh',
                  style: TextStyle(fontSize: 14, color: AppColors.greenLight)),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            _miniStat('Cost', '₱ ${_totalCostPhp.toStringAsFixed(2)}'),
            const SizedBox(width: 20),
            _miniStat('Devices', '$_onlineDevices / $_totalDevices online'),
          ]),
        ]),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _statCard('Voltage',      '220 V', Icons.electrical_services, AppColors.greenMid)),
        const SizedBox(width: 12),
        Expanded(child: _statCard('Frequency',    '60 Hz', Icons.waves,               AppColors.greenLight)),
        const SizedBox(width: 12),
        Expanded(child: _statCard('Power Factor', '0.98',  Icons.speed,               AppColors.greenPale,
            textColor: AppColors.greenDark)),
      ]),
    ]);
  }

  Widget _miniStat(String label, String value) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, color: Color(0x99C2EDD0))),
      Text(value, style: const TextStyle(fontSize: 13,
          fontWeight: FontWeight.w600, color: Colors.white)),
    ]);
  }

  Widget _statCard(String label, String value, IconData icon, Color bg,
      {Color textColor = Colors.white}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: textColor.withAlpha(204)),
        const SizedBox(height: 8),
        Text(value, style: TextStyle(fontFamily: 'Outfit', fontSize: 15,
            fontWeight: FontWeight.w700, color: textColor)),
        Text(label, style: TextStyle(fontSize: 10, color: textColor.withAlpha(179))),
      ]),
    );
  }

  Widget _buildSectionTitle(String title, {String? trailing}) {
    return Row(children: [
      Text(title, style: const TextStyle(fontFamily: 'Outfit', fontSize: 16,
          fontWeight: FontWeight.w600, color: AppColors.textDark)),
      const Spacer(),
      if (trailing != null)
        Text(trailing,
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
    ]);
  }

  Widget _buildBuildingCard(Map<String, dynamic> building) {
    final code  = building['code'] as String;
    final level = _energyLevel(code);
    final color = _energyColor(code);

    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/building', arguments: {
        'buildingCode': code,
        'buildingName': building['name'],
        'floors':       building['floors'],
        'role':         _role,  // pass role to building screen
      }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.greenMid.withAlpha(31)),
        ),
        child: Row(children: [
          // Building code badge
          Container(
            width: 46, height: 46,
            decoration: BoxDecoration(
              color: AppColors.greenPale,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(code,
                  style: const TextStyle(fontFamily: 'Outfit', fontSize: 11,
                      fontWeight: FontWeight.w700, color: AppColors.greenDark)),
            ),
          ),
          const SizedBox(width: 14),
          // Building info
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(building['name'],
                  style: const TextStyle(fontSize: 14,
                      fontWeight: FontWeight.w600, color: AppColors.textDark)),
              const SizedBox(height: 3),
              Text(
                '${building['floors']} ${building['floors'] == 1 ? 'floor' : 'floors'} · 3 utilities',
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ]),
          ),
          // Energy level indicator on right
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: color.withAlpha(26),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: color.withAlpha(77)),
              ),
              child: Text(level,
                  style: TextStyle(fontSize: 11,
                      fontWeight: FontWeight.w700, color: color)),
            ),
            const SizedBox(height: 4),
            Text('${(_buildingEnergy[code] ?? 0).toStringAsFixed(1)} kWh',
                style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
          ]),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, color: AppColors.textMuted, size: 20),
        ]),
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(
            color: Colors.black.withAlpha(15),
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
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_outlined),
              activeIcon: Icon(Icons.dashboard),
              label: 'Dashboard'),
          BottomNavigationBarItem(
              icon: Icon(Icons.map_outlined),
              activeIcon: Icon(Icons.map),
              label: 'Map'),
        ],
      ),
    );
  }
}
