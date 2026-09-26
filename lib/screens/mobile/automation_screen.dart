import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import '../../services/schedule_windows.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_fonts.dart';
import '../../theme/app_text_styles.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_segmented_control.dart';
import '../../widgets/app_switch.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/app_top_bar.dart';
import '../../widgets/delete_flow.dart';
import '../../widgets/outline_icon_box.dart';
import '../../widgets/range_calendar.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';

void _safeDialogPop<T>(BuildContext context, [T? result]) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;
    final nav = Navigator.of(context);
    if (!nav.canPop()) return;
    nav.pop<T>(result);
  });
}

// ─── Small shared formatting/date helpers ──────────────────────────────────
//
// Kept as private top-level functions (rather than instance methods) since
// both the list screen (`_AutomationScreenState`) and the pushed schedule
// editor (`_ScheduleEditorPageState`) need them and neither owns the other.

/// Canonical day order used everywhere in this file -- matches the web
/// model's `days` values exactly (`WebAutomationSchedule`/`_allDays` in
/// `automation_screen_web.dart`).
const List<String> _kAllDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

DateTime? _parseIsoDate(String? iso) {
  if (iso == null) return null;
  final parts = iso.split('-');
  if (parts.length != 3) return null;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return null;
  return DateTime(y, m, d);
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

const List<String> _kMonths3 = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

String _formatMonthDay(DateTime d) => '${_kMonths3[d.month - 1]} ${d.day}';

String _formatIsoDate(String iso) {
  final parts = iso.split('-');
  if (parts.length != 3) return iso;
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (month == null || day == null || month < 1 || month > 12) return iso;
  return '${_kMonths3[month - 1]} $day, ${parts[0]}';
}

/// 24h minutes-after-midnight -> "h:mm AM/PM".
String _formatMinutesLabel(int minutesOfDay) {
  final m = ((minutesOfDay % (24 * 60)) + 24 * 60) % (24 * 60);
  final h24 = m ~/ 60;
  final mm = m % 60;
  final period = h24 >= 12 ? 'PM' : 'AM';
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  return '$h12:${mm.toString().padLeft(2, '0')} $period';
}

/// "in 2h 19m" / "in 45m" -- [minutesOfDay] must be after [nowMinutes] on the
/// same day (the "Coming up today" section only ever calls this with future
/// times today).
String _inWordsLabel(int minutesOfDay, int nowMinutes) {
  final d = minutesOfDay - nowMinutes;
  final h = d ~/ 60;
  final mm = d % 60;
  if (h > 0 && mm > 0) return 'in ${h}h ${mm}m';
  if (h > 0) return 'in ${h}h';
  return 'in ${mm}m';
}

/// "Every day" / "Weekdays" / "Weekends" / "Mon, Wed, Fri" -- mirrors the
/// preview's `daysText()`.
String _daysText(List<String> days) {
  if (days.isEmpty) return 'No days set';
  if (days.length == 7) return 'Every day';
  final set = days.toSet();
  const weekdays = {'Mon', 'Tue', 'Wed', 'Thu', 'Fri'};
  const weekends = {'Sat', 'Sun'};
  if (set.length == 5 && set.containsAll(weekdays)) return 'Weekdays';
  if (set.length == 2 && set.containsAll(weekends)) return 'Weekends';
  return _kAllDays.where(days.contains).join(', ');
}

String _scopeLabelForTarget(String scope, String target) {
  switch (scope) {
    case 'global':
      return 'All buildings · all utilities';
    case 'building':
      return 'Building: $target';
    case 'utility':
      return 'Utility: $target';
    case 'device':
      return 'Device: $target';
    default:
      return scope;
  }
}

IconData _utilityIcon(String utility) {
  switch (utility.trim().toLowerCase()) {
    case 'ac':
    case 'aircon':
      return Icons.ac_unit;
    case 'lights':
    case 'light':
      return Icons.lightbulb_outline;
    case 'outlets':
    case 'outlet':
      return Icons.power_outlined;
    default:
      return Icons.schedule;
  }
}

bool _isSameDate(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

// ─── Model ────────────────────────────────────────────────────────────────

class AutomationSchedule {
  final String id;
  final String name;
  final String scope;
  final String target;
  final String utility;
  final String onTime;
  final String offTime;
  final List<String> days;
  final bool enabled;

  /// 'weekly' (default) or 'calendar' -- calendar-mode schedules can be both
  /// created and edited from this screen (see `_ScheduleEditorPage`), same
  /// as the desktop web Automation screen.
  final String scheduleMode;
  final String? startDate;
  final String? endDate;

  /// Several ON windows (see `services/schedule_windows.dart`), same shape
  /// web writes under `automations/{id}/windows`. Empty for schedules saved
  /// before windows existed, which use [onTime]/[offTime] -- see
  /// [effectiveWindows].
  final List<ScheduleWindow> windows;

  bool get isCalendarMode => scheduleMode == 'calendar';

  /// [windows], or the single [onTime]/[offTime] pair as one window --
  /// mirrors `WebAutomationSchedule.effectiveWindows` exactly so both
  /// platforms read the same schedule identically.
  List<ScheduleWindow> get effectiveWindows {
    if (windows.isNotEmpty) return windows;
    final on = parseHm(onTime);
    final off = parseHm(offTime);
    if (on == null || off == null) return const [];
    return [ScheduleWindow(on, (off - 1 + 24 * 60) % (24 * 60))];
  }

  AutomationSchedule({
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

  factory AutomationSchedule.fromMap(String id, Map<String, dynamic> data) {
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

    return AutomationSchedule(
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

  /// Matches `WebAutomationSchedule.toMap()` field-for-field (name/scope/
  /// target/utility/onTime/offTime/legacy action+time/days/enabled/
  /// scheduleMode/startDate/endDate/windows) so a schedule written from
  /// either platform looks identical in the database.
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

  /// A single realistic-looking fake schedule, used only while the
  /// automation screen's skeleton shimmer is showing (see [ScreenSkeleton]).
  factory AutomationSchedule.placeholder({String id = 'schedule-0'}) =>
      AutomationSchedule(
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

  static List<AutomationSchedule> placeholderList([int count = 4]) =>
      List.generate(
          count, (i) => AutomationSchedule.placeholder(id: 'schedule-$i'));
}

/// Where a device-scoped schedule's device currently lives, resolved from
/// the already-fetched `buildings` subtree (see
/// `_AutomationScreenState._listenAll`) so the list/editor can show
/// "<utility> · <room>" without extra Firebase reads.
class _DeviceInfo {
  final String building;
  final String room;
  final String utility;
  const _DeviceInfo({
    required this.building,
    required this.room,
    required this.utility,
  });
}

/// One turn-on or turn-off instant, unrolled from a schedule's
/// [AutomationSchedule.effectiveWindows] for display (the schedule card's
/// mini timeline, "Coming up today", and next-run text all work off this
/// flat, chronological event list -- matching the preview's `s.win` sample
/// data shape, which is itself a flat action list rather than paired
/// windows).
class _TimelineEvent {
  final bool isOn;
  final int minutes;
  const _TimelineEvent(this.isOn, this.minutes);
}

List<_TimelineEvent> _timelineEventsFor(AutomationSchedule s) {
  final events = <_TimelineEvent>[];
  for (final w in s.effectiveWindows) {
    events.add(_TimelineEvent(true, w.on));
    events.add(_TimelineEvent(false, w.offMinute));
  }
  events.sort((a, b) => a.minutes.compareTo(b.minutes));
  return events;
}

class _UpcomingItem {
  final AutomationSchedule schedule;
  final _TimelineEvent event;
  const _UpcomingItem(this.schedule, this.event);
}

enum _ScheduleFilter { all, active, paused }

// ─── Device Picker Dialog ─────────────────────────────────────────────────────

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
// descendant of any screen's local `Theme(...)` override in build(), and
// `context.institutePalette` can't resolve correctly here. Instead of
// re-deriving the theme inside this State, the caller passes its
// already-resolved `palette` straight through the constructor.
class _DevicePickerDialogState extends State<_DevicePickerDialog> {
  String? _selectedBuilding;
  int? _selectedFloor;
  String? _selectedRoom;
  String? _selectedDeviceId;
  String? _selectedDeviceLabel;

  // Loaded from Firebase
  List<String> _rooms = [];
  // deviceId → utility label
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
          style: TextStyle(
              fontFamily: AppFonts.family, fontWeight: FontWeight.w600)),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Step 1 — Building
          _stepLabel('1', 'Building'),
          const SizedBox(height: 6),
          _buildingList.isEmpty
              ? Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: AppColors.hairline),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'No buildings found',
                    style: TextStyle(fontSize: 13, color: AppColors.textMuted),
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

          // Step 2 — Floor
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

          // Step 3 — Room
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

          // Step 4 — Device
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
                        color: Colors.white,
                        border: Border.all(color: AppColors.hairline),
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
              // Building/room are included alongside id/label so the caller
              // (the schedule editor) can show "<building> · <room>" right
              // away, without a schedule needing to store them itself --
              // schedules only ever store the deviceId as `target`.
              : () => _safeDialogPop(context, <String, String>{
                    'id': _selectedDeviceId!,
                    'label': _selectedDeviceLabel!,
                    'building': _selectedBuilding ?? '',
                    'room': _selectedRoom ?? '',
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
        decoration:
            BoxDecoration(color: widget.palette.dark, shape: BoxShape.circle),
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

// ─── Automation Screen (list) ──────────────────────────────────────────────
//
// Body-only: this widget is embedded inside `dashboard_screen.dart`'s
// IndexedStack, which owns the shared top bar and bottom nav for all 4 tabs
// (see `AutomationScreen(role: _role, onSubtitleChanged: ...)` there -- the
// only caller). So this screen does NOT render its own `AppTopBar` -- the
// handoff's top-bar subtitle ("N of M schedules active") is instead reported
// up to the shell via [onSubtitleChanged] (see `_notifySubtitle`), which the
// shell shows in its shared top bar, matching how Devices/Analytics already
// get their subtitles computed centrally in `dashboard_screen.dart`.

class AutomationScreen extends StatefulWidget {
  final String role;
  /// Called whenever this screen's "N of M schedules active" figure
  /// changes (schedules loaded, institute hydrated, or a schedule
  /// toggled) so the shared shell top bar in `dashboard_screen.dart` can
  /// show it as this tab's subtitle. Null while there is nothing to show
  /// yet (before the first load) or if there are no schedules at all.
  final ValueChanged<String?>? onSubtitleChanged;
  const AutomationScreen(
      {super.key, this.role = 'faculty', this.onSubtitleChanged});

  @override
  State<AutomationScreen> createState() => _AutomationScreenState();
}

class _AutomationScreenState extends State<AutomationScreen> {
  List<AutomationSchedule> _schedules = [];
  StreamSubscription<List<DatabaseEvent>>? _combinedSub;
  // True until each stream's first snapshot has arrived; never reverts to
  // true afterwards, so a transient null on either path can't blank data
  // this screen already loaded this session. `_loadingBuildings` is also
  // read directly by the schedule editor's device-picker dialog.
  bool _loading = true;
  bool _loadingBuildings = true;
  bool get _isLoading => _loading || _loadingBuildings;
  String? _errorText;

  _ScheduleFilter _filter = _ScheduleFilter.all;

  bool get isAdmin =>
      widget.role == 'admin' ||
      widget.role == 'main_admin' ||
      widget.role == 'super_admin' ||
      widget.role == 'institute_admin';

  /// Institute admins see only their institute's schedules, grouped by room
  /// (handoff §5) rather than by building (handoff §4.8).
  bool get _isInstituteAdmin => widget.role.trim().toLowerCase() == 'institute_admin';

  List<String> _buildings = [];
  Map<String, int> _buildingFloors = {};

  /// deviceId -> where it currently lives, resolved from the `buildings`
  /// subtree already fetched below (no extra Firebase reads).
  final Map<String, _DeviceInfo> _deviceIndex = {};

  // ── Institute theming ──────────────────────────────────────────────────
  // `widget.role` is already passed in by dashboard_screen.dart (the only
  // caller -- see AutomationScreen(role: _role) there), but no institute is
  // threaded through, so it's hydrated here directly from the signed-in
  // user's own record, mirroring dashboard_screen.dart's
  // _hydrateSessionFromAuth.
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
      _notifySubtitle();
    } catch (_) {
      // Keep the green default if institute hydration fails.
    }
  }

  /// Same institute-scoping rule `_buildList` uses for its `scoped` list,
  /// factored out so `_notifySubtitle` can compute the identical figure the
  /// body would render, without duplicating a second Firebase read.
  List<AutomationSchedule> _scopedSchedules(List<AutomationSchedule> all) {
    return (_isInstituteAdmin && (_institute ?? '').isNotEmpty)
        ? all.where((s) => _belongsToInstitute(s, _institute!)).toList()
        : all;
  }

  /// Reports the current "N of M schedules active" figure up to
  /// [AutomationScreen.onSubtitleChanged] for the shared shell top bar.
  /// Null until the first real load completes (or once loaded, if there
  /// are no schedules at all) so the shell shows no subtitle rather than a
  /// misleading "0 of 0" while `_schedules` is still empty pre-load.
  void _notifySubtitle() {
    final cb = widget.onSubtitleChanged;
    if (cb == null) return;
    if (_isLoading) return;
    final scoped = _scopedSchedules(_schedules);
    if (scoped.isEmpty) {
      cb(null);
      return;
    }
    final activeCount = scoped.where((s) => s.enabled).length;
    cb('$activeCount of ${scoped.length} schedules active');
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

  // Combines the two screen-level Firebase streams (buildings, automations)
  // into one subscription with a sticky merge: a transient null/empty
  // result on either path is only accepted before that path's first
  // successful load, never after (see `_loading`/`_loadingBuildings`).
  void _listenAll() {
    _combinedSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('buildings').onValue,
      FirebaseDatabase.instance.ref('automations').onValue,
    ]).listen((events) {
      if (!mounted) return;
      setState(() {
        // ── buildings (+ nested device index) ─────────────────────────
        final buildingsRaw = events[0].snapshot.value;
        if (buildingsRaw is Map) {
          final list = <String>[];
          final floors = <String, int>{};
          final deviceIndex = <String, _DeviceInfo>{};
          final map = Map<String, dynamic>.from(buildingsRaw);
          for (final entry in map.entries) {
            final buildingCode = entry.key.toString();
            if (entry.value is Map) {
              final data = Map<String, dynamic>.from(entry.value as Map);
              final floorCount = (data['floors'] as num?)?.toInt() ?? 1;
              list.add(buildingCode);
              floors[buildingCode] = floorCount < 1 ? 1 : floorCount;

              // `ref('buildings').onValue` already downloads the whole
              // subtree (Realtime DB has no partial-fetch by default), so
              // floorData/devices are already here -- no extra reads.
              final floorData = data['floorData'];
              if (floorData is Map) {
                for (final floorEntry in floorData.entries) {
                  final floorVal = floorEntry.value;
                  if (floorVal is! Map) continue;
                  final devices = floorVal['devices'];
                  if (devices is! Map) continue;
                  for (final deviceEntry in devices.entries) {
                    final deviceVal = deviceEntry.value;
                    if (deviceVal is! Map) continue;
                    final d = Map<String, dynamic>.from(deviceVal);
                    deviceIndex[deviceEntry.key.toString()] = _DeviceInfo(
                      building: buildingCode,
                      room: (d['room'] ?? '').toString(),
                      utility: (d['utility'] ?? 'Unknown').toString(),
                    );
                  }
                }
              }
            }
          }
          list.sort();
          _buildings = list;
          _buildingFloors = floors;
          _deviceIndex
            ..clear()
            ..addAll(deviceIndex);
        } else if (_loadingBuildings) {
          _buildings = [];
          _buildingFloors = {};
          _deviceIndex.clear();
        }
        _loadingBuildings = false;

        // ── automations ────────────────────────────────────────────
        final autoRaw = events[1].snapshot.value;
        if (autoRaw is Map) {
          final list = <AutomationSchedule>[];
          autoRaw.forEach((id, val) {
            if (val is Map) {
              list.add(AutomationSchedule.fromMap(
                  id.toString(), Map<String, dynamic>.from(val)));
            }
          });
          list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
          _schedules = list;
          _errorText = null;
        } else if (_loading) {
          _schedules = [];
        }
        _loading = false;
      });
      _notifySubtitle();
    }, onError: (Object error) {
      if (!mounted) return;
      final denied = error.toString().toLowerCase().contains('permission');
      setState(() {
        _loading = false;
        _loadingBuildings = false;
        if (_schedules.isEmpty) {
          _errorText = denied
              ? 'You do not have permission to view automations.'
              : 'Failed to load automations.';
        }
      });
      _notifySubtitle();
    });
  }

  Future<void> _toggleEnabled(AutomationSchedule s) async {
    try {
      await FirebaseDatabase.instance
          .ref('automations/${s.id}/enabled')
          .set(!s.enabled);
    } catch (_) {
      if (!mounted) return;
      // The device itself may simply be offline/unreachable right now --
      // the write to Firebase (and therefore this schedule's enabled state)
      // failed either way, so tell the admin rather than silently no-op'ing.
      TopToast.error(context, 'Unable to update schedule. Check your connection and try again.');
    }
  }

  Future<void> _openEditor(AutomationSchedule? existing) async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _ScheduleEditorPage(
          existing: existing,
          palette: _palette,
          buildings: _buildings,
          buildingFloors: _buildingFloors,
          deviceIndex: _deviceIndex,
          readOnly: !isAdmin,
        ),
      ),
    );
    if (!mounted || result == null) return;
    if (result == 'added') TopToast.show(context, 'Schedule added.');
    if (result == 'updated') TopToast.show(context, 'Schedule updated.');
  }

  // ── Grouping / filtering helpers ────────────────────────────────────────

  bool _belongsToInstitute(AutomationSchedule s, String institute) {
    final code = institute.trim().toUpperCase();
    if (s.scope == 'device') {
      return (_deviceIndex[s.target]?.building ?? '').toUpperCase() == code;
    }
    if (s.scope == 'building') return s.target.trim().toUpperCase() == code;
    // Global/utility-wide schedules aren't attributable to one institute.
    return false;
  }

  String _buildingGroupKey(AutomationSchedule s) {
    if (s.scope == 'device') return _deviceIndex[s.target]?.building ?? 'Other';
    if (s.scope == 'building') return s.target;
    return 'All buildings';
  }

  String _roomGroupKey(AutomationSchedule s) {
    if (s.scope == 'device') return _deviceIndex[s.target]?.room ?? 'Unassigned';
    return 'Building-wide';
  }

  bool _isDateInRange(DateTime day, String? start, String? end) {
    final s = _parseIsoDate(start);
    if (s == null) return false;
    final e = _parseIsoDate(end) ?? s;
    return !day.isBefore(s) && !day.isAfter(e);
  }

  List<_UpcomingItem> _computeUpcoming(List<AutomationSchedule> schedules) {
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final today = DateTime(now.year, now.month, now.day);
    final todayCode = _kAllDays[now.weekday - 1];
    final out = <_UpcomingItem>[];
    for (final s in schedules) {
      if (!s.enabled) continue;
      final runsToday = s.isCalendarMode
          ? _isDateInRange(today, s.startDate, s.endDate)
          : s.days.contains(todayCode);
      if (!runsToday) continue;
      for (final e in _timelineEventsFor(s)) {
        if (e.minutes > nowMinutes) out.add(_UpcomingItem(s, e));
      }
    }
    out.sort((a, b) => a.event.minutes.compareTo(b.event.minutes));
    return out.take(3).toList();
  }

  String _nextRunLabel(AutomationSchedule s) {
    final events = _timelineEventsFor(s);
    if (events.isEmpty) return '';
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;

    if (s.isCalendarMode) {
      final start = _parseIsoDate(s.startDate);
      if (start == null) return '';
      final end = _parseIsoDate(s.endDate) ?? start;
      final today = DateTime(now.year, now.month, now.day);
      if (today.isBefore(start)) {
        final first = events.first;
        return 'Next: ${_formatMonthDay(start)}, ${_formatMinutesLabel(first.minutes)} · turns ${first.isOn ? 'on' : 'off'}';
      }
      if (!today.isAfter(end)) {
        for (final e in events) {
          if (e.minutes > nowMinutes) {
            return 'Next: Today, ${_formatMinutesLabel(e.minutes)} · turns ${e.isOn ? 'on' : 'off'}';
          }
        }
        final tomorrow = today.add(const Duration(days: 1));
        if (!tomorrow.isAfter(end)) {
          final first = events.first;
          return 'Next: Tomorrow, ${_formatMinutesLabel(first.minutes)} · turns ${first.isOn ? 'on' : 'off'}';
        }
      }
      return '';
    }

    if (s.days.isEmpty) return '';
    for (var k = 0; k < 8; k++) {
      final day = now.add(Duration(days: k));
      final dayCode = _kAllDays[(day.weekday - 1) % 7];
      if (!s.days.contains(dayCode)) continue;
      for (final e in events) {
        if (k > 0 || e.minutes > nowMinutes) {
          final when = k == 0 ? 'Today' : (k == 1 ? 'Tomorrow' : dayCode);
          return 'Next: $when, ${_formatMinutesLabel(e.minutes)} · turns ${e.isOn ? 'on' : 'off'}';
        }
      }
    }
    return '';
  }

  String _calendarDateLabel(AutomationSchedule s) {
    final start = s.startDate;
    final end = s.endDate;
    if (start == null) return 'No date set';
    if (end == null || end == start) return _formatIsoDate(start);
    return '${_formatIsoDate(start)} – ${_formatIsoDate(end)}';
  }

  String _scopeLabel(AutomationSchedule s) => _scopeLabelForTarget(s.scope, s.target);

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(widget.role, _institute)],
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: _errorText != null
            ? _buildError()
            : ScreenSkeleton(
                isLoading: _isLoading,
                child: Builder(builder: (context) {
                  final displaySchedules = _schedules.isEmpty && _isLoading
                      ? AutomationSchedule.placeholderList()
                      : _schedules;
                  return _buildList(displaySchedules);
                }),
              ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: AppColors.hairline),
                  borderRadius: BorderRadius.circular(20)),
              child: Icon(Icons.lock_outline, size: 34, color: _palette.mid)),
          const SizedBox(height: 16),
          Text('Cannot load automations',
              style: AppTextStyles.title.copyWith(color: AppColors.ink)),
          const SizedBox(height: 8),
          Text(_errorText ?? 'Something went wrong.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid)),
        ]),
      ),
    );
  }

  Widget _buildEmptyState({required String title, required String message}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                  color: Colors.white, border: Border.all(color: AppColors.hairline), borderRadius: BorderRadius.circular(20)),
              child: Icon(Icons.schedule, size: 36, color: _palette.dark)),
          const SizedBox(height: 16),
          Text(title, style: AppTextStyles.titleLg.copyWith(color: AppColors.ink)),
          const SizedBox(height: 6),
          Text(message,
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid)),
        ]),
      ),
    );
  }

  Widget _buildList(List<AutomationSchedule> allSchedules) {
    final scoped = _scopedSchedules(allSchedules);

    if (scoped.isEmpty) {
      return _buildEmptyState(
        title: 'No schedules yet',
        message: isAdmin
            ? 'Tap + next to "All schedules" to create one.'
            : 'No automation schedules set.',
      );
    }

    final activeCount = scoped.where((s) => s.enabled).length;
    final pausedCount = scoped.length - activeCount;

    final shown = scoped.where((s) {
      switch (_filter) {
        case _ScheduleFilter.active:
          return s.enabled;
        case _ScheduleFilter.paused:
          return !s.enabled;
        case _ScheduleFilter.all:
          return true;
      }
    }).toList();

    final upcoming = _computeUpcoming(scoped);

    final groups = <String, List<AutomationSchedule>>{};
    final order = <String>[];
    for (final s in shown) {
      final key = _isInstituteAdmin ? _roomGroupKey(s) : _buildingGroupKey(s);
      (groups[key] ??= []).add(s);
      if (!order.contains(key)) order.add(key);
    }
    order.sort();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // "N of M schedules active" now lives in the shared shell top
          // bar's subtitle (see `_notifySubtitle` / `dashboard_screen.dart`
          // `_topBarSubtitle`), not here.
          _comingUpSection(upcoming),
          const SizedBox(height: 28),
          Row(children: [
            Text('All schedules', style: AppTextStyles.title.copyWith(color: AppColors.ink)),
            const Spacer(),
            if (isAdmin)
              IconAddButton(
                onPressed: () => _openEditor(null),
                palette: _palette,
                semanticLabel: 'Add schedule',
              ),
          ]),
          const SizedBox(height: 12),
          AppSegmentedControl(
            palette: _palette,
            segments: [
              AppSegment(label: 'All ${scoped.length}'),
              AppSegment(label: 'Active $activeCount'),
              AppSegment(label: 'Paused $pausedCount'),
            ],
            selectedIndex: _filter.index,
            onChanged: (i) => setState(() => _filter = _ScheduleFilter.values[i]),
          ),
          if (order.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text('No ${_filter.name} schedules.',
                  style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid)),
            )
          else
            for (final key in order) _groupSection(key, groups[key]!),
        ],
      ),
    );
  }

  Widget _comingUpSection(List<_UpcomingItem> upcoming) {
    final today = DateTime.now();
    final label = '${_kAllDays[today.weekday - 1]}, ${_formatMonthDay(today)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('Coming up today', style: AppTextStyles.title.copyWith(color: AppColors.ink)),
            const Spacer(),
            Text(label, style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid)),
          ],
        ),
        const SizedBox(height: 12),
        if (upcoming.isEmpty)
          Row(children: [
            const Icon(Icons.check_circle, size: 18, color: AppColors.inkMid),
            const SizedBox(width: 8),
            Text('Nothing else runs today.',
                style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid)),
          ])
        else
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: _palette.line),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                for (var i = 0; i < upcoming.length; i++)
                  Container(
                    decoration: BoxDecoration(
                      border: i == 0 ? null : Border(top: BorderSide(color: _palette.line)),
                    ),
                    child: _upcomingRow(upcoming[i], today),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _upcomingRow(_UpcomingItem u, DateTime now) {
    final nowMinutes = now.hour * 60 + now.minute;
    final info = u.schedule.scope == 'device' ? _deviceIndex[u.schedule.target] : null;
    final deviceLabel = info?.utility ?? u.schedule.utility;
    final placeParts = <String>[
      if (!_isInstituteAdmin && info != null) info.building,
      if (info != null) info.room,
    ];
    final place = placeParts.isEmpty ? _scopeLabel(u.schedule) : placeParts.join(' · ');

    return InkWell(
      onTap: () => _openEditor(u.schedule),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 92,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_formatMinutesLabel(u.event.minutes),
                      style: TextStyle(
                          fontFamily: AppFonts.family,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: _palette.dark)),
                  Text(_inWordsLabel(u.event.minutes, nowMinutes),
                      style: AppTextStyles.caption.copyWith(color: AppColors.inkMid)),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Turn ${u.event.isOn ? 'on' : 'off'} · $deviceLabel',
                      style: AppTextStyles.subtitle.copyWith(color: AppColors.ink)),
                  Text('$place — ${u.schedule.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupSection(String header, List<AutomationSchedule> items) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.only(bottom: 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.ink, width: 1.5)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(header.toUpperCase(),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontFamily: AppFonts.family,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                          color: AppColors.ink)),
                ),
                const SizedBox(width: 8),
                Text('${items.length} schedule${items.length > 1 ? 's' : ''}',
                    style: AppTextStyles.caption.copyWith(color: AppColors.inkMid)),
              ],
            ),
          ),
          for (final s in items) _scheduleCard(s),
        ],
      ),
    );
  }

  Widget _scheduleCard(AutomationSchedule s) {
    final info = s.scope == 'device' ? _deviceIndex[s.target] : null;
    final utilityLabel = info?.utility ?? s.utility;
    final subtitle = info != null ? '$utilityLabel · ${info.room}' : '$utilityLabel · ${_scopeLabel(s)}';
    final events = _timelineEventsFor(s);
    final nextLabel = s.enabled ? _nextRunLabel(s) : 'Paused';

    return InkWell(
      onTap: () => _openEditor(s),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: _palette.line)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              OutlineIconBox(icon: _utilityIcon(utilityLabel), palette: _palette),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.subtitle
                            .copyWith(color: s.enabled ? AppColors.ink : AppColors.inkMid)),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AppSwitch(
                value: s.enabled,
                onChanged: isAdmin ? (_) => _toggleEnabled(s) : null,
                palette: _palette,
              ),
            ]),
            if (events.isNotEmpty) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(left: 52),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [for (final e in events) _timelineRow(e, s.enabled)],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(left: 52),
              child: Row(children: [
                Icon(s.isCalendarMode ? Icons.calendar_month : Icons.event_repeat,
                    size: 16, color: AppColors.inkMid),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    s.isCalendarMode ? _calendarDateLabel(s) : _daysText(s.days),
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.caption.copyWith(color: AppColors.inkMid),
                  ),
                ),
                if (nextLabel.isNotEmpty)
                  Text(nextLabel,
                      style: AppTextStyles.caption.copyWith(
                          color: s.enabled ? _palette.dark : AppColors.inkMid,
                          fontWeight: s.enabled ? FontWeight.w600 : FontWeight.w500)),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _timelineRow(_TimelineEvent e, bool enabled) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: e.isOn ? AppColors.success : Colors.white,
            border: e.isOn ? null : Border.all(color: AppColors.inkMid, width: 2),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 78,
          child: Text(_formatMinutesLabel(e.minutes),
              style: TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: enabled ? AppColors.ink : AppColors.inkMid)),
        ),
        Text(e.isOn ? 'Turn on' : 'Turn off',
            style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid)),
      ]),
    );
  }
}

