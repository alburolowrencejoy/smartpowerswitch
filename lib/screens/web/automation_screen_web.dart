import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/range_calendar.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';

String _isoDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _formatIsoDate(String iso) {
  final parts = iso.split('-');
  if (parts.length != 3) return iso;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (month == null || day == null || month < 1 || month > 12) return iso;
  return '${months[month - 1]} $day, ${parts[0]}';
}

/// Mode-aware toggle used by both the Add Schedule and Edit Schedule
/// dialogs to switch between the weekday-repeat chips and the calendar.
/// Takes [palette] as a parameter (rather than resolving it itself) since
/// this is a bare top-level function with no BuildContext/State of its own
/// to derive it from -- callers pass their already-resolved `_palette`.
Widget _scheduleModeToggle({
  required String scheduleMode,
  required ValueChanged<String> onChanged,
  required InstitutePalette palette,
}) {
  Widget half(String mode, String label, BorderRadius radius) {
    final selected = scheduleMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () => onChanged(mode),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? palette.dark : Colors.transparent,
            borderRadius: radius,
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppColors.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }

  return Container(
    decoration: BoxDecoration(
      border: Border.all(color: palette.mid.withAlpha(51)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(children: [
      half(
          'weekly',
          'Repeat Weekly',
          const BorderRadius.only(
              topLeft: Radius.circular(11), bottomLeft: Radius.circular(11))),
      half(
          'calendar',
          'Specific Date(s)',
          const BorderRadius.only(
              topRight: Radius.circular(11), bottomRight: Radius.circular(11))),
    ]),
  );
}

void _safeDialogPop<T>(BuildContext context, [T? result]) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;
    final nav = Navigator.of(context);
    if (!nav.canPop()) return;
    nav.pop<T>(result);
  });
}

// ─── Model (mirrors automation_screen.dart's AutomationSchedule) ───────────

class WebAutomationSchedule {
  final String id;
  final String name;
  final String scope;
  final String target;
  final String utility;
  final String onTime;
  final String offTime;
  final List<String> days;
  final bool enabled;

  /// 'weekly' (default, day-of-week chips) or 'calendar' (specific date or
  /// date range, no weekday chips). Missing/unrecognized values are treated
  /// as 'weekly' so every schedule written before this feature existed
  /// keeps behaving exactly as it did.
  final String scheduleMode;

  /// 'YYYY-MM-DD'. Only meaningful when [scheduleMode] is 'calendar'.
  /// Equal to [endDate] for a one-time (single-day) schedule.
  final String? startDate;
  final String? endDate;

  bool get isCalendarMode => scheduleMode == 'calendar';

  WebAutomationSchedule({
    required this.id,
    required this.name,
    required this.scope,
    required this.target,
    required this.utility,
    required this.onTime,
    required this.offTime,
    required this.days,
    required this.enabled,
    this.scheduleMode = 'weekly',
    this.startDate,
    this.endDate,
  });

  factory WebAutomationSchedule.fromMap(String id, Map<String, dynamic> data) {
    final rawDays = data['days'];
    List<String> days = [];
    if (rawDays is List) {
      days = rawDays.map((d) => d.toString()).toList();
    } else if (rawDays is Map) {
      days = rawDays.values.map((d) => d.toString()).toList();
    }

    final legacyAction = (data['action'] ?? '').toString().toLowerCase();
    final legacyTime = (data['time'] ?? '').toString();

    var onTime = (data['onTime'] ?? '').toString();
    var offTime = (data['offTime'] ?? '').toString();

    if (onTime.isEmpty && legacyAction == 'on' && legacyTime.isNotEmpty) {
      onTime = legacyTime;
    }
    if (offTime.isEmpty && legacyAction == 'off' && legacyTime.isNotEmpty) {
      offTime = legacyTime;
    }
    if (onTime.isEmpty) onTime = '08:00';
    if (offTime.isEmpty) offTime = '18:00';

    final scheduleMode = (data['scheduleMode'] ?? '').toString() == 'calendar'
        ? 'calendar'
        : 'weekly';
    final startDate = (data['startDate'] as String?)?.trim();
    final endDate = (data['endDate'] as String?)?.trim();

    return WebAutomationSchedule(
      id: id,
      name: (data['name'] ?? '').toString(),
      scope: (data['scope'] ?? 'global').toString(),
      target: (data['target'] ?? 'all').toString(),
      utility: (data['utility'] ?? 'All').toString(),
      onTime: onTime,
      offTime: offTime,
      days: days,
      enabled: data['enabled'] is bool
          ? data['enabled'] as bool
          : (data['enabled'] ?? true).toString().toLowerCase().trim() == 'true',
      scheduleMode: scheduleMode,
      startDate: (startDate != null && startDate.isNotEmpty) ? startDate : null,
      endDate: (endDate != null && endDate.isNotEmpty) ? endDate : null,
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'scope': scope,
        'target': target,
        'utility': utility,
        'onTime': onTime,
        'offTime': offTime,
        'action': 'on',
        'time': onTime,
        'days': days,
        'enabled': enabled,
        'scheduleMode': scheduleMode,
        if (startDate != null) 'startDate': startDate,
        if (endDate != null) 'endDate': endDate,
      };

  /// A single fake schedule, used only while this screen's skeleton
  /// shimmer is showing (see [ScreenSkeleton]).
  factory WebAutomationSchedule.placeholder({String id = 'schedule-0'}) =>
      WebAutomationSchedule(
        id: id,
        name: 'Loading schedule',
        scope: 'global',
        target: 'all',
        utility: 'All',
        onTime: '08:00',
        offTime: '18:00',
        days: const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'],
        enabled: true,
      );

  static List<WebAutomationSchedule> placeholderList([int count = 4]) =>
      List.generate(
        count,
        (i) => WebAutomationSchedule.placeholder(id: 'schedule-$i'),
      );
}

// ─── Device Picker Dialog ─────────────────────────────────────────────────

class _DevicePickerDialog extends StatefulWidget {
  final List<String> buildingList;
  final Map<String, int> buildingFloors;
  final InstitutePalette palette;

