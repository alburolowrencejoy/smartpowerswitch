import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../theme/app_colors.dart';

class BuildingFloorScreen extends StatefulWidget {
  final String buildingCode;
  final String buildingName;
  final int floors;

  const BuildingFloorScreen({
    super.key,
    required this.buildingCode,
    required this.buildingName,
    required this.floors,
  });

  @override
  State<BuildingFloorScreen> createState() => _BuildingFloorScreenState();
}

class _BuildingFloorScreenState extends State<BuildingFloorScreen> {
  int _selectedFloor = 1;
  Map<String, dynamic> _devices = {};

  @override
  void initState() {
    super.initState();
    _listenToDevices();
  }

  void _listenToDevices() {
    final ref = FirebaseDatabase.instance
        .ref('buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices');
    ref.onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      setState(() {
        _devices = data?.map((k, v) => MapEntry(k.toString(), Map<String, dynamic>.from(v))) ?? {};
      });
    });
  }

  void _switchFloor(int floor) {
    setState(() { _selectedFloor = floor; _devices = {}; });
    _listenToDevices();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildFloorTabs(),
            Expanded(child: _buildDeviceGrid()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      decoration: const BoxDecoration(
        color: AppColors.greenDark,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(28), bottomRight: Radius.circular(28),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(38),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 16),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.buildingCode,
                    style: const TextStyle(fontSize: 12, color: AppColors.greenLight,
                        fontWeight: FontWeight.w600, letterSpacing: 1)),
                Text(widget.buildingName,
                    style: const TextStyle(fontFamily: 'Outfit', fontSize: 16,
                        fontWeight: FontWeight.w600, color: Colors.white),
                    overflow: TextOverflow.ellipsis),
              ]),
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined, color: Colors.white, size: 22),
              onPressed: () => Navigator.pushNamed(context, '/settings'),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _buildFloorTabs() {
    return Container(
      height: 52,
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      decoration: BoxDecoration(
        color: AppColors.greenPale,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: List.generate(widget.floors, (i) {
          final floor = i + 1;
          final isSelected = _selectedFloor == floor;
          return Expanded(
            child: GestureDetector(
              onTap: () => _switchFloor(floor),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.greenDark : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text('Floor $floor',
                      style: TextStyle(
                        fontFamily: 'Outfit',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isSelected ? Colors.white : AppColors.textMid,
                      )),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildDeviceGrid() {
    if (_devices.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.greenMid),
      );
    }

    final deviceList = _devices.entries.toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Floor $_selectedFloor Devices',
              style: const TextStyle(fontFamily: 'Outfit', fontSize: 15,
                  fontWeight: FontWeight.w600, color: AppColors.textDark)),
          const SizedBox(height: 4),
          Text('${deviceList.length} devices · tap to view details',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          const SizedBox(height: 16),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.1,
            children: deviceList.map((entry) {
              return _buildDeviceTile(entry.key, Map<String, dynamic>.from(entry.value));
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceTile(String deviceId, Map<String, dynamic> device) {
    final utility = device['utility'] as String? ?? 'unknown';
    final status  = device['status']  as String? ?? 'offline';
    final relay   = device['relay']   as bool?   ?? false;
    final isOnline = status == 'online';

    final icon  = _utilityIcon(utility);
    final color = _utilityColor(utility);

    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/device', arguments: {
        'deviceId': deviceId,
        'utility':  utility,
        'building': widget.buildingCode,
        'floor':    _selectedFloor,
      }),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: relay && isOnline ? color.withAlpha(102) : AppColors.greenMid.withAlpha(26),
            width: relay && isOnline ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: isOnline ? color.withAlpha(31) : AppColors.offline.withAlpha(26),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 22,
                    color: isOnline ? color : AppColors.offline),
              ),
              const Spacer(),
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isOnline ? AppColors.success : AppColors.offline,
                ),
              ),
            ]),
            const Spacer(),
            Text(_utilityLabel(utility),
                style: const TextStyle(fontFamily: 'Outfit', fontSize: 14,
                    fontWeight: FontWeight.w600, color: AppColors.textDark)),
            const SizedBox(height: 2),
            Text(isOnline ? (relay ? 'ON' : 'OFF') : 'Offline',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                    color: isOnline
                        ? (relay ? AppColors.success : AppColors.textMuted)
                        : AppColors.offline)),
          ],
        ),
      ),
    );
  }

  IconData _utilityIcon(String utility) {
    switch (utility) {
      case 'lights':  return Icons.lightbulb_outline;
      case 'outlets': return Icons.electrical_services;
      case 'ac':      return Icons.ac_unit;
      default:        return Icons.device_unknown_outlined;
    }
  }

  Color _utilityColor(String utility) {
    switch (utility) {
      case 'lights':  return const Color(0xFFE8922A);
      case 'outlets': return AppColors.greenMid;
      case 'ac':      return const Color(0xFF2196F3);
      default:        return AppColors.textMuted;
    }
  }

  String _utilityLabel(String utility) {
    switch (utility) {
      case 'lights':  return 'Lights';
      case 'outlets': return 'Outlets';
      case 'ac':      return 'AC Unit';
      default:        return 'Device';
    }
  }
}
