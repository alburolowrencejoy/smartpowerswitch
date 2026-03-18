import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../theme/app_colors.dart';

class BuildingFloorScreen extends StatefulWidget {
  final String buildingCode;
  final String buildingName;
  final int    floors;
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
  int     _selectedFloor = 1;
  String? _selectedRoom;

  Map<int, List<String>> _rooms   = {};
  Map<String, dynamic>   _devices = {};

  double _buildingKwh    = 0;
  double _buildingCost   = 0;
  int    _buildingOnline = 0;
  int    _totalDeviceCount = 0;

  bool get isAdmin => widget.role == 'admin';

  @override
  void initState() {
    super.initState();
    _loadRooms();
    _listenToDevices();
    _listenToTotalDevices();
  }

  // ── Load rooms ───────────────────────────────────────────────
  void _loadRooms() {
    for (int f = 1; f <= widget.floors; f++) {
      final floor = f;
      FirebaseDatabase.instance
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
      });
    }
  }

  // ── Listen to devices on current floor ──────────────────────
  void _listenToDevices() {
    FirebaseDatabase.instance
        .ref('buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices')
        .onValue
        .listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      double kwh = 0; int online = 0;
      final devices = data?.map((k, v) =>
          MapEntry(k.toString(), Map<String, dynamic>.from(v as Map))) ?? {};
      setState(() {
        _devices        = devices;
        _buildingKwh    = kwh;
        _buildingCost   = kwh * 11.5;
        _buildingOnline = online;
      });
    });
  }

  void _listenToTotalDevices() {
    FirebaseDatabase.instance.ref('master_devices').onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      setState(() => _totalDeviceCount = data?.length ?? 0);
    });
  }

  void _switchFloor(int floor) {
    setState(() {
      _selectedFloor = floor;
      _selectedRoom  = null;
      _devices       = {};
    });
    _listenToDevices();
  }

  // ── Add room ─────────────────────────────────────────────────
  Future<void> _addRoom() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Add Room',
            style: TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
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
              child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.greenDark,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Add', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (result == null || result.isEmpty) return;
    final current = _rooms[_selectedFloor] ?? [];
    if (current.contains(result)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Room already exists.')));
      return;
    }
    await FirebaseDatabase.instance
        .ref('buildings/${widget.buildingCode}/floorData/$_selectedFloor/rooms')
        .set([...current, result]);
  }

  // ── Delete room ──────────────────────────────────────────────
  Future<void> _deleteRoom(String room) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Room',
            style: TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
        content: Text('Delete "$room" and all its utilities?',
            style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    // Remove all devices in this room
    final roomDevices = _devices.entries
        .where((e) => e.value['room'] == room)
        .toList();
    for (final entry in roomDevices) {
      await _unassignDevice(entry.key);
    }

    // Remove room from list
    final current = _rooms[_selectedFloor] ?? [];
    await FirebaseDatabase.instance
        .ref('buildings/${widget.buildingCode}/floorData/$_selectedFloor/rooms')
        .set(current.where((r) => r != room).toList());
  }

  // ── Add utility (admin types device ID manually) ─────────────
  Future<void> _addUtility(String room) async {
    if (_totalDeviceCount >= 24) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device limit reached (24 max).')));
      return;
    }

    // Step 1 — pick utility type
    String? utility = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Select Utility Type',
            style: TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          _utilityPickTile('lights',  Icons.lightbulb_outline,   'Lights',  'Relay 220V',      const Color(0xFFE8922A)),
          const SizedBox(height: 8),
          _utilityPickTile('outlets', Icons.electrical_services, 'Outlets', 'Relay 220V',      AppColors.greenMid),
          const SizedBox(height: 8),
          _utilityPickTile('ac',      Icons.ac_unit,             'AC Unit', 'Contactor 220V',  const Color(0xFF2196F3)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted))),
        ],
      ),
    );
    if (utility == null) return;

    // Step 2 — enter device ID
    final deviceIdController = TextEditingController();
    String? errorText;

    final deviceId = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Enter Device ID',
              style: TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Type the unique Device ID from the sticker on your ESP32.',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted)),
            const SizedBox(height: 12),
            TextField(
              controller: deviceIdController,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'e.g. DEV-2024-A3F7',
                errorText: errorText,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.greenMid)),
                prefixIcon: const Icon(Icons.qr_code, color: AppColors.textMuted),
              ),
              autofocus: true,
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.greenDark,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: () async {
                final id = deviceIdController.text.trim().toUpperCase();
                if (id.isEmpty) {
                  setS(() => errorText = 'Please enter a Device ID');
                  return;
                }
                // Validate against master_devices
                final snap = await FirebaseDatabase.instance
                    .ref('master_devices/$id').get();
                if (!snap.exists) {
                  setS(() => errorText = 'Device ID not found in system');
                  return;
                }
                // Check if already assigned
                final assigned = (snap.value as Map?)?['assignedTo'] as String?;
                if (assigned != null && assigned.isNotEmpty) {
                  setS(() => errorText = 'Device already assigned to $assigned');
                  return;
                }
                // Check if already in this building
                if (_devices.containsKey(id)) {
                  setS(() => errorText = 'Device already added to this floor');
                  return;
                }
                Navigator.pop(ctx, id);
              },
              child: const Text('Add Device', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
    if (deviceId == null) return;

    // Save to Firebase
    await FirebaseDatabase.instance
        .ref('buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices/$deviceId')
        .set({'utility': utility, 'status': 'offline', 'relay': false, 'room': room});

    await FirebaseDatabase.instance
        .ref('master_devices/$deviceId/assignedTo')
        .set('${widget.buildingCode}/floor$_selectedFloor/$room');

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$deviceId added as ${_utilityLabel(utility)} in $room.')));
  }

  // ── Delete utility / device ──────────────────────────────────
  Future<void> _deleteDevice(String deviceId, String utility) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove Device',
            style: TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
        content: Column(mainAxisSize: MainAxisSize.min,
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
              child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Remove', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _unassignDevice(deviceId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$deviceId removed.')));
  }

  Future<void> _unassignDevice(String deviceId) async {
    // Remove from building
    await FirebaseDatabase.instance
        .ref('buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices/$deviceId')
        .remove();
    // Reset in master_devices
    await FirebaseDatabase.instance
        .ref('master_devices/$deviceId/assignedTo')
        .set('');
  }

  // ── Utility pick tile ────────────────────────────────────────
  Widget _utilityPickTile(String value, IconData icon, String label,
      String sub, Color color) {
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
            width: 38, height: 38,
            decoration: BoxDecoration(
                color: color.withAlpha(26),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 14,
                fontWeight: FontWeight.w600, color: AppColors.textDark)),
            Text(sub, style: const TextStyle(fontSize: 11,
                color: AppColors.textMuted)),
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
          Expanded(
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
                style: const TextStyle(color: Colors.white,
                    fontFamily: 'Outfit', fontWeight: FontWeight.w600),
              ),
            )
          : null,
    );
  }

  // ── Header ───────────────────────────────────────────────────
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
            width: 36, height: 36,
            decoration: BoxDecoration(
                color: Colors.white.withAlpha(38),
                borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.arrow_back_ios_new,
                color: Colors.white, size: 16),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.buildingCode,
                style: const TextStyle(fontSize: 11,
                    color: AppColors.greenLight,
                    fontWeight: FontWeight.w600, letterSpacing: 1)),
            Text(
              _selectedRoom != null
                  ? '${widget.buildingName} · $_selectedRoom'
                  : widget.buildingName,
              style: const TextStyle(fontFamily: 'Outfit', fontSize: 15,
                  fontWeight: FontWeight.w600, color: Colors.white),
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
              style: const TextStyle(fontSize: 10,
                  fontWeight: FontWeight.w600, color: Colors.white)),
        ),
      ]),
    );
  }

  // ── Building dashboard ───────────────────────────────────────
  Widget _buildBuildingDashboard() {
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
        Expanded(child: _dashCard('Energy',
            '${_buildingKwh.toStringAsFixed(1)} kWh',
            Icons.bolt, AppColors.greenLight)),
        const SizedBox(width: 10),
        Expanded(child: _dashCard('Cost',
            '₱ ${_buildingCost.toStringAsFixed(0)}',
            Icons.payments_outlined, AppColors.greenPale)),
        const SizedBox(width: 10),
        Expanded(child: _dashCard('Online',
            '$_buildingOnline online',
            Icons.wifi, AppColors.greenMid)),
        if (isAdmin) ...[
          const SizedBox(width: 10),
          Expanded(child: _dashCard('Devices',
              '$_totalDeviceCount / 24',
              Icons.devices, _totalDeviceCount >= 24
                  ? AppColors.error
                  : AppColors.greenLight)),
        ],
      ]),
    );
  }

  Widget _dashCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
          color: Colors.white.withAlpha(15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withAlpha(26))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(height: 6),
        Text(value, style: TextStyle(fontFamily: 'Outfit', fontSize: 12,
            fontWeight: FontWeight.w700, color: color)),
        Text(label, style: TextStyle(fontSize: 10,
            color: color.withAlpha(179))),
      ]),
    );
  }

  // ── Floor tabs ───────────────────────────────────────────────
  Widget _buildFloorTabs() {
    return Container(
      height: 52,
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      decoration: BoxDecoration(
          color: AppColors.greenPale,
          borderRadius: BorderRadius.circular(14)),
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
                    borderRadius: BorderRadius.circular(10)),
                child: Center(
                  child: Text('Floor $floor',
                      style: TextStyle(fontFamily: 'Outfit', fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isSelected ? Colors.white : AppColors.textMid)),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  // ── Rooms list ───────────────────────────────────────────────
  Widget _buildRoomsList() {
    final rooms = _rooms[_selectedFloor] ?? [];

    if (rooms.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.meeting_room_outlined,
              size: 48, color: AppColors.textMuted),
          const SizedBox(height: 12),
          const Text('No rooms yet',
              style: TextStyle(fontFamily: 'Outfit', fontSize: 15,
                  fontWeight: FontWeight.w600, color: AppColors.textDark)),
          const SizedBox(height: 6),
          Text(
            isAdmin ? 'Tap + Add Room to get started'
                : 'No rooms have been added yet',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ]),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Floor $_selectedFloor · ${rooms.length} ${rooms.length == 1 ? 'room' : 'rooms'}',
            style: const TextStyle(fontFamily: 'Outfit', fontSize: 15,
                fontWeight: FontWeight.w600, color: AppColors.textDark)),
        const SizedBox(height: 16),
        ...rooms.map((room) => _buildRoomCard(room)),
      ]),
    );
  }

  Widget _buildRoomCard(String room) {
    final roomDevices = _devices.values
        .where((d) => (d as Map?)?['room'] == room)
        .toList();
    final onlineCount = roomDevices
        .where((d) => (d as Map?)?['status'] == 'online')
        .length;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.greenMid.withAlpha(26))),
      child: Column(children: [
        // Room header — tappable
        GestureDetector(
          onTap: () => setState(() => _selectedRoom = room),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                    color: AppColors.greenPale,
                    borderRadius: BorderRadius.circular(13)),
                child: const Icon(Icons.meeting_room_outlined,
                    size: 24, color: AppColors.greenDark),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(room, style: const TextStyle(fontFamily: 'Outfit',
                      fontSize: 15, fontWeight: FontWeight.w600,
                      color: AppColors.textDark)),
                  const SizedBox(height: 3),
                  Text(
                    roomDevices.isEmpty
                        ? 'No utilities added'
                        : '${roomDevices.length} ${roomDevices.length == 1 ? 'utility' : 'utilities'} · $onlineCount online',
                    style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ]),
              ),
              // Utility icon previews
              if (roomDevices.any((d) => (d as Map?)?['utility'] == 'lights'))
                _utilityDot(Icons.lightbulb_outline, const Color(0xFFE8922A)),
              if (roomDevices.any((d) => (d as Map?)?['utility'] == 'outlets'))
                Padding(padding: const EdgeInsets.only(left: 5),
                    child: _utilityDot(Icons.electrical_services, AppColors.greenMid)),
              if (roomDevices.any((d) => (d as Map?)?['utility'] == 'ac'))
                Padding(padding: const EdgeInsets.only(left: 5),
                    child: _utilityDot(Icons.ac_unit, const Color(0xFF2196F3))),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: AppColors.textMuted, size: 20),
            ]),
          ),
        ),
        // Admin delete button
        if (isAdmin) ...[
          Divider(height: 1, color: AppColors.greenMid.withAlpha(20)),
          TextButton.icon(
            onPressed: () => _deleteRoom(room),
            icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.error),
            label: const Text('Delete Room',
                style: TextStyle(fontSize: 12, color: AppColors.error)),
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
          ),
        ],
      ]),
    );
  }

  Widget _utilityDot(IconData icon, Color color) {
    return Container(
      width: 28, height: 28,
      decoration: BoxDecoration(
          color: color.withAlpha(26),
          borderRadius: BorderRadius.circular(8)),
      child: Icon(icon, size: 14, color: color),
    );
  }

  // ── Utilities inside a room ──────────────────────────────────
  Widget _buildUtilitiesInRoom(String room) {
    final roomDevices = _devices.entries
        .where((e) => (e.value as Map?)?['room'] == room)
        .toList();

    if (roomDevices.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.power_off_outlined, size: 48, color: AppColors.textMuted),
          const SizedBox(height: 12),
          const Text('No utilities yet',
              style: TextStyle(fontFamily: 'Outfit', fontSize: 15,
                  fontWeight: FontWeight.w600, color: AppColors.textDark)),
          const SizedBox(height: 6),
          Text(
            isAdmin ? 'Tap + Add Utility to add one'
                : 'No utilities have been added yet',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ]),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(room, style: const TextStyle(fontFamily: 'Outfit', fontSize: 15,
            fontWeight: FontWeight.w600, color: AppColors.textDark)),
        const SizedBox(height: 4),
        Text('${roomDevices.length} ${roomDevices.length == 1 ? 'utility' : 'utilities'}',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
        const SizedBox(height: 16),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 0.95,
          children: roomDevices.map((entry) =>
              _buildDeviceTile(entry.key,
                  Map<String, dynamic>.from(entry.value))).toList(),
        ),
      ]),
    );
  }

  Widget _buildDeviceTile(String deviceId, Map<String, dynamic> device) {
    final utility  = device['utility'] as String? ?? 'unknown';
    final status   = device['status']  as String? ?? 'offline';
    final relay    = device['relay']   as bool?   ?? false;
    final isOnline = status == 'online';
    final icon     = _utilityIcon(utility);
    final color    = _utilityColor(utility);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
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
            width: 38, height: 38,
            decoration: BoxDecoration(
                color: isOnline ? color.withAlpha(31) : AppColors.offline.withAlpha(26),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 20,
                color: isOnline ? color : AppColors.offline),
          ),
          const Spacer(),
          Container(width: 8, height: 8,
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: isOnline ? AppColors.success : AppColors.offline)),
        ]),
        const SizedBox(height: 8),
        Text(_utilityLabel(utility),
            style: const TextStyle(fontFamily: 'Outfit', fontSize: 13,
                fontWeight: FontWeight.w600, color: AppColors.textDark)),
        Text(deviceId,
            style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
            overflow: TextOverflow.ellipsis),
        Text(isOnline ? (relay ? 'ON' : 'OFF') : 'Offline',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                color: isOnline
                    ? (relay ? AppColors.success : AppColors.textMuted)
                    : AppColors.offline)),
        // Tap to view + admin delete
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: GestureDetector(
              onTap: () => Navigator.pushNamed(context, '/device', arguments: {
                'deviceId': deviceId,
                'utility':  utility,
                'building': widget.buildingCode,
                'floor':    _selectedFloor,
                'role':     widget.role,
              }),
              child: Container(
                height: 30,
                decoration: BoxDecoration(
                    color: AppColors.greenPale,
                    borderRadius: BorderRadius.circular(8)),
                child: const Center(
                  child: Text('View',
                      style: TextStyle(fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.greenDark)),
                ),
              ),
            ),
          ),
          if (isAdmin) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => _deleteDevice(deviceId, utility),
              child: Container(
                width: 30, height: 30,
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

  // ── Helpers ──────────────────────────────────────────────────
  IconData _utilityIcon(String u) {
    switch (u) {
      case 'lights':  return Icons.lightbulb_outline;
      case 'outlets': return Icons.electrical_services;
      case 'ac':      return Icons.ac_unit;
      default:        return Icons.device_unknown_outlined;
    }
  }

  Color _utilityColor(String u) {
    switch (u) {
      case 'lights':  return const Color(0xFFE8922A);
      case 'outlets': return AppColors.greenMid;
      case 'ac':      return const Color(0xFF2196F3);
      default:        return AppColors.textMuted;
    }
  }

  String _utilityLabel(String u) {
    switch (u) {
      case 'lights':  return 'Lights';
      case 'outlets': return 'Outlets';
      case 'ac':      return 'AC Unit';
      default:        return 'Device';
    }
  }
}