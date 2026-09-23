import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import '../../theme/app_colors.dart';
import '../../services/schedule_windows.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/range_calendar.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import 'web_theme.dart';
import 'web_widgets.dart';

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
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : WebColors.muted,
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

  /// Several ON windows (see services/schedule_windows.dart). Empty for
  /// schedules saved before windows existed, which use [onTime]/[offTime].
  final List<ScheduleWindow> windows;

  bool get isCalendarMode => scheduleMode == 'calendar';

  /// [windows], or the single [onTime]/[offTime] pair as one window. The
  /// conversion is exact: OFF at [offTime] == ON until one minute before.
  List<ScheduleWindow> get effectiveWindows {
    if (windows.isNotEmpty) return windows;
    final on = parseHm(onTime);
    final off = parseHm(offTime);
    if (on == null || off == null) return const [];
    return [ScheduleWindow(on, (off - 1 + 24 * 60) % (24 * 60))];
  }

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
    this.windows = const [],
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
      windows: ScheduleWindow.listFrom(data['windows']),
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
        if (windows.isNotEmpty) 'windows': [for (final w in windows) w.toMap()],
      };

  /// The timing fields written for [windows]: the list itself plus the
  /// first window as `onTime`/`offTime` (and the legacy `time`), so the
  /// mobile screen and older app versions keep running that window.
  static Map<String, dynamic> timingFields(List<ScheduleWindow> windows) {
    final first = windows.first;
    return {
      'windows': [for (final w in windows) w.toMap()],
      'onTime': first.onLabel,
      'offTime': first.offLabel,
      'action': 'on',
      'time': first.onLabel,
    };
  }

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
                          TextStyle(fontSize: 14, color: WebColors.muted),
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
                              fontSize: 14, color: WebColors.muted),
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
                                            fontSize: 13,
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
                style: TextStyle(color: WebColors.muted))),
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
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.white))),
      ),
      const SizedBox(width: 8),
      Text(label,
          style: const TextStyle(
              fontSize: 13,
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
          style: const TextStyle(fontSize: 14, color: WebColors.muted)),
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
// ─── Schedule form (add + edit) ────────────────────────────────────────────

/// Add Schedule (every field) or Edit Schedule (timing and days only; the
/// scope, target and utility stay locked, as before). Each invalid field
/// shows its own message with a red border and a shake. Resolves to `true`
/// once saved.
class _ScheduleFormDialog extends StatefulWidget {
  final InstitutePalette palette;
  final List<String> buildings;
  final Map<String, int> buildingFloors;
  final bool loadingBuildings;
  final WebAutomationSchedule? existing;

  const _ScheduleFormDialog({
    required this.palette,
    required this.buildings,
    required this.buildingFloors,
    required this.loadingBuildings,
    this.existing,
  });

  @override
  State<_ScheduleFormDialog> createState() => _ScheduleFormDialogState();
}

class _WindowDraft {
  TimeOfDay? on;
  TimeOfDay? until;
  _WindowDraft(this.on, this.until);

  ScheduleWindow? get window => on == null || until == null
      ? null
      : ScheduleWindow(on!.hour * 60 + on!.minute,
          until!.hour * 60 + until!.minute);
}

class _ScheduleFormDialogState extends State<_ScheduleFormDialog> {
  static const _allDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _utilities = ['All', 'Lights', 'Outlets', 'AC'];

  final _nameCtrl = TextEditingController();
  String _scope = 'global';
  String _target = 'all';
  String _deviceLabel = '';
  String _utility = 'All';
  late final List<_WindowDraft> _windows;
  List<String> _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'];
  String _mode = 'weekly';
  DateTime? _day;
  DateTimeRange? _range;
  bool _dragActive = false;
  bool _saving = false;

  /// Field id -> message. Window rows use 'w0', 'w1', ...; 'windows' is a
  /// problem with the set as a whole; '' is a save error.
  Map<String, String> _errors = {};
  int _shake = 0;

  bool get _isEdit => widget.existing != null;
  InstitutePalette get _p => widget.palette;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    if (s == null) {
      _windows = [
        _WindowDraft(const TimeOfDay(hour: 8, minute: 0),
            const TimeOfDay(hour: 17, minute: 59)),
      ];
      return;
    }
    _nameCtrl.text = s.name;
    _scope = s.scope;
    _target = s.target;
    _utility = s.utility;
    _windows = [
      for (final w in s.effectiveWindows)
        _WindowDraft(TimeOfDay(hour: w.on ~/ 60, minute: w.on % 60),
            TimeOfDay(hour: w.until ~/ 60, minute: w.until % 60)),
    ];
    if (_windows.isEmpty) _windows.add(_WindowDraft(null, null));
    _mode = s.scheduleMode;
    if (s.days.isNotEmpty) _days = [...s.days];
    final start = _parseIso(s.startDate);
    final end = _parseIso(s.endDate);
    if (start != null && end != null && start != end) {
      _range = DateTimeRange(start: start, end: end);
    } else {
      _day = start;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  static DateTime? _parseIso(String? iso) {
    final parts = (iso ?? '').split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  void _clear(String key) {
    if (_errors.containsKey(key)) setState(() => _errors.remove(key));
  }

  Map<String, String> _validate() {
    final e = <String, String>{};
    if (!_isEdit) {
      if (_nameCtrl.text.trim().isEmpty) e['name'] = 'Schedule name is required.';
      if (_scope == 'building' && !widget.buildings.contains(_target)) {
        e['target'] = 'Pick a building.';
      }
      if (_scope == 'device' && _target == 'all') {
        e['target'] = 'Pick a device.';
      }
    }
    final werr = validateWindows([for (final w in _windows) w.window]);
    werr.forEach((i, msg) => e[i < 0 ? 'windows' : 'w$i'] = msg);
    if (_mode == 'weekly' && _days.isEmpty) {
      e['days'] = 'Select at least one day.';
    }
    if (_mode == 'calendar' && _day == null && _range == null) {
      e['days'] = 'Pick a date on the calendar.';
    }
    return e;
  }

  Future<void> _save() async {
    final errs = _validate();
    if (errs.isNotEmpty) {
      setState(() {
        _errors = errs;
        _shake++;
      });
      return;
    }
    setState(() {
      _saving = true;
      _errors = {};
    });

    final windows = [for (final w in _windows) w.window!];
    String? startDate;
    String? endDate;
    if (_mode == 'calendar') {
      startDate = _isoDate(_range?.start ?? _day!);
      endDate = _isoDate(_range?.end ?? _day!);
    }
    final timing = {
      ...WebAutomationSchedule.timingFields(windows),
      'scheduleMode': _mode,
      'days': _mode == 'weekly' ? _days : <String>[],
      'startDate': startDate,
      'endDate': endDate,
    };

    try {
      if (_isEdit) {
        await FirebaseDatabase.instance
            .ref('automations/${widget.existing!.id}')
            .update(timing);
      } else {
        final ref = FirebaseDatabase.instance.ref('automations').push();
        await ref.set({
          'name': _nameCtrl.text.trim(),
          'scope': _scope,
          'target': _scope == 'global' ? 'all' : _target,
          'utility': _scope == 'utility' ? _target : _utility,
          'enabled': true,
          ...timing,
        }..removeWhere((_, v) => v == null));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errors = {
          '': e.toString().toLowerCase().contains('permission')
              ? 'You do not have permission to change schedules.'
              : 'Could not save the schedule. Try again.'
        };
        _shake++;
      });
      return;
    }
    if (mounted) Navigator.pop(context, true);
  }

  // ── Build ──────────────────────────────────────────────────────────────

  Widget _shaking(String key, Widget child) =>
      ShakeOnChange(trigger: _errors.containsKey(key) ? _shake : 0, child: child);

  Widget _errorText(String key) {
    final msg = _errors[key];
    if (msg == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 4),
      child: Text(msg,
          style: const TextStyle(fontSize: 12.5, color: AppColors.error)),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: WebColors.mid)),
      );

  @override
  Widget build(BuildContext context) {
    final s = widget.existing;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_isEdit ? 'Edit schedule' : 'Add schedule',
            style: const TextStyle(
                fontFamily: 'Outfit',
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: WebColors.ink)),
        if (s != null) ...[
          const SizedBox(height: 4),
          Text('${s.name} · ${_scopeText(s)} · ${s.utility}',
              style: const TextStyle(fontSize: 13.5, color: WebColors.muted)),
        ],
      ]),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          // Off while drag-selecting dates, so the scroll view doesn't
          // swallow the calendar's drag.
          physics: _dragActive ? const NeverScrollableScrollPhysics() : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_isEdit) ..._targetFields(),
              _label('Time windows'),
              for (var i = 0; i < _windows.length; i++) _windowRow(i),
              _shaking('windows', _errorText('windows')),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _windows.length >= 6
                      ? null
                      : () => setState(() {
                            _windows.add(_WindowDraft(null, null));
                            _errors.remove('windows');
                          }),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add time window'),
                  style: TextButton.styleFrom(foregroundColor: _p.dark),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 14),
                child: Text(
                    'Devices turn ON at the start and OFF one minute after the '
                    'end time. A window may run past midnight.',
                    style: TextStyle(fontSize: 12.5, color: WebColors.muted)),
              ),
              if (!_isEdit) ...[
                _scheduleModeToggle(
                  scheduleMode: _mode,
                  palette: _p,
                  onChanged: (v) => setState(() {
                    _mode = v;
                    _errors.remove('days');
                  }),
                ),
                const SizedBox(height: 14),
              ],
              _shaking('days', _whenField()),
              _errorText('days'),
              if (_errors.containsKey('')) ...[
                const SizedBox(height: 12),
                _shaking('', _errorText('')),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel', style: TextStyle(color: WebColors.mid)),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          style: ElevatedButton.styleFrom(
            backgroundColor: _p.dark,
            foregroundColor: Colors.white,
            elevation: 0,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(_isEdit ? 'Save' : 'Add schedule'),
        ),
      ],
    );
  }

  List<Widget> _targetFields() {
    return [
      _shaking(
        'name',
        TextField(
          controller: _nameCtrl,
          autofocus: true,
          decoration: webInputDecoration(_p,
              label: 'Schedule name',
              hint: 'e.g. Weekday lights',
              error: _errors['name']),
          onChanged: (_) => _clear('name'),
        ),
      ),
      const SizedBox(height: 14),
      _dropdown('Scope', _scope, const {
        'global': 'Global (every building)',
        'building': 'One building',
        'utility': 'One utility everywhere',
        'device': 'One device',
      }, (v) {
        setState(() {
          _scope = v;
          _target = v == 'building' && widget.buildings.isNotEmpty
              ? widget.buildings.first
              : v == 'utility'
                  ? 'Lights'
                  : 'all';
          _deviceLabel = '';
          _errors.remove('target');
        });
      }),
      const SizedBox(height: 14),
      if (_scope == 'building') ...[
        if (widget.loadingBuildings)
          LinearProgressIndicator(color: _p.mid)
        else
          _shaking(
            'target',
            _dropdown(
              'Building',
              widget.buildings.contains(_target) ? _target : '',
              {for (final b in widget.buildings) b: b},
              (v) => setState(() {
                _target = v;
                _errors.remove('target');
              }),
              error: _errors['target'],
            ),
          ),
        const SizedBox(height: 14),
      ],
      if (_scope == 'utility') ...[
        _dropdown('Utility', _target, const {
          'Lights': 'Lights',
          'Outlets': 'Outlets',
          'AC': 'AC',
        }, (v) => setState(() => _target = v)),
        const SizedBox(height: 14),
      ],
      if (_scope == 'device') ...[
        _shaking('target', _devicePickerField()),
        const SizedBox(height: 14),
      ],
      if (_scope != 'utility') ...[
        _dropdown('Utility to control', _utility,
            {for (final u in _utilities) u: u},
            (v) => setState(() => _utility = v)),
        const SizedBox(height: 18),
      ],
    ];
  }

  Widget _dropdown(String label, String value, Map<String, String> items,
      ValueChanged<String> onChanged,
      {String? error}) {
    return DropdownButtonFormField<String>(
      key: ValueKey('$label-$value-${items.length}'),
      initialValue: items.containsKey(value) ? value : null,
      isExpanded: true,
      decoration: webInputDecoration(_p, label: label, error: error),
      items: [
        for (final e in items.entries)
          DropdownMenuItem(value: e.key, child: Text(e.value)),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }

  Widget _devicePickerField() {
    final err = _errors['target'];
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () async {
        final result = await showDialog<Map<String, String>>(
          context: context,
          builder: (_) => _DevicePickerDialog(
            buildingList: widget.buildings,
            buildingFloors: widget.buildingFloors,
            palette: _p,
          ),
        );
        if (result != null) {
          setState(() {
            _target = result['id']!;
            _deviceLabel = result['label']!;
            _errors.remove('target');
          });
        }
      },
      child: InputDecorator(
        decoration: webInputDecoration(_p, label: 'Device', error: err),
        child: Row(children: [
          Expanded(
            child: Text(
              _deviceLabel.isEmpty
                  ? 'Pick building → floor → room → device'
                  : _deviceLabel,
              style: TextStyle(
                  fontSize: 14,
                  color:
                      _deviceLabel.isEmpty ? WebColors.muted : WebColors.ink),
            ),
          ),
          const Icon(Icons.chevron_right, color: WebColors.muted, size: 18),
        ]),
      ),
    );
  }

  Widget _windowRow(int i) {
    final d = _windows[i];
    final w = d.window;
    final key = 'w$i';
    final hasError = _errors.containsKey(key);
    String hint = '';
    if (w != null && w.duration < 24 * 60) {
      hint = 'OFF at ${w.offLabel}${w.overnight ? ' (next day)' : ''}';
    }
    return _shaking(
      key,
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: hasError ? AppColors.error : _p.mid.withAlpha(60),
                  width: hasError ? 1.6 : 1.2,
                ),
              ),
              child: Row(children: [
                const Text('ON',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: AppColors.greenMid)),
                const SizedBox(width: 10),
                _timeButton(d.on, 'Start', (t) => setState(() {
                      d.on = t;
                      _errors.remove(key);
                    })),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('to',
                      style: TextStyle(fontSize: 13, color: WebColors.muted)),
                ),
                _timeButton(d.until, 'End', (t) => setState(() {
                      d.until = t;
                      _errors.remove(key);
                    })),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(hint,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5, color: WebColors.muted)),
                ),
                WebIconButton(
                  icon: Icons.delete_outline_rounded,
                  tooltip: 'Remove window',
                  size: 30,
                  danger: true,
                  onPressed: _windows.length <= 1
                      ? null
                      : () => setState(() {
                            _windows.removeAt(i);
                            _errors.removeWhere((k, _) => k.startsWith('w'));
                          }),
                ),
              ]),
            ),
            _errorText(key),
          ],
        ),
      ),
    );
  }

  Widget _timeButton(
      TimeOfDay? value, String placeholder, ValueChanged<TimeOfDay> onPicked) {
    return OutlinedButton(
      onPressed: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: value ?? const TimeOfDay(hour: 8, minute: 0),
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
            child: child!,
          ),
        );
        if (picked != null) onPicked(picked);
      },
      style: OutlinedButton.styleFrom(
        foregroundColor: WebColors.ink,
        side: BorderSide(color: _p.mid.withAlpha(70)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
      child: Text(
        value == null ? placeholder : formatHm(value.hour * 60 + value.minute),
        style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: value == null ? WebColors.muted : WebColors.ink),
      ),
    );
  }

  Widget _whenField() {
    if (_mode == 'weekly') {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _label('Repeat on'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final d in _allDays)
              _dayChip(d, _days.contains(d), () => setState(() {
                    _days.contains(d) ? _days.remove(d) : _days.add(d);
                    _errors.remove('days');
                  })),
          ],
        ),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label('Date(s)'),
      Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _errors.containsKey('days')
                ? AppColors.error
                : _p.mid.withAlpha(40),
            width: _errors.containsKey('days') ? 1.6 : 1,
          ),
        ),
        child: RangeCalendar(
          initialStart: _range?.start ?? _day,
          initialEnd: _range?.end ?? _day,
          onDaySelected: (d) => setState(() {
            _day = d;
            if (d != null) _errors.remove('days');
          }),
          onRangeChanged: (r) => setState(() {
            _range = r;
            if (r != null) _errors.remove('days');
          }),
          onDragActiveChanged: (a) => setState(() => _dragActive = a),
        ),
      ),
    ]);
  }

  Widget _dayChip(String label, bool selected, VoidCallback onTap) {
    return Material(
      color: selected ? _p.dark : _p.pale,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : AppColors.textMid)),
        ),
      ),
    );
  }
}

