import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../theme/app_colors.dart';
import '../widgets/top_toast.dart';

class BuildingFloorScreen extends StatefulWidget {
  final String buildingCode;
  final String buildingName;
  final int floors;
  final String role;

  const BuildingFloorScreen({
    super.key,
    required this.buildingCode,
    required this.buildingName,
    required this.floors,
    required this.role,
  });

  @override
  State<BuildingFloorScreen> createState() => _BuildingFloorScreenState();
}

class _BuildingFloorScreenState extends State<BuildingFloorScreen> {
  int _selectedFloor = 1;
  String? _selectedRoom;

  final Map<int, List<String>> _rooms = {};
  Map<String, dynamic> _devices = {};

  double _buildingKwh = 0;
  int _buildingOnline = 0;
  bool _hasMonthlyBuildingEnergy = false;
  int _instituteTotalDevices = 0; // assigned devices in this building
  int _totalAssigned =
      0; // total assigned across all buildings (for 24-limit check)

  final List<StreamSubscription<DatabaseEvent>> _roomSubs = [];
  StreamSubscription? _devicesSub;
  StreamSubscription? _masterSub;
  StreamSubscription? _energySub;
  StreamSubscription? _historySub;
  StreamSubscription? _onlineSub;
  Map<String, dynamic> _liveDevices = {};

  bool get isAdmin => widget.role == 'admin';

  bool _isPermissionDenied(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') ||
        text.contains('permission_denied');
  }

  @override
  void initState() {
    super.initState();
    _loadRooms();
    _listenToDevices();
    _listenToMasterDevices();
    _listenToBuildingEnergy();
    _listenToBuildingOnline();
  }

  @override
  void dispose() {
    for (final sub in _roomSubs) {
      sub.cancel();
    }
    _roomSubs.clear();
    _devicesSub?.cancel();
    _masterSub?.cancel();
    _energySub?.cancel();
    _historySub?.cancel();
    _onlineSub?.cancel();
    super.dispose();
  }

  // â”€â”€ Load rooms â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  void _loadRooms() {
    for (final sub in _roomSubs) {
      sub.cancel();
    }
    _roomSubs.clear();

