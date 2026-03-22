import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../theme/app_colors.dart';

void _safeDialogPop<T>(BuildContext context, [T? result]) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;
    final nav = Navigator.of(context);
    if (!nav.canPop()) return;
    nav.pop<T>(result);
  });
}

// ─── Model ────────────────────────────────────────────────────────────────────

class AutomationSchedule {
  final String id;
  final String name;
  final String scope;
  final String target;
  final String utility;
  final String action;
  final String time;
  final List<String> days;
  final bool enabled;

  AutomationSchedule({
    required this.id,
    required this.name,
    required this.scope,
    required this.target,
    required this.utility,
    required this.action,
    required this.time,
    required this.days,
    required this.enabled,
  });

  factory AutomationSchedule.fromMap(String id, Map<String, dynamic> data) {
    final rawDays = data['days'];
    List<String> days = [];
    if (rawDays is List) {
      days = rawDays.map((d) => d.toString()).toList();
    } else if (rawDays is Map) {
      days = rawDays.values.map((d) => d.toString()).toList();
    }
    return AutomationSchedule(
      id:      id,
      name:    (data['name']    ?? '').toString(),
      scope:   (data['scope']   ?? 'global').toString(),
      target:  (data['target']  ?? 'all').toString(),
      utility: (data['utility'] ?? 'All').toString(),
      action:  (data['action']  ?? 'off').toString(),
      time:    (data['time']    ?? '18:00').toString(),
      days:    days,
      enabled: (data['enabled'] ?? true) as bool,
    );
  }

  Map<String, dynamic> toMap() => {
    'name': name, 'scope': scope, 'target': target,
    'utility': utility, 'action': action, 'time': time,
    'days': days, 'enabled': enabled,
  };
}

// ─── Device Picker Dialog ─────────────────────────────────────────────────────

class _DevicePickerDialog extends StatefulWidget {
  const _DevicePickerDialog();

  @override
  State<_DevicePickerDialog> createState() => _DevicePickerDialogState();
}

class _DevicePickerDialogState extends State<_DevicePickerDialog> {
  static const List<String> _buildingList = ['IC','ILEGG','ITED','IAAS','ADMIN'];
  static const Map<String, int> _buildingFloors = {
    'IC': 2, 'ILEGG': 2, 'ITED': 2, 'IAAS': 1, 'ADMIN': 1,
  };

  String? _selectedBuilding;
  int?    _selectedFloor;
  String? _selectedRoom;
  String? _selectedDeviceId;
  String? _selectedDeviceLabel;

  // Loaded from Firebase
  List<String> _rooms   = [];
  // deviceId → utility label
  Map<String, String> _devices = {};

  bool _loadingRooms   = false;
  bool _loadingDevices = false;

  void _onBuildingChanged(String? b) {
    setState(() {
      _selectedBuilding  = b;
      _selectedFloor     = null;
      _selectedRoom      = null;
      _selectedDeviceId  = null;
      _selectedDeviceLabel = null;
      _rooms   = [];
      _devices = {};
    });
  }

  void _onFloorChanged(int? f) {
    setState(() {
      _selectedFloor     = f;
      _selectedRoom      = null;
      _selectedDeviceId  = null;
      _selectedDeviceLabel = null;
      _rooms   = [];
      _devices = {};
    });
    if (_selectedBuilding != null && f != null) _loadRooms(_selectedBuilding!, f);
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
      if (mounted) setState(() { _rooms = rooms; _loadingRooms = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingRooms = false);
    }
  }

