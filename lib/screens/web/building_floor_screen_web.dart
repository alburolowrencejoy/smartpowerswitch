import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../utils/placeholder_data.dart';
import '../../widgets/responsive_center.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import 'web_theme.dart';
import 'web_widgets.dart';

/// The desktop "Building Floor" page: the same rooms/floors/devices, admin
/// actions (add/edit/delete room, add/remove device, room-wide relay
/// toggle) as [BuildingFloorScreen], laid out as a card grid instead of a
/// single stacked mobile column. Independent Firebase listeners from the
/// mobile screen, so [BuildingFloorScreen] itself is never touched.
class BuildingFloorScreenWeb extends StatefulWidget {
  final String buildingCode;
  final String buildingName;
  final int floors;
  final String role;

  /// False when this screen is embedded directly as an institute admin's
  /// dashboard tab (not pushed as its own route) — hides the back button so
  /// a stray click can't pop the whole dashboard shell.
  final bool showBackButton;

  /// When non-null, called instead of `Navigator.pop(context)` when the
  /// back button is pressed while no room is selected -- lets the desktop
  /// dashboard shell swap this screen out in-place instead of popping a
  /// full-screen route. Only used when [showBackButton] is true.
  final VoidCallback? onBack;

  /// When non-null, called instead of `Navigator.pushNamed(context,
  /// '/device', ...)` when a device tile's "View" is tapped -- lets the
  /// desktop dashboard shell show the device in-place instead of pushing a
  /// full-screen route that would hide its side nav.
  final void Function(String deviceId, String utility, String building,
      String room, int floor)? onDeviceTap;

  /// False when this screen is embedded under the institute admin's own
  /// dashboard tab, directly below `_InstituteSummaryCard` -- that card
  /// already surfaces energy/cost/online/assigned totals for the institute,
  /// so this screen's own 4-card energy/cost/online/devices row would just
  /// repeat it.
  final bool showDashboardSummary;

  /// False when this screen is embedded under the institute admin's own
  /// dashboard tab -- the Admin/Faculty role badge is shown once, inside
  /// `_InstituteSummaryCard`'s header, instead of being repeated here.
  final bool showRoleBadge;

  /// When embedded under the institute admin's dashboard tab, the parent's
  /// `_InstituteSummaryCard` widget, rendered as part of this screen's own
  /// `SingleChildScrollView` content -- directly above the floor tabs, same
  /// spot [showDashboardSummary]'s internal 4-card row would occupy.
  /// Putting it inside this screen's own scrollable (rather than the parent
  /// stacking it as a fixed sibling above an `Expanded` copy of this
  /// screen) is what makes it scroll away together with the rooms grid
  /// instead of staying pinned/cut off above it. Hidden automatically once
  /// a room is selected, mirroring mobile's behavior of pushing a
  /// full-screen `RoomDevicesScreen` that naturally covers the card.
  final Widget? embeddedSummaryCard;

  const BuildingFloorScreenWeb({
    super.key,
    required this.buildingCode,
    required this.buildingName,
    required this.floors,
    required this.role,
    this.showBackButton = true,
    this.onBack,
    this.onDeviceTap,
    this.showDashboardSummary = true,
    this.showRoleBadge = true,
    this.embeddedSummaryCard,
  });

  @override
  State<BuildingFloorScreenWeb> createState() => _BuildingFloorScreenWebState();
}

class _BuildingFloorScreenWebState extends State<BuildingFloorScreenWeb> {
  int _selectedFloor = 1;
  String? _selectedRoom;
  String? _roomTogglingRoom;

  /// The only place `_selectedRoom` should be assigned (besides the reset in
  /// `_switchFloor`, which always sets it to null).
  void _setSelectedRoom(String? room) {
    setState(() => _selectedRoom = room);
  }

  /// Bug fix: this used to branch on a super-admin role check (`_isSuperAdmin
  /// ? InstituteColors.admin : InstituteColors.forCode(widget.buildingCode)`,
  /// now removed since it was otherwise unused), forcing a super admin's
  /// view of this screen to always be green -- so the same institute
  /// building looked correctly institute-colored on mobile (whose
  /// `building_floor_screen.dart` has always resolved unconditionally off
  /// `widget.buildingCode`, no role branch) but silently reverted to green
  /// here for that exact same viewer/building pair on desktop. This screen
  /// already knows its exact building code, so there's no role ambiguity
  /// left to resolve -- keying off the code alone matches mobile and always
  /// shows the building being viewed in its own color, regardless of who's
  /// viewing it.
  InstitutePalette get _palette => InstituteColors.forCode(widget.buildingCode);

