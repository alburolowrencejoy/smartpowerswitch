import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/responsive_center.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';

/// Self-contained "device grid for one room" widget, extracted out of
/// `BuildingFloorScreen` so it can be dropped into both:
///  - `BuildingFloorScreen`'s existing in-place room-detail swap
///    (main-admin standalone path, `showBackButton: true`), and
///  - the new `RoomDevicesScreen` (institute-admin path, pushed as its own
///    route with no floor tabs).
///
/// Deliberately owns its own Firebase subscriptions (floor devices +
/// master_devices) rather than receiving a live device map as a prop --
/// that's what makes it genuinely reusable/testable instead of depending on
/// a parent to plumb live data down to it.
class RoomDevicesPanel extends StatefulWidget {
  final String buildingCode;
  final String buildingName;
  final int floor;
  final String room;
  final String role;

  const RoomDevicesPanel({
    super.key,
    required this.buildingCode,
    required this.buildingName,
    required this.floor,
    required this.room,
    required this.role,
  });

  @override
  State<RoomDevicesPanel> createState() => _RoomDevicesPanelState();
}

class _RoomDevicesPanelState extends State<RoomDevicesPanel> {
  InstitutePalette get _palette => InstituteColors.forCode(widget.buildingCode);

  bool get isAdmin =>
      widget.role == 'admin' ||
      widget.role == 'main_admin' ||
      widget.role == 'super_admin' ||
      widget.role == 'institute_admin';

  // Full floor device map (all rooms on this floor), same shape as
  // BuildingFloorScreen._devices -- kept unfiltered-by-room so the
  // "already added to this floor" duplicate-ID check in _addUtility below
  // matches BuildingFloorScreen's original behavior exactly. The device
  // grid itself filters this locally by widget.room.
  Map<String, dynamic> _devices = {};
  bool _devicesLoading = true;

  // Count of devices in master_devices assigned to this building
  // (assignedTo starting with "$buildingCode/"), reproducing the
  // 24-device-per-building cap check that used to live in
  // BuildingFloorScreen._addUtility.
  int _buildingAssignedCount = 0;

  StreamSubscription<DatabaseEvent>? _devicesSub;
  StreamSubscription<DatabaseEvent>? _masterSub;

  @override
  void initState() {
    super.initState();
    _listenDevices();
    _listenMasterDevices();
  }

  @override
  void dispose() {
    _devicesSub?.cancel();
    _masterSub?.cancel();
    super.dispose();
  }

  bool _isPermissionDenied(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') ||
        text.contains('permission_denied');
  }

