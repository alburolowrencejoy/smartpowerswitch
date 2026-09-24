import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/responsive_center.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import 'room_devices_panel.dart';
import 'room_devices_screen.dart';
import '../../theme/app_fonts.dart';
import '../../services/history_clock.dart';

class BuildingFloorScreen extends StatefulWidget {
  final String buildingCode;
  final String buildingName;
  final int floors;
  final String role;

  /// False when this screen is embedded directly as an institute admin's
  /// dashboard tab (not pushed as its own route) — hides the back arrow so
  /// a stray tap can't pop the whole dashboard shell.
  final bool showBackButton;

  const BuildingFloorScreen({
    super.key,
    required this.buildingCode,
    required this.buildingName,
    required this.floors,
    required this.role,
    this.showBackButton = true,
  });

  @override
  State<BuildingFloorScreen> createState() => _BuildingFloorScreenState();
}

class _BuildingFloorScreenState extends State<BuildingFloorScreen> {
  int _selectedFloor = 1;
  String? _selectedRoom;
  String? _roomTogglingRoom;

  /// This building's institute color ramp (falls back to the main green
  /// palette for institutes without a dedicated color).
  InstitutePalette get _palette => InstituteColors.forCode(widget.buildingCode);

  final Map<int, List<String>> _rooms = {};
  Map<String, dynamic> _devices = {};

  double _buildingKwh = 0;
  int _buildingOnline = 0;
  bool _hasMonthlyBuildingEnergy = false;
  int _instituteTotalDevices = 0; // assigned devices in this building

  final List<StreamSubscription<DatabaseEvent>> _roomSubs = [];
  StreamSubscription? _combinedSub;
  Map<String, dynamic> _liveDevices = {};

  // True until the first combined emission of this screen's 4 Firebase
  // streams (floor devices, master_devices, monthly history, flat devices)
  // has been received; never reverts to true afterwards, so a transient
  // null on any one path can't blank out data already shown this session.
  bool _isLoading = true;