  void _onRoomChanged(String? room) {
    setState(() {
      _selectedRoom      = room;
      _selectedDeviceId  = null;
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
            final deviceRoom = (d['room'] ?? '').toString().trim().toLowerCase();
            if (deviceRoom == room.trim().toLowerCase()) {
              final utility = (d['utility'] ?? 'Unknown').toString();
              devices[deviceId] = '$deviceId · $utility';
            }
          }
        });
      }
      if (mounted) setState(() { _devices = devices; _loadingDevices = false; });
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
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [

          // Step 1 — Building
          _stepLabel('1', 'Building'),
          const SizedBox(height: 6),
          _dropdown<String>(
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
              ? const Padding(padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(color: AppColors.greenMid))
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
              ? const Padding(padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(color: AppColors.greenMid))
              : _devices.isEmpty
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.greenPale,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _selectedRoom == null ? 'Select a room first' : 'No devices in this room',
                        style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
                      ),
                    )
                  : Column(
                      children: _devices.entries.map((e) {
                        final isSelected = _selectedDeviceId == e.key;
                        return GestureDetector(
                          onTap: () => setState(() {
                            _selectedDeviceId    = e.key;
                            _selectedDeviceLabel = e.value;
                          }),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isSelected ? AppColors.greenDark : Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected ? AppColors.greenDark : AppColors.greenMid.withAlpha(60),
                              ),
                            ),
                            child: Row(children: [
                              Icon(Icons.device_hub, size: 16,
                                  color: isSelected ? Colors.white : AppColors.greenMid),
                              const SizedBox(width: 10),
                              Expanded(child: Text(e.value,
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                                      color: isSelected ? Colors.white : AppColors.textDark))),
                              if (isSelected)
                                const Icon(Icons.check_circle, size: 16, color: Colors.white),
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
            child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted))),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.greenDark,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
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
        width: 20, height: 20,
        decoration: const BoxDecoration(color: AppColors.greenDark, shape: BoxShape.circle),
        child: Center(child: Text(step, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white))),
      ),
      const SizedBox(width: 8),
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textDark)),
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
        filled: true, fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppColors.greenMid.withAlpha(51))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppColors.greenMid.withAlpha(51))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.greenMid)),
      ),
      hint: Text(hint, style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
      items: items.map((i) => DropdownMenuItem<T>(value: i, child: Text(labelOf(i)))).toList(),
      onChanged: onChanged,
    );
  }
}

// ─── Automation Screen ────────────────────────────────────────────────────────

class AutomationScreen extends StatefulWidget {
  final String role;
  const AutomationScreen({super.key, this.role = 'faculty'});

  @override
  State<AutomationScreen> createState() => _AutomationScreenState();
}

class _AutomationScreenState extends State<AutomationScreen> {
  List<AutomationSchedule> _schedules = [];
  StreamSubscription<DatabaseEvent>? _sub;
  bool _loading  = true;
  String? _errorText;

  bool get isAdmin => widget.role == 'admin';

  static const List<String> _allDays  = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  static const List<String> _buildings = ['IC','ILEGG','ITED','IAAS','ADMIN'];
  static const List<String> _utilities = ['All','Lights','Outlets','AC'];

