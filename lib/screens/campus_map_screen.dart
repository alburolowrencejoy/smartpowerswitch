import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../theme/app_colors.dart';

// ─── Energy Level ─────────────────────────────────────────────────────────────

enum EnergyLevel { low, mid, high }

EnergyLevel _energyLevel(double kwh) {
  if (kwh >= 100) return EnergyLevel.high;
  if (kwh >= 50)  return EnergyLevel.mid;
  return EnergyLevel.low;
}

Color _energyColor(EnergyLevel level) {
  switch (level) {
    case EnergyLevel.high: return const Color(0xFFD64A4A);
    case EnergyLevel.mid:  return const Color(0xFFE8922A);
    case EnergyLevel.low:  return AppColors.greenMid;
  }
}

String _energyLabel(EnergyLevel level) {
  switch (level) {
    case EnergyLevel.high: return 'HIGH';
    case EnergyLevel.mid:  return 'MID';
    case EnergyLevel.low:  return 'LOW';
  }
}

IconData _utilityIcon(String type) {
  switch (type.toLowerCase()) {
    case 'lights':  return Icons.lightbulb_outline;
    case 'outlets': return Icons.electrical_services;
    case 'ac':      return Icons.ac_unit;
    default:        return Icons.device_unknown;
  }
}

// ─── Building Metadata ────────────────────────────────────────────────────────

const Map<String, Map<String, dynamic>> _buildingMeta = {
  'IC':    {'name': 'Institute of Computing',                    'floors': 2},
  'ILEGG': {'name': 'Institute of Leadership & Good Governance', 'floors': 2},
  'ITED':  {'name': 'Institute of Teachers Education',           'floors': 2},
  'IAAS':  {'name': 'Institute of Aquatic Science',              'floors': 1},
  'ADMIN': {'name': 'Administrator Building',                    'floors': 1},
};

// ─── Hotspot positions ────────────────────────────────────────────────────────

class _Hotspot {
  final String buildingId;
  final Offset position;
  final Size size;
  const _Hotspot({required this.buildingId, required this.position, required this.size});
}

const List<_Hotspot> _hotspots = [
  _Hotspot(buildingId: 'IC',    position: Offset(0.44, 0.294), size: Size(0.13, 0.10)),
  _Hotspot(buildingId: 'ILEGG', position: Offset(0.65, 0.36), size: Size(0.21, 0.30)),
  _Hotspot(buildingId: 'ITED',  position: Offset(0.75, 0.07), size: Size(0.11, 0.28)),
  _Hotspot(buildingId: 'IAAS',  position: Offset(0.61, 0.77), size: Size(0.24, 0.20)),
  _Hotspot(buildingId: 'ADMIN', position: Offset(0.22, 0.72), size: Size(0.32, 0.17)),
];

// ─── Campus Map Screen ────────────────────────────────────────────────────────

class CampusMapScreen extends StatefulWidget {
  final String role;
  final bool showAppBar; // false when embedded in dashboard
  const CampusMapScreen({super.key, this.role = 'faculty', this.showAppBar = false});

  @override
  State<CampusMapScreen> createState() => _CampusMapScreenState();
}

class _CampusMapScreenState extends State<CampusMapScreen> {
  String? _selectedBuildingId;
  Map<String, Map<String, dynamic>> _buildingData = {};
  StreamSubscription? _devicesSub;

  @override
  void initState() {
    super.initState();
    _listenToData();
  }

  @override
  void dispose() {
    _devicesSub?.cancel();
    super.dispose();
  }