  // Set only if the combined listener fails (or times out) before the
  // first successful load ever completes -- gives the dashboard skeleton
  // shimmer a real escape hatch instead of spinning forever.
  String? _errorText;
  Timer? _loadTimeoutTimer;
  bool _postLoadErrorNotified = false;

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
    _combinedSub?.cancel();
    _loadTimeoutTimer?.cancel();
    super.dispose();
  }

  /// Clears the error state and re-attaches the combined listener from
  /// scratch. Used by the Retry button shown when the first load fails.
  void _retryLoad() {
    _combinedSub?.cancel();
    _loadTimeoutTimer?.cancel();
    setState(() {
      _errorText = null;
      _isLoading = true;
      _postLoadErrorNotified = false;
    });
    _listenAll();
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

  // ── Listen to every Firebase path this screen needs (floor devices,
  // master_devices, this month's building history, and the flat devices
  // node) in one combined stream so a transient null on any single path
  // can't blank out data already shown this session. The flat `devices`
  // snapshot is read once and used to derive both live energy totals and
  // the online count -- previously two separate subscriptions to the same
  // path.
  void _listenAll() {
    _loadTimeoutTimer?.cancel();
    if (_isLoading) {
      _loadTimeoutTimer = Timer(const Duration(seconds: 15), () {
        if (!mounted || !_isLoading) return;
        setState(() {
          _isLoading = false;
          _errorText =
              'Taking too long to load this floor. Check your connection.';
        });
      });
    }

    final monthKey = _monthKey(HistoryClock.instance.now());
    _combinedSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance
          .ref(
              'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices')
          .onValue,
      FirebaseDatabase.instance.ref('master_devices').onValue,
      FirebaseDatabase.instance
          .ref('history/monthly/$monthKey/buildings/${widget.buildingCode}/kwh')
          .onValue,
      FirebaseDatabase.instance.ref('devices').onValue,
    ]).listen((events) {
      if (!mounted) return;
      _loadTimeoutTimer?.cancel();
      setState(() {
        // ── floor devices (for this floor's room/device tiles) ─────
        final floorRaw = events[0].snapshot.value;
        if (floorRaw is Map) {
          final devices = <String, dynamic>{};
          floorRaw.forEach((k, v) {
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

        // ── master_devices (assigned counts) ───────────────────────
        final masterRaw = events[1].snapshot.value;
        if (masterRaw is Map) {
          int buildingCount = 0;
          masterRaw.forEach((id, val) {
            if (val is! Map) return;
            final assignedTo = (val['assignedTo'] ?? '').toString();
            if (assignedTo.isEmpty) return;
            // assignedTo format: "IC/1/Comlab 1"
            final parts = assignedTo.split('/');
            if (parts.isNotEmpty && parts[0] == widget.buildingCode) {
              buildingCount++;
            }
          });
          _instituteTotalDevices = buildingCount;
        } else if (_isLoading) {
          _instituteTotalDevices = 0;
        }

        // ── this month's building energy from history ──────────────
        final historyRaw = events[2].snapshot.value;
        if (historyRaw is num) {
          _hasMonthlyBuildingEnergy = true;
          _buildingKwh = historyRaw.toDouble();
        } else if (_isLoading) {
          _hasMonthlyBuildingEnergy = false;
        }

        // ── flat devices node: live energy totals + online count ──
        final devicesRaw = events[3].snapshot.value;
        if (devicesRaw is Map) {
          final liveDevices = <String, dynamic>{};
          double kwh = 0;
          int online = 0;
          devicesRaw.forEach((id, val) {
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
          _buildingOnline = 0;
          if (!_hasMonthlyBuildingEnergy) {
            _buildingKwh = 0;
          }
        }

        _isLoading = false;
        _errorText = null;
        _postLoadErrorNotified = false;
      });
    }, onError: (Object error) {
      if (!mounted) return;
      debugPrint('[BuildingFloor] Combined listen error: $error');
      _loadTimeoutTimer?.cancel();
      if (_isLoading) {
        setState(() {
          _isLoading = false;
          _errorText = _isPermissionDenied(error)
              ? 'You do not have permission to view this floor.'
              : 'Failed to load this floor.';
        });
      } else if (!_postLoadErrorNotified) {
        _postLoadErrorNotified = true;
        TopToast.show(
          context,
          'Lost connection to live floor data.',
          isError: true,
        );
      }
    });
  }

  void _switchFloor(int floor) {
    setState(() {
      _selectedFloor = floor;
      _selectedRoom = null;
      // Deliberate reset (not a network blip): the floor actually changed,
      // so the previous floor's device tiles must not linger.
      _devices = {};
    });
    _combinedSub?.cancel();
    _listenAll();
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

  // â”€â”€ Add room â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  /// Room-name prompt shared by add and edit. [validate] returns an error
  /// message, shown on the field (with a shake), or null to accept.
  Future<String?> _roomNameDialog({
    required String title,
    required String actionLabel,
    required String? Function(String name) validate,
    String initial = '',
  }) {
    final controller = TextEditingController(text: initial);
    String? error;
    int shake = 0;

    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          void submit() {
            final name = controller.text.trim();
            final err = validate(name);
            if (err != null) {
              setS(() {
                error = err;
                shake++;
              });
              return;
            }
            Navigator.pop(ctx, name);
          }

          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(title,
                style: const TextStyle(
                    fontFamily: AppFonts.family, fontWeight: FontWeight.w600)),
            content: AppTextField(
              controller: controller,
              shakeTrigger: shake,
              decoration: InputDecoration(
                hintText: 'e.g. Room 2, Lab 1, Office',
                errorText: error,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: _palette.mid)),
              ),
              autofocus: true,
              onChanged: (_) {
                if (error != null) setS(() => error = null);
              },
              onSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel',
                      style: TextStyle(color: AppColors.textMuted))),
              ElevatedButton(
                onPressed: submit,
                style: ElevatedButton.styleFrom(
                    backgroundColor: _palette.dark,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
                child: Text(actionLabel,
                    style: const TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addRoom() async {
    final current = _rooms[_selectedFloor] ?? [];
    final result = await _roomNameDialog(
      title: 'Add Room',
      actionLabel: 'Add',
      validate: (name) {
        if (name.isEmpty) return 'Room name is required';
        if (current.contains(name)) return 'Room already exists';
        return null;
      },
    );
    if (result == null) return;

    final updated = [...current, result];
    final roomMap = {for (int i = 0; i < updated.length; i++) '$i': updated[i]};
    await FirebaseDatabase.instance
        .ref('buildings/${widget.buildingCode}/floorData/$_selectedFloor/rooms')
        .set(roomMap);
  }

  // â”€â”€ Edit room â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> _editRoom(String oldRoom) async {
    final current = _rooms[_selectedFloor] ?? [];
    final result = await _roomNameDialog(
      title: 'Edit Room Name',
      actionLabel: 'Save',
      initial: oldRoom,
      validate: (name) {
        if (name.isEmpty) return 'Room name is required';
        if (name != oldRoom && current.contains(name)) {
          return 'Room name already exists';
        }
        return null;
      },
    );
    if (result == null || result == oldRoom) return;

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
            style: TextStyle(
                fontFamily: AppFonts.family, fontWeight: FontWeight.w600)),
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

  // Add-utility and delete-device flows (including the utility-type picker
  // dialog) moved to RoomDevicesPanel (lib/screens/mobile/room_devices_panel.dart)
  // as part of extracting the room-devices view into its own reusable
  // widget. _unassignDevice below stays here too -- see the comment on it.

  // Deliberately duplicated in RoomDevicesPanel._unassignDevice (used there
  // by that widget's own _deleteDevice). Kept here because this copy is
  // also used by _deleteRoom's cascading delete above, which stays in this
  // file (rooms-list flow, not part of the extracted panel). If you touch
  // this, update the copy in room_devices_panel.dart too so the two don't
  // drift.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(children: [
          // Both this header (building code/name + Admin badge) and the
          // stats row below are skipped when embedded as an institute
          // admin's dashboard tab -- the parent dashboard already shows an
          // equivalent institute-scoped summary card just above this
          // screen, so showing either here is pure duplication (they cover
          // the same institute, since an institute admin has exactly one
          // building). Safe to gate the header on showBackButton alone now:
          // room taps in the embedded instance push RoomDevicesScreen
          // instead of setting _selectedRoom, so the header's back-arrow-
          // for-a-selected-room case never applies here.
          if (widget.showBackButton) ...[
            _buildHeader(),
            _buildBuildingDashboard(),
          ],
          _buildFloorTabs(),
          Flexible(
            fit: FlexFit.loose,
            child: ResponsiveCenter(
              maxWidth: 900,
              child: _selectedRoom == null
                  ? _buildRoomsList()
                  // Room-devices grid + its own "Add Utility" FAB now live
                  // in RoomDevicesPanel; this in-place swap only applies to
                  // the main-admin standalone path (showBackButton: true --
                  // see _buildRoomCard's onTap below for the institute-admin
                  // path, which pushes RoomDevicesScreen instead).
                  : RoomDevicesPanel(
                      buildingCode: widget.buildingCode,
                      buildingName: widget.buildingName,
                      floor: _selectedFloor,
                      room: _selectedRoom!,
                      role: widget.role,
                    ),
            ),
          ),
        ]),
      ),
      // Add Utility is now owned by RoomDevicesPanel itself (see build()
      // above), so this outer FAB only ever drives Add Room, and only
      // shows up on the rooms-list step.
      floatingActionButton: isAdmin && _selectedRoom == null
          ? FloatingActionButton.extended(
              onPressed: _addRoom,
              backgroundColor: _palette.dark,
              icon: const Icon(Icons.add, color: Colors.white),
              label: const Text(
                'Add Room',
                style: TextStyle(
                    color: Colors.white,
                    fontFamily: AppFonts.family,
                    fontWeight: FontWeight.w600),
              ),
            )
          : null,
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      color: _palette.dark,
      child: Row(children: [
        if (widget.showBackButton || _selectedRoom != null) ...[
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
        ],
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Skip the small code caption when the building has no custom
            // name yet — showing "IC" twice in a row is pure redundancy.
            if (widget.buildingName.trim().toUpperCase() !=
                widget.buildingCode.trim().toUpperCase())
              Text(widget.buildingCode,
                  style: TextStyle(
                      fontSize: 11,
                      color: _palette.light,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1)),
            Text(
              _selectedRoom != null
                  ? '${widget.buildingName} - $_selectedRoom'
                  : widget.buildingName,
              style: const TextStyle(
                  fontFamily: AppFonts.family,
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
      decoration: BoxDecoration(
        color: _palette.dark,
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
      ),
      child: _errorText != null
          ? _buildDashboardError()
          : ScreenSkeleton(
              isLoading: _isLoading,
              child: Row(children: [
                Expanded(
                    child: _dashCard(
                        _energyScopeLabel(),
                        '${energyKwh.toStringAsFixed(1)} kWh',
                        Icons.bolt,
                        _palette.light)),
                const SizedBox(width: 10),
                Expanded(
                    child: _dashCard(
                        'Cost',
                        'PHP ${energyCost.toStringAsFixed(0)}',
                        Icons.payments_outlined,
                        _palette.pale)),
                const SizedBox(width: 10),
                Expanded(
                    child: _dashCard('Online', '$_buildingOnline online',
                        Icons.wifi, _palette.mid)),
                if (isAdmin) ...[
                  const SizedBox(width: 10),
                  Expanded(
                      child: _dashCard(
                          'Devices',
                          '$_instituteTotalDevices assigned',
                          Icons.devices,
                          _palette.light)),
                ],
              ]),
            ),
    );
  }

  Widget _buildDashboardError() {
    return SizedBox(
      height: 84,
      child: Row(children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
                color: Colors.white.withAlpha(15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withAlpha(26))),
            child: Row(children: [
              Icon(Icons.wifi_off_rounded, size: 18, color: _palette.light),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _errorText ?? 'Failed to load floor data.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: _palette.pale),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _retryLoad,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                      color: Colors.white.withAlpha(38),
                      borderRadius: BorderRadius.circular(8)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.refresh, size: 14, color: Colors.white),
                    SizedBox(width: 4),
                    Text('Retry',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                  ]),
                ),
              ),
            ]),
          ),
        ),
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
                      fontFamily: AppFonts.family,
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
                          fontFamily: AppFonts.family,
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
                  fontFamily: AppFonts.family,
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
                fontFamily: AppFonts.family,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        const SizedBox(height: 16),
        ...rooms.map((room) => _buildRoomCard(room)),
      ]),
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
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _palette.mid.withAlpha(26))),
      child: Column(children: [
        GestureDetector(
          onTap: () {
            if (!widget.showBackButton) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => RoomDevicesScreen(
                    buildingCode: widget.buildingCode,
                    buildingName: widget.buildingName,
                    floor: _selectedFloor,
                    room: room,
                    role: widget.role,
                  ),
                ),
              );
            } else {
              setState(() => _selectedRoom = room);
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                    color: _palette.pale,
                    borderRadius: BorderRadius.circular(13)),
                child: Icon(Icons.meeting_room_outlined,
                    size: 24, color: _palette.dark),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(room,
                          style: const TextStyle(
                              fontFamily: AppFonts.family,
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
              if (isAdmin && utilityCount > 0) ...[
                const SizedBox(width: 12),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 50,
                      height: 28,
                      child: Switch.adaptive(
                        value: roomSwitchOn,
                        onChanged: roomSwitchBusy
                            ? null
                            : (value) => _setRoomRelays(room, value),
                        activeThumbColor: _palette.light,
                        activeTrackColor: _palette.mid.withAlpha(80),
                        inactiveThumbColor: Colors.white,
                        inactiveTrackColor: AppColors.textMuted.withAlpha(70),
                      ),
                    ),
                  ],
                ),
              ],
              // Show utility icons only when the main switch is not displayed
              if (!(isAdmin && utilityCount > 0)) ...[
                if (hasLights)
                  _utilityDot(Icons.lightbulb_outline, const Color(0xFFE8922A)),
                if (hasOutlets)
                  Padding(
                      padding: const EdgeInsets.only(left: 5),
                      child:
                          _utilityDot(Icons.electrical_services, _palette.mid)),
                if (hasAc)
                  Padding(
                      padding: const EdgeInsets.only(left: 5),
                      child:
                          _utilityDot(Icons.ac_unit, const Color(0xFF2196F3))),
              ],
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right,
                  color: AppColors.textMuted, size: 20),
            ]),
          ),
        ),
        if (isAdmin) ...[
          Divider(height: 1, color: _palette.mid.withAlpha(20)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => _editRoom(room),
                  icon:
                      Icon(Icons.edit_outlined, size: 16, color: _palette.dark),
                  label: Text('Edit',
                      style: TextStyle(fontSize: 12, color: _palette.dark)),
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
}