  const _DevicePickerDialog({
    required this.buildingList,
    required this.buildingFloors,
    required this.palette,
  });

  @override
  State<_DevicePickerDialog> createState() => _DevicePickerDialogState();
}

// Institute theming: this dialog is opened via `showDialog(context: ctx,
// ...)` with the default `useRootNavigator: true`, so its route (and this
// State's own BuildContext) is inserted at the root Overlay -- it is not a
// descendant of _AutomationScreenWebState's local `Theme(...)` override in
// build(), and `context.institutePalette` can't resolve correctly here.
// Instead of re-deriving the theme inside this State, the caller passes its
// already-resolved `palette` straight through the constructor (matches
// mobile automation_screen.dart's fix for its own file-private
// `_DevicePickerDialog` -- a separate class since Dart's leading-underscore
// privacy is per-file).
class _DevicePickerDialogState extends State<_DevicePickerDialog> {
  String? _selectedBuilding;
  int? _selectedFloor;
  String? _selectedRoom;
  String? _selectedDeviceId;
  String? _selectedDeviceLabel;

  List<String> _rooms = [];
  Map<String, String> _devices = {};

  bool _loadingRooms = false;
  bool _loadingDevices = false;

  List<String> get _buildingList => widget.buildingList;
  Map<String, int> get _buildingFloors => widget.buildingFloors;

  void _onBuildingChanged(String? b) {
    setState(() {
      _selectedBuilding = b;
      _selectedFloor = null;
      _selectedRoom = null;
      _selectedDeviceId = null;
      _selectedDeviceLabel = null;
      _rooms = [];
      _devices = {};
    });
  }

  void _onFloorChanged(int? f) {
    setState(() {
      _selectedFloor = f;
      _selectedRoom = null;
      _selectedDeviceId = null;
      _selectedDeviceLabel = null;
      _rooms = [];
      _devices = {};
    });
    if (_selectedBuilding != null && f != null) {
      _loadRooms(_selectedBuilding!, f);
    }
  }