    for (int f = 1; f <= widget.floors; f++) {
      final floor = f;
      final sub = FirebaseDatabase.instance
          .ref('buildings/${widget.buildingCode}/floorData/$floor/rooms')
          .onValue
          .listen((event) {
        if (!mounted) return;
        final data = event.snapshot.value;
        List<String> roomList = [];
        if (data is List) {
          roomList = data.whereType<String>().toList();
        } else if (data is Map) {
          roomList = data.values.whereType<String>().toList();
        }
        setState(() => _rooms[floor] = roomList);
      }, onError: (Object error) {
        if (!mounted || _isPermissionDenied(error)) return;
      });
      _roomSubs.add(sub);
    }
  }

  // â”€â”€ Listen to devices on current floor â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  void _listenToDevices() {
    _devicesSub?.cancel();
    _devicesSub = FirebaseDatabase.instance
        .ref(
            'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices')
        .onValue
        .listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value;
      final devices = <String, dynamic>{};

      if (data is Map) {
        data.forEach((k, v) {
          if (v is Map) {
            final device = <String, dynamic>{};
            v.forEach((dk, dv) => device[dk.toString()] = dv);
            devices[k.toString()] = device;
          }
        });
      }

      setState(() => _devices = devices);
    }, onError: (Object error) {
      if (!mounted || _isPermissionDenied(error)) return;
    });
  }

  // â”€â”€ Count devices from master_devices â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  void _listenToMasterDevices() {
    _masterSub =
        FirebaseDatabase.instance.ref('master_devices').onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) {
        setState(() {
          _instituteTotalDevices = 0;
          _totalAssigned = 0;
        });
        return;
      }

      int buildingCount = 0;
      int totalAssigned = 0;

      data.forEach((id, val) {
        if (val is! Map) return;
        final assignedTo = (val['assignedTo'] ?? '').toString();
        if (assignedTo.isNotEmpty) {
          totalAssigned++;
          // assignedTo format: "IC/1/Comlab 1"
          final parts = assignedTo.split('/');
          if (parts.isNotEmpty && parts[0] == widget.buildingCode) {
            buildingCount++;
          }
        }
      });

      setState(() {
        _instituteTotalDevices = buildingCount;
        _totalAssigned = totalAssigned;
      });
    }, onError: (Object error) {
      if (!mounted || _isPermissionDenied(error)) return;
    });
  }

  void _switchFloor(int floor) {
    setState(() {
      _selectedFloor = floor;
      _selectedRoom = null;
      _devices = {};
    });
    _listenToDevices();
  }

  // â”€â”€ Building energy from current-month history â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  void _listenToBuildingEnergy() {
    _energySub?.cancel();
    _historySub?.cancel();
    final monthKey = _monthKey(DateTime.now());
    _historySub = FirebaseDatabase.instance
        .ref('history/monthly/$monthKey/buildings/${widget.buildingCode}/kwh')
        .onValue
        .listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;
      if (raw is num) {
        final kwh = raw.toDouble();
        setState(() {
          _hasMonthlyBuildingEnergy = true;
          _buildingKwh = kwh;
        });
      } else {
        if (_hasMonthlyBuildingEnergy) {
          setState(() => _hasMonthlyBuildingEnergy = false);
        }
      }
    }, onError: (Object error) {
      if (!mounted || _isPermissionDenied(error)) return;
    });

    _energySub =
        FirebaseDatabase.instance.ref('devices').onValue.listen((event) {
      final data = event.snapshot.value;
      final liveDevices = <String, dynamic>{};
      double kwh = 0;

      if (data is Map) {
        data.forEach((id, val) {
          if (val is! Map) return;
          final device = Map<String, dynamic>.from(val);
          liveDevices[id.toString()] = device;

          final building = (device['building'] ?? '').toString();
          if (building != widget.buildingCode) return;
          kwh += ((device['kwh'] ?? 0.0) as num).toDouble();
        });
      }

      if (!mounted) return;
      setState(() {
        _liveDevices = liveDevices;
        if (!_hasMonthlyBuildingEnergy) {
          _buildingKwh = kwh;
        }
      });
    }, onError: (Object error) {
      if (!mounted || _isPermissionDenied(error)) return;
    });
  }

  double _roomKwh(String room) {
    double total = 0;
    // Read from live devices (flat /devices node) filtered by building + room
    _liveDevices.forEach((_, val) {
      if (val is! Map) return;
      final device = Map<String, dynamic>.from(val);
      final deviceBuilding = (device['building'] ?? '').toString();
      final deviceRoom = device['room']?.toString().trim() ?? '';

      // Only sum if building matches and room matches
      if (deviceBuilding != widget.buildingCode) return;
      if (deviceRoom != room.trim()) return;

      total += ((device['kwh'] ?? 0.0) as num).toDouble();
    });
    return total;
  }

  double _currentEnergyKwh() {
    if (_selectedRoom != null) {
      return _roomKwh(_selectedRoom!);
    }
    return _buildingKwh;
  }

  String _energyScopeLabel() {
    return _selectedRoom != null ? 'Room' : 'All Rooms';
  }

  String _monthKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';

  // ── Live online count from flat devices node ───────────────────────────────
  void _listenToBuildingOnline() {
    _onlineSub?.cancel();
    _onlineSub =
        FirebaseDatabase.instance.ref('devices').onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value;
      if (data is! Map) {
        setState(() => _buildingOnline = 0);
        return;
      }

      int online = 0;
      data.forEach((_, val) {
        if (val is! Map) return;
        final device = Map<String, dynamic>.from(val);
        final building = (device['building'] ?? '').toString();
        if (building != widget.buildingCode) return;
        final lastSeen = device['last_seen'];
        if (lastSeen != null && lastSeen != 0) {
          final dt = DateTime.fromMillisecondsSinceEpoch(lastSeen as int);
          if (DateTime.now().difference(dt).inMinutes < 2) online++;
        }
      });

      setState(() => _buildingOnline = online);
    }, onError: (Object error) {
      if (!mounted || _isPermissionDenied(error)) return;
    });
  }

  // â”€â”€ Add room â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> _addRoom() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Add Room',
            style:
                TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'e.g. Room 2, Lab 1, Office',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.greenMid)),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel',
                  style: TextStyle(color: AppColors.textMuted))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.greenDark,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('Add', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (result == null || result.isEmpty) return;
    final current = _rooms[_selectedFloor] ?? [];
    if (current.contains(result)) {
      if (!mounted) return;
      TopToast.error(context, 'Room already exists.');
      return;
    }

    final updated = [...current, result];
    final roomMap = {for (int i = 0; i < updated.length; i++) '$i': updated[i]};
    await FirebaseDatabase.instance
        .ref('buildings/${widget.buildingCode}/floorData/$_selectedFloor/rooms')
        .set(roomMap);
  }

  // â”€â”€ Edit room â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> _editRoom(String oldRoom) async {
    final controller = TextEditingController(text: oldRoom);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Edit Room Name',
            style:
                TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'e.g. Room 2, Lab 1, Office',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.greenMid)),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel',
                  style: TextStyle(color: AppColors.textMuted))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.greenDark,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (result == null || result.isEmpty || result == oldRoom) return;

    final current = _rooms[_selectedFloor] ?? [];
    if (current.contains(result)) {
      if (!mounted) return;
      TopToast.error(context, 'Room name already exists.');
      return;
    }

    // Update room name in the list
    final updated = current.map((r) => r == oldRoom ? result : r).toList();
    final roomMap = {for (int i = 0; i < updated.length; i++) '$i': updated[i]};
    await FirebaseDatabase.instance
        .ref('buildings/${widget.buildingCode}/floorData/$_selectedFloor/rooms')
        .set(roomMap);

    // Update all devices in this room
    final snap = await FirebaseDatabase.instance
        .ref(
            'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices')
        .get();

    if (snap.exists) {
      final data = snap.value as Map<dynamic, dynamic>;
      for (final entry in data.entries) {
        final val = entry.value as Map?;
        if (val?['room'] == oldRoom) {
          final deviceId = entry.key.toString();
          // Update in buildings node
          await FirebaseDatabase.instance
              .ref(
                  'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices/$deviceId/room')
              .set(result);
          // Update in flat devices node
          await FirebaseDatabase.instance
              .ref('devices/$deviceId/room')
              .set(result);
        }
      }
    }

    if (!mounted) return;
    TopToast.success(context, '"$oldRoom" renamed to "$result".');
  }

  // â”€â”€ Delete room â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> _deleteRoom(String room) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Room',
            style:
                TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
        content: Text('Delete "$room" and all its utilities?',
            style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel',
                  style: TextStyle(color: AppColors.textMuted))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final snap = await FirebaseDatabase.instance
        .ref(
            'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices')
        .get();

    if (snap.exists) {
      final data = snap.value as Map<dynamic, dynamic>;
      for (final entry in data.entries) {
        final val = entry.value as Map?;
        if (val?['room'] == room) await _unassignDevice(entry.key.toString());
      }
    }

    final current = List<String>.from(_rooms[_selectedFloor] ?? []);
    current.remove(room);
    final roomMap = {for (int i = 0; i < current.length; i++) '$i': current[i]};
    await FirebaseDatabase.instance
        .ref('buildings/${widget.buildingCode}/floorData/$_selectedFloor/rooms')
        .set(current.isEmpty ? {} : roomMap);

    if (!mounted) return;
    TopToast.success(context, '"$room" deleted.');
  }

  // â”€â”€ Add utility â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> _addUtility(String room) async {
    if (_totalAssigned >= 24) {
      TopToast.threshold(context, 'Device limit reached (24 max).');
      return;
    }

    String? utility = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Select Utility Type',
            style:
                TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          _utilityPickTile('Lights', Icons.lightbulb_outline, 'Lights',
              'Relay 220V', const Color(0xFFE8922A)),
          const SizedBox(height: 8),
          _utilityPickTile('Outlets', Icons.electrical_services, 'Outlets',
              'Relay 220V', AppColors.greenMid),
          const SizedBox(height: 8),
          _utilityPickTile('AC', Icons.ac_unit, 'AC Unit', 'Contactor 220V',
              const Color(0xFF2196F3)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel',
                  style: TextStyle(color: AppColors.textMuted))),
        ],
      ),
    );
    if (utility == null || !mounted) return;

    final deviceIdController = TextEditingController();
    String? errorText;

    final deviceId = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Enter Device ID',
              style:
                  TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
                'Type the unique Device ID from the sticker on your ESP32.',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted)),
            const SizedBox(height: 12),
            TextField(
              controller: deviceIdController,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'e.g. DEV-2024-A3F7',
                errorText: errorText,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.greenMid)),
                prefixIcon:
                    const Icon(Icons.qr_code, color: AppColors.textMuted),
              ),
              autofocus: true,
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel',
                    style: TextStyle(color: AppColors.textMuted))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.greenDark,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              onPressed: () async {
                final id = deviceIdController.text.trim().toUpperCase();
                if (id.isEmpty) {
                  setS(() => errorText = 'Please enter a Device ID');
                  return;
                }
                final snap = await FirebaseDatabase.instance
                    .ref('master_devices/$id')
                    .get();
                if (!snap.exists) {
                  setS(() => errorText = 'Device ID not found in system');
                  return;
                }
                final assigned = (snap.value as Map?)?['assignedTo'] as String?;
                if (assigned != null && assigned.isNotEmpty) {
                  setS(
                      () => errorText = 'Device already assigned to $assigned');
                  return;
                }
                if (_devices.containsKey(id)) {
                  setS(() => errorText = 'Device already added to this floor');
                  return;
                }
                if (ctx.mounted) Navigator.pop(ctx, id);
              },
              child: const Text('Add Device',
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
    if (deviceId == null || !mounted) return;

    // Save to buildings node
    await FirebaseDatabase.instance
        .ref(
            'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices/$deviceId')
        .set({
      'utility': utility,
      'status': 'offline',
      'relay': false,
      'room': room,
    });

    // Save to flat devices node
    await FirebaseDatabase.instance.ref('devices/$deviceId').update({
      'building': widget.buildingCode,
      'floor': '$_selectedFloor',
      'room': room,
      'utility': utility,
      'relay': false,
      'status': 'offline',
      'kwh': 0,
      'voltage': 0,
      'current': 0,
      'power': 0,
      'last_seen': 0,
      'last_updated': 0,
    });

    // Update master_devices assignedTo
    await FirebaseDatabase.instance
        .ref('master_devices/$deviceId/assignedTo')
        .set('${widget.buildingCode}/$_selectedFloor/$room');

    if (!mounted) return;
    TopToast.success(context, '$deviceId added as $utility in $room.');
  }

  // â”€â”€ Delete device â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> _deleteDevice(String deviceId, String utility) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove Device',
            style:
                TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Remove ${_utilityLabel(utility)} ($deviceId)?',
                style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 8),
            const Text('The device will be unassigned and available for reuse.',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel',
                  style: TextStyle(color: AppColors.textMuted))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('Remove', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _unassignDevice(deviceId);
    if (!mounted) return;
    TopToast.success(context, '$deviceId removed.');
  }

  Future<void> _unassignDevice(String deviceId) async {
    await FirebaseDatabase.instance
        .ref(
            'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices/$deviceId')
        .remove();
    await FirebaseDatabase.instance
        .ref('master_devices/$deviceId')
        .update({'assignedTo': ''});
    await FirebaseDatabase.instance.ref('devices/$deviceId').update({
      'building': '',
      'floor': '',
      'room': '',
      'status': 'offline',
    });
  }

  Widget _utilityPickTile(
      String value, IconData icon, String label, String sub, Color color) {
    return GestureDetector(
      onTap: () => Navigator.pop(context, value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: color.withAlpha(15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(51)),
        ),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
                color: color.withAlpha(26),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark)),
            Text(sub,
                style:
                    const TextStyle(fontSize: 11, color: AppColors.textMuted)),
          ]),
          const Spacer(),
          Icon(Icons.chevron_right, color: color, size: 18),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(children: [
          _buildHeader(),
          _buildBuildingDashboard(),
          _buildFloorTabs(),
          Flexible(
            fit: FlexFit.loose,
            child: _selectedRoom == null
                ? _buildRoomsList()
                : _buildUtilitiesInRoom(_selectedRoom!),
          ),
        ]),
      ),
      floatingActionButton: isAdmin
          ? FloatingActionButton.extended(
              onPressed: _selectedRoom == null
                  ? _addRoom
                  : () => _addUtility(_selectedRoom!),
              backgroundColor: AppColors.greenDark,
              icon: const Icon(Icons.add, color: Colors.white),
              label: Text(
                _selectedRoom == null ? 'Add Room' : 'Add Utility',
                style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'Outfit',
                    fontWeight: FontWeight.w600),
              ),
            )
          : null,
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      color: AppColors.greenDark,
      child: Row(children: [
        GestureDetector(
          onTap: () {
            if (_selectedRoom != null) {
              setState(() => _selectedRoom = null);
            } else {
              Navigator.pop(context);
            }
          },
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: Colors.white.withAlpha(38),
                borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.arrow_back_ios_new,
                color: Colors.white, size: 16),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.buildingCode,
                style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.greenLight,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1)),
            Text(
              _selectedRoom != null
                  ? '${widget.buildingName} - $_selectedRoom'
                  : widget.buildingName,
              style: const TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.white),
              overflow: TextOverflow.ellipsis,
            ),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              color: Colors.white.withAlpha(26),
              borderRadius: BorderRadius.circular(12)),
          child: Text(isAdmin ? 'Admin' : 'Faculty',
              style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
        ),
      ]),
    );
  }

  Widget _buildBuildingDashboard() {
    final energyKwh = _currentEnergyKwh();
    final energyCost = energyKwh * 11.5;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      decoration: const BoxDecoration(
        color: AppColors.greenDark,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
      ),
      child: Row(children: [
        Expanded(
            child: _dashCard(
                _energyScopeLabel(),
                '${energyKwh.toStringAsFixed(1)} kWh',
                Icons.bolt,
                AppColors.greenLight)),
        const SizedBox(width: 10),
        Expanded(
            child: _dashCard('Cost', 'PHP ${energyCost.toStringAsFixed(0)}',
                Icons.payments_outlined, AppColors.greenPale)),
        const SizedBox(width: 10),
        Expanded(
            child: _dashCard('Online', '$_buildingOnline online', Icons.wifi,
                AppColors.greenMid)),
        if (isAdmin) ...[
          const SizedBox(width: 10),
          Expanded(
              child: _dashCard('Devices', '$_instituteTotalDevices assigned',
                  Icons.devices, AppColors.greenLight)),
        ],
      ]),
    );
  }

  Widget _dashCard(String label, String value, IconData icon, Color color) {
    return SizedBox(
      height: 84,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
            color: Colors.white.withAlpha(15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withAlpha(26))),
        child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(height: 6),
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: color)),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: color.withAlpha(179))),
            ]),
      ),
    );
  }

  Widget _buildFloorTabs() {
    return Container(
      height: 52,
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      decoration: BoxDecoration(
          color: AppColors.greenPale, borderRadius: BorderRadius.circular(14)),
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
                    color:
                        isSelected ? AppColors.greenDark : Colors.transparent,
                    borderRadius: BorderRadius.circular(10)),
                child: Center(
                  child: Text('Floor $floor',
                      style: TextStyle(
                          fontFamily: 'Outfit',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color:
                              isSelected ? Colors.white : AppColors.textMid)),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildRoomsList() {
    final rooms = _rooms[_selectedFloor] ?? [];
    if (rooms.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.meeting_room_outlined,
              size: 48, color: AppColors.textMuted),
          const SizedBox(height: 12),
          const Text('No rooms yet',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark)),
          const SizedBox(height: 6),
          Text(
            isAdmin
                ? 'Tap + Add Room to get started'
                : 'No rooms have been added yet',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ]),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            'Floor $_selectedFloor - ${rooms.length} ${rooms.length == 1 ? 'room' : 'rooms'}',
            style: const TextStyle(
                fontFamily: 'Outfit',
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        const SizedBox(height: 16),
        ...rooms.map((room) => _buildRoomCard(room)),
      ]),
    );
  }

  Widget _buildRoomCard(String room) {
    int utilityCount = 0;
    int onlineCount = 0;
    bool hasLights = false;
    bool hasOutlets = false;
    bool hasAc = false;

    _devices.forEach((id, d) {
      if (d is Map && d['room']?.toString().trim() == room.trim()) {
        utilityCount++;
        if (d['status'] == 'online') onlineCount++;
        final u = (d['utility'] ?? '').toString().toLowerCase();
        if (u == 'lights') hasLights = true;
        if (u == 'outlets') hasOutlets = true;
        if (u == 'ac') hasAc = true;
      }
    });

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.greenMid.withAlpha(26))),
      child: Column(children: [
        GestureDetector(
          onTap: () => setState(() => _selectedRoom = room),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                    color: AppColors.greenPale,
                    borderRadius: BorderRadius.circular(13)),
                child: const Icon(Icons.meeting_room_outlined,
                    size: 24, color: AppColors.greenDark),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(room,
                          style: const TextStyle(
                              fontFamily: 'Outfit',
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textDark)),
                      const SizedBox(height: 3),
                      Text(
                        utilityCount == 0
                            ? 'No utilities added'
                            : '$utilityCount ${utilityCount == 1 ? 'utility' : 'utilities'} - $onlineCount online',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textMuted),
                      ),
                    ]),
              ),
              if (hasLights)
                _utilityDot(Icons.lightbulb_outline, const Color(0xFFE8922A)),
              if (hasOutlets)
                Padding(
                    padding: const EdgeInsets.only(left: 5),
                    child: _utilityDot(
                        Icons.electrical_services, AppColors.greenMid)),
              if (hasAc)
                Padding(
                    padding: const EdgeInsets.only(left: 5),
                    child: _utilityDot(Icons.ac_unit, const Color(0xFF2196F3))),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right,
                  color: AppColors.textMuted, size: 20),
            ]),
          ),
        ),
        if (isAdmin) ...[
          Divider(height: 1, color: AppColors.greenMid.withAlpha(20)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => _editRoom(room),
                  icon: const Icon(Icons.edit_outlined,
                      size: 16, color: AppColors.greenDark),
                  label: const Text('Edit',
                      style:
                          TextStyle(fontSize: 12, color: AppColors.greenDark)),
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 10)),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: () => _deleteRoom(room),
                  icon: const Icon(Icons.delete_outline,
                      size: 16, color: AppColors.error),
                  label: const Text('Delete',
                      style: TextStyle(fontSize: 12, color: AppColors.error)),
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 10)),
                ),
              ),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _utilityDot(IconData icon, Color color) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
          color: color.withAlpha(26), borderRadius: BorderRadius.circular(8)),
      child: Icon(icon, size: 14, color: color),
    );
  }

  Widget _buildUtilitiesInRoom(String room) {
    final roomDevices = <MapEntry<String, dynamic>>[];
    _devices.forEach((id, d) {
      if (d is Map && d['room']?.toString().trim() == room.trim()) {
        roomDevices.add(MapEntry(id, d));
      }
    });

    if (roomDevices.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.power_off_outlined,
              size: 48, color: AppColors.textMuted),
          const SizedBox(height: 12),
          const Text('No utilities yet',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark)),
          const SizedBox(height: 6),
          Text(
            isAdmin
                ? 'Tap + Add Utility to add one'
                : 'No utilities have been added yet',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ]),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(room,
            style: const TextStyle(
                fontFamily: 'Outfit',
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        const SizedBox(height: 4),
        Text(
            '${roomDevices.length} ${roomDevices.length == 1 ? 'utility' : 'utilities'}',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
        const SizedBox(height: 16),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.10,
          ),
          itemCount: roomDevices.length,
          itemBuilder: (context, index) {
            final entry = roomDevices[index];
            return _buildDeviceTile(
              entry.key,
              Map<String, dynamic>.from(entry.value),
              room,
            );
          },
        ),
      ]),
    );
  }

  Widget _buildDeviceTile(String deviceId, Map<String, dynamic> device, String room) {
    final utility = device['utility'] as String? ?? 'unknown';
    final status = device['status'] as String? ?? 'offline';
    final relay = device['relay'] as bool? ?? false;
    final isOnline = status == 'online';
    final color = _utilityColor(utility);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: relay && isOnline
              ? color.withAlpha(102)
              : AppColors.greenMid.withAlpha(26),
          width: relay && isOnline ? 1.5 : 1,
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: _AnimatedUtilityIcon(
              utility: utility,
              isOn: relay && isOnline,
              isOnline: isOnline,
            ),
          ),
          const Spacer(),
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isOnline ? AppColors.success : AppColors.offline)),
        ]),
        const SizedBox(height: 6),
        Text(_utilityLabel(utility),
            style: const TextStyle(
                fontFamily: 'Outfit',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        Text(deviceId,
            style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
            overflow: TextOverflow.ellipsis),
        Text(isOnline ? (relay ? 'ON' : 'OFF') : 'Offline',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isOnline
                    ? (relay ? AppColors.success : AppColors.textMuted)
                    : AppColors.offline)),
        const Spacer(),
        Row(children: [
          Expanded(
            child: GestureDetector(
              onTap: () => Navigator.pushNamed(context, '/device', arguments: {
                'deviceId': deviceId,
                'utility': utility,
                'building': widget.buildingCode,
                'room': room,
                'floor': _selectedFloor,
                'role': widget.role,
              }),
              child: Container(
                height: 28,
                decoration: BoxDecoration(
                    color: AppColors.greenPale,
                    borderRadius: BorderRadius.circular(8)),
                child: const Center(
                  child: Text('View',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.greenDark)),
                ),
              ),
            ),
          ),
          if (isAdmin) ...[
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => _deleteDevice(deviceId, utility),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                    color: AppColors.error.withAlpha(20),
                    borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.delete_outline,
                    size: 16, color: AppColors.error),
              ),
            ),
          ],
        ]),
      ]),
    );
  }

  Color _utilityColor(String u) {
    switch (u.toLowerCase()) {
      case 'light':
      case 'lights':
        return const Color(0xFFE8922A);
      case 'outlet':
      case 'outlets':
        return AppColors.greenMid;
      case 'aircon':
      case 'ac':
      case 'air conditioner':
        return const Color(0xFF2196F3);
      default:
        return AppColors.textMuted;
    }
  }

  String _utilityLabel(String u) {
    switch (u.toLowerCase()) {
      case 'light':
      case 'lights':
        return 'Lights';
      case 'outlet':
      case 'outlets':
        return 'Outlets';
      case 'aircon':
      case 'ac':
      case 'air conditioner':
        return 'AC Unit';
      default:
        return 'Device';
    }
  }
}