  final Map<int, List<String>> _rooms = {};
  Map<String, dynamic> _devices = {};

  double _buildingKwh = 0;
  int _buildingOnline = 0;
  bool _hasMonthlyBuildingEnergy = false;
  int _instituteTotalDevices = 0;
  int _totalAssigned = 0;

  /// True until the combined Firebase stream's first emission for the
  /// currently-selected floor. Never reverts to true afterwards except when
  /// switching floors (a legitimate fresh load for that floor's data).
  bool _isLoading = true;
  String? _errorText;
  bool _hasLoadedOnce = false;

  static const Duration _loadTimeout = Duration(seconds: 15);
  Timer? _timeoutTimer;

  final List<StreamSubscription<DatabaseEvent>> _roomSubs = [];
  StreamSubscription? _combinedSub;
  Map<String, dynamic> _liveDevices = {};

  bool get isAdmin =>
      widget.role == 'admin' ||
      widget.role == 'main_admin' ||
      widget.role == 'super_admin' ||
      widget.role == 'institute_admin';

  bool _isPermissionDenied(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') ||
        text.contains('permission_denied');
  }

  List<MapEntry<String, Map<String, dynamic>>> _roomDeviceEntries(String room) {
    final roomDevices = <MapEntry<String, Map<String, dynamic>>>[];
    _devices.forEach((id, d) {
      if (d is Map && d['room']?.toString().trim() == room.trim()) {
        roomDevices.add(MapEntry(id, Map<String, dynamic>.from(d)));
      }
    });
    return roomDevices;
  }

  bool _roomRelayIsOn(String room) {
    final roomDevices = _roomDeviceEntries(room);
    if (roomDevices.isEmpty) return false;
    return roomDevices.every((entry) => entry.value['relay'] == true);
  }