  Future<void> _loadRooms(String building, int floor) async {
    setState(() => _loadingRooms = true);
    try {
      final snap = await FirebaseDatabase.instance
          .ref('buildings/$building/floorData/$floor/rooms')
          .get();
      List<String> rooms = [];
      if (snap.exists && snap.value != null) {
        final raw = snap.value;
        if (raw is List) {
          rooms = raw.whereType<String>().toList();
        } else if (raw is Map) {
          rooms = raw.values.whereType<String>().toList();
        }
      }
      if (mounted) {
        setState(() {
          _rooms = rooms;
          _loadingRooms = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingRooms = false);
    }
  }

  void _onRoomChanged(String? room) {
    setState(() {
      _selectedRoom = room;
      _selectedDeviceId = null;
      _selectedDeviceLabel = null;
      _devices = {};
    });
    if (_selectedBuilding != null && _selectedFloor != null && room != null) {
      _loadDevices(_selectedBuilding!, _selectedFloor!, room);
    }
  }

  Future<void> _loadDevices(String building, int floor, String room) async {
    setState(() => _loadingDevices = true);
    try {
      final snap = await FirebaseDatabase.instance
          .ref('buildings/$building/floorData/$floor/devices')
          .get();
      final Map<String, String> devices = {};
      if (snap.exists && snap.value is Map) {
        final raw = Map<String, dynamic>.from(snap.value as Map);
        raw.forEach((deviceId, val) {
          if (val is Map) {
            final d = Map<String, dynamic>.from(val);
            final deviceRoom =
                (d['room'] ?? '').toString().trim().toLowerCase();
            if (deviceRoom == room.trim().toLowerCase()) {
              final utility = (d['utility'] ?? 'Unknown').toString();
              devices[deviceId] = '$deviceId · $utility';
            }
          }
        });
      }
      if (mounted) {
        setState(() {
          _devices = devices;
          _loadingDevices = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingDevices = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final floors = _selectedBuilding != null
        ? List.generate(_buildingFloors[_selectedBuilding!] ?? 1, (i) => i + 1)
        : <int>[];

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Select Device',
          style: TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _stepLabel('1', 'Building'),
            const SizedBox(height: 6),
            _buildingList.isEmpty
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: widget.palette.pale,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'No buildings found',
                      style:
                          TextStyle(fontSize: 13, color: AppColors.textMuted),
                    ),
                  )
                : _dropdown<String>(
                    value: _selectedBuilding,
                    hint: 'Select building',
                    items: _buildingList,
                    labelOf: (b) => b,
                    onChanged: _onBuildingChanged,
                  ),
            const SizedBox(height: 14),
            _stepLabel('2', 'Floor'),
            const SizedBox(height: 6),
            _dropdown<int>(
              value: _selectedFloor,
              hint: 'Select floor',
              items: floors,
              labelOf: (f) => 'Floor $f',
              onChanged: _selectedBuilding == null ? null : _onFloorChanged,
            ),
            const SizedBox(height: 14),
            _stepLabel('3', 'Room'),
            const SizedBox(height: 6),
            _loadingRooms
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(color: widget.palette.mid))
                : _dropdown<String>(
                    value: _selectedRoom,
                    hint: _rooms.isEmpty ? 'No rooms found' : 'Select room',
                    items: _rooms,
                    labelOf: (r) => r,
                    onChanged: _rooms.isEmpty ? null : _onRoomChanged,
                  ),
            const SizedBox(height: 14),
            _stepLabel('4', 'Device'),
            const SizedBox(height: 6),
            _loadingDevices
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(color: widget.palette.mid))
                : _devices.isEmpty
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                        decoration: BoxDecoration(
                          color: widget.palette.pale,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _selectedRoom == null
                              ? 'Select a room first'
                              : 'No devices in this room',
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textMuted),
                        ),
                      )
                    : Column(
                        children: _devices.entries.map((e) {
                          final isSelected = _selectedDeviceId == e.key;
                          return GestureDetector(
                            onTap: () => setState(() {
                              _selectedDeviceId = e.key;
                              _selectedDeviceLabel = e.value;
                            }),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? widget.palette.dark
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSelected
                                      ? widget.palette.dark
                                      : widget.palette.mid.withAlpha(60),
                                ),
                              ),
                              child: Row(children: [
                                Icon(Icons.device_hub,
                                    size: 16,
                                    color: isSelected
                                        ? Colors.white
                                        : widget.palette.mid),
                                const SizedBox(width: 10),
                                Expanded(
                                    child: Text(e.value,
                                        style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: isSelected
                                                ? Colors.white
                                                : AppColors.textDark))),
                                if (isSelected)
                                  const Icon(Icons.check_circle,
                                      size: 16, color: Colors.white),
                              ]),
                            ),
                          );
                        }).toList(),
                      ),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => _safeDialogPop(context),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textMuted))),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: widget.palette.dark,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10))),
          onPressed: _selectedDeviceId == null || _selectedDeviceLabel == null
              ? null
              : () => _safeDialogPop(context, <String, String>{
                    'id': _selectedDeviceId!,
                    'label': _selectedDeviceLabel!,
                  }),
          child: const Text('Confirm', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }

  Widget _stepLabel(String step, String label) {
    return Row(children: [
      Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
            color: widget.palette.dark, shape: BoxShape.circle),
        child: Center(
            child: Text(step,
                style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Colors.white))),
      ),
      const SizedBox(width: 8),
      Text(label,
          style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textDark)),
    ]);
  }

  Widget _dropdown<T>({
    required T? value,
    required String hint,
    required List<T> items,
    required String Function(T) labelOf,
    required void Function(T?)? onChanged,
  }) {
    return DropdownButtonFormField<T>(
      initialValue: items.contains(value) ? value : null,
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: widget.palette.mid.withAlpha(51))),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: widget.palette.mid.withAlpha(51))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: widget.palette.mid)),
      ),
      hint: Text(hint,
          style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
      items: items
          .map((i) => DropdownMenuItem<T>(value: i, child: Text(labelOf(i))))
          .toList(),
      onChanged: onChanged,
    );
  }
}

// ─── Automation Screen (desktop grid) ──────────────────────────────────────

/// The desktop "Automation" section: the same schedules, add/edit dialogs,
/// and device picker as [AutomationScreen], with the schedule list laid out
/// as a card grid instead of a stacked column and the FAB replaced by a
/// header button. Independent Firebase listeners from the mobile screen, so
/// [AutomationScreen] itself is never touched.
class AutomationScreenWeb extends StatefulWidget {
  final String role;
  const AutomationScreenWeb({super.key, this.role = 'faculty'});

  @override
  State<AutomationScreenWeb> createState() => _AutomationScreenWebState();
}

class _AutomationScreenWebState extends State<AutomationScreenWeb> {
  List<WebAutomationSchedule> _schedules = [];

  /// True until the combined buildings+automations stream's first
  /// emission. Never reverts to true afterwards -- a fresh instance of
  /// this screen is the only legitimate reset. Drives both the screen's
  /// skeleton shimmer and [_loadingBuildings] (the Add Schedule dialog's
  /// building-dropdown spinner, which mirrors the same buildings stream).
  bool _isLoading = true;
  bool get _loadingBuildings => _isLoading;
  StreamSubscription<List<DatabaseEvent>>? _combinedSub;
  String? _errorText;

  bool get isAdmin =>
      widget.role == 'admin' ||
      widget.role == 'main_admin' ||
      widget.role == 'super_admin' ||
      widget.role == 'institute_admin';