  void _listenToData() {
    _devicesSub = FirebaseDatabase.instance
        .ref('devices')
        .onValue
        .listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;

      final Map<String, Map<String, dynamic>> bData = {};
      for (final id in _buildingMeta.keys) {
        bData[id] = {
          'kwh':         0.0,
          'deviceCount': 0,
          'rooms':       <String, Map<String, dynamic>>{},
        };
      }

      if (raw != null) {
        final devices = Map<String, dynamic>.from(raw as Map);
        devices.forEach((deviceId, val) {
          if (val is! Map) return;
          final device   = Map<String, dynamic>.from(val);
          final building = (device['building'] ?? '').toString();
          final room     = (device['room']     ?? '').toString();
          final utility  = (device['utility']  ?? '').toString();
          final kwh      = (device['kwh']      ?? 0.0) as num;
          final status   = (device['status']   ?? 'offline').toString();
          final relay    = (device['relay']    ?? false) as bool;

          if (!bData.containsKey(building)) return;

          bData[building]!['kwh'] =
              (bData[building]!['kwh'] as double) + kwh.toDouble();
          bData[building]!['deviceCount'] =
              (bData[building]!['deviceCount'] as int) + 1;

          if (room.isNotEmpty) {
            final rooms = bData[building]!['rooms'] as Map<String, Map<String, dynamic>>;
            if (!rooms.containsKey(room)) {
              rooms[room] = {'utilities': <Map<String, dynamic>>[]};
            }
            (rooms[room]!['utilities'] as List<Map<String, dynamic>>).add({
              'id':      deviceId,
              'utility': utility,
              'kwh':     kwh.toDouble(),
              'status':  status,
              'relay':   relay,
            });
          }
        });
      }

      setState(() => _buildingData = bData);
    });
  }

  void _onBuildingTap(String buildingId) {
    setState(() {
      _selectedBuildingId =
          _selectedBuildingId == buildingId ? null : buildingId;
    });
  }

  void _dismissPopup() => setState(() => _selectedBuildingId = null);

  Widget _buildMap() {
    return GestureDetector(
      onTap: _dismissPopup,
      child: Stack(
        children: [
          // ── Map ──────────────────────────────────────────────
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 4.0,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  final h = constraints.maxHeight;
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: Image.asset(
                          'assets/images/campus_map.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                      ..._hotspots.map((spot) {
                        final bData     = _buildingData[spot.buildingId];
                        final kwh       = (bData?['kwh'] as double?) ?? 0.0;
                        final level     = _energyLevel(kwh);
                        final color     = _energyColor(level);
                        final isSelected = _selectedBuildingId == spot.buildingId;

                        return Positioned(
                          left:   spot.position.dx * w,
                          top:    spot.position.dy * h,
                          width:  spot.size.width  * w,
                          height: spot.size.height * h,
                          child: GestureDetector(
                            onTap: () => _onBuildingTap(spot.buildingId),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              decoration: BoxDecoration(
                                color: color.withAlpha(isSelected ? 120 : 60),
                                border: Border.all(
                                    color: color,
                                    width: isSelected ? 3 : 1.5),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: color.withAlpha(200),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(spot.buildingId,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold)),
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  );
                },
              ),
            ),
          ),

          // ── Legend (top left) ─────────────────────────────────
          Positioned(
            top: 12, left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(220),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(
                    color: Colors.black.withAlpha(20),
                    blurRadius: 8)],
              ),
              child: const Row(children: [
                _LegendDot(color: AppColors.greenMid,      label: 'Low'),
                SizedBox(width: 8),
                _LegendDot(color: Color(0xFFE8922A), label: 'Mid'),
                SizedBox(width: 8),
                _LegendDot(color: Color(0xFFD64A4A), label: 'High'),
              ]),
            ),
          ),

          // ── Popup ─────────────────────────────────────────────
          if (_selectedBuildingId != null)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: GestureDetector(
                onTap: () {},
                child: _BuildingPopup(
                  buildingId:   _selectedBuildingId!,
                  buildingName: _buildingMeta[_selectedBuildingId!]!['name'],
                  floors:       _buildingMeta[_selectedBuildingId!]!['floors'],
                  data:         _buildingData[_selectedBuildingId!] ?? {},
                  role:         widget.role,
                  onClose:      _dismissPopup,
                  onViewDetails: () {
                    _dismissPopup();
                    Navigator.pushNamed(context, '/building', arguments: {
                      'buildingCode': _selectedBuildingId,
                      'buildingName': _buildingMeta[_selectedBuildingId!]!['name'],
                      'floors':       _buildingMeta[_selectedBuildingId!]!['floors'],
                      'role':         widget.role,
                    });
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.showAppBar) {
      return Scaffold(
        backgroundColor: const Color(0xFFF0F4F0),
        appBar: AppBar(
          backgroundColor: AppColors.greenDark,
          title: const Text('Campus Map',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  color: Colors.white,
                  fontWeight: FontWeight.w700)),
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: _buildMap(),
      );
    }

    // Embedded mode — no AppBar
    return _buildMap();
  }
}

// ─── Legend Dot ───────────────────────────────────────────────────────────────

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(
          width: 9, height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 4),
      Text(label,
          style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.textDark)),
    ]);
  }
}

// ─── Building Popup ───────────────────────────────────────────────────────────

class _BuildingPopup extends StatelessWidget {
  final String buildingId;
  final String buildingName;
  final int floors;
  final Map<String, dynamic> data;
  final String role;
  final VoidCallback onClose;
  final VoidCallback onViewDetails;