  @override
  void initState() {
    super.initState();
    _listenSchedules();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _listenSchedules() {
    _sub?.cancel();
    _sub = FirebaseDatabase.instance.ref('automations').onValue.listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;
      final List<AutomationSchedule> list = [];
      if (raw is Map) {
        raw.forEach((id, val) {
          if (val is Map) list.add(AutomationSchedule.fromMap(id.toString(), Map<String, dynamic>.from(val)));
        });
      }
      list.sort((a, b) => a.time.compareTo(b.time));
      setState(() { _schedules = list; _loading = false; _errorText = null; });
    }, onError: (Object error) {
      if (!mounted) return;
      final denied = error.toString().toLowerCase().contains('permission');
      setState(() {
        _schedules = []; _loading = false;
        _errorText = denied ? 'You do not have permission to view automations.' : 'Failed to load automations.';
      });
    });
  }

  Future<void> _toggleEnabled(AutomationSchedule s) async {
    try {
      await FirebaseDatabase.instance.ref('automations/${s.id}/enabled').set(!s.enabled);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Unable to update schedule.')));
    }
  }

  Future<void> _deleteSchedule(AutomationSchedule s) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Schedule', style: TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
        content: Text('Delete "${s.name}"?'),
        actions: [
          TextButton(onPressed: () => _safeDialogPop(dialogCtx, false),
              child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted))),
          ElevatedButton(
            onPressed: () => _safeDialogPop(dialogCtx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Unable to delete schedule.')));
    }
  }

  Future<void> _addSchedule() async {
    final nameCtrl = TextEditingController();
    String scope   = 'global';
    String target  = 'all';
    String deviceLabel = '';
    String utility = 'All';
    String action  = 'off';
    TimeOfDay time = const TimeOfDay(hour: 18, minute: 0);
    List<String> days = ['Mon','Tue','Wed','Thu','Fri'];
    String? error;
    bool loading = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Add Schedule',
              style: TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [

              // Name
              TextField(
                controller: nameCtrl,
                decoration: _inputDeco('Schedule name', Icons.label_outline),
                autofocus: true,
              ),
              const SizedBox(height: 14),

              // Scope
              _dropdownField('Scope', scope,
                  ['global','building','utility','device'],
                  (v) => setS(() { scope = v!; target = 'all'; deviceLabel = ''; })),
              const SizedBox(height: 12),

              // Target — conditional on scope
              if (scope == 'building') ...[
                _dropdownField('Building', target == 'all' ? _buildings.first : target,
                    _buildings, (v) => setS(() => target = v!)),
                const SizedBox(height: 12),
              ],

              if (scope == 'utility') ...[
                _dropdownField('Utility', target == 'all' ? 'Lights' : target,
                    ['Lights','Outlets','AC'], (v) => setS(() => target = v!)),
                const SizedBox(height: 12),
              ],

              // ── Device picker ────────────────────────────────
              if (scope == 'device') ...[
                GestureDetector(
                  onTap: () async {
                    final result = await showDialog<Map<String, String>>(
                      context: ctx,
                      builder: (_) => const _DevicePickerDialog(),
                    );
                    if (result != null) {
                      setS(() {
                        target      = result['id']!;
                        deviceLabel = result['label']!;
                      });
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.greenMid.withAlpha(80)),
                      borderRadius: BorderRadius.circular(12),
                      color: Colors.white,
                    ),
                    child: Row(children: [
                      const Icon(Icons.device_hub, size: 18, color: AppColors.textMuted),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          deviceLabel.isEmpty ? 'Tap to pick a device' : deviceLabel,
                          style: TextStyle(fontSize: 13,
                              color: deviceLabel.isEmpty ? AppColors.textMuted : AppColors.textDark),
                        ),
                      ),
                      const Icon(Icons.chevron_right, color: AppColors.textMuted, size: 18),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // Utility to control (hidden if scope=utility since target IS the utility)
              if (scope != 'utility') ...[
                _dropdownField('Utility to control', utility, _utilities,
                    (v) => setS(() => utility = v!)),
                const SizedBox(height: 12),
              ],

              // Action
              _actionToggle(action, (v) => setS(() => action = v)),
              const SizedBox(height: 12),

              // Time
              GestureDetector(
                onTap: () async {
                  final picked = await showTimePicker(context: ctx, initialTime: time);
                  if (picked != null) setS(() => time = picked);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.greenMid.withAlpha(80)),
                    borderRadius: BorderRadius.circular(12), color: Colors.white,
                  ),
                  child: Row(children: [
                    const Icon(Icons.access_time, size: 18, color: AppColors.textMuted),
                    const SizedBox(width: 10),
                    Text(time.format(ctx), style: const TextStyle(fontSize: 14, color: AppColors.textDark)),
                    const Spacer(),
                    const Icon(Icons.chevron_right, color: AppColors.textMuted, size: 18),
                  ]),
                ),
              ),
              const SizedBox(height: 12),

              // Days
              const Align(alignment: Alignment.centerLeft,
                  child: Text('Repeat on', style: TextStyle(fontSize: 12,
                      color: AppColors.textMuted, fontWeight: FontWeight.w500))),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6, runSpacing: 6,
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
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: selected ? AppColors.greenDark : AppColors.greenPale,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(d, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                          color: selected ? Colors.white : AppColors.textMid)),
                    ),
                  );
                }).toList(),
              ),

              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!, style: const TextStyle(fontSize: 12, color: AppColors.error)),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => _safeDialogPop(ctx),
                child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.greenDark,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: loading ? null : () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty)  { setS(() => error = 'Name is required'); return; }
                if (days.isEmpty)  { setS(() => error = 'Select at least one day'); return; }
                if (scope == 'device' && target == 'all') {
                  setS(() => error = 'Please select a device'); return;
                }

                final finalTarget  = scope == 'global'  ? 'all'
                    : scope == 'utility' ? target
                    : target == 'all'    ? _buildings.first
                    : target;
                final finalUtility = scope == 'utility' ? target : utility;
                final timeStr = '${time.hour.toString().padLeft(2,'0')}:${time.minute.toString().padLeft(2,'0')}';

                setS(() { loading = true; error = null; });

                final newRef = FirebaseDatabase.instance.ref('automations').push();
                try {
                  await newRef.set(AutomationSchedule(
                    id: newRef.key!, name: name, scope: scope, target: finalTarget,
                    utility: finalUtility, action: action, time: timeStr, days: days, enabled: true,
                  ).toMap());
                } catch (_) {
                  setS(() { loading = false; error = 'No permission to add schedules.'; });
                  return;
                }

                if (!mounted || !ctx.mounted) return;
                _safeDialogPop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Schedule added.')));
              },
              child: loading
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Text('Save', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      floatingActionButton: isAdmin
          ? FloatingActionButton.extended(
              onPressed: _addSchedule,
              backgroundColor: AppColors.greenDark,
              icon: const Icon(Icons.add, color: Colors.white),
              label: const Text('Add Schedule',
                  style: TextStyle(color: Colors.white, fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.greenMid))
          : _errorText != null ? _buildError()
          : _schedules.isEmpty ? _buildEmpty()
          : _buildList(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(width: 72, height: 72,
              decoration: BoxDecoration(color: AppColors.greenPale, borderRadius: BorderRadius.circular(20)),
              child: const Icon(Icons.lock_outline, size: 34, color: AppColors.greenMid)),
          const SizedBox(height: 16),
          const Text('Cannot load automations',
              style: TextStyle(fontFamily: 'Outfit', fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textDark)),
          const SizedBox(height: 8),
          Text(_errorText ?? 'Something went wrong.', textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
        ]),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(width: 72, height: 72,
            decoration: BoxDecoration(color: AppColors.greenPale, borderRadius: BorderRadius.circular(20)),
            child: const Icon(Icons.schedule, size: 36, color: AppColors.greenDark)),
        const SizedBox(height: 16),
        const Text('No schedules yet',
            style: TextStyle(fontFamily: 'Outfit', fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textDark)),
        const SizedBox(height: 6),
        Text(isAdmin ? 'Tap + Add Schedule to create one' : 'No automation schedules set',
            style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
      ]),
    );
  }

  Widget _buildList() {
    final global   = _schedules.where((s) => s.scope == 'global').toList();
    final building = _schedules.where((s) => s.scope == 'building').toList();
    final utility  = _schedules.where((s) => s.scope == 'utility').toList();
    final device   = _schedules.where((s) => s.scope == 'device').toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (global.isNotEmpty)   ...[_sectionHeader('🌐 Global',   global.length),   const SizedBox(height: 10), ...global.map(_buildCard),   const SizedBox(height: 20)],
        if (building.isNotEmpty) ...[_sectionHeader('🏫 Building', building.length), const SizedBox(height: 10), ...building.map(_buildCard), const SizedBox(height: 20)],
        if (utility.isNotEmpty)  ...[_sectionHeader('⚡ Utility',  utility.length),  const SizedBox(height: 10), ...utility.map(_buildCard),  const SizedBox(height: 20)],
        if (device.isNotEmpty)   ...[_sectionHeader('📟 Device',   device.length),   const SizedBox(height: 10), ...device.map(_buildCard),   const SizedBox(height: 20)],
      ]),
    );
  }

  Widget _sectionHeader(String title, int count) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 6,
      children: [
        Text(title, style: const TextStyle(fontFamily: 'Outfit', fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textDark)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: AppColors.greenPale, borderRadius: BorderRadius.circular(20)),
          child: Text('$count', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.greenDark)),
        ),
      ],
    );
  }

  Widget _buildCard(AutomationSchedule s) {
    final actionColor = s.action == 'on' ? AppColors.greenMid : AppColors.warning;
    final actionIcon  = s.action == 'on' ? Icons.power_settings_new : Icons.power_off_outlined;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: s.enabled ? AppColors.greenMid.withAlpha(60) : AppColors.greenMid.withAlpha(20)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 260;
            return isNarrow
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(width: 40, height: 40,
                          decoration: BoxDecoration(color: actionColor.withAlpha(20), borderRadius: BorderRadius.circular(12)),
                          child: Icon(actionIcon, color: actionColor, size: 20)),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(s.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: 'Outfit', fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textDark)),
                        const SizedBox(height: 2),
                        Text(_scopeLabel(s),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
                      ])),
                    ]),
                    if (isAdmin)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Switch(value: s.enabled, activeThumbColor: AppColors.greenMid, onChanged: (_) => _toggleEnabled(s)),
                      ),
                  ])
                : Row(children: [
                    Container(width: 40, height: 40,
                        decoration: BoxDecoration(color: actionColor.withAlpha(20), borderRadius: BorderRadius.circular(12)),
                        child: Icon(actionIcon, color: actionColor, size: 20)),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontFamily: 'Outfit', fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textDark)),
                      const SizedBox(height: 2),
                      Text(_scopeLabel(s),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
                    ])),
                    if (isAdmin)
                      Switch(value: s.enabled, activeThumbColor: AppColors.greenMid, onChanged: (_) => _toggleEnabled(s)),
                  ]);
          },
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _chip(Icons.access_time, s.time, AppColors.greenDark),
          _chip(actionIcon, s.action.toUpperCase(), actionColor),
          _chip(Icons.electrical_services, s.utility, AppColors.greenMid),
        ]),
        const SizedBox(height: 8),
        Wrap(
          spacing: 4, runSpacing: 4,
          children: _allDays.map((d) {
            final active = s.days.contains(d);
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: active ? AppColors.greenDark : AppColors.greenPale,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(d, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                  color: active ? Colors.white : AppColors.textMuted)),
            );
          }).toList(),
        ),
        if (isAdmin) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: () => _deleteSchedule(s),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: AppColors.error.withAlpha(15), borderRadius: BorderRadius.circular(8)),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.delete_outline, size: 14, color: AppColors.error),
                  SizedBox(width: 4),
                  Text('Delete', style: TextStyle(fontSize: 11, color: AppColors.error, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _chip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(15), borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(40)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }

  String _scopeLabel(AutomationSchedule s) {
    switch (s.scope) {
      case 'global':   return 'All buildings · all utilities';
      case 'building': return 'Building: ${s.target}';
      case 'utility':  return 'Utility: ${s.target}';
      case 'device':   return 'Device: ${s.target}';
      default:         return s.scope;
    }
  }

  Widget _actionToggle(String current, Function(String) onChanged) {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: AppColors.greenMid.withAlpha(51)), borderRadius: BorderRadius.circular(12)),
      child: Row(children: ['on','off'].map((a) {
        final selected = current == a;
        final color    = a == 'on' ? AppColors.greenMid : AppColors.warning;
        return Expanded(
          child: GestureDetector(
            onTap: () => onChanged(a),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: selected ? color : Colors.transparent,
                borderRadius: BorderRadius.circular(a == 'on' ? 11 : 0).copyWith(
                  topRight:    a == 'off' ? const Radius.circular(11) : Radius.zero,
                  bottomRight: a == 'off' ? const Radius.circular(11) : Radius.zero,
                ),
              ),
              child: Center(child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(a == 'on' ? Icons.power_settings_new : Icons.power_off_outlined,
                    size: 14, color: selected ? Colors.white : AppColors.textMuted),
                const SizedBox(width: 6),
                Text(a.toUpperCase(), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : AppColors.textMuted)),
              ])),
            ),
          ),
        );
      }).toList()),
    );
  }

  Widget _dropdownField(String label, String value, List<String> items, void Function(String?) onChanged) {
    return DropdownButtonFormField<String>(
      initialValue: items.contains(value) ? value : items.first,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 12, color: AppColors.textMuted),
        filled: true, fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppColors.greenMid.withAlpha(51))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppColors.greenMid.withAlpha(51))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.greenMid)),
      ),
      items: items.map((i) => DropdownMenuItem(value: i, child: Text(i))).toList(),
      onChanged: onChanged,
    );
  }

  InputDecoration _inputDeco(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
      prefixIcon: Icon(icon, size: 18, color: AppColors.textMuted),
      filled: true, fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.greenMid.withAlpha(51))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.greenMid.withAlpha(51))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.greenMid)),
    );
  }
}