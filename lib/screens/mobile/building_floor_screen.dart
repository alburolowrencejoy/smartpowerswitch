import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/app_top_bar.dart';
import '../../widgets/app_segmented_control.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_switch.dart';
import '../../widgets/app_bottom_sheet.dart';
import '../../widgets/outline_icon_box.dart';
import '../../widgets/delete_flow.dart';
import '../../widgets/delete_row_transition.dart';
import '../../widgets/responsive_center.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import '../../utils/last_seen.dart';

/// Best-effort full institute names for the Building screen's subtitle
/// (handoff §4.4: "IC Building" / "Institute of Computing"). Only "IC" is
/// confirmed by the handoff doc itself -- ILEGG/ITED/IAAS are reasonable
/// guesses from the abbreviation pattern, NOT confirmed against any real
/// school record in this repo (there is no full-name field anywhere in
/// Firebase; `buildings/{code}` only stores `name` + `floors`). Flagged for
/// verification. Unmapped codes (including a future 6th institute) show no
/// subtitle rather than a fabricated name.
const Map<String, String> _kInstituteFullNames = {
  'IC': 'Institute of Computing',
  'ILEGG': 'Institute of Law, Education and Good Governance',
  'ITED': 'Institute of Teacher Education',
  'IAAS': 'Institute of Agriculture and Applied Sciences',
  'ADMIN': 'Campus Administration',
};

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

  /// This building's institute color ramp (falls back to the main green
  /// palette for institutes without a dedicated color).
  InstitutePalette get _palette => InstituteColors.forCode(widget.buildingCode);

  String? get _instituteFullName =>
      _kInstituteFullNames[widget.buildingCode.trim().toUpperCase()];

  final Map<int, List<String>> _rooms = {};

  /// This floor's devices, keyed by deviceId, straight from
  /// `buildings/{code}/floorData/{floor}/devices` (fields: utility, status,
  /// relay, room -- no live telemetry).
  Map<String, dynamic> _devices = {};

  /// The flat `devices` node (all devices, every building) -- source of
  /// live telemetry (power, kwh, last_seen) keyed by deviceId. Cross
  /// referenced against [_devices] (which already scopes to this floor).
  Map<String, dynamic> _liveDevices = {};

  final List<StreamSubscription<DatabaseEvent>> _roomSubs = [];
  StreamSubscription? _combinedSub;

  /// Room currently mid-delete-animation (handoff §7.4) -- flipped to a
  /// room name by [_confirmDeleteRoom]'s `onOptimisticRemove`, cleared by
  /// `onRestore` if Undo is tapped. The room only actually disappears from
  /// [_rooms] once the deferred Firebase write in [_commitDeleteRoom] lands
  /// and the live `rooms` listener picks it up -- by then the row's height
  /// is already collapsed, so there's no visible jump.
  String? _deletingRoom;

  /// Device IDs with an in-flight relay write, so a rapid double-tap on a
  /// device row's switch can't fire two overlapping writes.
  final Set<String> _togglingDevices = {};

  // True until the first combined emission of this screen's 2 Firebase
  // streams (this floor's devices, the flat devices node) has been
  // received; never reverts to true afterwards, so a transient null on
  // either path can't blank out data already shown this session.
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

  Map<String, dynamic>? _liveFor(String deviceId) =>
      _liveDevices[deviceId] as Map<String, dynamic>?;

  bool _isDeviceOnline(String deviceId) =>
      isRecentlySeen(_liveFor(deviceId)?['last_seen']);

  // ── Floor-level summary (handoff §4.4: "Devices / On now / Today kWh") ──
  int get _floorDeviceCount => _devices.length;

  int get _floorOnNowCount => _devices.entries.where((e) {
        final floorDevice = e.value as Map;
        return floorDevice['relay'] == true && _isDeviceOnline(e.key);
      }).length;

  double get _floorTodayKwh => _devices.keys.fold<double>(0, (sum, id) {
        final kwh = (_liveFor(id)?['kwh'] as num?)?.toDouble() ?? 0.0;
        return sum + kwh;
      });

  double _roomPowerKw(String room) {
    double totalWatts = 0;
    for (final entry in _roomDeviceEntries(room)) {
      totalWatts += (_liveFor(entry.key)?['power'] as num?)?.toDouble() ?? 0.0;
    }
    return totalWatts / 1000;
  }

  String _roomSubtitle(String room) {
    final count = _roomDeviceEntries(room).length;
    if (count == 0) return 'No devices yet';
    final kw = _roomPowerKw(room);
    return '$count ${count == 1 ? 'device' : 'devices'} · ${kw.toStringAsFixed(1)} kW now';
  }

  Future<void> _toggleDeviceRelay(String deviceId, bool newValue) async {
    if (_togglingDevices.contains(deviceId)) return;
    setState(() => _togglingDevices.add(deviceId));
    try {
      final db = FirebaseDatabase.instance.ref();
      await Future.wait([
        db.child('devices/$deviceId/relay').set(newValue),
        db
            .child(
                'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices/$deviceId/relay')
            .set(newValue),
      ]);
    } catch (e) {
      if (mounted) {
        TopToast.error(context, 'Could not reach the device. Try again.');
      }
    } finally {
      if (mounted) setState(() => _togglingDevices.remove(deviceId));
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

  // ── Load rooms ───────────────────────────────────────────────────────
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

  // ── Listen to this floor's devices + the flat devices node (for live
  // telemetry/online state) in one combined stream so a transient null on
  // either path can't blank out data already shown this session.
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

    _combinedSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance
          .ref(
              'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices')
          .onValue,
      FirebaseDatabase.instance.ref('devices').onValue,
    ]).listen((events) {
      if (!mounted) return;
      _loadTimeoutTimer?.cancel();
      setState(() {
        // ── floor devices (for this floor's room/device rows) ───────
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

        // ── flat devices node: live telemetry + online state ───────
        final devicesRaw = events[1].snapshot.value;
        if (devicesRaw is Map) {
          final liveDevices = <String, dynamic>{};
          devicesRaw.forEach((id, val) {
            if (val is! Map) return;
            liveDevices[id.toString()] = Map<String, dynamic>.from(val);
          });
          _liveDevices = liveDevices;
        } else if (_isLoading) {
          _liveDevices = {};
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
      // Deliberate reset (not a network blip): the floor actually changed,
      // so the previous floor's device tiles must not linger.
      _devices = {};
    });
    _combinedSub?.cancel();
    _listenAll();
  }

  // ── Add room (handoff: "simple add-room sheet: room name/number") ────
  Future<void> _addRoom() async {
    final current = _rooms[_selectedFloor] ?? [];
    final controller = TextEditingController();
    String? error;
    int shake = 0;

    final result = await showAppBottomSheet<String>(
      context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setS) {
          void submit() {
            final name = controller.text.trim();
            if (name.isEmpty) {
              setS(() {
                error = 'Room name is required';
                shake++;
              });
              return;
            }
            if (current.contains(name)) {
              setS(() {
                error = 'Room already exists';
                shake++;
              });
              return;
            }
            Navigator.of(sheetContext).pop(name);
          }

          return BottomSheetScaffold(
            title: 'Add room',
            palette: _palette,
            body: AppTextField(
              controller: controller,
              shakeTrigger: shake,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Room name or number',
                hintText: 'e.g. Room 204, Lab 1',
                errorText: error,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onChanged: (_) {
                if (error != null) setS(() => error = null);
              },
              onSubmitted: (_) => submit(),
            ),
            footer: BottomSheetFooter(
              palette: _palette,
              applyLabel: 'Add',
              onCancel: () => Navigator.of(sheetContext).pop(),
              onApply: submit,
            ),
          );
        },
      ),
    );
    if (result == null) return;

    final updated = [...current, result];
    final roomMap = {for (int i = 0; i < updated.length; i++) '$i': updated[i]};
    try {
      await FirebaseDatabase.instance
          .ref(
              'buildings/${widget.buildingCode}/floorData/$_selectedFloor/rooms')
          .set(roomMap);
      if (mounted) TopToast.success(context, '"$result" added.');
    } catch (e) {
      if (mounted) TopToast.error(context, 'Failed to add room: $e');
    }
  }

  // ── Add device to a room (preserves the existing "Add Utility" flow;
  // the handoff's Building screen mock doesn't show this control at all,
  // but removing the only way to assign a device to a room would be an
  // undocumented regression, so it's kept as a trailing row inside each
  // room section instead of a header icon -- see the class doc in
  // room_devices_panel.dart for the canonical version of this flow, which
  // this deliberately mirrors; keep the two in sync if you touch either.) ─
  Future<void> _addDeviceToRoom(String room) async {
    var assignedInBuilding = 0;
    try {
      final capSnap =
          await FirebaseDatabase.instance.ref('master_devices').get();
      if (capSnap.value is Map) {
        (capSnap.value as Map).forEach((id, val) {
          if (val is! Map) return;
          final assignedTo = (val['assignedTo'] ?? '').toString();
          if (assignedTo.startsWith('${widget.buildingCode}/')) {
            assignedInBuilding++;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        TopToast.error(context, 'Could not check the device limit: $e');
      }
      return;
    }
    if (!mounted) return;
    if (assignedInBuilding >= 24) {
      TopToast.threshold(context, 'Device limit reached (24 max).');
      return;
    }

    // One "Add device" sheet (utility + ID together) in the redesign's
    // sheet chrome, instead of two back-to-back dialogs.
    final idController = TextEditingController();
    String? pickedUtility;
    String? utilityError;
    String? idError;
    int idShake = 0;
    bool checking = false;

    final picked = await showAppBottomSheet<(String, String)>(
      context,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setS) {
          Future<void> submit() async {
            final id = idController.text.trim().toUpperCase();
            String? ue = pickedUtility == null ? 'Choose a utility type' : null;
            String? ie = id.isEmpty ? 'Please enter a Device ID' : null;
            if (ue != null || ie != null) {
              setS(() {
                utilityError = ue;
                idError = ie;
                idShake++;
              });
              return;
            }
            if (_devices.containsKey(id)) {
              setS(() {
                idError = 'Device already added to this floor';
                idShake++;
              });
              return;
            }
            setS(() => checking = true);
            String? err;
            try {
              final snap = await FirebaseDatabase.instance
                  .ref('master_devices/$id')
                  .get();
              if (!snap.exists) {
                err = 'Device ID not found in system';
              } else {
                final assigned =
                    (snap.value as Map?)?['assignedTo'] as String?;
                if (assigned != null && assigned.isNotEmpty) {
                  err = 'Device already assigned to $assigned';
                }
              }
            } catch (e) {
              err = 'Could not check this ID: $e';
            }
            if (!sheetCtx.mounted) return;
            if (err != null) {
              setS(() {
                checking = false;
                idError = err;
                idShake++;
              });
              return;
            }
            Navigator.pop(sheetCtx, (pickedUtility!, id));
          }

          Widget option(String value, IconData icon, String label) {
            final selected = pickedUtility == value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setS(() {
                  pickedUtility = value;
                  utilityError = null;
                }),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  // Outline system: selected = theme ring, never a fill.
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected ? _palette.dark : AppColors.hairline,
                      width: selected ? 1.5 : 1,
                    ),
                  ),
                  child: Row(children: [
                    OutlineIconBox(icon: icon, palette: _palette),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(label,
                          style: AppTextStyles.subtitle
                              .copyWith(color: AppColors.ink)),
                    ),
                    Icon(
                        selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 22,
                        color: selected ? _palette.dark : AppColors.inkMuted),
                  ]),
                ),
              ),
            );
          }

          return BottomSheetScaffold(
            title: 'Add device to $room',
            palette: _palette,
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Utility',
                    style: AppTextStyles.label.copyWith(color: AppColors.ink)),
                const SizedBox(height: 8),
                ShakeOnError(
                  error: utilityError,
                  trigger: idShake,
                  child: Column(children: [
                    option('Lights', Icons.lightbulb_outline, 'Lights'),
                    option('Outlets', Icons.electrical_services, 'Outlets'),
                    option('AC', Icons.ac_unit, 'AC unit'),
                  ]),
                ),
                if (utilityError != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(utilityError!,
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.errorText)),
                  ),
                const SizedBox(height: 10),
                Text('Device ID',
                    style: AppTextStyles.label.copyWith(color: AppColors.ink)),
                const SizedBox(height: 4),
                Text('The ID on the sticker of the ESP32 board.',
                    style: AppTextStyles.bodySm
                        .copyWith(color: AppColors.inkMid)),
                const SizedBox(height: 8),
                AppTextField(
                  controller: idController,
                  shakeTrigger: idError == null ? 0 : idShake,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    hintText: 'e.g. ESP32-ROOM101-001',
                    errorText: idError,
                    prefixIcon:
                        const Icon(Icons.qr_code, color: AppColors.inkMuted),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onChanged: (_) {
                    if (idError != null) setS(() => idError = null);
                  },
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
            footer: BottomSheetFooter(
              palette: _palette,
              applyLabel: checking ? 'Checking…' : 'Add device',
              onCancel: () => Navigator.pop(sheetCtx),
              onApply: checking ? null : submit,
            ),
          );
        },
      ),
    );
    if (picked == null || !mounted) return;
    final (utility, deviceId) = picked;

    try {
      await FirebaseDatabase.instance
          .ref(
              'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices/$deviceId')
          .set({
        'utility': utility,
        'status': 'offline',
        'relay': false,
        'room': room,
      });
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
      await FirebaseDatabase.instance
          .ref('master_devices/$deviceId/assignedTo')
          .set('${widget.buildingCode}/$_selectedFloor/$room');

      if (!mounted) return;
      TopToast.success(context, '$deviceId added as $utility in $room.');
    } catch (e) {
      if (!mounted) return;
      TopToast.error(context, 'Failed to add device: $e');
    }
  }

  // ── Delete room (handoff §7: two-step confirm + 5s Undo) ─────────────
  Future<void> _confirmDeleteRoom(String room) async {
    final roomDevices = _roomDeviceEntries(room);
    final deviceCount = roomDevices.length;

    final committed = await showDeleteFlow(
      context,
      type: DeleteType.room,
      itemName: '$room · ${widget.buildingName}',
      impact: [
        deviceCount > 0
            ? '$deviceCount ${deviceCount == 1 ? 'device' : 'devices'} will be unassigned'
            : 'No devices are assigned to this room',
        'Schedules for these devices will stop',
        'Usage history stays in Analytics',
      ],
      onOptimisticRemove: () => setState(() => _deletingRoom = room),
      onRestore: () => setState(() => _deletingRoom = null),
      onCommit: (reason, otherText) =>
          _commitDeleteRoom(room, roomDevices, reason, otherText),
    );

    if (committed && mounted) {
      TopToast.success(context, 'Room deleted');
    }
  }

  Future<void> _commitDeleteRoom(
    String room,
    List<MapEntry<String, Map<String, dynamic>>> roomDevices,
    String reason,
    String? otherText,
  ) async {
    final db = FirebaseDatabase.instance.ref();
    final remainingRooms = List<String>.from(_rooms[_selectedFloor] ?? [])
      ..remove(room);
    final roomMap = {
      for (var i = 0; i < remainingRooms.length; i++) '$i': remainingRooms[i]
    };

    final updates = <String, Object?>{
      'buildings/${widget.buildingCode}/floorData/$_selectedFloor/rooms':
          remainingRooms.isEmpty ? {} : roomMap,
    };

    for (final entry in roomDevices) {
      final id = entry.key;
      updates['buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices/$id'] =
          null;
      updates['master_devices/$id/assignedTo'] = '';
      updates['devices/$id/building'] = '';
      updates['devices/$id/floor'] = '';
      updates['devices/$id/room'] = '';
      updates['devices/$id/status'] = 'offline';
    }

    final user = FirebaseAuth.instance.currentUser;
    final logRef = db.child('deletion_log').push();
    updates['deletion_log/${logRef.key}'] = {
      'type': 'room',
      'buildingCode': widget.buildingCode,
      'floor': _selectedFloor,
      'room': room,
      'deviceIds': roomDevices.map((e) => e.key).toList(),
      'reason': reason,
      'otherText': otherText,
      'deletedBy': user?.uid,
      'deletedByEmail': user?.email,
      'timestamp': ServerValue.timestamp,
    };

    try {
      await db.update(updates);
    } catch (e) {
      if (mounted) {
        setState(() => _deletingRoom = null);
        TopToast.error(context, 'Failed to delete room: $e');
      }
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme(palette: _palette)],
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Column(children: [
            // Skipped when embedded directly as an institute admin's
            // dashboard tab -- the parent dashboard already shows an
            // equivalent institute-scoped summary card just above this
            // screen (see class doc on `showBackButton`).
            if (widget.showBackButton)
              AppTopBar(
                title: widget.buildingName,
                subtitle: _instituteFullName,
                variant: AppTopBarVariant.small,
                showBackButton: true,
                showInstituteLine: true,
                palette: _palette,
              ),
            _buildFloorRow(),
            if (_errorText == null) _buildSummaryBoxes(),
            Expanded(
              child: ResponsiveCenter(
                maxWidth: 900,
                child: _errorText != null
                    ? _buildFloorError()
                    : ScreenSkeleton(
                        isLoading: _isLoading,
                        child: _buildRoomsList(),
                      ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildFloorRow() {
    final segments = List.generate(
        widget.floors, (i) => AppSegment(label: 'Floor ${i + 1}'));
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(children: [
        Expanded(
          child: AppSegmentedControl(
            segments: segments,
            selectedIndex: _selectedFloor - 1,
            onChanged: (i) => _switchFloor(i + 1),
            palette: _palette,
          ),
        ),
        if (isAdmin) ...[
          const SizedBox(width: 10),
          IconAddButton(
            onPressed: _addRoom,
            palette: _palette,
            semanticLabel: 'Add room',
          ),
        ],
      ]),
    );
  }

  Widget _buildSummaryBoxes() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(children: [
        Expanded(
            child: _StatBox(
                label: 'Devices',
                value: '$_floorDeviceCount',
                palette: _palette)),
        const SizedBox(width: 8),
        Expanded(
            child: _StatBox(
                label: 'On now',
                value: '$_floorOnNowCount',
                palette: _palette)),
        const SizedBox(width: 8),
        Expanded(
            child: _StatBox(
                label: 'Today',
                value: _floorTodayKwh.toStringAsFixed(1),
                unit: 'kWh',
                palette: _palette)),
      ]),
    );
  }

  Widget _buildFloorError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.wifi_off_rounded, size: 34, color: _palette.mid),
          const SizedBox(height: 12),
          Text(_errorText ?? 'Failed to load this floor.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _retryLoad,
            icon: const Icon(Icons.refresh, size: 16, color: Colors.white),
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

  Widget _buildRoomsList() {
    final rooms = _rooms[_selectedFloor] ?? [];
    if (rooms.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.meeting_room_outlined, size: 48, color: _palette.mid),
          const SizedBox(height: 12),
          Text('No rooms yet',
              style: AppTextStyles.subtitle.copyWith(color: AppColors.ink)),
          const SizedBox(height: 6),
          Text(
            isAdmin ? 'Tap + to add one' : 'No rooms have been added yet',
            style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted),
          ),
        ]),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final room in rooms)
            // Gap sits outside the transition so the red "Room deleted"
            // strip hangs from the room's last row, not from the gap.
            Padding(
              key: ValueKey('room-$room'),
              padding: const EdgeInsets.only(bottom: 22),
              child: DeleteRowTransition(
                deleting: _deletingRoom == room,
                message: 'Room deleted',
                onDeleteAnimationComplete: () {},
                child: _buildRoomSection(room),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRoomSection(String room) {
    final roomDevices = _roomDeviceEntries(room);
    return Container(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(room,
                        style:
                            AppTextStyles.title.copyWith(color: AppColors.ink)),
                    const SizedBox(height: 2),
                    Text(_roomSubtitle(room),
                        style: AppTextStyles.bodySm
                            .copyWith(color: AppColors.inkMuted)),
                  ],
                ),
              ),
              if (isAdmin)
                IconDeleteButton(
                  onPressed: () => _confirmDeleteRoom(room),
                  semanticLabel: 'Delete $room',
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (roomDevices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text('No devices yet',
                  style:
                      AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
            )
          else
            ...roomDevices
                .map((entry) => ValueListenableBuilder<Set<String>>(
                      // Plays the delete animation after "Remove device" on
                      // the device page brings the user back here.
                      key: ValueKey('device-${entry.key}'),
                      valueListenable: pendingRowDeletes,
                      builder: (context, pending, _) => DeleteRowTransition(
                        deleting: pending.contains('device:${entry.key}'),
                        message: 'Device removed',
                        child: _deviceRow(entry.key, entry.value, room),
                      ),
                    )),
          if (isAdmin) _addDeviceRow(room),
        ],
      ),
    );
  }

  Widget _deviceRow(
      String deviceId, Map<String, dynamic> floorDevice, String room) {
    final utility = (floorDevice['utility'] ?? '').toString();
    final online = _isDeviceOnline(deviceId);
    final relayOn = floorDevice['relay'] == true;
    final watts = (_liveFor(deviceId)?['power'] as num?)?.toDouble();
    final statusText = online
        ? 'Online${watts != null ? ' · ${watts.toStringAsFixed(0)} W' : ''}'
        : 'Offline';
    final dotColor = online ? AppColors.success : AppColors.offline;
    final toggling = _togglingDevices.contains(deviceId);

    return Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.pushNamed(context, '/device', arguments: {
          'deviceId': deviceId,
          'utility': utility,
          'building': widget.buildingCode,
          'room': room,
          'floor': _selectedFloor,
          'role': widget.role,
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            OutlineIconBox(icon: _utilityIcon(utility), palette: _palette),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_utilityLabel(utility),
                      style: AppTextStyles.subtitle
                          .copyWith(color: AppColors.ink)),
                  const SizedBox(height: 2),
                  Row(children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle, color: dotColor),
                    ),
                    const SizedBox(width: 5),
                    Text(statusText,
                        style: AppTextStyles.bodySm
                            .copyWith(color: AppColors.inkMuted)),
                  ]),
                ],
              ),
            ),
            if (toggling)
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: _palette.dark),
              )
            else
              AppSwitch(
                value: relayOn,
                onChanged:
                    isAdmin ? (v) => _toggleDeviceRelay(deviceId, v) : null,
                palette: _palette,
              ),
          ]),
        ),
      ),
    );
  }

  Widget _addDeviceRow(String room) {
    return Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _addDeviceToRoom(room),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            OutlineIconBox(icon: Icons.add, palette: _palette),
            const SizedBox(width: 12),
            Text('Add device',
                style: AppTextStyles.subtitle.copyWith(color: _palette.dark)),
          ]),
        ),
      ),
    );
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
}

/// White + 1px institute-line border reading box (handoff §3.2's "outline
/// system"), used for the Devices / On now / Today floor summary.
class _StatBox extends StatelessWidget {
  const _StatBox({
    required this.label,
    required this.value,
    required this.palette,
    this.unit,
  });

  final String label;
  final String value;
  final String? unit;
  final InstitutePalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: AppTextStyles.caption.copyWith(color: AppColors.inkMid)),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(value,
                  style: AppTextStyles.subtitle.copyWith(
                      color: AppColors.ink,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              if (unit != null) ...[
                const SizedBox(width: 3),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(unit!,
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.inkMuted)),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
