import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/responsive_center.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/delete_flow.dart';
import '../../widgets/delete_row_transition.dart';
import '../../widgets/top_toast.dart';
import 'web_theme.dart';
import 'web_widgets.dart';
import '../../theme/app_fonts.dart';
import '../../services/history_clock.dart';

/// The desktop building page: floor tabs, then one card per room listing
/// its devices with a live switch, View, and admin add/edit/delete icons.
/// Independent Firebase listeners from the mobile [BuildingFloorScreen].
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
  /// back link is pressed -- lets the desktop
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
  /// instead of staying pinned/cut off above it.
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

    final monthKey = _monthKey(HistoryClock.instance.now());
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

  /// Shared `devices` snapshot: live per-device kWh / last_seen for the rows,
  /// and the energy sum feeding [_buildingKwh] when no monthly total exists.
  void _applyDevicesSnapshot(Object? raw) {
    if (raw is Map) {
      final liveDevices = <String, dynamic>{};
      double kwh = 0;
      raw.forEach((id, val) {
        if (val is! Map) return;
        final device = Map<String, dynamic>.from(val);
        liveDevices[id.toString()] = device;

        final building = (device['building'] ?? '').toString();
        if (building != widget.buildingCode) return;
        kwh += ((device['kwh'] ?? 0.0) as num).toDouble();
      });

      _liveDevices = liveDevices;
      if (!_hasMonthlyBuildingEnergy) {
        _buildingKwh = kwh;
      }
    } else if (_isLoading) {
      _liveDevices = {};
      if (!_hasMonthlyBuildingEnergy) {
        _buildingKwh = 0;
      }
    }
  }

  void _switchFloor(int floor) {
    setState(() {
      _selectedFloor = floor;
      _devices = {};
      _isLoading = true;
      _hasLoadedOnce = false;
      _errorText = null;
    });
    _listenAll();
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

  /// Room whose delete animation is playing / whose commit is pending.
  String? _deletingRoom;

  /// Same two-step confirm -> reason flow, red strip, 5s Undo and deferred
  /// atomic commit (with a `deletion_log` entry) as mobile.
  Future<void> _deleteRoom(String room) async {
    final floor = _selectedFloor;
    final deviceIds = _roomDeviceEntries(room).map((e) => e.key).toList();
    final n = deviceIds.length;
    await showDeleteFlow(
      context,
      type: DeleteType.room,
      itemName: '$room · ${widget.buildingCode} · Floor $floor',
      impact: [
        n > 0
            ? '$n device${n == 1 ? '' : 's'} will be unassigned'
            : 'No devices are assigned to this room',
        'Schedules for these devices will stop',
        'Usage history stays in Analytics',
      ],
      onOptimisticRemove: () => setState(() => _deletingRoom = room),
      onRestore: () {
        if (mounted) setState(() => _deletingRoom = null);
      },
      onCommit: (reason, otherText) async {
        final base = 'buildings/${widget.buildingCode}/floorData/$floor';
        final remaining = List<String>.from(_rooms[floor] ?? [])..remove(room);
        final db = FirebaseDatabase.instance.ref();
        final user = FirebaseAuth.instance.currentUser;
        final logRef = db.child('deletion_log').push();
        final updates = <String, Object?>{
          '$base/rooms': remaining.isEmpty
              ? null
              : {for (var i = 0; i < remaining.length; i++) '$i': remaining[i]},
          for (final id in deviceIds) ...{
            '$base/devices/$id': null,
            'master_devices/$id/assignedTo': '',
            'devices/$id/building': '',
            'devices/$id/floor': '',
            'devices/$id/room': '',
            'devices/$id/status': 'offline',
          },
          'deletion_log/${logRef.key}': {
            'type': 'room',
            'buildingCode': widget.buildingCode,
            'floor': floor,
            'room': room,
            'deviceIds': deviceIds,
            'reason': reason,
            'otherText': otherText,
            'deletedBy': user?.uid,
            'deletedByEmail': user?.email,
            'timestamp': ServerValue.timestamp,
          },
        };
        try {
          await db.update(updates);
        } catch (e) {
          if (mounted) TopToast.error(context, 'Failed to delete room: $e');
          rethrow;
        } finally {
          if (mounted) setState(() => _deletingRoom = null);
        }
      },
    );
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

  // ── Build (preview layout) ────────────────────────────────────────────

  /// Device ids whose relay write is in flight (their switch is disabled).
  final Set<String> _togglingDevices = {};

  Map<String, dynamic>? _live(String deviceId) {
    final v = _liveDevices[deviceId];
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }

  bool _deviceOnline(String deviceId) {
    final seen = _live(deviceId)?['last_seen'];
    if (seen is! num || seen == 0) return false;
    return DateTime.now()
            .difference(DateTime.fromMillisecondsSinceEpoch(seen.toInt()))
            .inMinutes <
        2;
  }

  double _deviceKwh(String deviceId) {
    final k = _live(deviceId)?['kwh'];
    return k is num ? k.toDouble() : 0.0;
  }

  Future<void> _setDeviceRelay(String deviceId, bool on) async {
    if (_togglingDevices.contains(deviceId)) return;
    setState(() => _togglingDevices.add(deviceId));
    try {
      await FirebaseDatabase.instance.ref().update({
        'devices/$deviceId/relay': on,
        'buildings/${widget.buildingCode}/floorData/$_selectedFloor/devices/$deviceId/relay':
            on,
      });
    } catch (e) {
      if (mounted) TopToast.error(context, 'Could not switch $deviceId: $e');
    } finally {
      if (mounted) setState(() => _togglingDevices.remove(deviceId));
    }
  }

  void _openDevice(String deviceId, String utility, String room) {
    if (widget.onDeviceTap != null) {
      widget.onDeviceTap!(
          deviceId, utility, widget.buildingCode, room, _selectedFloor);
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
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme(palette: _palette)],
      ),
      child: Builder(builder: (context) {
        return ScreenSkeleton(
          isLoading: _isLoading,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 18, 28, 32),
            child: ResponsiveCenter(
              maxWidth: 1320,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.showBackButton) ...[
                    WebBackLink(
                      onTap: widget.onBack ?? () => Navigator.pop(context),
                    ),
                    const SizedBox(height: 6),
                    _buildHeader(),
                    const SizedBox(height: 22),
                  ],
                  if (widget.embeddedSummaryCard != null) ...[
                    widget.embeddedSummaryCard!,
                    const SizedBox(height: 20),
                  ],
                  if (_errorText != null)
                    _buildLoadError()
                  else ...[
                    Row(children: [
                      Flexible(
                        child: WebTabs<int>(
                          options: {
                            for (var f = 1; f <= widget.floors; f++)
                              f: 'Floor $f'
                          },
                          selected: _selectedFloor,
                          onSelected: _switchFloor,
                        ),
                      ),
                      const Spacer(),
                      if (isAdmin)
                        WebIconButton(
                          icon: Icons.add_rounded,
                          tooltip: 'Add room',
                          solid: true,
                          size: 38,
                          onPressed: _addRoom,
                        ),
                    ]),
                    const SizedBox(height: 18),
                    _buildRoomsGrid(),
                  ],
                ],
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildHeader() {
    final level = WebLevelPill.forMonthKwh(_buildingKwh);
    return Padding(
      // Clear of the shell's floating role badge and bell.
      padding: const EdgeInsets.only(right: 180),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 6,
          children: [
            Text(widget.buildingName,
                style: const TextStyle(
                    fontFamily: AppFonts.family,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: WebColors.ink)),
            WebLevelPill(level),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${widget.floors} ${widget.floors == 1 ? 'floor' : 'floors'} · '
          '$_instituteTotalDevices devices · '
          '${_buildingKwh.toStringAsFixed(1)} kWh this month',
          style: const TextStyle(fontSize: 14, color: WebColors.muted),
        ),
      ]),
    );
  }

  Widget _buildLoadError() {
    return WebCard(
      child: SizedBox(
        width: double.infinity,
        child: Column(children: [
          const SizedBox(height: 24),
          const Icon(Icons.cloud_off_outlined, size: 44, color: WebColors.muted),
          const SizedBox(height: 12),
          const Text('Cannot load this building',
              style: TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: WebColors.ink)),
          const SizedBox(height: 6),
          Text(_errorText ?? 'Something went wrong.',
              style: const TextStyle(fontSize: 14, color: WebColors.muted)),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Retry'),
            style: TextButton.styleFrom(foregroundColor: _palette.dark),
          ),
          const SizedBox(height: 12),
        ]),
      ),
    );
  }

  Widget _buildRoomsGrid() {
    final rooms = _rooms[_selectedFloor] ?? [];
    final loading = rooms.isEmpty && _isLoading;
    final display = loading ? const ['Room 101', 'Room 102', 'Room 103'] : rooms;

    if (display.isEmpty) {
      return WebCard(
        child: SizedBox(
          width: double.infinity,
          child: Text(
            isAdmin
                ? 'No rooms on this floor yet. Use + to add one.'
                : 'No rooms on this floor yet.',
            style: const TextStyle(fontSize: 14, color: WebColors.muted),
          ),
        ),
      );
    }

    return LayoutBuilder(builder: (context, c) {
      const gap = 16.0;
      // Like CSS repeat(auto-fill, minmax(300px, 1fr)).
      final cols = math.max(1, ((c.maxWidth + gap) / (300 + gap)).floor());
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final room in display)
            SizedBox(
              key: ValueKey('room-$room'),
              width: w,
              child: DeleteRowTransition(
                deleting: _deletingRoom == room,
                message: 'Room deleted',
                child: _buildRoomCard(room),
              ),
            ),
        ],
      );
    });
  }

  Widget _buildRoomCard(String room) {
    final devices = _roomDeviceEntries(room);
    final onCount = devices.where((e) => e.value['relay'] == true).length;
    return WebCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text(room,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: AppFonts.family,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: WebColors.ink)),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
                color: _palette.pale.withAlpha(115),
                borderRadius: BorderRadius.circular(8)),
            child: Text('$onCount/${devices.length} on',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _palette.dark)),
          ),
          if (isAdmin) ...[
            const SizedBox(width: 4),
            _ghostIcon(Icons.add_to_queue_rounded, 'Add device',
                () => _addUtility(room)),
            _ghostIcon(Icons.edit_outlined, 'Rename room', () => _editRoom(room)),
            _ghostIcon(Icons.delete_outline_rounded, 'Delete room',
                () => _deleteRoom(room),
                danger: true),
          ],
        ]),
        const SizedBox(height: 6),
        if (devices.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text('No devices yet.',
                style: TextStyle(fontSize: 13, color: WebColors.muted)),
          )
        else
          for (var i = 0; i < devices.length; i++)
            // Plays the delete animation after "Remove device" on the
            // device page brings the user back here.
            ValueListenableBuilder<Set<String>>(
              key: ValueKey('device-${devices[i].key}'),
              valueListenable: pendingRowDeletes,
              builder: (context, pending, _) => DeleteRowTransition(
                deleting: pending.contains('device:${devices[i].key}'),
                message: 'Device removed',
                child: _buildDeviceRow(devices[i].key, devices[i].value, room,
                    first: i == 0),
              ),
            ),
      ]),
    );
  }

  /// Transparent icon button (preview `.ibtn`): tinted only on hover.
  Widget _ghostIcon(IconData icon, String tooltip, VoidCallback onTap,
      {bool danger = false, double size = 32}) {
    final fg = danger ? const Color(0xFFA83434) : _palette.dark;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        hoverColor: danger
            ? const Color(0xFFD64A4A).withAlpha(31)
            : _palette.pale.withAlpha(153),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: size * 0.56, color: fg),
        ),
      ),
    );
  }

  Widget _buildDeviceRow(String deviceId, Map<String, dynamic> device,
      String room,
      {required bool first}) {
    final utility = (device['utility'] ?? '').toString();
    final relay = device['relay'] == true;
    final online = _deviceOnline(deviceId);
    final busy = _togglingDevices.contains(deviceId);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: first
            ? null
            : Border(
                top: BorderSide(color: const Color(0xFF2E9E52).withAlpha(33))),
      ),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
              color: _palette.pale.withAlpha(140),
              borderRadius: BorderRadius.circular(10)),
          child: Icon(_utilityIcon(utility), size: 18, color: _palette.dark),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_utilityLabel(utility),
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: WebColors.ink)),
            Text(deviceId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: WebColors.muted,
                    fontFeatures: [FontFeature.tabularFigures()])),
            Text(
                online
                    ? '${_deviceKwh(deviceId).toStringAsFixed(2)} kWh today'
                    : 'Offline',
                style: const TextStyle(
                    fontSize: 12, height: 1.35, color: WebColors.muted)),
          ]),
        ),
        const SizedBox(width: 10),
        WebSwitch(
          value: relay,
          semanticLabel: '${_utilityLabel(utility)} $room switch',
          onChanged: isAdmin && online && !busy
              ? (v) => _setDeviceRelay(deviceId, v)
              : null,
        ),
        const SizedBox(width: 10),
        Column(mainAxisSize: MainAxisSize.min, children: [
          TextButton(
            onPressed: () => _openDevice(deviceId, utility, room),
            style: TextButton.styleFrom(
              foregroundColor: _palette.dark,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            child: const Text('View'),
          ),
          // Edit / remove live on the device page (View), not on this row.
        ]),
      ]),
    );
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