class _AnimatedUtilityIcon extends StatefulWidget {
  final String utility;
  final bool isOn;
  final bool isOnline;

  const _AnimatedUtilityIcon({
    required this.utility,
    required this.isOn,
    required this.isOnline,
  });

  @override
  State<_AnimatedUtilityIcon> createState() => _AnimatedUtilityIconState();
}

class _AnimatedUtilityIconState extends State<_AnimatedUtilityIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.isOn ? 1100 : 1500),
    )..repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _AnimatedUtilityIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isOn != widget.isOn ||
        oldWidget.isOnline != widget.isOnline) {
      _controller.duration = Duration(milliseconds: widget.isOn ? 1100 : 1500);
      if (!_controller.isAnimating) {
        _controller.repeat(reverse: true);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  IconData _iconForUtility(String u) {
    switch (u.toLowerCase()) {
      case 'light':
      case 'lights':
        return Icons.lightbulb_outline;
      case 'outlet':
      case 'outlets':
        return Icons.electrical_services;
      case 'aircon':
      case 'ac':
      case 'air conditioner':
        return Icons.ac_unit;
      default:
        return Icons.device_unknown_outlined;
    }
  }

  Color _colorForUtility(String u) {
    switch (u.toLowerCase()) {
      case 'light':
      case 'lights':
        return const Color(0xFFE8922A);
      case 'outlet':
      case 'outlets':
        return AppColors.greenMid;
      case 'aircon':
      case 'ac':
      case 'air conditioner':
        return const Color(0xFF2196F3);
      default:
        return AppColors.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final utilityColor = _colorForUtility(widget.utility);
    final icon = _iconForUtility(widget.utility);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final pulse = 0.5 + (_controller.value * 0.5);
        final scale =
            widget.isOn ? 0.98 + (pulse * 0.16) : 0.95 + (pulse * 0.07);
        final glow = widget.isOn
            ? utilityColor.withAlpha((70 + (pulse * 120)).toInt())
            : Colors.grey.withAlpha((22 + (pulse * 40)).toInt());
        final fill = widget.isOn
            ? utilityColor.withAlpha((28 + (pulse * 56)).toInt())
            : Colors.grey.withAlpha((16 + (pulse * 28)).toInt());
        final iconColor = widget.isOn
            ? utilityColor
            : AppColors.textMuted.withAlpha((180 + (pulse * 45)).toInt());

        return Transform.scale(
          scale: scale,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: glow,
                  blurRadius: widget.isOn ? 12 + (pulse * 10) : 4 + (pulse * 3),
                  spreadRadius: widget.isOn ? 1 + (pulse * 1.5) : 0,
                ),
              ],
            ),
            child: Icon(icon, size: 18, color: iconColor),
          ),
        );
      },
    );
  }
}