// ─── Schedule editor (pushed screen: "New schedule" / "Edit schedule") ─────

class _ActionDraft {
  bool isOn;
  TimeOfDay time;
  _ActionDraft(this.isOn, this.time);

  int get minutes => time.hour * 60 + time.minute;
}

class _ScheduleEditorPage extends StatefulWidget {
  final AutomationSchedule? existing;
  final InstitutePalette palette;
  final List<String> buildings;
  final Map<String, int> buildingFloors;
  final Map<String, _DeviceInfo> deviceIndex;
  final bool readOnly;

  const _ScheduleEditorPage({
    required this.existing,
    required this.palette,
    required this.buildings,
    required this.buildingFloors,
    required this.deviceIndex,
    required this.readOnly,
  });

  @override
  State<_ScheduleEditorPage> createState() => _ScheduleEditorPageState();
}

class _ScheduleEditorPageState extends State<_ScheduleEditorPage> {
  final _nameCtrl = TextEditingController();
  String? _nameError;
  String? _error;
  int _shake = 0;
  bool _saving = false;

  // New schedules created from this screen are always device-scoped (the
  // handoff's "New schedule" flow is purely "Building, floor, room, then
  // device" -- there's no scope-type selector in the mobile redesign).
  // Existing global/building/utility-scoped schedules (creatable only on
  // web) remain viewable/editable here for their name/times/repeat, with
  // the Device row shown read-only (mobile has no UI to reassign those
  // scope types -- see `_deviceRow`).
  late String _scope;
  late String _target;
  late String _utility;
  String _deviceLabel = '';
  String? _deviceBuilding;
  String? _deviceRoom;

