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
  int _selectedIndex = 0;

  final List<Map<String, dynamic>> _buildings = [
    {'code': 'IC',    'name': 'Institute of Computing',                      'floors': 2},
    {'code': 'ILEGG', 'name': 'Institute of Leadership & Good Governance',   'floors': 2},
    {'code': 'ITED',  'name': 'Institute of Teachers Education',             'floors': 2},
    {'code': 'IAAS',  'name': 'Institute of Aquatic Science',                'floors': 1},
    {'code': 'ADMIN', 'name': 'Administrator Building',                      'floors': 1},
  ];

  // Mock totals — replace with Firebase reads
  double _totalKwh      = 284.5;
  double _totalCostPhp  = 3271.75;
  int    _onlineDevices = 18;
  final int    _totalDevices  = 24;

  @override
  void initState() {
    super.initState();
    _listenToSummary();
  }

  void _listenToSummary() {
    // Listen to all readings and aggregate
    FirebaseDatabase.instance.ref('readings').onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) return;
      double kwh = 0;
      int online = 0;
      data.forEach((key, val) {
        if (val is Map) {
          kwh += (val['energy'] as num?)?.toDouble() ?? 0;
          if (val['status'] == 'online') online++;
        }
      });
      setState(() {
        _totalKwh     = kwh;
        _totalCostPhp = kwh * 11.5;
        _onlineDevices = online;
      });
    });
  }

  void _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/login');
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
      child: Row(
        children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(color: AppColors.greenMid, borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.bolt, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('SmartPowerSwitch',
                style: TextStyle(fontFamily: 'Outfit', fontSize: 16,
                    fontWeight: FontWeight.w600, color: Colors.white)),
          ),
          IconButton(
            icon: const Icon(Icons.notifications_outlined, color: Colors.white, size: 22),
            onPressed: () => Navigator.pushNamed(context, '/notifications'),
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white, size: 20),
            onPressed: _logout,
          ),
        ],
      ),
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
          _buildSectionTitle('Campus Buildings', trailing: '${_buildings.length} buildings'),
          const SizedBox(height: 12),
          ..._buildings.map(_buildBuildingCard),
        ],
      ),
    );
  }

  Widget _buildGreeting() {
    final user = FirebaseAuth.instance.currentUser;
    final hour = DateTime.now().hour;
    final greeting = hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(greeting,
            style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
        Text(user?.email?.split('@').first ?? 'User',
            style: const TextStyle(fontFamily: 'Outfit', fontSize: 22,
                fontWeight: FontWeight.w700, color: AppColors.textDark)),
      ],
    );
  }

  Widget _buildEnergyCards() {
    return Column(
      children: [
        // Main energy card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.greenDark,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: AppColors.greenDark.withAlpha(77),
                blurRadius: 20, offset: const Offset(0, 8))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Total Energy Today',
                  style: TextStyle(fontSize: 12, color: Color(0xB3C2EDD0))),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_totalKwh.toStringAsFixed(1),
                      style: const TextStyle(fontFamily: 'Outfit', fontSize: 36,
                          fontWeight: FontWeight.w700, color: Colors.white)),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 6, left: 4),
                    child: Text('kWh', style: TextStyle(fontSize: 14, color: AppColors.greenLight)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(children: [
                _miniStat('Cost', '₱ ${_totalCostPhp.toStringAsFixed(2)}'),
                const SizedBox(width: 20),
                _miniStat('Devices', '$_onlineDevices / $_totalDevices online'),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _statCard('Voltage', '220 V', Icons.electrical_services, AppColors.greenMid)),
          const SizedBox(width: 12),
          Expanded(child: _statCard('Frequency', '60 Hz', Icons.waves, AppColors.greenLight)),
          const SizedBox(width: 12),
          Expanded(child: _statCard('Power Factor', '0.98', Icons.speed, AppColors.greenPale,
              textColor: AppColors.greenDark)),
        ]),
      ],
    );
  }

  Widget _miniStat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Color(0x99C2EDD0))),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
      ],
    );
  }

  Widget _statCard(String label, String value, IconData icon, Color bg, {Color textColor = Colors.white}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: textColor.withAlpha(204)),
          const SizedBox(height: 8),
          Text(value, style: TextStyle(fontFamily: 'Outfit', fontSize: 15,
              fontWeight: FontWeight.w700, color: textColor)),
          Text(label, style: TextStyle(fontSize: 10, color: textColor.withAlpha(179))),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, {String? trailing}) {
    return Row(children: [
      Text(title, style: const TextStyle(fontFamily: 'Outfit', fontSize: 16,
          fontWeight: FontWeight.w600, color: AppColors.textDark)),
      const Spacer(),
      if (trailing != null)
        Text(trailing, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
    ]);
  }

  Widget _buildBuildingCard(Map<String, dynamic> building) {
    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/building', arguments: {
        'buildingCode': building['code'],
        'buildingName': building['name'],
        'floors':       building['floors'],
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
          Container(
            width: 46, height: 46,
            decoration: BoxDecoration(
              color: AppColors.greenPale,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(building['code'],
                  style: const TextStyle(fontFamily: 'Outfit', fontSize: 11,
                      fontWeight: FontWeight.w700, color: AppColors.greenDark)),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(building['name'],
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                      color: AppColors.textDark)),
              const SizedBox(height: 3),
              Text('${building['floors']} ${building['floors'] == 1 ? 'floor' : 'floors'} · 3 utilities',
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            ]),
          ),
          const Icon(Icons.chevron_right, color: AppColors.textMuted, size: 20),
        ]),
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(15), blurRadius: 16, offset: const Offset(0, -4))],
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
          BottomNavigationBarItem(icon: Icon(Icons.dashboard_outlined),
              activeIcon: Icon(Icons.dashboard), label: 'Dashboard'),
          BottomNavigationBarItem(icon: Icon(Icons.map_outlined),
              activeIcon: Icon(Icons.map), label: 'Map'),
        ],
      ),
    );
  }
}
