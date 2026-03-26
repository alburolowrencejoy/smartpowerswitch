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

const double _mapAspectRatio = 354 / 496;

class _ContainRect {
  final double left, top, width, height;
  const _ContainRect({required this.left, required this.top, required this.width, required this.height});
}

// ─── Hotspot Model ────────────────────────────────────────────────────────────

class _HotspotData {
  final String buildingId;
  double x, y, w, h; // all 0.0–1.0 fractions

  _HotspotData({required this.buildingId, required this.x, required this.y, required this.w, required this.h});

  Map<String, dynamic> toMap() => {'x': x, 'y': y, 'w': w, 'h': h};
}

// ─── Campus Map Screen ────────────────────────────────────────────────────────

class CampusMapScreen extends StatefulWidget {
  final String role;
  final bool showAppBar;
  const CampusMapScreen({super.key, this.role = 'faculty', this.showAppBar = false});

  @override
  State<CampusMapScreen> createState() => _CampusMapScreenState();
}

class _CampusMapScreenState extends State<CampusMapScreen> {
  String? _selectedBuildingId;
  bool    _editMode = false;

  // From Firebase
  Map<String, Map<String, dynamic>> _buildingData  = {}; // energy data
  Map<String, Map<String, dynamic>> _buildingsInfo = {}; // name, floors
  Map<String, _HotspotData>         _hotspots      = {}; // hotspot positions

  StreamSubscription? _devicesSub;
  StreamSubscription? _buildingsSub;
  StreamSubscription? _hotspotsSub;

  bool get isAdmin => widget.role == 'admin';

  bool _isPermissionDenied(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') || text.contains('permission_denied');
  }

  @override
  void initState() {
    super.initState();
    _listenDevices();
    _listenBuildings();
    _listenHotspots();
  }

  @override
  void dispose() {
    _devicesSub?.cancel();
    _buildingsSub?.cancel();
    _hotspotsSub?.cancel();
    super.dispose();
  }