  void _listenDevices() {
    _devicesSub = FirebaseDatabase.instance
        .ref('buildings/${widget.buildingCode}/floorData/${widget.floor}/devices')
        .onValue
        .listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;
      if (raw is Map) {
        final devices = <String, dynamic>{};
        raw.forEach((k, v) {
          if (v is Map) {
            final device = <String, dynamic>{};
            v.forEach((dk, dv) => device[dk.toString()] = dv);
            devices[k.toString()] = device;
          }
        });
        setState(() {
          _devices = devices;
          _devicesLoading = false;
        });
      } else {
        setState(() {
          _devices = {};
          _devicesLoading = false;
        });
      }
    }, onError: (Object error) {
      if (!mounted) return;
      setState(() => _devicesLoading = false);
      if (_isPermissionDenied(error)) return;
      TopToast.error(context, 'Lost connection to live device data.');
    });
  }

  void _listenMasterDevices() {
    _masterSub =
        FirebaseDatabase.instance.ref('master_devices').onValue.listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;
      int count = 0;
      if (raw is Map) {
        raw.forEach((id, val) {
          if (val is! Map) return;
          final assignedTo = (val['assignedTo'] ?? '').toString();
          if (assignedTo.startsWith('${widget.buildingCode}/')) count++;
        });
      }
      setState(() => _buildingAssignedCount = count);
    }, onError: (Object error) {
      // Permission-denied here just means the 24-device cap check falls
      // back to "not at cap" rather than blocking Add Utility outright --
      // matches the tolerant handling of permission errors elsewhere in
      // this file's Firebase listeners.
    });
  }

  // ── Room-local filter. Deliberately re-derived here rather than reusing
  // BuildingFloorScreen._roomDeviceEntries, which stays in that file for
  // its own room-list/room-switch use (see building_floor_screen.dart).
  List<MapEntry<String, Map<String, dynamic>>> _roomDeviceEntries() {
    final roomDevices = <MapEntry<String, Map<String, dynamic>>>[];
    _devices.forEach((id, d) {
      if (d is Map && d['room']?.toString().trim() == widget.room.trim()) {
        roomDevices.add(MapEntry(id, Map<String, dynamic>.from(d)));
      }
    });
    return roomDevices;
  }

  // ── Add utility ────────────────────────────────────────────────────
  Future<void> _addUtility() async {
    if (_buildingAssignedCount >= 24) {
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
                    borderSide: BorderSide(color: _palette.mid)),
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
                  backgroundColor: _palette.dark,
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
            'buildings/${widget.buildingCode}/floorData/${widget.floor}/devices/$deviceId')
        .set({
      'utility': utility,
      'status': 'offline',
      'relay': false,
      'room': widget.room,
    });

    // Save to flat devices node
    await FirebaseDatabase.instance.ref('devices/$deviceId').update({
      'building': widget.buildingCode,
      'floor': '${widget.floor}',
      'room': widget.room,
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
        .set('${widget.buildingCode}/${widget.floor}/${widget.room}');

    if (!mounted) return;
    TopToast.success(context, '$deviceId added as $utility in ${widget.room}.');
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

  // ── Delete device ─────────────────────────────────────────────────
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

  // Deliberately duplicated from BuildingFloorScreen._unassignDevice (used
  // there by _deleteRoom's cascading delete, which stays in that file).
  // Kept as an exact ~10-line duplicate rather than hoisted to a shared
  // helper -- if you touch this, update the copy in
  // building_floor_screen.dart too so the two don't drift.
  Future<void> _unassignDevice(String deviceId) async {
    await FirebaseDatabase.instance
        .ref(
            'buildings/${widget.buildingCode}/floorData/${widget.floor}/devices/$deviceId')
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

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned.fill(child: _buildBody()),
      if (isAdmin)
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.extended(
            onPressed: _addUtility,
            backgroundColor: _palette.dark,
            icon: const Icon(Icons.add, color: Colors.white),
            label: const Text('Add Utility',
                style: TextStyle(
                    color: Colors.white,
                    fontFamily: 'Outfit',
                    fontWeight: FontWeight.w600)),
          ),
        ),
    ]);
  }

  Widget _buildBody() {
    final roomDevices = _roomDeviceEntries();

    if (roomDevices.isEmpty) {
      return ScreenSkeleton(
        isLoading: _devicesLoading,
        child: Center(
          child:
              Column(mainAxisAlignment: MainAxisAlignment.center, children: [
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
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.room,
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
        LayoutBuilder(
          builder: (context, constraints) {
            final crossAxisCount = responsiveColumnCount(
              constraints.maxWidth,
              mobileColumns: 2,
              idealTileWidth: 190,
              maxColumns: 4,
            );
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.10,
              ),
              itemCount: roomDevices.length,
              itemBuilder: (context, index) {
                final entry = roomDevices[index];
                return _buildDeviceTile(entry.key, entry.value);
              },
            );
          },
        ),
      ]),
    );
  }

  Widget _buildDeviceTile(String deviceId, Map<String, dynamic> device) {
    final utility = device['utility'] as String? ?? 'unknown';
    final status = device['status'] as String? ?? 'offline';
    final relay = device['relay'] as bool? ?? false;
    final isOnline = status == 'online';
    final isActive = relay;
    final color = _utilityColor(utility);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive ? color.withAlpha(102) : _palette.mid.withAlpha(26),
          width: isActive ? 1.5 : 1,
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
              isOn: isActive,
              isOnline: isOnline,
            ),
          ),
          const Spacer(),
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive ? AppColors.success : AppColors.offline)),
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
        Text(isActive ? 'ON' : 'OFF',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isActive ? AppColors.success : AppColors.offline)),
        const Spacer(),
        Row(children: [
          Expanded(
            child: GestureDetector(
              onTap: () => Navigator.pushNamed(context, '/device', arguments: {
                'deviceId': deviceId,
                'utility': utility,
                'building': widget.buildingCode,
                'room': widget.room,
                'floor': widget.floor,
                'role': widget.role,
              }),
              child: Container(
                height: 28,
                decoration: BoxDecoration(
                    color: _palette.pale,
                    borderRadius: BorderRadius.circular(8)),
                child: Center(
                  child: Text('View',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _palette.dark)),
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

class _AnimatedUtilityIcon extends StatelessWidget {
  final String utility;
  final bool isOn;
  final bool isOnline;

  const _AnimatedUtilityIcon({
    required this.utility,
    required this.isOn,
    required this.isOnline,
  });

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

  @override
  Widget build(BuildContext context) {
    final icon = _iconForUtility(utility);
    final isActiveHighlight = isOn;
    const highlight = Color(0xFFF2C94C);

    final fill =
        isActiveHighlight ? highlight.withAlpha(28) : Colors.grey.withAlpha(14);
    final iconColor =
        isActiveHighlight ? highlight : AppColors.textMuted.withAlpha(180);
    final glow =
        isActiveHighlight ? highlight.withAlpha(60) : Colors.transparent;

    return Container(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(10),
        boxShadow: glow == Colors.transparent
            ? null
            : [BoxShadow(color: glow, blurRadius: 12, spreadRadius: 1)],
      ),
      child: Icon(icon, size: 18, color: iconColor),
    );
  }
}
