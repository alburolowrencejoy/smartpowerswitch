import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/responsive_center.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import '../../widgets/app_top_bar.dart';
import '../../widgets/outline_icon_box.dart';
import '../../widgets/app_switch.dart';
import '../../widgets/delete_flow.dart';
import '../../widgets/delete_row_transition.dart';
import '../../services/readings_service.dart';
import '../../utils/last_seen.dart';
import '../../services/home_widget_service.dart';
import '../../theme/app_fonts.dart';
import 'automation_screen.dart';

class DeviceDetailScreen extends StatefulWidget {
  final String deviceId;
  final String utility;
  final String building;
  final String room;
  final String role;
  final int floor;

  const DeviceDetailScreen({
    super.key,
    required this.deviceId,
    required this.utility,
    required this.building,
    required this.room,
    required this.role,
    required this.floor,
  });

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  Map<String, dynamic> _deviceData = {};
  bool _relay = false;
  bool _hasPzemReadings = false;
  bool _isOnline = false;
  bool _toggling = false;
  double _ratePhp = 11.5;
  double _lastValidEnergy = 0.0; // Persists last valid reading
  double _lastReportedMeterKwh = -1.0; // Track PZEM meter kWh to detect deltas
  int? _lastRecordedSeen; // Track last telemetry update to avoid duplicates
  DateTime?
      _lastToggleTime; // Track when relay was last toggled to ignore Firebase updates

  // Today's accumulated energy for this device, read live from
  // `history/daily/{today}/devices/{deviceId}/kwh` (written by
  // HistoryService whenever a meaningful PZEM delta is recorded) --
  // deliberately NOT the same number as `_lastValidEnergy` above, which is
  // the PZEM's lifetime cumulative meter reading. The redesign's "Energy
  // today" / "Cost today" readings need the daily figure, not lifetime.
  double _energyTodayKwh = 0.0;
  late String _todayKey = _dailyKey(DateTime.now());

  // The single automations entry (if any) whose scope is 'device' and whose
  // target is this deviceId -- drives the Schedule row. Null means "no
  // schedule targets this device" once loading has completed at least once.
  Map<String, dynamic>? _deviceSchedule;

  // One-shot (not live -- a 7-day trend doesn't need 5s-fresh updates) fetch
  // of this device's last 7 daily kWh figures, oldest first. Null while
  // loading; empty-with-error text set on failure instead of silently
  // showing a misleading empty/zero chart.
  List<double>? _weeklyKwh;
  String? _weeklyError;

  // True until the first combined emission (device + rate) has been
  // received; never reverts to true afterwards. Note this does NOT change
  // how the device snapshot itself is handled -- a null device snapshot was
  // already ignored outright (see below), so relay/readings state was
  // already immune to the "blank on reconnect" bug this flag exists for
  // elsewhere; it only gates the skeleton and the rate default.
  bool _isLoading = true;

  // Set only if the combined listener fails (or times out) before the
  // first successful load ever completes -- gives the skeleton shimmer a
  // real escape hatch instead of spinning forever. Once a first load has
  // succeeded, a later error no longer blanks the screen (relay/readings
  // state was already reconnect-safe); it just surfaces a non-blocking
  // toast so a real, sustained failure isn't silently swallowed.
  String? _errorText;
  Timer? _loadTimeoutTimer;
  bool _postLoadErrorNotified = false;

  StreamSubscription? _combinedSub;

  bool _isPermissionDenied(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') ||
        text.contains('permission_denied');
  }

  bool get _canControl =>
      widget.role == 'admin' ||
      widget.role == 'main_admin' ||
      widget.role == 'super_admin' ||
      widget.role == 'institute_admin';