  static const List<String> _allDays = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun'
  ];
  static const List<String> _utilities = ['All', 'Lights', 'Outlets', 'AC'];

  List<String> _buildings = [];
  Map<String, int> _buildingFloors = {};

  // ── Institute theming ──────────────────────────────────────────────────
  // `widget.role` is already passed in by dashboard_web.dart (the only
  // caller -- see AutomationScreenWeb(role: _role) there), but no institute
  // is threaded through, so it's hydrated here directly from the signed-in
  // user's own record, mirroring mobile automation_screen.dart's
  // _hydrateInstitute.
  String? _institute;

  InstitutePalette get _palette =>
      InstituteTheme.resolve(widget.role, _institute).palette;

  Future<void> _hydrateInstitute() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final snap =
          await FirebaseDatabase.instance.ref('users/${user.uid}').get();
      final data = snap.value;
      if (data is! Map) return;
      final map = Map<String, dynamic>.from(data);
      final institute = (map['institute'] as String?)?.trim();
      if (!mounted) return;
      setState(() => _institute = institute);
    } catch (_) {
      // Keep the green default if institute hydration fails.
    }
  }

  @override
  void initState() {
    super.initState();
    _hydrateInstitute();
    _listenAll();
  }

  @override
  void dispose() {
    _combinedSub?.cancel();
    super.dispose();
  }

  /// Combines this screen's 2 screen-level Firebase streams (buildings,
  /// automations) into one subscription with a sticky merge, so a
  /// transient null/empty snapshot never blanks data that already loaded
  /// once. The device-picker dialog's own `_loadingRooms`/`_loadingDevices`
  /// state is unrelated and untouched.
  void _listenAll() {
    _combinedSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('buildings').onValue,
      FirebaseDatabase.instance.ref('automations').onValue,
    ]).listen((events) {
      if (!mounted) return;
      setState(() {
        _applyBuildings(events[0].snapshot.value);
        _applySchedules(events[1].snapshot.value);
        _isLoading = false;
        _errorText = null;
      });
    }, onError: (Object error) {
      if (!mounted) return;
      final denied = error.toString().toLowerCase().contains('permission');
      setState(() {
        _isLoading = false;
        _errorText = denied
            ? 'You do not have permission to view automations.'
            : 'Failed to load automations.';
      });
    });
  }

  void _applyBuildings(Object? raw) {
    if (raw is Map) {
      final list = <String>[];
      final floors = <String, int>{};
      final map = Map<String, dynamic>.from(raw);
      for (final entry in map.entries) {
        final buildingCode = entry.key.toString();
        if (entry.value is Map) {
          final data = Map<String, dynamic>.from(entry.value as Map);
          final floorCount = (data['floors'] as num?)?.toInt() ?? 1;
          list.add(buildingCode);
          floors[buildingCode] = floorCount < 1 ? 1 : floorCount;
        }
      }
      list.sort();
      _buildings = list;
      _buildingFloors = floors;
    } else if (_isLoading) {
      _buildings = [];
      _buildingFloors = {};
    }
  }

  void _applySchedules(Object? raw) {
    if (raw is Map) {
      final List<WebAutomationSchedule> list = [];
      raw.forEach((id, val) {
        if (val is Map) {
          list.add(WebAutomationSchedule.fromMap(
              id.toString(), Map<String, dynamic>.from(val)));
        }
      });
      list.sort((a, b) => a.onTime.compareTo(b.onTime));
      _schedules = list;
    } else if (_isLoading) {
      _schedules = [];
    }
  }

  Future<void> _toggleEnabled(WebAutomationSchedule s) async {
    try {
      await FirebaseDatabase.instance
          .ref('automations/${s.id}/enabled')
          .set(!s.enabled);
    } catch (_) {
      if (!mounted) return;
      TopToast.show(context, 'Unable to update schedule.', isError: true);
    }
  }

  Future<void> _deleteSchedule(WebAutomationSchedule s) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Schedule',
            style:
                TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
        content: Text('Delete "${s.name}"?'),
        actions: [
          TextButton(
              onPressed: () => _safeDialogPop(dialogCtx, false),
              child: const Text('Cancel',
                  style: TextStyle(color: AppColors.textMuted))),
          ElevatedButton(
            onPressed: () => _safeDialogPop(dialogCtx, true),
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
    try {
      await FirebaseDatabase.instance.ref('automations/${s.id}').remove();
    } catch (_) {
      if (!mounted) return;
      TopToast.show(context, 'Unable to delete schedule.', isError: true);
    }
  }

  Future<void> _addSchedule() async {
    final nameCtrl = TextEditingController();
    String scope = 'global';
    String target = 'all';
    String deviceLabel = '';
    String utility = 'All';
    TimeOfDay onTime = const TimeOfDay(hour: 8, minute: 0);
    TimeOfDay offTime = const TimeOfDay(hour: 18, minute: 0);
    List<String> days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'];
    String scheduleMode = 'weekly';
    DateTime? calendarDay;
    DateTimeRange? calendarRange;
    bool calendarDragActive = false;
    String? error;
    bool loading = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Add Schedule',
              style:
                  TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              // Disabled while drag-selecting a calendar range so this
              // scroll view's own drag recognizer doesn't compete with
              // and swallow the calendar's long-press-drag.
              physics: calendarDragActive
                  ? const NeverScrollableScrollPhysics()
                  : null,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: nameCtrl,
                  decoration: _inputDeco('Schedule name', Icons.label_outline),
                  autofocus: true,
                ),
                const SizedBox(height: 14),
                _dropdownField(
                    'Scope',
                    scope,
                    ['global', 'building', 'utility', 'device'],
                    (v) => setS(() {
                          scope = v!;
                          target = 'all';
                          deviceLabel = '';
                        })),
                const SizedBox(height: 12),
                if (scope == 'building') ...[
                  _loadingBuildings
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child:
                              LinearProgressIndicator(color: _palette.mid),
                        )
                      : _dropdownField(
                          'Building',
                          _buildings.isEmpty
                              ? target
                              : (_buildings.contains(target)
                                  ? target
                                  : _buildings.first),
                          _buildings,
                          (v) => setS(() => target = v!),
                        ),
                  const SizedBox(height: 12),
                ],
                if (scope == 'utility') ...[
                  _dropdownField(
                      'Utility',
                      target == 'all' ? 'Lights' : target,
                      ['Lights', 'Outlets', 'AC'],
                      (v) => setS(() => target = v!)),
                  const SizedBox(height: 12),
                ],
                if (scope == 'device') ...[
                  GestureDetector(
                    onTap: () async {
                      final result = await showDialog<Map<String, String>>(
                        context: ctx,
                        builder: (_) => _DevicePickerDialog(
                          buildingList: _buildings,
                          buildingFloors: _buildingFloors,
                          palette: _palette,
                        ),
                      );
                      if (result != null) {
                        setS(() {
                          target = result['id']!;
                          deviceLabel = result['label']!;
                        });
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 14),
                      decoration: BoxDecoration(
                        border: Border.all(color: _palette.mid.withAlpha(80)),
                        borderRadius: BorderRadius.circular(12),
                        color: Colors.white,
                      ),
                      child: Row(children: [
                        const Icon(Icons.device_hub,
                            size: 18, color: AppColors.textMuted),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            deviceLabel.isEmpty
                                ? 'Click to pick a device'
                                : deviceLabel,
                            style: TextStyle(
                                fontSize: 13,
                                color: deviceLabel.isEmpty
                                    ? AppColors.textMuted
                                    : AppColors.textDark),
                          ),
                        ),
                        const Icon(Icons.chevron_right,
                            color: AppColors.textMuted, size: 18),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (scope != 'utility') ...[
                  _dropdownField('Utility to control', utility, _utilities,
                      (v) => setS(() => utility = v!)),
                  const SizedBox(height: 12),
                ],
                // Semantic: paired against AppColors.warning for the "OFF
                // time" tile directly below -- communicates ON vs OFF, not
                // brand chrome. Deliberately NOT retheme'd (matches mobile
                // automation_screen.dart).
                _timePickerTile(
                  context: ctx,
                  label: 'ON time',
                  value: onTime,
                  icon: Icons.power_settings_new,
                  iconColor: AppColors.greenMid,
                  onPicked: (v) => setS(() => onTime = v),
                ),
                const SizedBox(height: 10),
                _timePickerTile(
                  context: ctx,
                  label: 'OFF time',
                  value: offTime,
                  icon: Icons.power_off_outlined,
                  iconColor: AppColors.warning,
                  onPicked: (v) => setS(() => offTime = v),
                ),
                const SizedBox(height: 12),
                _scheduleModeToggle(
                  scheduleMode: scheduleMode,
                  onChanged: (v) => setS(() => scheduleMode = v),
                  palette: _palette,
                ),
                const SizedBox(height: 12),
                if (scheduleMode == 'weekly') ...[
                  const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Repeat on',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                              fontWeight: FontWeight.w500))),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _allDays.map((d) {
                      final selected = days.contains(d);
                      return GestureDetector(
                        onTap: () => setS(() {
                          if (selected) {
                            days.remove(d);
                          } else {
                            days.add(d);
                          }
                        }),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: selected ? _palette.dark : _palette.pale,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(d,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: selected
                                      ? Colors.white
                                      : AppColors.textMid)),
                        ),
                      );
                    }).toList(),
                  ),
                ] else ...[
                  const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Pick a date, or drag for a range',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                              fontWeight: FontWeight.w500))),
                  const SizedBox(height: 6),
                  RangeCalendar(
                    onDaySelected: (d) => setS(() => calendarDay = d),
                    onRangeChanged: (r) => setS(() => calendarRange = r),
                    onDragActiveChanged: (active) =>
                        setS(() => calendarDragActive = active),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.error)),
                ],
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => _safeDialogPop(ctx),
                child: const Text('Cancel',
                    style: TextStyle(color: AppColors.textMuted))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: _palette.dark,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              onPressed: loading
                  ? null
                  : () async {
                      final name = nameCtrl.text.trim();
                      if (name.isEmpty) {
                        setS(() => error = 'Name is required');
                        return;
                      }
                      if (scheduleMode == 'weekly' && days.isEmpty) {
                        setS(() => error = 'Select at least one day');
                        return;
                      }
                      String? startDateStr;
                      String? endDateStr;
                      if (scheduleMode == 'calendar') {
                        if (calendarRange != null) {
                          startDateStr = _isoDate(calendarRange!.start);
                          endDateStr = _isoDate(calendarRange!.end);
                        } else if (calendarDay != null) {
                          startDateStr = _isoDate(calendarDay!);
                          endDateStr = startDateStr;
                        } else {
                          setS(() => error = 'Pick a date on the calendar');
                          return;
                        }
                      }
                      if (scope == 'device' && target == 'all') {
                        setS(() => error = 'Please select a device');
                        return;
                      }
                      if (scope == 'building' && !_buildings.contains(target)) {
                        setS(() => error = 'Please select a building');
                        return;
                      }

                      final finalTarget = scope == 'global'
                          ? 'all'
                          : scope == 'utility'
                              ? target
                              : target;
                      final finalUtility =
                          scope == 'utility' ? target : utility;
                      final onTimeStr =
                          '${onTime.hour.toString().padLeft(2, '0')}:${onTime.minute.toString().padLeft(2, '0')}';
                      final offTimeStr =
                          '${offTime.hour.toString().padLeft(2, '0')}:${offTime.minute.toString().padLeft(2, '0')}';
                      if (onTimeStr == offTimeStr) {
                        setS(() => error = 'ON and OFF time must be different');
                        return;
                      }

                      setS(() {
                        loading = true;
                        error = null;
                      });

                      final newRef =
                          FirebaseDatabase.instance.ref('automations').push();
                      try {
                        await newRef.set(WebAutomationSchedule(
                          id: newRef.key!,
                          name: name,
                          scope: scope,
                          target: finalTarget,
                          utility: finalUtility,
                          onTime: onTimeStr,
                          offTime: offTimeStr,
                          days: scheduleMode == 'weekly' ? days : const [],
                          enabled: true,
                          scheduleMode: scheduleMode,
                          startDate: startDateStr,
                          endDate: endDateStr,
                        ).toMap());
                      } catch (_) {
                        setS(() {
                          loading = false;
                          error = 'No permission to add schedules.';
                        });
                        return;
                      }

                      if (!mounted || !ctx.mounted) return;
                      _safeDialogPop(ctx);
                      TopToast.show(context, 'Schedule added.');
                    },
              child: loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Text('Save', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  TimeOfDay _parseTime(String value, {required TimeOfDay fallback}) {
    final parts = value.split(':');
    if (parts.length != 2) return fallback;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return fallback;
    }
    return TimeOfDay(hour: h, minute: m);
  }

  DateTime? _parseIsoDate(String? iso) {
    if (iso == null || iso.isEmpty) return null;
    final parts = iso.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  Future<void> _editScheduleTiming(WebAutomationSchedule s) async {
    TimeOfDay onTime =
        _parseTime(s.onTime, fallback: const TimeOfDay(hour: 8, minute: 0));
    TimeOfDay offTime =
        _parseTime(s.offTime, fallback: const TimeOfDay(hour: 18, minute: 0));
    List<String> days = [...s.days];
    if (days.isEmpty) {
      days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'];
    }
    final startDate = _parseIsoDate(s.startDate);
    final endDate = _parseIsoDate(s.endDate);
    DateTime? calendarDay =
        (startDate != null && endDate != null && startDate == endDate)
            ? startDate
            : null;
    DateTimeRange? calendarRange =
        (startDate != null && endDate != null && startDate != endDate)
            ? DateTimeRange(start: startDate, end: endDate)
            : null;
    bool calendarDragActive = false;
    String? error;
    bool loading = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Edit Schedule Time & Days',
              style:
                  TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              physics: calendarDragActive
                  ? const NeverScrollableScrollPhysics()
                  : null,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.name,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textDark)),
                  const SizedBox(height: 4),
                  Text('Settings are locked: ${_scopeLabel(s)} · ${s.utility}',
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textMuted)),
                  const SizedBox(height: 12),
                  // Semantic: paired against AppColors.warning for the "OFF
                  // time" tile directly below -- deliberately NOT retheme'd
                  // (matches mobile automation_screen.dart).
                  _timePickerTile(
                    context: ctx,
                    label: 'ON time',
                    value: onTime,
                    icon: Icons.power_settings_new,
                    iconColor: AppColors.greenMid,
                    onPicked: (v) => setS(() => onTime = v),
                  ),
                  const SizedBox(height: 10),
                  _timePickerTile(
                    context: ctx,
                    label: 'OFF time',
                    value: offTime,
                    icon: Icons.power_off_outlined,
                    iconColor: AppColors.warning,
                    onPicked: (v) => setS(() => offTime = v),
                  ),
                  const SizedBox(height: 12),
                  if (!s.isCalendarMode) ...[
                    const Text('Repeat on',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textMuted,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _allDays.map((d) {
                        final selected = days.contains(d);
                        return GestureDetector(
                          onTap: () => setS(() {
                            if (selected) {
                              days.remove(d);
                            } else {
                              days.add(d);
                            }
                          }),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: selected ? _palette.dark : _palette.pale,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(d,
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: selected
                                        ? Colors.white
                                        : AppColors.textMid)),
                          ),
                        );
                      }).toList(),
                    ),
                  ] else ...[
                    const Text('Date(s)',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textMuted,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 6),
                    RangeCalendar(
                      onDaySelected: (d) => setS(() => calendarDay = d),
                      onRangeChanged: (r) => setS(() => calendarRange = r),
                      onDragActiveChanged: (active) =>
                          setS(() => calendarDragActive = active),
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(error!,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.error)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => _safeDialogPop(ctx),
                child: const Text('Cancel',
                    style: TextStyle(color: AppColors.textMuted))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: _palette.dark,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              onPressed: loading
                  ? null
                  : () async {
                      String? startDateStr;
                      String? endDateStr;
                      if (s.isCalendarMode) {
                        if (calendarRange != null) {
                          startDateStr = _isoDate(calendarRange!.start);
                          endDateStr = _isoDate(calendarRange!.end);
                        } else if (calendarDay != null) {
                          startDateStr = _isoDate(calendarDay!);
                          endDateStr = startDateStr;
                        } else {
                          setS(() => error = 'Pick a date on the calendar');
                          return;
                        }
                      } else if (days.isEmpty) {
                        setS(() => error = 'Select at least one day');
                        return;
                      }

                      final onTimeStr =
                          '${onTime.hour.toString().padLeft(2, '0')}:${onTime.minute.toString().padLeft(2, '0')}';
                      final offTimeStr =
                          '${offTime.hour.toString().padLeft(2, '0')}:${offTime.minute.toString().padLeft(2, '0')}';
                      if (onTimeStr == offTimeStr) {
                        setS(() => error = 'ON and OFF time must be different');
                        return;
                      }

                      setS(() {
                        loading = true;
                        error = null;
                      });

                      try {
                        await FirebaseDatabase.instance
                            .ref('automations/${s.id}')
                            .update({
                          'onTime': onTimeStr,
                          'offTime': offTimeStr,
                          'action': 'on',
                          'time': onTimeStr,
                          if (s.isCalendarMode) 'startDate': startDateStr,
                          if (s.isCalendarMode) 'endDate': endDateStr,
                          if (!s.isCalendarMode) 'days': days,
                        });
                      } catch (_) {
                        setS(() {
                          loading = false;
                          error = 'Unable to update schedule timing.';
                        });
                        return;
                      }

                      if (!mounted || !ctx.mounted) return;
                      _safeDialogPop(ctx);
                      TopToast.show(context, 'Schedule updated.');
                    },
              child: loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Text('Save', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  // ── Build (desktop grid layout) ───────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final schedulesLoading = _schedules.isEmpty && _isLoading;
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(widget.role, _institute)],
      ),
      child: ScreenSkeleton(
      isLoading: _isLoading,
      child: SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Automation',
                        style: TextStyle(
                            fontFamily: 'Outfit',
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textDark)),
                    SizedBox(height: 4),
                    Text('Scheduled ON/OFF rules for buildings and devices',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textMuted)),
                  ],
                ),
              ),
              if (isAdmin)
                ElevatedButton.icon(
                  onPressed: _addSchedule,
                  icon: const Icon(Icons.add, color: Colors.white, size: 18),
                  label: const Text('Add Schedule',
                      style: TextStyle(color: Colors.white)),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: _palette.dark,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                ),
            ],
          ),
          const SizedBox(height: 24),
          if (schedulesLoading)
            _buildGroupedGrid(WebAutomationSchedule.placeholderList())
          else if (_errorText != null)
            _buildError()
          else if (_schedules.isEmpty)
            _buildEmpty()
          else
            _buildGroupedGrid(_schedules),
        ],
      ),
      ),
      ),
    );
  }

  Widget _buildError() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                  color: _palette.pale,
                  borderRadius: BorderRadius.circular(20)),
              child: Icon(Icons.lock_outline, size: 34, color: _palette.mid)),
          const SizedBox(height: 16),
          const Text('Cannot load automations',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark)),
          const SizedBox(height: 8),
          Text(_errorText ?? 'Something went wrong.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
        ]),
      ),
    );
  }

  Widget _buildEmpty() {
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
          Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                  color: _palette.pale,
                  borderRadius: BorderRadius.circular(20)),
              child:
                  Icon(Icons.schedule, size: 36, color: _palette.dark)),
          const SizedBox(height: 16),
          const Text('No schedules yet',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textDark)),
          const SizedBox(height: 6),
          Text(
              isAdmin
                  ? 'Click + Add Schedule to create one'
                  : 'No automation schedules set',
              style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
        ]),
      ),
    );
  }

  Widget _buildGroupedGrid(List<WebAutomationSchedule> schedules) {
    final global = schedules.where((s) => s.scope == 'global').toList();
    final building = schedules.where((s) => s.scope == 'building').toList();
    final utility = schedules.where((s) => s.scope == 'utility').toList();
    final device = schedules.where((s) => s.scope == 'device').toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (global.isNotEmpty) ...[
        _sectionHeader('🌐 Global', global.length),
        const SizedBox(height: 12),
        _cardWrap(global),
        const SizedBox(height: 24)
      ],
      if (building.isNotEmpty) ...[
        _sectionHeader('🏫 Building', building.length),
        const SizedBox(height: 12),
        _cardWrap(building),
        const SizedBox(height: 24)
      ],
      if (utility.isNotEmpty) ...[
        _sectionHeader('⚡ Utility', utility.length),
        const SizedBox(height: 12),
        _cardWrap(utility),
        const SizedBox(height: 24)
      ],
      if (device.isNotEmpty) ...[
        _sectionHeader('📟 Device', device.length),
        const SizedBox(height: 12),
        _cardWrap(device),
        const SizedBox(height: 24)
      ],
    ]);
  }

  Widget _cardWrap(List<WebAutomationSchedule> items) {
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children:
          items.map((s) => SizedBox(width: 380, child: _buildCard(s))).toList(),
    );
  }

  Widget _sectionHeader(String title, int count) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 6,
      children: [
        Text(title,
            style: const TextStyle(
                fontFamily: 'Outfit',
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.textDark)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
              color: _palette.pale, borderRadius: BorderRadius.circular(20)),
          child: Text('$count',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _palette.dark)),
        ),
      ],
    );
  }

  Widget _buildCard(WebAutomationSchedule s) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        // Semantic: emphasis tied to s.enabled (this schedule is currently
        // active vs. disabled), same enabled/disabled state this card's
        // Switch below communicates -- deliberately NOT retheme'd (matches
        // mobile automation_screen.dart).
        border: Border.all(
            color: s.enabled
                ? AppColors.greenMid.withAlpha(60)
                : AppColors.greenMid.withAlpha(20)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: _palette.mid.withAlpha(20),
                  borderRadius: BorderRadius.circular(12)),
              child: Icon(Icons.schedule, color: _palette.mid, size: 20)),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: 'Outfit',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark)),
                const SizedBox(height: 2),
                Text(_scopeLabel(s),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textMuted)),
              ])),
          if (isAdmin)
            // Semantic: communicates "this automation rule is currently
            // active" -- deliberately NOT retheme'd (matches mobile
            // automation_screen.dart).
            Switch(
                value: s.enabled,
                activeThumbColor: AppColors.greenMid,
                onChanged: (_) => _toggleEnabled(s)),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          // Semantic: ON chip paired against the OFF chip's AppColors.warning
          // immediately below -- deliberately NOT retheme'd.
          _chip(Icons.power_settings_new, 'ON ${s.onTime}', AppColors.greenMid),
          _chip(
              Icons.power_off_outlined, 'OFF ${s.offTime}', AppColors.warning),
          _chip(Icons.electrical_services, s.utility, _palette.mid),
        ]),
        const SizedBox(height: 8),
        if (s.isCalendarMode)
          _chip(Icons.calendar_month, _calendarDateLabel(s), _palette.dark)
        else
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: _allDays.map((d) {
              final active = s.days.contains(d);
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: active ? _palette.dark : _palette.pale,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(d,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: active ? Colors.white : AppColors.textMuted)),
              );
            }).toList(),
          ),
        if (isAdmin) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              GestureDetector(
                onTap: () => _editScheduleTiming(s),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                      color: _palette.pale,
                      borderRadius: BorderRadius.circular(8)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.edit_outlined,
                        size: 14, color: _palette.dark),
                    const SizedBox(width: 4),
                    Text('Edit time/days',
                        style: TextStyle(
                            fontSize: 11,
                            color: _palette.dark,
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _deleteSchedule(s),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                      color: AppColors.error.withAlpha(15),
                      borderRadius: BorderRadius.circular(8)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.delete_outline,
                        size: 14, color: AppColors.error),
                    SizedBox(width: 4),
                    Text('Delete',
                        style: TextStyle(
                            fontSize: 11,
                            color: AppColors.error,
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _chip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(40)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }

  String _calendarDateLabel(WebAutomationSchedule s) {
    final start = s.startDate;
    final end = s.endDate;
    if (start == null) return 'No date set';
    if (end == null || end == start) return _formatIsoDate(start);
    return '${_formatIsoDate(start)} – ${_formatIsoDate(end)}';
  }

  String _scopeLabel(WebAutomationSchedule s) {
    switch (s.scope) {
      case 'global':
        return 'All buildings · all utilities';
      case 'building':
        return 'Building: ${s.target}';
      case 'utility':
        return 'Utility: ${s.target}';
      case 'device':
        return 'Device: ${s.target}';
      default:
        return s.scope;
    }
  }

  Widget _timePickerTile({
    required BuildContext context,
    required String label,
    required TimeOfDay value,
    required IconData icon,
    required Color iconColor,
    required void Function(TimeOfDay value) onPicked,
  }) {
    return GestureDetector(
      onTap: () async {
        final picked =
            await showTimePicker(context: context, initialTime: value);
        if (picked != null) onPicked(picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: _palette.mid.withAlpha(80)),
          borderRadius: BorderRadius.circular(12),
          color: Colors.white,
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 10),
          Text(label,
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          const Spacer(),
          Text(value.format(context),
              style: const TextStyle(fontSize: 14, color: AppColors.textDark)),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, color: AppColors.textMuted, size: 18),
        ]),
      ),
    );
  }

  Widget _dropdownField(String label, String value, List<String> items,
      void Function(String?) onChanged) {
    return DropdownButtonFormField<String>(
      initialValue: items.contains(value) ? value : items.first,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 12, color: AppColors.textMuted),
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: _palette.mid.withAlpha(51))),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: _palette.mid.withAlpha(51))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: _palette.mid)),
      ),
      items:
          items.map((i) => DropdownMenuItem(value: i, child: Text(i))).toList(),
      onChanged: onChanged,
    );
  }

  InputDecoration _inputDeco(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
      prefixIcon: Icon(icon, size: 18, color: AppColors.textMuted),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _palette.mid.withAlpha(51))),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _palette.mid.withAlpha(51))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _palette.mid)),
    );
  }
}