  const _BuildingPopup({
    required this.buildingId,
    required this.buildingName,
    required this.floors,
    required this.data,
    required this.role,
    required this.onClose,
    required this.onViewDetails,
  });

  @override
  Widget build(BuildContext context) {
    final kwh         = (data['kwh']         as double?) ?? 0.0;
    final deviceCount = (data['deviceCount'] as int?)    ?? 0;
    final rooms       = (data['rooms'] as Map<String, Map<String, dynamic>>?) ?? {};
    final level       = _energyLevel(kwh);
    final color       = _energyColor(level);

    return Container(
      constraints: const BoxConstraints(maxHeight: 400),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withAlpha(40),
              blurRadius: 16,
              offset: const Offset(0, -4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 10),
            width: 40, height: 4,
            decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2)),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(buildingName,
                      style: const TextStyle(
                          fontFamily: 'Outfit',
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.greenDark)),
                  const SizedBox(height: 4),
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: color.withAlpha(30),
                        border: Border.all(color: color),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(children: [
                        Icon(Icons.circle, color: color, size: 8),
                        const SizedBox(width: 4),
                        Text(_energyLabel(level),
                            style: TextStyle(
                                color: color,
                                fontSize: 11,
                                fontWeight: FontWeight.bold)),
                      ]),
                    ),
                    const SizedBox(width: 8),
                    Text('${kwh.toStringAsFixed(1)} kWh',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                  ]),
                ]),
              ),
              IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                  color: Colors.grey),
            ]),
          ),

          // Stats
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              _StatBox(icon: Icons.layers,              label: 'Floors',  value: '$floors'),
              const SizedBox(width: 8),
              _StatBox(icon: Icons.meeting_room,        label: 'Rooms',   value: '${rooms.length}'),
              const SizedBox(width: 8),
              _StatBox(icon: Icons.electrical_services, label: 'Devices', value: '$deviceCount'),
              const SizedBox(width: 8),
              _StatBox(icon: Icons.bolt,                label: 'kWh',     value: kwh.toStringAsFixed(1)),
            ]),
          ),

          const SizedBox(height: 10),
          const Divider(height: 1),

          // Room list
          rooms.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    deviceCount == 0 ? 'No devices assigned yet' : 'No room data',
                    style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
                  ),
                )
              : Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    children: rooms.entries.map((entry) {
                      final roomName  = entry.key;
                      final utilities = (entry.value['utilities'] as List<Map<String, dynamic>>?) ?? [];
                      final roomKwh   = utilities.fold(0.0, (s, u) => s + (u['kwh'] as double));
                      return _RoomTile(
                          roomName: roomName,
                          utilities: utilities,
                          roomKwh: roomKwh);
                    }).toList(),
                  ),
                ),

          // Button
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onViewDetails,
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: const Text('View Building Details'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.greenDark,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Stat Box ─────────────────────────────────────────────────────────────────

class _StatBox extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StatBox({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.greenPale,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(children: [
          Icon(icon, color: AppColors.greenDark, size: 16),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: AppColors.greenDark)),
          Text(label,
              style: TextStyle(fontSize: 9, color: Colors.grey[600])),
        ]),
      ),
    );
  }
}

// ─── Room Tile ────────────────────────────────────────────────────────────────

class _RoomTile extends StatelessWidget {
  final String roomName;
  final List<Map<String, dynamic>> utilities;
  final double roomKwh;
  const _RoomTile({required this.roomName, required this.utilities, required this.roomKwh});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.meeting_room_outlined, size: 14, color: AppColors.greenMid),
          const SizedBox(width: 6),
          Text(roomName,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 13, color: AppColors.greenDark)),
          const Spacer(),
          Text('${roomKwh.toStringAsFixed(1)} kWh',
              style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        ]),
        const SizedBox(height: 4),
        Row(
          children: utilities.map((u) {
            final status  = (u['status']  as String?) ?? 'offline';
            final utility = (u['utility'] as String?) ?? '';
            final kwh     = (u['kwh']     as double?) ?? 0.0;
            final isOnline = status == 'online';
            return Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Row(children: [
                Icon(_utilityIcon(utility),
                    size: 12,
                    color: isOnline ? AppColors.greenMid : AppColors.textMuted),
                const SizedBox(width: 3),
                Text('${kwh.toStringAsFixed(1)} kWh',
                    style: TextStyle(fontSize: 10, color: Colors.grey[600])),
              ]),
            );
          }).toList(),
        ),
        const Divider(height: 12),
      ]),
    );
  }
}