  // ── Institute theming ──────────────────────────────────────────────────
  // `widget.role` is already passed in by the caller (see main.dart's
  // '/device' route), but no institute is threaded through, so it's
  // hydrated here directly from the signed-in user's own record, mirroring
  // dashboard_screen.dart's _hydrateSessionFromAuth. This is purely
  // cosmetic (chrome colors) and never touches relay/readings state.
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
    // Save device selection for home screen widget
    HomeWidgetService.saveDeviceSelection(
      deviceId: widget.deviceId,
      building: widget.building,
      room: widget.room,
    );
    _loadPersistedReading();
    _listenAll();
    _loadWeeklyHistory();
  }

  @override
  void dispose() {
    _combinedSub?.cancel();
    _loadTimeoutTimer?.cancel();
    super.dispose();
  }

  /// Clears the error state and re-attaches the combined listener from
  /// scratch. Used by the Retry button shown when the first load fails.
  /// Does not touch relay/readings state -- only the loading/error flags.
  void _retryLoad() {
    _combinedSub?.cancel();
    _loadTimeoutTimer?.cancel();
    setState(() {
      _errorText = null;
      _isLoading = true;
      _postLoadErrorNotified = false;
    });
    _listenAll();
    _loadWeeklyHistory();
  }

  // ── Listen directly to Firebase for real-time relay state, combined with
  // the electricity rate, today's energy total and this device's schedule
  // (if any) into a single stream (see class doc for _isLoading).
  // Background service continues collecting readings independently.
  void _listenAll() {
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted || !_isLoading) return;
      setState(() {
        _isLoading = false;
        _errorText =
            'Taking too long to load this device. Check your connection.';
      });
    });

    _todayKey = _dailyKey(DateTime.now());

    _combinedSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('devices/${widget.deviceId}').onValue,
      FirebaseDatabase.instance.ref('settings/electricityRate').onValue,
      FirebaseDatabase.instance
          .ref('history/daily/$_todayKey/devices/${widget.deviceId}/kwh')
          .onValue,
      FirebaseDatabase.instance.ref('automations').onValue,
    ]).listen((events) {
      if (!mounted) return;
      _loadTimeoutTimer?.cancel();

      final raw = events[0].snapshot.value;
      final rateRaw = events[1].snapshot.value;
      final todayKwhRaw = events[2].snapshot.value;
      final automationsRaw = events[3].snapshot.value;

      // Precompute the device-side updates exactly as the original
      // single-path listener did -- a null/duplicate snapshot is ignored
      // outright rather than clearing anything (this device stream was
      // already reconnect-safe before this change).
      Map<String, dynamic>? parsedDevice;
      bool? computedHasPzem;
      bool? computedIsOnline;
      bool? computedRelay;
      int? newLastSeen;

      if (raw != null) {
        final data = Map<String, dynamic>.from(raw as Map);
        final lastSeen = (data['last_seen'] as num?)?.toInt();

        if (lastSeen == null || lastSeen != _lastRecordedSeen) {
          // ✅ Use PZEM meter kWh delta (not calculated from power)
          // The PZEM module reports cumulative energy since last reset.
          // We track deltas and write only significant changes to history.
          final meterKwh = (data['kwh'] as num?)?.toDouble() ?? 0.0;
          final relay = (data['relay'] as bool?) ?? false;

          // Don't override relay state if we just toggled it (give ESP32
          // time to respond).
          final now = DateTime.now();
          final ignoreRelayUpdate = _lastToggleTime != null &&
              now.difference(_lastToggleTime!).inMilliseconds < 3000;

          // Calculate delta from PZEM meter reading
          double kwhDelta = 0.0;
          if (_lastReportedMeterKwh >= 0.0) {
            kwhDelta = meterKwh - _lastReportedMeterKwh;
            // If meter reset detected (new reading < old), use new reading
            // as delta.
            if (kwhDelta < 0.0) {
              kwhDelta = meterKwh;
            }
          }

          // Only record if delta is significant (avoid noise). History
          // itself is written once, globally, by GlobalReadingsListener --
          // this screen no longer duplicates that write, which used to
          // double-count energy/cost for a device whenever its detail
          // screen happened to be open.
          if (kwhDelta >= 0.000001) {
            _lastValidEnergy = meterKwh; // Running total = meter reading

            ReadingsService.recordReading(
              deviceId: widget.deviceId,
              building: widget.building,
              room: widget.room,
              kwh: _lastValidEnergy,
              relay: relay,
            );

            _lastReportedMeterKwh = meterKwh; // Track this meter reading
          }

          parsedDevice = data;
          computedHasPzem = _checkHasPzemReadings(data);
          computedIsOnline = _checkOnline(data);
          computedRelay = ignoreRelayUpdate ? null : relay;
          newLastSeen = lastSeen;
        }
      }

      // ── this device's schedule (if any) ─────────────────────────────
      Map<String, dynamic>? parsedSchedule;
      if (automationsRaw is Map) {
        parsedSchedule = _findDeviceSchedule(automationsRaw);
      }

      setState(() {
        if (parsedDevice != null) {
          _deviceData = parsedDevice;
          _hasPzemReadings = computedHasPzem!;
          _isOnline = computedIsOnline!;
          if (computedRelay != null) {
            _relay = computedRelay;
          }
        }

        if (rateRaw is num) {
          _ratePhp = rateRaw.toDouble();
        } else if (_isLoading) {
          _ratePhp = 11.5;
        }

        if (todayKwhRaw is num) {
          _energyTodayKwh = todayKwhRaw.toDouble();
        } else if (_isLoading) {
          _energyTodayKwh = 0.0;
        }

        if (automationsRaw is Map) {
          _deviceSchedule = parsedSchedule;
        } else if (_isLoading) {
          _deviceSchedule = null;
        }

        _isLoading = false;
        _errorText = null;
        _postLoadErrorNotified = false;
      });

      if (parsedDevice != null) {
        // Update home screen widget with latest data
        unawaited(HomeWidgetService.updateWidget());
        if (newLastSeen != null) {
          _lastRecordedSeen = newLastSeen;
        }
      }
    }, onError: (Object error) {
      if (!mounted) return;
      debugPrint('[DeviceDetail] Combined listen error: $error');
      _loadTimeoutTimer?.cancel();
      if (_isLoading) {
        // Never loaded successfully yet -- surface a real error state
        // instead of leaving the skeleton shimmer spinning forever. This
        // does not touch _relay/_deviceData, which were never populated.
        setState(() {
          _isLoading = false;
          _errorText = _isPermissionDenied(error)
              ? 'You do not have permission to view this device.'
              : 'Failed to load this device.';
        });
      } else if (!_postLoadErrorNotified) {
        // Already showing real relay/readings data this session -- keep it
        // on screen (sticky, as before) and just surface a lightweight,
        // non-blocking notice instead of silently swallowing the error.
        _postLoadErrorNotified = true;
        TopToast.show(
          context,
          'Lost connection to live device data.',
          isError: true,
        );
      }
    });
  }

  Map<String, dynamic>? _findDeviceSchedule(Map automationsRaw) {
    for (final entry in automationsRaw.entries) {
      final val = entry.value;
      if (val is! Map) continue;
      final scope = (val['scope'] ?? '').toString();
      final target = (val['target'] ?? '').toString();
      if (scope == 'device' && target == widget.deviceId) {
        final data = Map<String, dynamic>.from(val);
        data['id'] = entry.key.toString();
        return data;
      }
    }
    return null;
  }

  Future<void> _loadPersistedReading() async {
    try {
      final snap = await FirebaseDatabase.instance
          .ref('readings/${widget.building}/${widget.room}/${widget.deviceId}')
          .get();

      if (!mounted || snap.value == null || snap.value is! Map) return;

      final data = Map<String, dynamic>.from(snap.value as Map);
      final cumulative = (data['cumulative_kwh'] as num?)?.toDouble();
      if (cumulative == null) return;

      setState(() {
        _lastValidEnergy = cumulative;
        _lastReportedMeterKwh = cumulative;
        _hasPzemReadings = true;
      });
    } catch (e) {
      debugPrint('[DeviceDetail] Failed to load persisted reading: $e');
    }
  }

  // ── Last 7 days (one-shot; see field doc) ────────────────────────────
  Future<void> _loadWeeklyHistory() async {
    setState(() {
      _weeklyKwh = null;
      _weeklyError = null;
    });
    try {
      final now = DateTime.now();
      final keys = List.generate(
          7, (i) => _dailyKey(now.subtract(Duration(days: 6 - i))));
      final snaps = await Future.wait(keys.map((key) => FirebaseDatabase
          .instance
          .ref('history/daily/$key/devices/${widget.deviceId}/kwh')
          .get()));
      if (!mounted) return;
      setState(() {
        _weeklyKwh = snaps
            .map((s) => (s.value as num?)?.toDouble() ?? 0.0)
            .toList(growable: false);
      });
    } catch (e) {
      debugPrint('[DeviceDetail] Failed to load 7-day history: $e');
      if (!mounted) return;
      setState(() => _weeklyError = 'History unavailable right now.');
    }
  }

  String _dailyKey(DateTime d) => '${d.year}-${_pad(d.month)}-${_pad(d.day)}';
  String _pad(int n) => n.toString().padLeft(2, '0');

  // ── Online check based on last_seen (< 2 minutes = online) ──────────────────
  bool _checkOnline(Map<String, dynamic> data) =>
      isRecentlySeen(data['last_seen']);

  bool _checkHasPzemReadings(Map<String, dynamic> data) {
    final voltage = data['voltage'];
    if (voltage is! num) return false;
    return voltage.toDouble() > 0.0;
  }

  String _safeFormatPzem(dynamic value, int decimals) {
    if (value is! num) return '--';
    final numVal = value;
    // Check for NaN and negative infinity
    if (numVal.isNaN || numVal.isInfinite) return '00';
    return numVal.toDouble().toStringAsFixed(decimals);
  }

  String? _voltageWarningMessage(Map<String, dynamic> data) {
    final warning = data['voltage_warning']?.toString();
    switch (warning) {
      case 'under_voltage_brownout':
        return 'Under-voltage (Brownout) Below 207V';
      case 'over_voltage_surge':
        return 'Over-voltage (Surge) Above 253V';
      default:
        return null;
    }
  }

  String _lastSeenText() {
    final millis = lastSeenMillis(_deviceData['last_seen']);
    if (millis == null) return 'never';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }

  // ── Toggle relay in BOTH locations ───────────────────────────────────────────
  Future<void> _toggleRelay() async {
    if (_toggling) return;
    final previousRelay = _relay;
    final newRelay = !previousRelay;

    _lastToggleTime = DateTime.now(); // Record when we toggled

    setState(() {
      _relay = newRelay;
      _toggling = true;
    });

    final db = FirebaseDatabase.instance.ref();
    Object? lastError;
    var success = false;

    for (var attempt = 0; attempt < 2 && !success; attempt++) {
      try {
        // Update the live device node first so the ESP32 and the relay card
        // react immediately, then mirror to the building copy in the background.
        await db
            .child('devices/${widget.deviceId}/relay')
            .set(newRelay)
            .timeout(const Duration(milliseconds: 1200));

        // Best-effort mirror for the building/floor screens.
        unawaited(db
            .child(
                'buildings/${widget.building}/floorData/${widget.floor}/devices/${widget.deviceId}/relay')
            .set(newRelay));

        success = true;
      } catch (e) {
        lastError = e;
        if (attempt < 1) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _toggling = false;
      if (!success) {
        _relay = previousRelay;
        _lastToggleTime = null; // Clear toggle time if failed
      }
    });

    if (!success) {
      debugPrint('Relay update failed: $lastError');
      TopToast.error(context, 'Could not reach the device. Try again.');
    }
  }

  Future<void> _toggleScheduleEnabled(bool newValue) async {
    final schedule = _deviceSchedule;
    if (schedule == null) return;
    final id = schedule['id'] as String;
    try {
      await FirebaseDatabase.instance
          .ref('automations/$id/enabled')
          .set(newValue);
    } catch (e) {
      if (!mounted) return;
      TopToast.error(context, 'Unable to update schedule.');
    }
  }

  /// Pushes today's automation editor for this device. There is no
  /// dedicated per-device "schedule editor" route yet (per the redesign
  /// handoff, that's a later phase) -- this wires the Schedule row to the
  /// same `AutomationScreen` the Automation tab already uses, wrapped in a
  /// minimal app bar so it's reachable as a pushed screen. Deliberately not
  /// restyled or otherwise modified.
  void _openScheduleEditor() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(
          backgroundColor: _palette.dark,
          foregroundColor: Colors.white,
          title: const Text('Automation',
              style: TextStyle(fontFamily: AppFonts.family)),
        ),
        body: AutomationScreen(role: widget.role),
      ),
    ));
  }

  Future<void> _confirmUnlink() async {
    // Captured before any pop below -- this Navigator's own context stays
    // mounted for the lifetime of the app (it belongs to the containing
    // route stack, not this screen), so it's safe to use for a toast after
    // this screen has already been popped by `onOptimisticRemove`.
    final messengerContext = Navigator.of(context, rootNavigator: true).context;
    final hasSchedule = _deviceSchedule != null;

    final committed = await showDeleteFlow(
      context,
      type: DeleteType.device,
      itemName: '${_utilityLabel(widget.utility)} · ${widget.deviceId}',
      impact: [
        'The device will be unassigned from ${widget.building} · Floor ${widget.floor} · ${widget.room}',
        hasSchedule
            ? '1 schedule will stop'
            : 'No schedules are linked to this device',
        'It can be registered again later',
      ],
      onOptimisticRemove: () {
        if (Navigator.of(context).canPop()) Navigator.of(context).pop();
        markPendingRowDelete('device:${widget.deviceId}');
      },
      onRestore: () => clearPendingRowDelete('device:${widget.deviceId}'),
      onCommit: (reason, otherText) =>
          _commitUnlink(messengerContext, reason, otherText),
    );

    if (committed && messengerContext.mounted) {
      TopToast.success(messengerContext, 'Device removed');
    }
  }

  Future<void> _commitUnlink(
      BuildContext messengerContext, String reason, String? otherText) async {
    final db = FirebaseDatabase.instance.ref();
    final user = FirebaseAuth.instance.currentUser;
    final logRef = db.child('deletion_log').push();

    final updates = <String, Object?>{
      'buildings/${widget.building}/floorData/${widget.floor}/devices/${widget.deviceId}':
          null,
      'master_devices/${widget.deviceId}/assignedTo': '',
      'devices/${widget.deviceId}/building': '',
      'devices/${widget.deviceId}/floor': '',
      'devices/${widget.deviceId}/room': '',
      'devices/${widget.deviceId}/status': 'offline',
      'deletion_log/${logRef.key}': {
        'type': 'device',
        'deviceId': widget.deviceId,
        'utility': widget.utility,
        'buildingCode': widget.building,
        'floor': widget.floor,
        'room': widget.room,
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
      if (messengerContext.mounted) {
        TopToast.error(messengerContext, 'Failed to remove device: $e');
      }
      rethrow;
    } finally {
      clearPendingRowDelete('device:${widget.deviceId}');
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(widget.role, _institute)],
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Column(
            children: [
              AppTopBar(
                title: _utilityLabel(widget.utility),
                subtitle:
                    '${widget.building} · Floor ${widget.floor} · ${widget.room}',
                variant: AppTopBarVariant.small,
                showBackButton: true,
                showInstituteLine: true,
                palette: _palette,
                actions: _canControl
                    ? [
                        AppTopBarAction(
                          icon: Icons.link_off,
                          tooltip: 'Remove device',
                          onTap: _confirmUnlink,
                        ),
                      ]
                    : const [],
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: ResponsiveCenter(
                    maxWidth: 720,
                    child: _errorText != null
                        ? _buildError()
                        : ScreenSkeleton(
                            isLoading: _isLoading,
                            child: Column(
                              children: [
                                _buildPowerSection(),
                                const SizedBox(height: 24),
                                _buildReadingsSection(),
                                const SizedBox(height: 20),
                                _buildWeeklyBarsSection(),
                                const SizedBox(height: 20),
                                _buildScheduleRow(),
                                const SizedBox(height: 16),
                                _buildDeviceIdRow(),
                              ],
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: AppColors.hairline),
                  borderRadius: BorderRadius.circular(20)),
              child:
                  Icon(Icons.wifi_off_rounded, size: 34, color: _palette.mid)),
          const SizedBox(height: 16),
          Text('Cannot load device',
              style: AppTextStyles.title.copyWith(color: AppColors.ink)),
          const SizedBox(height: 8),
          Text(_errorText ?? 'Something went wrong.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
          const SizedBox(height: 16),
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

  // ── Big round power button + status (handoff §4.5) ───────────────────
  Widget _buildPowerSection() {
    final on = _relay;
    final watts = _safeFormatPzem(_deviceData['power'], 0);

    return Column(children: [
      GestureDetector(
        onTap: (_canControl && !_toggling) ? _toggleRelay : null,
        child: Container(
          width: 132,
          height: 132,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            border: Border.all(color: _palette.line, width: 1.5),
          ),
          child: Container(
            width: 112,
            height: 112,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on ? _palette.dark : const Color(0xFFE3EBE6),
            ),
            child: _toggling
                ? SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: on ? Colors.white : AppColors.inkMid,
                    ),
                  )
                : Icon(
                    Icons.power_settings_new,
                    size: 48,
                    color: on ? Colors.white : AppColors.inkMid,
                  ),
          ),
        ),
      ),
      const SizedBox(height: 14),
      Text(on ? 'On' : 'Off',
          style: AppTextStyles.titleLg.copyWith(color: AppColors.ink)),
      const SizedBox(height: 6),
      Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          _statusPill(),
          if (_hasPzemReadings)
            Text('$watts W',
                style: AppTextStyles.label.copyWith(color: AppColors.ink)),
          Text('· seen ${_lastSeenText()}',
              style: AppTextStyles.caption.copyWith(color: AppColors.inkMuted)),
        ],
      ),
      if (!_canControl) ...[
        const SizedBox(height: 6),
        Text('Only admins can control this device',
            style: AppTextStyles.caption.copyWith(color: AppColors.inkMuted)),
      ],
      if (_voltageWarningMessage(_deviceData) != null) ...[
        const SizedBox(height: 8),
        Text(
          _voltageWarningMessage(_deviceData)!,
          style: AppTextStyles.caption.copyWith(
            color: AppColors.warningText,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ]);
  }

  // Semantic: fixed online/offline pairing, deliberately NOT retheme'd (same
  // reasoning the original file already documented for this badge).
  Widget _statusPill() {
    final color = _isOnline ? AppColors.successText : AppColors.offline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration:
          BoxDecoration(
              color: Colors.white,
              border: Border.all(color: color.withAlpha(140)),
              borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 5),
        Text(_isOnline ? 'Online' : 'Offline',
            style: AppTextStyles.caption
                .copyWith(color: color, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  // ── Live readings (handoff §4.5: "PZEM-004T · every 5 s") ────────────
  Widget _buildReadingsSection() {
    final voltage = _safeFormatPzem(_deviceData['voltage'], 1);
    final current = _safeFormatPzem(_deviceData['current'], 2);
    final power = _safeFormatPzem(_deviceData['power'], 1);
    final powerFactor = _safeFormatPzem(_deviceData['powerFactor'], 2);
    final energyToday = _energyTodayKwh.toStringAsFixed(2);
    final costToday = (_energyTodayKwh * _ratePhp).toStringAsFixed(2);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Live readings',
            style: AppTextStyles.title.copyWith(color: AppColors.ink)),
        const SizedBox(height: 2),
        Text('PZEM-004T · every 5 s',
            style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 2.0,
          children: [
            _readingBox('Power', power, 'W'),
            _readingBox('Energy today', energyToday, 'kWh'),
            _readingBox('Voltage', voltage, 'V'),
            _readingBox('Current', current, 'A'),
            _readingBox('Power factor', powerFactor, null),
            _readingBox('Cost today', '₱$costToday', null),
          ],
        ),
      ],
    );
  }

  // White + 1px institute-line border, no tinted fill -- handoff §3.2's
  // "outline system" applied to the reading boxes (preview `.dev .reading`).
  Widget _readingBox(String label, String value, String? unit) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _palette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
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
                      fontSize: 20,
                      fontWeight: FontWeight.w700)),
              if (unit != null) ...[
                const SizedBox(width: 3),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(unit,
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

  // ── Last 7 days bar chart (handoff §4.5) ─────────────────────────────
  Widget _buildWeeklyBarsSection() {
    final weekly = _weeklyKwh;
    final avgLabel = (weekly == null || weekly.isEmpty)
        ? null
        : (weekly.reduce((a, b) => a + b) / weekly.length).toStringAsFixed(1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Last 7 days',
            style: AppTextStyles.title.copyWith(color: AppColors.ink)),
        const SizedBox(height: 2),
        Text(
          avgLabel == null ? 'kWh per day' : 'Average $avgLabel kWh',
          style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _palette.line),
          ),
          child: _weeklyError != null
              ? SizedBox(
                  height: 96,
                  child: Center(
                    child: Text(_weeklyError!,
                        style: AppTextStyles.bodySm
                            .copyWith(color: AppColors.inkMuted)),
                  ),
                )
              : weekly == null
                  ? const SizedBox(
                      height: 96,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _WeeklyBars(values: weekly, palette: _palette),
        ),
      ],
    );
  }

  // ── Schedule row (handoff §4.5: "tap → editor") ──────────────────────
  Widget _buildScheduleRow() {
    final schedule = _deviceSchedule;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Schedule',
            style: AppTextStyles.title.copyWith(color: AppColors.ink)),
        const SizedBox(height: 8),
        Material(
          color: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _openScheduleEditor,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _palette.line),
              ),
              child: Row(children: [
                OutlineIconBox(icon: Icons.schedule, palette: _palette),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        schedule == null
                            ? 'No schedule set'
                            : (schedule['name'] ?? 'Schedule').toString(),
                        style: AppTextStyles.subtitle
                            .copyWith(color: AppColors.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        schedule == null
                            ? 'Tap to add one'
                            : _scheduleSummary(schedule),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodySm
                            .copyWith(color: AppColors.inkMuted),
                      ),
                    ],
                  ),
                ),
                if (schedule != null && _canControl)
                  AppSwitch(
                    value: schedule['enabled'] == true,
                    onChanged: _toggleScheduleEnabled,
                    palette: _palette,
                  ),
              ]),
            ),
          ),
        ),
      ],
    );
  }

  String _scheduleSummary(Map<String, dynamic> schedule) {
    final onTime = _formatTime12h(schedule['onTime']?.toString());
    final offTime = _formatTime12h(schedule['offTime']?.toString());
    final daysRaw = schedule['days'];
    final days = daysRaw is List
        ? daysRaw.map((d) => d.toString()).toList()
        : <String>[];
    final dayLabel = days.isEmpty
        ? 'Every day'
        : (days.length == 7 ? 'Every day' : days.join(', '));
    return 'On $onTime · Off $offTime · $dayLabel';
  }

  String _formatTime12h(String? hhmm) {
    if (hhmm == null) return '--';
    final parts = hhmm.split(':');
    if (parts.length != 2) return hhmm;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return hhmm;
    final period = h >= 12 ? 'PM' : 'AM';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12:${m.toString().padLeft(2, '0')} $period';
  }

  // ── Device ID row with copy (handoff §4.5) ───────────────────────────
  Widget _buildDeviceIdRow() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _palette.line),
      ),
      child: Row(children: [
        OutlineIconBox(icon: Icons.memory, palette: _palette),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.deviceId,
                  style: AppTextStyles.subtitle.copyWith(color: AppColors.ink)),
              const SizedBox(height: 2),
              Text('Device ID',
                  style:
                      AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Copy device ID',
          icon: Icon(Icons.content_copy, size: 20, color: _palette.dark),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: widget.deviceId));
            if (!mounted) return;
            TopToast.success(context, 'Copied');
          },
        ),
      ]),
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
}

/// Simple 7-bar chart (today emphasized), scoped to this screen only --
/// deliberately not a shared widget since no other screen needs it yet.
class _WeeklyBars extends StatelessWidget {
  const _WeeklyBars({required this.values, required this.palette});

  final List<double> values;
  final InstitutePalette palette;

  static const _dayLabels = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

  @override
  Widget build(BuildContext context) {
    final max = values.fold<double>(0, (m, v) => v > m ? v : m);
    final safeMax = max <= 0 ? 1.0 : max;
    final today = DateTime.now();

    return SizedBox(
      height: 120,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(values.length, (i) {
          final isToday = i == values.length - 1;
          final date = today.subtract(Duration(days: values.length - 1 - i));
          final heightFactor = (values[i] / safeMax).clamp(0.04, 1.0);
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: heightFactor,
                        child: Container(
                          decoration: BoxDecoration(
                            color: isToday ? palette.dark : palette.mid,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isToday ? 'Today' : _dayLabels[date.weekday % 7],
                    style: AppTextStyles.captionSmall
                        .copyWith(color: AppColors.inkMuted),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}