  late List<_ActionDraft> _actions;
  late String _mode; // 'weekly' | 'calendar'
  late List<String> _days;
  bool _customDayMode = false;
  DateTime? _calStart;
  DateTime? _calEnd;

  bool get _isEdit => widget.existing != null;
  InstitutePalette get _p => widget.palette;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    if (s == null) {
      _scope = 'device';
      _target = 'all';
      _utility = 'All';
      _actions = [
        _ActionDraft(true, const TimeOfDay(hour: 8, minute: 0)),
        _ActionDraft(false, const TimeOfDay(hour: 18, minute: 0)),
      ];
      _mode = 'weekly';
      _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'];
      return;
    }
    _nameCtrl.text = s.name;
    _scope = s.scope;
    _target = s.target;
    _utility = s.utility;
    if (_scope == 'device') {
      final info = widget.deviceIndex[_target];
      if (info != null) {
        _deviceBuilding = info.building;
        _deviceRoom = info.room;
        _deviceLabel = '$_target · ${info.utility}';
      } else {
        _deviceLabel = _target;
      }
    }
    _actions = _actionsFromWindows(s.effectiveWindows);
    _mode = s.scheduleMode;
    _days = s.days.isNotEmpty ? [...s.days] : ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'];
    if (_mode == 'calendar') {
      _calStart = _parseIsoDate(s.startDate);
      _calEnd = _parseIsoDate(s.endDate) ?? _calStart;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  List<_ActionDraft> _actionsFromWindows(List<ScheduleWindow> windows) {
    if (windows.isEmpty) {
      return [
        _ActionDraft(true, const TimeOfDay(hour: 8, minute: 0)),
        _ActionDraft(false, const TimeOfDay(hour: 18, minute: 0)),
      ];
    }
    final drafts = <_ActionDraft>[];
    for (final w in windows) {
      drafts.add(_ActionDraft(true, TimeOfDay(hour: w.on ~/ 60, minute: w.on % 60)));
      drafts.add(_ActionDraft(
          false, TimeOfDay(hour: w.offMinute ~/ 60, minute: w.offMinute % 60)));
    }
    drafts.sort((a, b) => a.minutes.compareTo(b.minutes));
    return drafts;
  }

  // ── Actions section ─────────────────────────────────────────────────────

  Future<void> _pickTime(int index) async {
    final picked = await showTimePicker(context: context, initialTime: _actions[index].time);
    if (picked != null) setState(() => _actions[index].time = picked);
  }

  void _addAction() {
    setState(() {
      final lastOn = _actions.isEmpty ? true : !_actions.last.isOn;
      final base = _actions.isEmpty ? const TimeOfDay(hour: 8, minute: 0) : _actions.last.time;
      final nextMinutes = (base.hour * 60 + base.minute + 60) % (24 * 60);
      _actions.add(_ActionDraft(lastOn, TimeOfDay(hour: nextMinutes ~/ 60, minute: nextMinutes % 60)));
    });
  }

  void _removeAction(int index) {
    setState(() => _actions.removeAt(index));
    TopToast.show(context, 'Removed');
  }

  // ── Device section ──────────────────────────────────────────────────────

  Future<void> _pickDevice() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _DevicePickerDialog(
        buildingList: widget.buildings,
        buildingFloors: widget.buildingFloors,
        palette: _p,
      ),
    );
    if (result == null) return;
    setState(() {
      _target = result['id']!;
      _deviceLabel = result['label']!;
      _deviceBuilding = (result['building'] ?? '').isEmpty ? null : result['building'];
      _deviceRoom = (result['room'] ?? '').isEmpty ? null : result['room'];
      final parts = result['label']!.split(' · ');
      if (parts.length > 1) _utility = parts.last;
    });
  }

  // ── When (weekly / calendar) section ────────────────────────────────────

  void _selectPreset(String preset) {
    setState(() {
      switch (preset) {
        case 'Every day':
          _customDayMode = false;
          _days = [..._kAllDays];
          break;
        case 'Weekdays':
          _customDayMode = false;
          _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'];
          break;
        case 'Weekends':
          _customDayMode = false;
          _days = ['Sat', 'Sun'];
          break;
        case 'Custom':
          _customDayMode = true;
          break;
      }
    });
  }

  void _toggleDay(String day) {
    setState(() {
      if (_days.contains(day)) {
        // At least one day must stay selected (handoff §4.9).
        if (_days.length > 1) _days.remove(day);
      } else {
        _days.add(day);
      }
    });
  }

  // `RangeCalendar` fires BOTH callbacks on every selection change, one with
  // a real value and the other with null as its "the other kind of
  // selection is now inactive" companion call (see range_calendar.dart's
  // `_emitChange`) -- so only non-null calls are ever acted on here, except
  // for the one genuine "cleared" case, which is detected by the still-a-
  // single-day guard below.
  void _onDaySelected(DateTime? d) {
    if (d != null) {
      setState(() {
        _calStart = d;
        _calEnd = d;
      });
    } else if (_calStart != null && _calEnd != null && _isSameDate(_calStart!, _calEnd!)) {
      setState(() {
        _calStart = null;
        _calEnd = null;
      });
    }
  }

  void _onRangeChanged(DateTimeRange? r) {
    if (r == null) return;
    setState(() {
      _calStart = r.start;
      _calEnd = r.end;
    });
  }

  String _calendarFooterText() {
    if (_calStart == null) return 'Tap one day, or two days for a range';
    final end = _calEnd ?? _calStart!;
    if (_isSameDate(_calStart!, end)) return '${_formatMonthDay(_calStart!)} · one day';
    final days = end.difference(_calStart!).inDays + 1;
    return '${_formatMonthDay(_calStart!)} – ${_formatMonthDay(end)} · $days days';
  }

  // ── Delete (only entry point for schedule deletion -- handoff §7.3) ────

  Future<void> _confirmDelete() async {
    final s = widget.existing;
    if (s == null) return;
    await showDeleteFlow(
      context,
      type: DeleteType.schedule,
      itemName: s.name,
      // Per handoff §7.4 point 6: navigate back to the list first, then the
      // floating Undo bar/animation plays over it (showDeleteFlow's Undo bar
      // uses a root-level Overlay entry, so it keeps working after this pop
      // -- see delete_flow.dart).
      onOptimisticRemove: () {
        if (mounted) Navigator.of(context).pop();
      },
      onCommit: (reason, otherText) async {
        // Runs ~5s after the pop above, once this page is long gone -- there
        // is no surface left here to show a failure to the user. On error
        // the write below simply doesn't happen, so the schedule stays in
        // Firebase and the list keeps showing it (a safe, non-destructive
        // failure mode) rather than silently losing data.
        try {
          final db = FirebaseDatabase.instance.ref();
          final updates = <String, Object?>{};
          updates['automations/${s.id}'] = null;
          final logId = db.child('deletion_log').push().key;
          updates['deletion_log/$logId'] = {
            'type': 'schedule',
            'scheduleId': s.id,
            'name': s.name,
            'reason': reason,
            if (otherText != null && otherText.trim().isNotEmpty) 'otherText': otherText.trim(),
            'deletedBy': FirebaseAuth.instance.currentUser?.uid ?? 'unknown',
            'deletedByEmail': FirebaseAuth.instance.currentUser?.email ?? '',
            'timestamp': ServerValue.timestamp,
          };
          await db.update(updates);
        } catch (_) {
          // See doc comment above.
        }
      },
    );
  }

  // ── Save ─────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    setState(() {
      _nameError = null;
      _error = null;
    });

    final name = _nameCtrl.text.trim();
    var hasError = false;
    String? nameError;
    String? generalError;

    if (name.isEmpty) {
      nameError = 'Schedule name is required.';
      hasError = true;
    }
    if (_scope == 'device' && (_target == 'all' || _target.trim().isEmpty)) {
      generalError = 'Please choose a device.';
      hasError = true;
    }

    final sorted = [..._actions]..sort((a, b) => a.minutes.compareTo(b.minutes));
    final windows = <ScheduleWindow>[];
    String? actionsError;
    if (sorted.isEmpty) {
      actionsError = 'Add at least one time window.';
    } else if (sorted.length.isOdd) {
      actionsError = 'Each On needs a matching Off time.';
    } else {
      for (var i = 0; i < sorted.length; i++) {
        final expectedOn = i.isEven;
        if (sorted[i].isOn != expectedOn) {
          actionsError = 'Actions must alternate On, Off, On, Off…';
          break;
        }
      }
      if (actionsError == null) {
        for (var i = 0; i < sorted.length; i += 2) {
          final onMin = sorted[i].minutes;
          final offMin = sorted[i + 1].minutes;
          final untilMin = (offMin - 1 + 24 * 60) % (24 * 60);
          final w = ScheduleWindow(onMin, untilMin);
          if (w.duration >= 24 * 60) {
            actionsError = 'On and Off times must differ.';
            break;
          }
          windows.add(w);
        }
      }
      if (actionsError == null) {
        final overlapErrors = validateWindows(windows);
        if (overlapErrors.isNotEmpty) actionsError = overlapErrors.values.first;
      }
    }
    if (actionsError != null) {
      generalError = actionsError;
      hasError = true;
    }

    if (_mode == 'weekly' && _days.isEmpty) {
      generalError = 'Select at least one day.';
      hasError = true;
    }
    if (_mode == 'calendar' && _calStart == null) {
      generalError = 'Pick a date on the calendar.';
      hasError = true;
    }

    if (hasError) {
      setState(() {
        _nameError = nameError;
        _error = generalError;
        _shake++;
      });
      return;
    }

    setState(() => _saving = true);

    final first = windows.first;
    final timing = <String, Object?>{
      'windows': [for (final w in windows) w.toMap()],
      'onTime': first.onLabel,
      'offTime': first.offLabel,
      'action': 'on',
      'time': first.onLabel,
      'scheduleMode': _mode,
      'days': _mode == 'weekly' ? _days : <String>[],
      'startDate': _mode == 'calendar' ? _isoDate(_calStart!) : null,
      'endDate': _mode == 'calendar' ? _isoDate(_calEnd ?? _calStart!) : null,
      'name': name,
    };
    // Renaming and (for device-scoped schedules) reassigning the device are
    // both editable from this screen even when editing -- a deliberate,
    // mobile-only relaxation of the web dialog, which hides name/target
    // entirely once a schedule exists. Scope/utility for non-device scopes
    // (global/building/utility) are left untouched since this screen has no
    // UI to reassign those.
    if (_scope == 'device') {
      timing['target'] = _target;
      timing['utility'] = _utility;
    }

    try {
      if (_isEdit) {
        await FirebaseDatabase.instance
            .ref('automations/${widget.existing!.id}')
            .update(timing..removeWhere((_, v) => v == null));
      } else {
        final ref = FirebaseDatabase.instance.ref('automations').push();
        await ref.set({
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
        _error = e.toString().toLowerCase().contains('permission')
            ? 'You do not have permission to change schedules.'
            : 'Could not save the schedule. Check your connection and try again.';
        _shake++;
      });
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop(_isEdit ? 'updated' : 'added');
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(extensions: [InstituteTheme(palette: _p)]),
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppTopBar(
          title: _isEdit ? 'Edit schedule' : 'New schedule',
          variant: AppTopBarVariant.small,
          showBackButton: true,
          palette: _p,
          actions: [
            if (_isEdit && !widget.readOnly)
              AppTopBarAction(
                icon: Icons.delete_outline,
                tooltip: 'Delete schedule',
                onTap: _confirmDelete,
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionLabel('Name'),
                AppTextField(
                  controller: _nameCtrl,
                  enabled: !widget.readOnly,
                  shakeTrigger: _shake,
                  decoration: InputDecoration(
                    hintText: 'e.g. AC shutdown',
                    hintStyle: const TextStyle(color: AppColors.inkMuted, fontSize: 13),
                    errorText: _nameError,
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: _p.line)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: _p.line)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: _p.dark)),
                  ),
                  onChanged: (_) {
                    if (_nameError != null) setState(() => _nameError = null);
                  },
                ),
                const SizedBox(height: 22),
                _sectionLabel('Device'),
                _deviceRow(),
                const SizedBox(height: 22),
                Row(children: [
                  Expanded(child: _sectionLabel('Actions', bottomPad: 0)),
                  if (!widget.readOnly)
                    IconAddButton(onPressed: _addAction, palette: _p, semanticLabel: 'Add a time'),
                ]),
                const SizedBox(height: 8),
                for (var i = 0; i < _actions.length; i++) _actionRow(i),
                const SizedBox(height: 22),
                _sectionLabel('When'),
                AppSegmentedControl(
                  palette: _p,
                  enabled: !widget.readOnly,
                  segments: const [
                    AppSegment(label: 'Repeat weekly'),
                    AppSegment(label: 'Specific date(s)'),
                  ],
                  selectedIndex: _mode == 'calendar' ? 1 : 0,
                  onChanged: (i) => setState(() => _mode = i == 0 ? 'weekly' : 'calendar'),
                ),
                const SizedBox(height: 14),
                _mode == 'weekly' ? _weeklyPicker() : _calendarPicker(),
                const SizedBox(height: 22),
                _summaryCard(),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(fontSize: 12, color: AppColors.error)),
                ],
                const SizedBox(height: 24),
                if (!widget.readOnly)
                  Row(children: [
                    Expanded(
                        child: AppOutlineButton(
                            label: 'Cancel',
                            onPressed: () => Navigator.of(context).pop(),
                            palette: _p,
                            expand: true)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: AppPrimaryButton(
                            label: _saving ? 'Saving…' : 'Save',
                            onPressed: _saving ? null : _save,
                            palette: _p,
                            expand: true)),
                  ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text, {double bottomPad = 8}) => Padding(
        padding: EdgeInsets.only(bottom: bottomPad),
        child: Text(text,
            style: const TextStyle(
                fontFamily: AppFonts.family,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.ink)),
      );

  Widget _deviceRow() {
    final canPick = _scope == 'device' && !widget.readOnly;
    final title = _scope != 'device'
        ? _scopeLabelForTarget(_scope, _target)
        : (_deviceLabel.isEmpty
            ? 'Choose a device'
            : (widget.deviceIndex[_target]?.utility ?? _deviceLabel));
    final subtitle = _scope != 'device'
        ? 'Set on the web dashboard'
        : (_deviceBuilding != null && _deviceRoom != null
            ? '$_deviceBuilding · $_deviceRoom'
            : 'Building, floor, room, then device');
    final icon = _scope == 'device'
        ? _utilityIcon(widget.deviceIndex[_target]?.utility ?? _utility)
        : Icons.device_hub;

    return InkWell(
      onTap: canPick ? _pickDevice : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _p.line),
        ),
        child: Row(children: [
          OutlineIconBox(icon: icon, palette: _p),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTextStyles.subtitle.copyWith(color: AppColors.ink)),
                Text(subtitle, style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid)),
              ],
            ),
          ),
          if (canPick) const Icon(Icons.chevron_right, color: AppColors.inkMid),
        ]),
      ),
    );
  }

  Widget _actionRow(int index) {
    final a = _actions[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        SizedBox(
          width: 120,
          child: AppSegmentedControl(
            palette: _p,
            enabled: !widget.readOnly,
            segments: const [AppSegment(label: 'On'), AppSegment(label: 'Off')],
            selectedIndex: a.isOn ? 0 : 1,
            onChanged: (i) => setState(() => a.isOn = i == 0),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: InkWell(
            onTap: widget.readOnly ? null : () => _pickTime(index),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _p.line),
              ),
              child: Row(children: [
                const Icon(Icons.schedule, size: 18, color: AppColors.inkMid),
                const SizedBox(width: 8),
                Text(_formatMinutesLabel(a.minutes),
                    style: const TextStyle(
                        fontFamily: AppFonts.family,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink)),
              ]),
            ),
          ),
        ),
        if (!widget.readOnly)
          IconButton(
            onPressed: () => _removeAction(index),
            icon: const Icon(Icons.close, color: AppColors.inkMid),
            tooltip: 'Remove',
          ),
      ]),
    );
  }

  Widget _weeklyPicker() {
    final preset = _daysText(_days);
    const namedPresets = {'Every day', 'Weekdays', 'Weekends'};
    final showCircles = _customDayMode || !namedPresets.contains(preset);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in ['Every day', 'Weekdays', 'Weekends', 'Custom'])
            AppFilterChip(
              label: p,
              palette: _p,
              selected: p == 'Custom' ? showCircles : (!showCircles && p == preset),
              onTap: widget.readOnly ? () {} : () => _selectPreset(p),
            ),
        ]),
        if (showCircles) ...[
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [for (final d in _kAllDays) _dayCircle(d)],
          ),
        ],
      ],
    );
  }

  Widget _dayCircle(String day) {
    final selected = _days.contains(day);
    return InkWell(
      onTap: widget.readOnly ? null : () => _toggleDay(day),
      borderRadius: BorderRadius.circular(19),
      child: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? _p.dark : Colors.white,
          border: Border.all(color: selected ? _p.dark : _p.line),
        ),
        child: Text(day[0],
            style: TextStyle(
                fontFamily: AppFonts.family,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : AppColors.inkMid)),
      ),
    );
  }

  Widget _calendarPicker() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _p.line),
      ),
      child: Column(children: [
        IgnorePointer(
          ignoring: widget.readOnly,
          child: RangeCalendar(
            initialStart: _calStart,
            initialEnd: _calEnd,
            disablePast: true,
            showInfoText: false,
            onDaySelected: _onDaySelected,
            onRangeChanged: _onRangeChanged,
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(_calendarFooterText(),
              style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid)),
        ),
      ]),
    );
  }

  Widget _summaryCard() {
    final deviceLabel = _scope == 'device'
        ? (widget.deviceIndex[_target]?.utility ?? (_deviceLabel.isEmpty ? null : _deviceLabel))
        : null;
    final roomLabel = _deviceRoom;
    final sorted = [..._actions]..sort((a, b) => a.minutes.compareTo(b.minutes));
    final actionsText = sorted.isEmpty
        ? 'has no times set yet'
        : sorted
            .map((a) => 'turns ${a.isOn ? 'on' : 'off'} at ${_formatMinutesLabel(a.minutes)}')
            .join(', ');

    String whenText;
    if (_mode == 'calendar') {
      if (_calStart == null) {
        whenText = 'on the date you pick';
      } else if (_calEnd != null && !_isSameDate(_calStart!, _calEnd!)) {
        whenText = 'every day from ${_formatMonthDay(_calStart!)} to ${_formatMonthDay(_calEnd!)}';
      } else {
        whenText = 'on ${_formatMonthDay(_calStart!)} only';
      }
    } else {
      final preset = _daysText(_days);
      whenText = {'Every day', 'Weekdays', 'Weekends'}.contains(preset)
          ? preset.toLowerCase()
          : 'on $preset';
    }

    final subject = deviceLabel != null
        ? '$deviceLabel${roomLabel != null ? ' in $roomLabel' : ''}'
        : 'The device';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _p.line),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.info_outline, size: 18, color: AppColors.inkMid),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid),
              children: [
                TextSpan(
                    text: subject,
                    style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink)),
                TextSpan(text: ' $actionsText, $whenText. Philippine time.'),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}