  void _listenDevices() {
    _devicesSub = FirebaseDatabase.instance.ref('devices').onValue.listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;
      final Map<String, Map<String, dynamic>> bData = {};
      for (final id in _buildingsInfo.keys) {
        bData[id] = {'kwh': 0.0, 'deviceCount': 0, 'rooms': <String, Map<String, dynamic>>{}};
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
          if (!bData.containsKey(building)) {
            bData[building] = {'kwh': 0.0, 'deviceCount': 0, 'rooms': <String, Map<String, dynamic>>{}};
          }
          bData[building]!['kwh']         = (bData[building]!['kwh'] as double) + kwh.toDouble();
          bData[building]!['deviceCount'] = (bData[building]!['deviceCount'] as int) + 1;
          if (room.isNotEmpty) {
            final rooms = bData[building]!['rooms'] as Map<String, Map<String, dynamic>>;
            if (!rooms.containsKey(room)) rooms[room] = {'utilities': <Map<String, dynamic>>[]};
            (rooms[room]!['utilities'] as List<Map<String, dynamic>>).add({
              'id': deviceId, 'utility': utility, 'kwh': kwh.toDouble(), 'status': status, 'relay': relay,
            });
          }
        });
      }
      setState(() => _buildingData = bData);
    });
  }

  void _listenBuildings() {
    _buildingsSub = FirebaseDatabase.instance.ref('buildings').onValue.listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;
      if (raw == null) { setState(() => _buildingsInfo = {}); return; }
      final data = Map<String, dynamic>.from(raw as Map);
      final Map<String, Map<String, dynamic>> info = {};
      data.forEach((code, val) {
        if (val is! Map) return;
        final b = Map<String, dynamic>.from(val);
        info[code] = {'name': (b['name'] ?? code).toString(), 'floors': (b['floors'] ?? 1) as int};
      });
      setState(() => _buildingsInfo = info);
    });
  }

  void _listenHotspots() {
    _hotspotsSub = FirebaseDatabase.instance.ref('hotspots').onValue.listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;
      final Map<String, _HotspotData> spots = {};
      if (raw is Map) {
        raw.forEach((id, val) {
          if (val is Map) {
            final data = Map<String, dynamic>.from(val);
            // Parse safely as double
            spots[id.toString()] = _HotspotData(
              buildingId: id.toString(),
              x: ((data['x'] ?? 0.1) as num).toDouble(),
              y: ((data['y'] ?? 0.1) as num).toDouble(),
              w: ((data['w'] ?? 0.2) as num).toDouble(),
              h: ((data['h'] ?? 0.1) as num).toDouble(),
            );
          }
        });
      }
      setState(() => _hotspots = spots);
    });
  }

  // Buildings that exist but have no hotspot yet
  List<String> get _buildingsWithoutHotspot =>
      _buildingsInfo.keys.where((id) => !_hotspots.containsKey(id)).toList();

  Future<void> _addHotspot(String buildingId) async {
    // Place in center by default
    final spot = _HotspotData(buildingId: buildingId, x: 0.35, y: 0.35, w: 0.22, h: 0.10);
    if (mounted) {
      setState(() => _hotspots[buildingId] = spot);
    }
    try {
      await FirebaseDatabase.instance.ref('hotspots/$buildingId').set(spot.toMap());
    } catch (e) {
      if (mounted) {
        setState(() => _hotspots.remove(buildingId));
      }
      rethrow;
    }
  }

  Future<void> _deleteHotspot(String buildingId) async {
    await FirebaseDatabase.instance.ref('hotspots/$buildingId').remove();
  }

  Future<void> _saveHotspot(String buildingId) async {
    final spot = _hotspots[buildingId];
    if (spot == null) return;
    await FirebaseDatabase.instance.ref('hotspots/$buildingId').set(spot.toMap());
  }

  void _onBuildingTap(String buildingId) {
    if (_editMode) return;
    setState(() {
      _selectedBuildingId = _selectedBuildingId == buildingId ? null : buildingId;
    });
  }

  void _dismissPopup() => setState(() => _selectedBuildingId = null);

  void _viewBuildingDetails(String buildingId) {
    final code   = buildingId;
    final info   = _buildingsInfo[buildingId] ?? {};
    final name   = info['name'] as String? ?? buildingId;
    final floors = info['floors'] as int? ?? 1;
    final role   = widget.role;
    setState(() => _selectedBuildingId = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.pushNamed(context, '/building', arguments: {
        'buildingCode': code, 'buildingName': name, 'floors': floors, 'role': role,
      });
    });
  }

  _ContainRect _computeContainRect(BoxConstraints constraints) {
    final w = constraints.maxWidth;
    final h = constraints.maxHeight;
    final aspect = w / h;
    if (aspect > _mapAspectRatio) {
      final iW = h * _mapAspectRatio;
      return _ContainRect(left: (w - iW) / 2, top: 0, width: iW, height: h);
    }
    final iH = w / _mapAspectRatio;
    return _ContainRect(left: 0, top: (h - iH) / 2, width: w, height: iH);
  }

  // ── Build hotspot widget (view mode) ──────────────────────────────────────
  Widget _buildViewHotspot(_HotspotData spot, _ContainRect rect) {
    final bData      = _buildingData[spot.buildingId];
    final kwh        = (bData?['kwh'] as double?) ?? 0.0;
    final level      = _energyLevel(kwh);
    final color      = _energyColor(level);
    final isSelected = _selectedBuildingId == spot.buildingId;

    return Positioned(
      left:   rect.left + spot.x * rect.width,
      top:    rect.top  + spot.y * rect.height,
      width:  spot.w * rect.width,
      height: spot.h * rect.height,
      child: GestureDetector(
        onTap: () => _onBuildingTap(spot.buildingId),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: color.withAlpha(isSelected ? 120 : 60),
            border: Border.all(color: color, width: isSelected ? 3 : 1.5),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(color: color.withAlpha(200), borderRadius: BorderRadius.circular(4)),
              child: Text(spot.buildingId,
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ),
    );
  }

  // ── Build hotspot widget (edit mode) ──────────────────────────────────────
  Widget _buildEditHotspot(_HotspotData spot, _ContainRect rect) {
    const double handleSize = 18.0;

    return Positioned(
      left:   rect.left + spot.x * rect.width,
      top:    rect.top  + spot.y * rect.height,
      width:  spot.w * rect.width,
      height: spot.h * rect.height,
      child: GestureDetector(
        // Drag the whole zone
        onPanUpdate: (details) {
          setState(() {
            spot.x = (spot.x + details.delta.dx / rect.width).clamp(0.0, 1.0 - spot.w);
            spot.y = (spot.y + details.delta.dy / rect.height).clamp(0.0, 1.0 - spot.h);
          });
        },
        onPanEnd: (_) => _saveHotspot(spot.buildingId),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.greenDark.withAlpha(40),
            border: Border.all(color: AppColors.greenDark, width: 2),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Label
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(color: AppColors.greenDark, borderRadius: BorderRadius.circular(4)),
                  child: Text(spot.buildingId,
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
              ),

              // Delete button top-left
              Positioned(
                top: -10, left: -10,
                child: GestureDetector(
                  onTap: () async {
                    await _deleteHotspot(spot.buildingId);
                  },
                  child: Container(
                    width: 22, height: 22,
                    decoration: const BoxDecoration(color: AppColors.error, shape: BoxShape.circle),
                    child: const Icon(Icons.close, color: Colors.white, size: 14),
                  ),
                ),
              ),

              // ── Corner resize handles ─────────────────────────────

              // Bottom-right corner
              Positioned(
                right: -handleSize / 2, bottom: -handleSize / 2,
                child: GestureDetector(
                  onPanUpdate: (d) {
                    setState(() {
                      spot.w = (spot.w + d.delta.dx / rect.width).clamp(0.05, 1.0 - spot.x);
                      spot.h = (spot.h + d.delta.dy / rect.height).clamp(0.03, 1.0 - spot.y);
                    });
                  },
                  onPanEnd: (_) => _saveHotspot(spot.buildingId),
                  child: _resizeHandle(),
                ),
              ),

              // Bottom-left corner
              Positioned(
                left: -handleSize / 2, bottom: -handleSize / 2,
                child: GestureDetector(
                  onPanUpdate: (d) {
                    setState(() {
                      final newW = (spot.w - d.delta.dx / rect.width).clamp(0.05, spot.x + spot.w);
                      final dx   = spot.w - newW;
                      spot.x    = (spot.x + dx).clamp(0.0, 1.0);
                      spot.w    = newW;
                      spot.h    = (spot.h + d.delta.dy / rect.height).clamp(0.03, 1.0 - spot.y);
                    });
                  },
                  onPanEnd: (_) => _saveHotspot(spot.buildingId),
                  child: _resizeHandle(),
                ),
              ),

              // Top-right corner
              Positioned(
                right: -handleSize / 2, top: -handleSize / 2,
                child: GestureDetector(
                  onPanUpdate: (d) {
                    setState(() {
                      spot.w    = (spot.w + d.delta.dx / rect.width).clamp(0.05, 1.0 - spot.x);
                      final newH = (spot.h - d.delta.dy / rect.height).clamp(0.03, spot.y + spot.h);
                      final dy   = spot.h - newH;
                      spot.y    = (spot.y + dy).clamp(0.0, 1.0);
                      spot.h    = newH;
                    });
                  },
                  onPanEnd: (_) => _saveHotspot(spot.buildingId),
                  child: _resizeHandle(),
                ),
              ),

              // Top-left corner
              Positioned(
                left: -handleSize / 2, top: -handleSize / 2,
                child: GestureDetector(
                  onPanUpdate: (d) {
                    setState(() {
                      final newW = (spot.w - d.delta.dx / rect.width).clamp(0.05, spot.x + spot.w);
                      final dx   = spot.w - newW;
                      spot.x    = (spot.x + dx).clamp(0.0, 1.0);
                      spot.w    = newW;
                      final newH = (spot.h - d.delta.dy / rect.height).clamp(0.03, spot.y + spot.h);
                      final dy   = spot.h - newH;
                      spot.y    = (spot.y + dy).clamp(0.0, 1.0);
                      spot.h    = newH;
                    });
                  },
                  onPanEnd: (_) => _saveHotspot(spot.buildingId),
                  child: _resizeHandle(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _resizeHandle() {
    return Container(
      width: 18, height: 18,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppColors.greenDark, width: 2),
        shape: BoxShape.circle,
      ),
    );
  }

  // ── Add hotspot picker ────────────────────────────────────────────────────
  void _showAddHotspotPicker() {
    final available = _buildingsWithoutHotspot;
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All buildings already have hotspots.')));
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) {
        final maxHeight = MediaQuery.of(context).size.height * 0.75;
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 14, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Add Hotspot Zone',
                      style: TextStyle(fontFamily: 'Outfit', fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textDark),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    'Select a building to add a hotspot zone on the map.',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    children: available.map((id) {
                      final info = _buildingsInfo[id] ?? {};
                      return ListTile(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(color: AppColors.greenPale, borderRadius: BorderRadius.circular(10)),
                          child: Center(
                            child: Text(
                              id,
                              style: const TextStyle(fontFamily: 'Outfit', fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.greenDark),
                            ),
                          ),
                        ),
                        title: Text(info['name'] ?? id, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textDark)),
                        subtitle: Text('${info['floors'] ?? 1} floors', style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
                        trailing: const Icon(Icons.add_circle_outline, color: AppColors.greenMid),
                        onTap: () async {
                          Navigator.pop(context);
                          if (!mounted) return;
                          try {
                            await _addHotspot(id);
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Hotspot added for $id. Drag to position it.')),
                            );
                          } catch (e) {
                            if (!mounted) return;
                            final msg = _isPermissionDenied(e)
                                ? 'Permission denied. You do not have access to create hotspot zones.'
                                : 'Failed to add hotspot: $e';
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                          }
                        },
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMap() {
    return GestureDetector(
      onTap: _editMode ? null : _dismissPopup,
      child: Stack(
        children: [
          // ── Map ──────────────────────────────────────────────
          Positioned.fill(
            child: InteractiveViewer(
              // Disable pan/zoom in edit mode so drags work correctly
              panEnabled:  !_editMode,
              scaleEnabled: !_editMode,
              minScale: 0.8,
              maxScale: 4.0,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final rect = _computeContainRect(constraints);
                  return Stack(
                    children: [
                      Positioned.fill(child: Image.asset('assets/images/campus_map.png', fit: BoxFit.contain)),
                      // Render hotspots
                      ..._hotspots.values.map((spot) =>
                          _editMode
                              ? _buildEditHotspot(spot, rect)
                              : _buildViewHotspot(spot, rect)),
                    ],
                  );
                },
              ),
            ),
          ),

          // ── Legend (top left) ─────────────────────────────────
          if (!_editMode)
            Positioned(
              top: 12, left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(220),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [BoxShadow(color: Color.fromARGB(20, 0, 0, 0), blurRadius: 8)],
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

          // ── Edit Mode toolbar (top right) ─────────────────────
          if (isAdmin)
            Positioned(
              top: 12, right: 12,
              child: _editMode
                  ? Row(children: [
                      // Add hotspot button
                      GestureDetector(
                        onTap: _showAddHotspotPicker,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(
                            color: AppColors.greenMid,
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [BoxShadow(color: Colors.black.withAlpha(30), blurRadius: 8)],
                          ),
                          child: const Row(children: [
                            Icon(Icons.add, color: Colors.white, size: 16),
                            SizedBox(width: 4),
                            Text('Add Zone', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Done button
                      GestureDetector(
                        onTap: () => setState(() => _editMode = false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(
                            color: AppColors.greenDark,
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [BoxShadow(color: Colors.black.withAlpha(30), blurRadius: 8)],
                          ),
                          child: const Row(children: [
                            Icon(Icons.check, color: Colors.white, size: 16),
                            SizedBox(width: 4),
                            Text('Done', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ),
                    ])
                  : GestureDetector(
                      onTap: () => setState(() { _editMode = true; _selectedBuildingId = null; }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(220),
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [BoxShadow(color: Colors.black.withAlpha(20), blurRadius: 8)],
                        ),
                        child: const Row(children: [
                          Icon(Icons.edit_location_alt_outlined, color: AppColors.greenDark, size: 16),
                          SizedBox(width: 4),
                          Text('Edit Zones', style: TextStyle(color: AppColors.greenDark, fontSize: 12, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    ),
            ),

          // ── Edit mode hint banner ─────────────────────────────
          if (_editMode)
            Positioned(
              bottom: 16, left: 16, right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.greenDark.withAlpha(230),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(children: [
                  Icon(Icons.info_outline, color: Colors.white, size: 14),
                  SizedBox(width: 8),
                  Expanded(child: Text('Drag zone to move · Drag corners to resize · Tap ✕ to delete',
                      style: TextStyle(color: Colors.white, fontSize: 11))),
                ]),
              ),
            ),

          // ── Popup ─────────────────────────────────────────────
          if (_selectedBuildingId != null && !_editMode)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: GestureDetector(
                onTap: () {},
                child: _BuildingPopup(
                  buildingId:   _selectedBuildingId!,
                  buildingName: _buildingsInfo[_selectedBuildingId!]?['name'] ?? _selectedBuildingId!,
                  floors:       _buildingsInfo[_selectedBuildingId!]?['floors'] ?? 1,
                  data:         _buildingData[_selectedBuildingId!] ?? {},
                  role:         widget.role,
                  onClose:      _dismissPopup,
                  onViewDetails: () => _viewBuildingDetails(_selectedBuildingId!),
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
              style: TextStyle(fontFamily: 'Outfit', color: Colors.white, fontWeight: FontWeight.w700)),
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: _buildMap(),
      );
    }
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
      Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: AppColors.textDark)),
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
    final rawRooms    = data['rooms'];
    final rooms       = rawRooms is Map
        ? Map<String, Map<String, dynamic>>.from(rawRooms.map((k, v) =>
            MapEntry(k.toString(), v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{})))
        : <String, Map<String, dynamic>>{};
    final level = _energyLevel(kwh);
    final color = _energyColor(level);

    return Container(
      constraints: const BoxConstraints(maxHeight: 400),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(40), blurRadius: 16, offset: const Offset(0, -4))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(margin: const EdgeInsets.only(top: 10), width: 40, height: 4,
            decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(buildingName,
                  style: const TextStyle(fontFamily: 'Outfit', fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.greenDark)),
              const SizedBox(height: 4),
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: color.withAlpha(30), border: Border.all(color: color), borderRadius: BorderRadius.circular(20)),
                  child: Row(children: [
                    Icon(Icons.circle, color: color, size: 8),
                    const SizedBox(width: 4),
                    Text(_energyLabel(level), style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
                  ]),
                ),
                const SizedBox(width: 8),
                Text('${kwh.toStringAsFixed(1)} kWh', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
              ]),
            ])),
            IconButton(onPressed: onClose, icon: const Icon(Icons.close), color: Colors.grey),
          ]),
        ),
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
        rooms.isEmpty
            ? Padding(padding: const EdgeInsets.all(16),
                child: Text(deviceCount == 0 ? 'No devices assigned yet' : 'No room data',
                    style: const TextStyle(fontSize: 13, color: AppColors.textMuted)))
            : Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  children: rooms.entries.map((entry) {
                    final roomName  = entry.key;
                    final utilities = (entry.value['utilities'] as List<Map<String, dynamic>>?) ?? [];
                    final roomKwh   = utilities.fold(0.0, (s, u) => s + (u['kwh'] as double));
                    return _RoomTile(roomName: roomName, utilities: utilities, roomKwh: roomKwh);
                  }).toList(),
                ),
              ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onViewDetails,
              icon: const Icon(Icons.arrow_forward, size: 16),
              label: const Text('View Building Details'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.greenDark, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ),
      ]),
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
        decoration: BoxDecoration(color: AppColors.greenPale, borderRadius: BorderRadius.circular(10)),
        child: Column(children: [
          Icon(icon, color: AppColors.greenDark, size: 16),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.greenDark)),
          Text(label, style: TextStyle(fontSize: 9, color: Colors.grey[600])),
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
          Text(roomName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppColors.greenDark)),
          const Spacer(),
          Text('${roomKwh.toStringAsFixed(1)} kWh', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        ]),
        const SizedBox(height: 4),
        Row(
          children: utilities.map((u) {
            final status   = (u['status']  as String?) ?? 'offline';
            final utility  = (u['utility'] as String?) ?? '';
            final kwh      = (u['kwh']     as double?) ?? 0.0;
            final isOnline = status == 'online';
            return Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Row(children: [
                Icon(_utilityIcon(utility), size: 12, color: isOnline ? AppColors.greenMid : AppColors.textMuted),
                const SizedBox(width: 3),
                Text('${kwh.toStringAsFixed(1)} kWh', style: TextStyle(fontSize: 10, color: Colors.grey[600])),
              ]),
            );
          }).toList(),
        ),
        const Divider(height: 12),
      ]),
    );
  }
}