String _scopeText(WebAutomationSchedule s) {
  switch (s.scope) {
    case 'global':
      return 'All buildings';
    case 'building':
      return 'Building ${s.target}';
    case 'utility':
      return 'Utility ${s.target}';
    case 'device':
      return 'Device ${s.target}';
    default:
      return s.scope;
  }
}

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
    final ok = await showWebConfirmDialog(
      context: context,
      title: 'Delete schedule?',
      message: '"${s.name}" will stop running and be removed.',
      onConfirm: () =>
          FirebaseDatabase.instance.ref('automations/${s.id}').remove(),
    );
    if (ok && mounted) TopToast.show(context, 'Schedule deleted.');
  }

  /// Opens the schedule form: a new schedule, or [s]'s timing and days.
  Future<void> _openScheduleForm([WebAutomationSchedule? s]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ScheduleFormDialog(
        palette: _palette,
        buildings: _buildings,
        buildingFloors: _buildingFloors,
        loadingBuildings: _loadingBuildings,
        existing: s,
      ),
    );
    if (saved == true && mounted) {
      TopToast.show(context, s == null ? 'Schedule added.' : 'Schedule updated.');
    }
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
                            fontSize: 13, color: WebColors.muted)),
                  ],
                ),
              ),
              if (isAdmin)
                Padding(
                  // Clear of the shell's floating role badge and bell.
                  padding: const EdgeInsets.only(right: 180),
                  child: WebIconButton(
                    icon: Icons.add_rounded,
                    tooltip: 'Add schedule',
                    solid: true,
                    size: 40,
                    onPressed: _openScheduleForm,
                  ),
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
              style: const TextStyle(fontSize: 14, color: WebColors.muted)),
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
                  ? 'Use the + button to create one'
                  : 'No automation schedules set',
              style: const TextStyle(fontSize: 14, color: WebColors.muted)),
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
                  fontSize: 12,
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
          if (isAdmin) ...[
            WebIconButton(
              icon: Icons.edit_outlined,
              tooltip: 'Edit schedule',
              size: 34,
              onPressed: () => _openScheduleForm(s),
            ),
            const SizedBox(width: 6),
            WebIconButton(
              icon: Icons.delete_outline_rounded,
              tooltip: 'Delete schedule',
              size: 34,
              danger: true,
              onPressed: () => _deleteSchedule(s),
            ),
          ] else
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
                        fontSize: 12, color: WebColors.muted)),
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
          for (final w in s.effectiveWindows)
            Tooltip(
              message: 'ON at ${w.onLabel}, OFF at ${w.offLabel}'
                  '${w.overnight ? ' the next day' : ''}',
              child: _chip(Icons.power_settings_new,
                  'ON ${w.onLabel}–${w.untilLabel}', AppColors.greenMid),
            ),
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
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: active ? Colors.white : WebColors.muted)),
              );
            }).toList(),
          ),
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
                fontSize: 12, fontWeight: FontWeight.w600, color: color)),
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

}