  Future<void> _setRoomRelays(String room, bool turnOn) async {
    if (_roomTogglingRoom != null) return;

    final roomDevices = _roomDeviceEntries(room);
    if (roomDevices.isEmpty) {
      TopToast.error(context, 'No utilities found in this room.');
      return;
    }

    setState(() => _roomTogglingRoom = room);

    try {
      final db = FirebaseDatabase.instance.ref();
      final writes = <Future<void>>[];

      for (final entry in roomDevices) {
        final deviceId = entry.key;
        writes.add(db.child('devices/$deviceId/relay').set(turnOn));
        writes.add(db
            .child(
                'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices/$deviceId/relay')
            .set(turnOn));
      }

      await Future.wait(writes);

      if (mounted) {
        TopToast.success(
          context,
          '${turnOn ? 'Turned on' : 'Turned off'} all utilities in $room.',
        );
      }
    } catch (e) {
      if (mounted) {
        TopToast.error(context, 'Room switch failed: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _roomTogglingRoom = null);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _loadRooms();
    _listenAll();
  }

  @override
  void dispose() {
    for (final sub in _roomSubs) {
      sub.cancel();
    }
    _roomSubs.clear();
    _timeoutTimer?.cancel();
    _combinedSub?.cancel();
    super.dispose();
  }

  /// Clears the error state, resets the loading flag, and re-attaches the
  /// combined listener from scratch for the currently-selected floor.
  void _retry() {
    setState(() {
      _errorText = null;
      _isLoading = true;
    });
    _timeoutTimer?.cancel();
    _combinedSub?.cancel();
    _listenAll();
  }

  // ── Data (ported from BuildingFloorScreen, unchanged behavior) ───────────

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

  /// Combines the screen's 4 distinct Firebase paths (this floor's devices,
  /// master_devices, the shared `devices` node used for both live energy
  /// and online/offline counts, and this month's building history kwh) into
  /// one subscription, with a sticky merge so a transient null/empty
  /// snapshot never blanks data that already loaded once. Re-created on
  /// floor switches since the floor-devices path depends on
  /// [_selectedFloor].
  void _listenAll() {
    _combinedSub?.cancel();
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(_loadTimeout, () {
      if (!mounted || _hasLoadedOnce) return;
      setState(() {
        _isLoading = false;
        _errorText =
            'Loading is taking too long. Check your connection and try again.';
      });
    });

    final monthKey = _monthKey(DateTime.now());
    _combinedSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance
          .ref(
              'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices')
          .onValue,
      FirebaseDatabase.instance.ref('master_devices').onValue,
      FirebaseDatabase.instance.ref('devices').onValue,
      FirebaseDatabase.instance
          .ref('history/monthly/$monthKey/buildings/${widget.buildingCode}/kwh')
          .onValue,
    ]).listen((events) {
      if (!mounted) return;
      _applyFloorDevices(events[0].snapshot.value);
      _applyMasterDevices(events[1].snapshot.value);
      _applyHistoryKwh(events[3].snapshot.value);
      _applyDevicesSnapshot(events[2].snapshot.value);

      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      setState(() {
        _hasLoadedOnce = true;
        _isLoading = false;
        _errorText = null;
      });
    }, onError: (Object error) {
      if (!mounted) return;
      if (_isPermissionDenied(error)) {
        if (!_hasLoadedOnce) {
          _timeoutTimer?.cancel();
          _timeoutTimer = null;
          setState(() {
            _isLoading = false;
            _errorText = 'You do not have permission to view this building.';
          });
        }
        return;
      }
      if (!_hasLoadedOnce) {
        _timeoutTimer?.cancel();
        _timeoutTimer = null;
        setState(() {
          _isLoading = false;
          _errorText = 'Failed to load building data.';
        });
      }
    });
  }

  void _applyFloorDevices(Object? raw) {
    if (raw is Map) {
      final devices = <String, dynamic>{};
      raw.forEach((k, v) {
        if (v is Map) {
          final device = <String, dynamic>{};
          v.forEach((dk, dv) => device[dk.toString()] = dv);
          devices[k.toString()] = device;
        }
      });
      _devices = devices;
    } else if (_isLoading) {
      _devices = {};
    }
  }

  void _applyMasterDevices(Object? raw) {
    if (raw is Map) {
      int buildingCount = 0;
      int totalAssigned = 0;
      raw.forEach((id, val) {
        if (val is! Map) return;
        final assignedTo = (val['assignedTo'] ?? '').toString();
        if (assignedTo.isNotEmpty) {
          totalAssigned++;
          final parts = assignedTo.split('/');
          if (parts.isNotEmpty && parts[0] == widget.buildingCode) {
            buildingCount++;
          }
        }
      });
      _instituteTotalDevices = buildingCount;
      _totalAssigned = totalAssigned;
    } else if (_isLoading) {
      _instituteTotalDevices = 0;
      _totalAssigned = 0;
    }
  }

  void _applyHistoryKwh(Object? raw) {
    if (raw is num) {
      _hasMonthlyBuildingEnergy = true;
      _buildingKwh = raw.toDouble();
    } else {
      // Absence of a monthly total is a legitimate ongoing state (falls
      // back to the live device kwh sum below), not a loading regression.
      _hasMonthlyBuildingEnergy = false;
    }
  }

  /// Shared `devices` snapshot used for both the live energy sum (feeding
  /// [_buildingKwh] when no monthly total exists yet) and the online count.
  void _applyDevicesSnapshot(Object? raw) {
    if (raw is Map) {
      final liveDevices = <String, dynamic>{};
      double kwh = 0;
      int online = 0;
      raw.forEach((id, val) {
        if (val is! Map) return;
        final device = Map<String, dynamic>.from(val);
        liveDevices[id.toString()] = device;

        final building = (device['building'] ?? '').toString();
        if (building != widget.buildingCode) return;
        kwh += ((device['kwh'] ?? 0.0) as num).toDouble();

        final lastSeen = device['last_seen'];
        if (lastSeen != null && lastSeen != 0) {
          final dt = DateTime.fromMillisecondsSinceEpoch(lastSeen as int);
          if (DateTime.now().difference(dt).inMinutes < 2) online++;
        }
      });

      _liveDevices = liveDevices;
      if (!_hasMonthlyBuildingEnergy) {
        _buildingKwh = kwh;
      }
      _buildingOnline = online;
    } else if (_isLoading) {
      _liveDevices = {};
      if (!_hasMonthlyBuildingEnergy) {
        _buildingKwh = 0;
      }
      _buildingOnline = 0;
    }
  }

  void _switchFloor(int floor) {
    setState(() {
      _selectedFloor = floor;
      _selectedRoom = null;
      _devices = {};
      _isLoading = true;
      _hasLoadedOnce = false;
      _errorText = null;
    });
    _listenAll();
  }

  double _roomKwh(String room) {
    double total = 0;
    _liveDevices.forEach((_, val) {
      if (val is! Map) return;
      final device = Map<String, dynamic>.from(val);
      final deviceBuilding = (device['building'] ?? '').toString();
      final deviceRoom = device['room']?.toString().trim() ?? '';

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

  DatabaseReference get _roomsRef => FirebaseDatabase.instance
      .ref('buildings/${widget.buildingCode}/floorData/$_selectedFloor/rooms');

  Future<void> _writeRooms(List<String> rooms) => _roomsRef.set(
      rooms.isEmpty ? {} : {for (int i = 0; i < rooms.length; i++) '$i': rooms[i]});

  /// Error for a room name on the current floor, or null when it's valid.
  String? _roomNameError(String name, {String? except}) {
    if (name.isEmpty) return 'Room name is required.';
    final taken = (_rooms[_selectedFloor] ?? []).any((r) =>
        r != except && r.trim().toLowerCase() == name.toLowerCase());
    return taken ? 'A room with that name exists on this floor.' : null;
  }

  Future<void> _addRoom() async {
    String? added;
    await showWebFormDialog(
      context: context,
      title: 'Add room',
      subtitle: 'Floor $_selectedFloor',
      okLabel: 'Add',
      fields: const [
        WebField(id: 'name', label: 'Room name', hint: 'e.g. Room 2, Lab 1, Office'),
      ],
      onSubmit: (v) async {
        final name = v['name']!;
        final err = _roomNameError(name);
        if (err != null) return {'name': err};
        await _writeRooms([...(_rooms[_selectedFloor] ?? []), name]);
        added = name;
        return null;
      },
    );
    if (added != null && mounted) TopToast.success(context, '"$added" added.');
  }

  Future<void> _editRoom(String oldRoom) async {
    String? renamed;
    await showWebFormDialog(
      context: context,
      title: 'Rename room',
      subtitle: 'Floor $_selectedFloor',
      fields: [WebField(id: 'name', label: 'Room name', initial: oldRoom)],
      onSubmit: (v) async {
        final result = v['name']!;
        if (result == oldRoom) return null;
        final err = _roomNameError(result, except: oldRoom);
        if (err != null) return {'name': err};

        final current = _rooms[_selectedFloor] ?? [];
        await _writeRooms(
            current.map((r) => r == oldRoom ? result : r).toList());

        final snap = await FirebaseDatabase.instance
            .ref(
                'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices')
            .get();
        if (snap.value is Map) {
          final updates = <String, dynamic>{};
          (snap.value as Map).forEach((id, val) {
            if (val is Map && val['room'] == oldRoom) {
              updates['buildings/${widget.buildingCode}/floorData/'
                  '$_selectedFloor/devices/$id/room'] = result;
              updates['devices/$id/room'] = result;
            }
          });
          if (updates.isNotEmpty) {
            await FirebaseDatabase.instance.ref().update(updates);
          }
        }
        renamed = result;
        return null;
      },
    );
    if (renamed != null && mounted) {
      TopToast.success(context, '"$oldRoom" renamed to "$renamed".');
    }
  }

  Future<void> _deleteRoom(String room) async {
    final n = _roomDeviceEntries(room).length;
    final ok = await showWebConfirmDialog(
      context: context,
      title: 'Delete room?',
      message: n > 0
          ? '$room and its $n device${n == 1 ? '' : 's'} will be unassigned.'
          : '$room will be removed.',
      onConfirm: () async {
        final snap = await FirebaseDatabase.instance
            .ref(
                'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices')
            .get();
        if (snap.value is Map) {
          for (final entry in (snap.value as Map).entries) {
            final val = entry.value;
            if (val is Map && val['room'] == room) {
              await _unassignDevice(entry.key.toString());
            }
          }
        }
        final current = List<String>.from(_rooms[_selectedFloor] ?? [])
          ..remove(room);
        await _writeRooms(current);
      },
    );
    if (!ok || !mounted) return;
    if (_selectedRoom == room) _setSelectedRoom(null);
    TopToast.success(context, '"$room" deleted.');
  }

  static const _utilityOptions = ['Lights', 'Outlets', 'AC'];

  Future<void> _addUtility(String room) async {
    if (_totalAssigned >= 24) {
      TopToast.threshold(context, 'Device limit reached (24 max).');
      return;
    }
    String? addedId;
    String? addedUtility;
    await showWebFormDialog(
      context: context,
      title: 'Add device',
      subtitle: '$room · Floor $_selectedFloor. '
          'Type the Device ID from the sticker on the ESP32.',
      okLabel: 'Add',
      fields: const [
        WebField(
            id: 'id', label: 'Device ID', hint: 'e.g. DEV-2024-A3F7', uppercase: true),
        WebField(
            id: 'utility',
            label: 'Utility type',
            options: _utilityOptions,
            initial: 'Lights'),
      ],
      onSubmit: (v) async {
        final id = v['id']!.toUpperCase();
        final utility = v['utility']!;
        if (id.isEmpty) return {'id': 'Device ID is required.'};
        if (_devices.containsKey(id)) {
          return {'id': 'That device is already on this floor.'};
        }
        final snap =
            await FirebaseDatabase.instance.ref('master_devices/$id').get();
        if (!snap.exists) return {'id': 'Device ID not found in the system.'};
        final assigned = (snap.value as Map?)?['assignedTo'] as String?;
        if (assigned != null && assigned.isNotEmpty) {
          return {'id': 'Already assigned to $assigned.'};
        }

        await FirebaseDatabase.instance
            .ref(
                'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices/$id')
            .set({
          'utility': utility,
          'status': 'offline',
          'relay': false,
          'room': room,
        });
        await FirebaseDatabase.instance.ref('devices/$id').update({
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
        await FirebaseDatabase.instance
            .ref('master_devices/$id/assignedTo')
            .set('${widget.buildingCode}/$_selectedFloor/$room');
        addedId = id;
        addedUtility = utility;
        return null;
      },
    );
    if (addedId != null && mounted) {
      TopToast.success(context, '$addedId added as $addedUtility in $room.');
    }
  }

  /// Changes a device's utility type (Lights / Outlets / AC).
  Future<void> _editDevice(String deviceId, String utility) async {
    final current = _utilityOptions.firstWhere(
        (o) => o.toLowerCase() == utility.toLowerCase(),
        orElse: () => _utilityOptions.first);
    final ok = await showWebFormDialog(
      context: context,
      title: 'Edit device',
      subtitle: deviceId,
      fields: [
        WebField(
            id: 'utility',
            label: 'Utility type',
            options: _utilityOptions,
            initial: current),
      ],
      onSubmit: (v) async {
        final next = v['utility']!;
        if (next == current) return null;
        await FirebaseDatabase.instance.ref().update({
          'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices/$deviceId/utility':
              next,
          'devices/$deviceId/utility': next,
        });
        return null;
      },
    );
    if (ok && mounted) TopToast.success(context, '$deviceId updated.');
  }

  Future<void> _deleteDevice(String deviceId, String utility) async {
    final ok = await showWebConfirmDialog(
      context: context,
      title: 'Remove device?',
      message: '${_utilityLabel(utility)} ($deviceId) will be unassigned and '
          'available for reuse.',
      okLabel: 'Remove',
      onConfirm: () => _unassignDevice(deviceId),
    );
    if (ok && mounted) TopToast.success(context, '$deviceId removed.');
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

  // ── Build (desktop grid layout) ───────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ScreenSkeleton(
      isLoading: _isLoading,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: ResponsiveCenter(
          maxWidth: 1400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Skipped entirely at the rooms-list step when embedded
              // (showBackButton: false) -- the parent dashboard already
              // shows an equivalent institute-scoped summary card just
              // above this screen there, so this header's title (bare
              // building name/code) would be pure duplication. Still shown
              // once a room is selected even when embedded, since that's
              // the only back-navigation affordance back to the rooms grid
              // (mobile's equivalent case pushes a full-screen
              // RoomDevicesScreen with its own back button instead; this
              // desktop shell swaps the room view in-place, so it needs
              // this row's back arrow).
              if (widget.showBackButton || _selectedRoom != null) ...[
                _buildHeader(),
                const SizedBox(height: 20),
              ],
              if (_errorText != null)
                _buildLoadError()
              else ...[
                if (widget.embeddedSummaryCard != null) ...[
                  if (_selectedRoom == null) ...[
                    widget.embeddedSummaryCard!,
                    const SizedBox(height: 20),
                  ],
                ] else if (widget.showDashboardSummary) ...[
                  _buildDashboardRow(),
                  const SizedBox(height: 20),
                ],
                _buildFloorTabs(),
                const SizedBox(height: 20),
                _selectedRoom == null
                    ? _buildRoomsGrid()
                    : _buildUtilitiesInRoom(_selectedRoom!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadError() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 60),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_outlined,
              size: 48, color: WebColors.muted),
          const SizedBox(height: 12),
          const Text('Cannot load this building',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark)),
          const SizedBox(height: 6),
          Text(_errorText ?? 'Something went wrong.',
              style: const TextStyle(fontSize: 13, color: WebColors.muted)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh, color: Colors.white, size: 18),
            label: const Text('Retry', style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
                backgroundColor: _palette.dark,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
          ),
        ]),
      ),
    );
  }

  Widget _buildHeader() {
    // Right padding reserves space for the fixed notification bell the
    // dashboard shell floats over the top-right corner, so "Admin"/"Add
    // Room" never sit underneath it.
    return Padding(
      padding: const EdgeInsets.only(right: 64),
      child: Row(
        children: [
          if (widget.showBackButton || _selectedRoom != null) ...[
            Material(
              color: AppColors.cardBg,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () {
                  if (_selectedRoom != null) {
                    _setSelectedRoom(null);
                  } else if (widget.onBack != null) {
                    widget.onBack!();
                  } else {
                    Navigator.pop(context);
                  }
                },
                child: const Padding(
                  padding: EdgeInsets.all(10.0),
                  child: Icon(Icons.arrow_back,
                      size: 18, color: AppColors.textDark),
                ),
              ),
            ),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Text(
              _selectedRoom != null
                  ? '${widget.buildingName} · $_selectedRoom'
                  : widget.buildingName,
              style: const TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textDark),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.showRoleBadge)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                  color: _palette.pale,
                  borderRadius: BorderRadius.circular(20)),
              child: Text(isAdmin ? 'Admin' : 'Faculty',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _palette.dark)),
            ),
        ],
      ),
    );
  }

  /// The "Add Room" / "Add Utility" action -- lives level with the
  /// floor/room count row (`_buildRoomsGrid`/`_buildUtilitiesInRoom`)
  /// instead of the page header, and doubles as the call-to-action in
  /// those sections' empty states.
  Widget _addActionButton() {
    return WebIconButton(
      icon: _selectedRoom == null ? Icons.add_rounded : Icons.add_to_queue_rounded,
      tooltip: _selectedRoom == null ? 'Add room' : 'Add device',
      solid: true,
      size: 38,
      onPressed:
          _selectedRoom == null ? _addRoom : () => _addUtility(_selectedRoom!),
    );
  }

  Widget _buildDashboardRow() {
    final energyKwh = _currentEnergyKwh();
    final energyCost = energyKwh * 11.5;

    final cards = [
      _dashCard(_energyScopeLabel(), '${energyKwh.toStringAsFixed(1)} kWh',
          Icons.bolt),
      _dashCard('Cost', '₱ ${energyCost.toStringAsFixed(0)}',
          Icons.payments_outlined),
      _dashCard('Online', '$_buildingOnline online', Icons.wifi),
      if (isAdmin)
        _dashCard('Devices', '$_instituteTotalDevices assigned', Icons.devices),
    ];

    return IntrinsicHeight(
      child: Row(
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(width: 16),
            Expanded(child: cards[i]),
          ],
        ],
      ),
    );
  }

  Widget _dashCard(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_palette.dark, _palette.mid],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.white),
          const SizedBox(height: 12),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
          const SizedBox(height: 2),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: 12, color: Colors.white.withAlpha(200))),
        ],
      ),
    );
  }

  Widget _buildFloorTabs() {
    return Container(
      height: 48,
      decoration: BoxDecoration(
          color: _palette.pale, borderRadius: BorderRadius.circular(14)),
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
                    color: isSelected ? _palette.dark : Colors.transparent,
                    borderRadius: BorderRadius.circular(10)),
                child: Center(
                  child: Text('Floor $floor',
                      style: TextStyle(
                          fontFamily: 'Outfit',
                          fontSize: 14,
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

  Widget _buildRoomsGrid() {
    final rooms = _rooms[_selectedFloor] ?? [];
    final roomsLoading = rooms.isEmpty && _isLoading;
    final displayRooms =
        roomsLoading ? List.generate(4, (i) => 'Room ${i + 1}') : rooms;
    if (displayRooms.isEmpty) {
      return _emptyState(
        icon: Icons.meeting_room_outlined,
        title: 'No rooms yet',
        subtitle: isAdmin
            ? 'Click Add Room to get started'
            : 'No rooms have been added yet',
        action: isAdmin ? _addActionButton() : null,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                  'Floor $_selectedFloor · ${displayRooms.length} ${displayRooms.length == 1 ? 'room' : 'rooms'}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDark)),
            ),
            if (isAdmin) _addActionButton(),
          ],
        ),
        const SizedBox(height: 16),
        // Fixed at 3 columns intentionally -- rooms should never collapse to
        // fewer columns at narrow widths (product owner call). Unlike the
        // devices/utilities grid below, this one does not use
        // responsiveColumnCount.
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 1.35,
          ),
          itemCount: displayRooms.length,
          itemBuilder: (context, index) => _buildRoomCard(displayRooms[index]),
        ),
      ],
    );
  }

  Widget _buildRoomCard(String room) {
    final roomDevices = _roomDeviceEntries(room);
    final utilityCount = roomDevices.length;
    final onlineCount = roomDevices.where((entry) {
      final device = entry.value;
      return device['status'] == 'online';
    }).length;
    bool hasLights = false;
    bool hasOutlets = false;
    bool hasAc = false;

    for (final entry in roomDevices) {
      final device = entry.value;
      final u = (device['utility'] ?? '').toString().toLowerCase();
      if (u == 'lights') hasLights = true;
      if (u == 'outlets') hasOutlets = true;
      if (u == 'ac') hasAc = true;
    }

    final roomSwitchOn = _roomRelayIsOn(room);
    final roomSwitchBusy = _roomTogglingRoom == room;

    return Container(
      decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(18),
          // Bumped from a ~10%-alpha hairline to a full-opacity 1.5px border
          // (matching the weight the hero energy cards used before their own
          // revert): a hairline blends into an all-white page once the
          // institute-admin page background switches to AppColors.cardBg
          // (see dashboard_web.dart's Scaffold), where this card previously
          // relied on the colored `palette.pale` wash behind it for contrast.
          border: Border.all(color: _palette.mid, width: 1.5)),
      // The whole card (InkWell, Switch, TextButtons below) needs a single
      // Material ancestor to paint on -- transparency mode so it doesn't
      // cover the card's own background/border.
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: InkWell(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(18)),
                onTap: () => _setSelectedRoom(room),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                            color: _palette.pale,
                            borderRadius: BorderRadius.circular(12)),
                        child: Icon(Icons.meeting_room_outlined,
                            size: 22, color: _palette.dark),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(room,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontFamily: 'Outfit',
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textDark)),
                            const SizedBox(height: 4),
                            Text(
                              utilityCount == 0
                                  ? 'No utilities added'
                                  : '$utilityCount ${utilityCount == 1 ? 'utility' : 'utilities'} · $onlineCount online',
                              style: const TextStyle(
                                  fontSize: 13, color: WebColors.muted),
                            ),
                            const SizedBox(height: 8),
                            Wrap(spacing: 6, children: [
                              if (hasLights)
                                _utilityDot(Icons.lightbulb_outline,
                                    const Color(0xFFE8922A)),
                              if (hasOutlets)
                                _utilityDot(
                                    Icons.electrical_services, _palette.mid),
                              if (hasAc)
                                _utilityDot(
                                    Icons.ac_unit, const Color(0xFF2196F3)),
                            ]),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right,
                          color: WebColors.muted, size: 20),
                    ],
                  ),
                ),
              ),
            ),
            if (isAdmin) ...[
              Divider(height: 1, color: _palette.mid.withAlpha(20)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(children: [
                  if (utilityCount > 0) ...[
                    Expanded(
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Flexible(
                          child: Text('Room switch',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12, color: WebColors.muted)),
                        ),
                        const SizedBox(width: 6),
                        Switch.adaptive(
                          value: roomSwitchOn,
                          onChanged: roomSwitchBusy
                              ? null
                              : (value) => _setRoomRelays(room, value),
                          activeThumbColor: _palette.mid,
                        ),
                      ]),
                    ),
                  ] else
                    const Spacer(),
                  WebIconButton(
                    icon: Icons.add_to_queue_rounded,
                    tooltip: 'Add device',
                    size: 30,
                    onPressed: () => _addUtility(room),
                  ),
                  const SizedBox(width: 6),
                  WebIconButton(
                    icon: Icons.edit_outlined,
                    tooltip: 'Rename room',
                    size: 30,
                    onPressed: () => _editRoom(room),
                  ),
                  const SizedBox(width: 6),
                  WebIconButton(
                    icon: Icons.delete_outline_rounded,
                    tooltip: 'Delete room',
                    size: 30,
                    danger: true,
                    onPressed: () => _deleteRoom(room),
                  ),
                  const SizedBox(width: 4),
                ]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _utilityDot(IconData icon, Color color) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
          color: color.withAlpha(26), borderRadius: BorderRadius.circular(7)),
      child: Icon(icon, size: 13, color: color),
    );
  }

  Widget _buildUtilitiesInRoom(String room) {
    final roomDevices = <MapEntry<String, dynamic>>[];
    _devices.forEach((id, d) {
      if (d is Map && d['room']?.toString().trim() == room.trim()) {
        roomDevices.add(MapEntry(id, d));
      }
    });

    final devicesLoading = roomDevices.isEmpty && _isLoading;
    final displayRoomDevices = devicesLoading
        ? placeholderDeviceList(4)
            .asMap()
            .entries
            .map((e) =>
                MapEntry<String, dynamic>('placeholder-${e.key}', e.value))
            .toList()
        : roomDevices;

    if (displayRoomDevices.isEmpty) {
      return _emptyState(
        icon: Icons.power_off_outlined,
        title: 'No utilities yet',
        subtitle: isAdmin
            ? 'Click Add Utility to add one'
            : 'No utilities have been added yet',
        action: isAdmin ? _addActionButton() : null,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                  '$room · ${displayRoomDevices.length} ${displayRoomDevices.length == 1 ? 'utility' : 'utilities'}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDark)),
            ),
            if (isAdmin) _addActionButton(),
          ],
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final crossAxisCount = responsiveColumnCount(
              constraints.maxWidth,
              mobileColumns: 2,
              idealTileWidth: 220,
              maxColumns: 6,
            );
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                // Admin tiles carry an extra edit/delete row.
                childAspectRatio: isAdmin ? 0.9 : 1.05,
              ),
              itemCount: displayRoomDevices.length,
              itemBuilder: (context, index) {
                final entry = displayRoomDevices[index];
                return _buildDeviceTile(
                  entry.key,
                  Map<String, dynamic>.from(entry.value),
                  room,
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildDeviceTile(
      String deviceId, Map<String, dynamic> device, String room) {
    final utility = device['utility'] as String? ?? 'unknown';
    final relay = device['relay'] as bool? ?? false;
    final isActive = relay;
    final color = _utilityColor(utility);

    return Container(
      padding: const EdgeInsets.all(14),
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
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: isActive
                  ? const Color(0xFFF2C94C).withAlpha(28)
                  : Colors.grey.withAlpha(14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_utilityIcon(utility),
                size: 18,
                color: isActive
                    ? const Color(0xFFF2C94C)
                    : WebColors.muted.withAlpha(180)),
          ),
          const Spacer(),
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive ? AppColors.success : AppColors.offline)),
        ]),
        const SizedBox(height: 10),
        Text(_utilityLabel(utility),
            style: const TextStyle(
                fontFamily: 'Outfit',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        Text(deviceId,
            maxLines: 1,
            style: const TextStyle(fontSize: 12, color: WebColors.muted),
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        Text(isActive ? 'ON' : 'OFF',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isActive ? AppColors.success : AppColors.offline)),
        const Spacer(),
        Row(children: [
          Expanded(
            child: GestureDetector(
              onTap: () {
                if (widget.onDeviceTap != null) {
                  widget.onDeviceTap!(deviceId, utility, widget.buildingCode,
                      room, _selectedFloor);
                  return;
                }
                Navigator.pushNamed(context, '/device', arguments: {
                  'deviceId': deviceId,
                  'utility': utility,
                  'building': widget.buildingCode,
                  'room': room,
                  'floor': _selectedFloor,
                  'role': widget.role,
                });
              },
              child: Container(
                height: 30,
                decoration: BoxDecoration(
                    color: _palette.pale,
                    borderRadius: BorderRadius.circular(8)),
                child: Center(
                  child: Text('View',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _palette.dark)),
                ),
              ),
            ),
          ),
        ]),
        if (isAdmin) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              WebIconButton(
                icon: Icons.edit_outlined,
                tooltip: 'Edit device',
                size: 28,
                onPressed: () => _editDevice(deviceId, utility),
              ),
              const SizedBox(width: 6),
              WebIconButton(
                icon: Icons.delete_outline_rounded,
                tooltip: 'Remove device',
                size: 28,
                danger: true,
                onPressed: () => _deleteDevice(deviceId, utility),
              ),
            ],
          ),
        ],
      ]),
    );
  }

  Widget _emptyState(
      {required IconData icon,
      required String title,
      required String subtitle,
      Widget? action}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 60),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 48, color: WebColors.muted),
          const SizedBox(height: 12),
          Text(title,
              style: const TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark)),
          const SizedBox(height: 6),
          Text(subtitle,
              style: const TextStyle(fontSize: 13, color: WebColors.muted)),
          if (action != null) ...[
            const SizedBox(height: 16),
            action,
          ],
        ]),
      ),
    );
  }

  Color _utilityColor(String u) {
    switch (u.toLowerCase()) {
      case 'light':
      case 'lights':
        return const Color(0xFFE8922A);
      case 'outlet':
      case 'outlets':
        // Bug fix: was hardcoded green regardless of viewer -- matches
        // mobile's room-row "Outlets" utility dot, which already ties this
        // specific utility type's color to `_palette.mid` (Lights/AC stay
        // fixed orange/blue; only Outlets follows the brand ramp).
        return _palette.mid;
      case 'aircon':
      case 'ac':
      case 'air conditioner':
        return const Color(0xFF2196F3);
      default:
        return WebColors.muted;
    }
  }

  IconData _utilityIcon(String u) {
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
