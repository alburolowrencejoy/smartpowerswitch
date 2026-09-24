import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/responsive_center.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import '../../services/readings_service.dart';
import '../../services/home_widget_service.dart';
import '../../theme/app_fonts.dart';

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
  }

  // ── Listen directly to Firebase for real-time relay state, combined with
  // the electricity rate into a single stream (see class doc for
  // _isLoading). Background service continues collecting readings
  // independently.
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

    _combinedSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('devices/${widget.deviceId}').onValue,
      FirebaseDatabase.instance.ref('settings/electricityRate').onValue,
    ]).listen((events) {
      if (!mounted) return;
      _loadTimeoutTimer?.cancel();

      final raw = events[0].snapshot.value;
      final rateRaw = events[1].snapshot.value;

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


  // ── Online check based on last_seen (< 2 minutes = online) ──────────────────
  bool _checkOnline(Map<String, dynamic> data) {
    final lastSeen = data['last_seen'];
    if (lastSeen == null || lastSeen == 0) return false;
    final lastSeenTime = DateTime.fromMillisecondsSinceEpoch(lastSeen as int);
    return DateTime.now().difference(lastSeenTime).inMinutes < 2;
  }

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
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Use last valid energy, cost stays persistent when NaN arrives
    final energy = _lastValidEnergy;
    final cost = energy * _ratePhp;

    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(widget.role, _institute)],
      ),
      child: Scaffold(
        backgroundColor: AppColors.surface,
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
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
                                _buildStatusCard(),
                                const SizedBox(height: 16),
                                _buildRelayCard(),
                                const SizedBox(height: 16),
                                _buildReadingsGrid(),
                                const SizedBox(height: 16),
                                _buildCostCard(energy, cost),
                                const SizedBox(height: 16),
                                _buildDeviceInfoCard(),
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
                  color: _palette.pale,
                  borderRadius: BorderRadius.circular(20)),
              child: Icon(Icons.wifi_off_rounded, size: 34, color: _palette.mid)),
          const SizedBox(height: 16),
          const Text('Cannot load device',
              style: TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark)),
          const SizedBox(height: 8),
          Text(_errorText ?? 'Something went wrong.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _retryLoad,
            icon: const Icon(Icons.refresh, size: 16, color: Colors.white),
            label:
                const Text('Retry', style: TextStyle(color: Colors.white)),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      decoration: BoxDecoration(
        color: _palette.dark,
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(38),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.arrow_back_ios_new,
                color: Colors.white, size: 16),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${widget.building} · Floor ${widget.floor}',
                style: TextStyle(
                    fontSize: 11,
                    color: _palette.light,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5)),
            Text(_utilityLabel(widget.utility),
                style: const TextStyle(
                    fontFamily: AppFonts.family,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
          ]),
        ),
        // Semantic: this whole badge (background/dot/text) is a live
        // online/offline device-status indicator paired against
        // AppColors.offline for the offline state -- deliberately NOT
        // retheme'd (see also _buildStatusCard's "Last seen" text and
        // _buildRelayCard's relay-state coloring below, which follow the
        // same reasoning).
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _isOnline
                ? AppColors.greenLight.withAlpha(51)
                : Colors.white.withAlpha(26),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isOnline ? AppColors.greenLight : AppColors.offline,
              ),
            ),
            const SizedBox(width: 5),
            Text(_isOnline ? 'Online' : 'Offline',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _isOnline ? AppColors.greenLight : AppColors.offline,
                )),
          ]),
        ),
      ]),
    );
  }

  Widget _buildStatusCard() {
    final lastSeen = _deviceData['last_seen'];
    String lastSeenText = 'Never';
    if (lastSeen != null && lastSeen != 0) {
      final dt = DateTime.fromMillisecondsSinceEpoch(lastSeen as int);
      final diff = DateTime.now().difference(dt);
      if (diff.inSeconds < 60) {
        lastSeenText = '${diff.inSeconds}s ago';
      } else if (diff.inMinutes < 60) {
        lastSeenText = '${diff.inMinutes}m ago';
      } else {
        lastSeenText = '${diff.inHours}h ago';
      }
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Row(children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: _utilityColor(widget.utility).withAlpha(31),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(_utilityIcon(widget.utility),
              size: 28, color: _utilityColor(widget.utility)),
        ),
        const SizedBox(width: 16),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.deviceId,
              style: const TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark)),
          const SizedBox(height: 2),
          Text(
              '${widget.building} · Floor ${widget.floor} · ${_utilityLabel(widget.utility)}',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          const SizedBox(height: 4),
          // Semantic: same online/offline pairing as the header badge --
          // deliberately NOT retheme'd.
          Text('Last seen: $lastSeenText',
              style: TextStyle(
                fontSize: 11,
                color: _isOnline ? AppColors.greenMid : AppColors.offline,
              )),
        ])),
      ]),
    );
  }

  Widget _buildRelayCard() {
    final isAc = widget.utility == 'ac';
    // Show relay state even when there are no PZEM readings (meter may be
    // placed after the relay). Allow toggling regardless of PZEM presence.
    final relayVisible = _relay;
    final warningMessage = _voltageWarningMessage(_deviceData);
    // Semantic: this entire card's coloring (background, border, text, the
    // toggle track/knob further down) is driven by `relayVisible`
    // (live relay ON/OFF hardware state) and `_isOnline` -- this is the
    // canonical case the institute-theming rollout heuristic calls out
    // (enabled/disabled state), so none of it is retheme'd below.
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: relayVisible ? AppColors.greenDark : AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: relayVisible
              ? AppColors.greenMid
              : AppColors.greenMid.withAlpha(26),
        ),
      ),
      child: Row(children: [
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(isAc ? 'Contactor' : 'Relay',
              style: TextStyle(
                  fontSize: 12,
                  color: relayVisible
                      ? AppColors.greenPale
                      : AppColors.textMuted)),
          const SizedBox(height: 4),
          Text(relayVisible ? 'Turned ON' : 'Turned OFF',
              style: TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: relayVisible ? Colors.white : AppColors.textDark)),
          const SizedBox(height: 2),
          Text(
            !_hasPzemReadings
                ? 'No PZEM reading'
                : (!_isOnline
                    ? 'Device is offline'
                    : (relayVisible ? 'Tap to turn off' : 'Tap to turn on')),
            style: TextStyle(
                fontSize: 12,
                color: relayVisible
                    ? AppColors.greenPale.withAlpha(179)
                    : AppColors.textMuted),
          ),
          if (warningMessage != null) ...[
            const SizedBox(height: 4),
            Text(
              warningMessage,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFFFFC107),
              ),
            ),
          ],
        ])),
        // Only show toggle if role is admin
        if (widget.role == 'admin' ||
            widget.role == 'main_admin' ||
            widget.role == 'super_admin' ||
            widget.role == 'institute_admin')
          GestureDetector(
            onTap: (!_toggling) ? _toggleRelay : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 64,
              height: 34,
              decoration: BoxDecoration(
                color: !_isOnline
                    ? Colors.grey.withAlpha(80)
                    : (relayVisible
                        ? AppColors.greenLight
                        : const Color(0xFFE0E0E0)),
                borderRadius: BorderRadius.circular(17),
              ),
              child: Stack(children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 250),
                  left: relayVisible ? 32 : 2,
                  top: 2,
                  bottom: 2,
                  child: Container(
                    width: 30,
                    decoration: const BoxDecoration(
                        color: Colors.white, shape: BoxShape.circle),
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        switchInCurve: Curves.easeOutBack,
                        switchOutCurve: Curves.easeIn,
                        transitionBuilder: (child, animation) {
                          return ScaleTransition(
                            scale: Tween<double>(begin: 0.5, end: 1.0)
                                .animate(animation),
                            child: RotationTransition(
                              turns: Tween<double>(begin: 0.85, end: 1.0)
                                  .animate(animation),
                              child: child,
                            ),
                          );
                        },
                        child: _toggling
                            ? const SizedBox(
                                key: ValueKey('loading'),
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.greenMid,
                                ),
                              )
                            : Icon(
                                relayVisible
                                    ? Icons.power_rounded
                                    : Icons.power_off_rounded,
                                key: ValueKey<bool>(relayVisible),
                                size: 15,
                                color: relayVisible
                                    ? AppColors.greenMid
                                    : AppColors.textMuted,
                              ),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        // Faculty sees a lock icon instead
        if (widget.role != 'admin')
          Container(
            width: 64,
            height: 34,
            decoration: BoxDecoration(
              color: Colors.grey.withAlpha(40),
              borderRadius: BorderRadius.circular(17),
            ),
            child: const Icon(Icons.lock_outline,
                size: 16, color: AppColors.textMuted),
          ),
      ]),
    );
  }

  Widget _buildReadingsGrid() {
    final voltage = _safeFormatPzem(_deviceData['voltage'], 1);
    final current = _safeFormatPzem(_deviceData['current'], 2);
    final power = _safeFormatPzem(_deviceData['power'], 1);
    final powerFactor = _safeFormatPzem(_deviceData['powerFactor'], 2);
    final frequency = _safeFormatPzem(_deviceData['frequency'], 1);
    // Display kWh as accumulated energy (kW × hours). _lastValidEnergy is
    // accumulated from instantaneous `power` (Watts) readings using the
    // formula: kWh = (power_watts / 1000) × time_hours.
    final energyValue = _lastValidEnergy > 0
        ? _lastValidEnergy
        : ((_deviceData['kwh'] is num)
            ? (_deviceData['kwh'] as num).toDouble()
            : 0.0);
    final energy = energyValue.toStringAsFixed(2);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('PZEM-004T Readings',
            style: TextStyle(
                fontFamily: AppFonts.family,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final crossAxisCount = responsiveColumnCount(
              constraints.maxWidth,
              mobileColumns: 3,
              idealTileWidth: 150,
              maxColumns: 6,
            );
            return GridView.count(
              crossAxisCount: crossAxisCount,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 1.05,
              // Semantic: fixed per-metric color key (voltage/current/power/
              // energy/frequency/power factor each get their own hue so the
              // 6 tiles stay visually distinguishable), mixing AppColors.green*
              // with literal hex colors (blue/purple) -- not institute brand
              // chrome, so deliberately NOT retheme'd.
              children: [
                _readingTile('Voltage', voltage, 'V', Icons.electrical_services,
                    AppColors.greenMid),
                _readingTile(
                    'Current', current, 'A', Icons.bolt, AppColors.warning),
                _readingTile(
                    'Power', power, 'W', Icons.power, AppColors.greenDark),
                _readingTile('Energy', energy, 'kWh',
                    Icons.battery_charging_full, const Color(0xFF2196F3)),
                _readingTile('Freq.', frequency, 'Hz', Icons.waves,
                    AppColors.greenLight),
                _readingTile('P.Factor', powerFactor, '', Icons.speed,
                    const Color(0xFF9C27B0)),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _readingTile(
      String label, String value, String unit, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withAlpha(38)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, size: 18, color: color),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(value,
                  style: const TextStyle(
                      fontFamily: AppFonts.family,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDark)),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 2),
                Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: Text(unit,
                      style: const TextStyle(
                          fontSize: 9, color: AppColors.textMuted)),
                ),
              ],
            ]),
            Text(label,
                style:
                    const TextStyle(fontSize: 10, color: AppColors.textMuted)),
          ]),
        ],
      ),
    );
  }

  Widget _buildCostCard(double energy, double cost) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _palette.pale,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(51)),
      ),
      child: Row(children: [
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Estimated Cost',
              style: TextStyle(fontSize: 12, color: AppColors.textMid)),
          const SizedBox(height: 4),
          Text('₱ ${cost.toStringAsFixed(2)}',
              style: TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: _palette.dark)),
          Text('at ₱${_ratePhp.toStringAsFixed(2)} / kWh',
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          const Text('Total Energy',
              style: TextStyle(fontSize: 11, color: AppColors.textMid)),
          Text('${energy.toStringAsFixed(2)} kWh',
              style: TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: _palette.dark)),
        ]),
      ]),
    );
  }

  Widget _buildDeviceInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Column(children: [
        _infoRow('Device ID', widget.deviceId),
        _infoRow('Building', widget.building),
        _infoRow('Floor', 'Floor ${widget.floor}'),
        _infoRow('Utility', _utilityLabel(widget.utility)),
        _infoRow('Control',
            widget.utility == 'ac' ? 'Contactor 220V' : 'Relay 220V'),
        _infoRow('Sensor', 'PZEM-004T + CT Clamp'),
      ]),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Text(label,
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
        const Spacer(),
        Text(value,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
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

  // Semantic: fixed per-utility-type color key (lights=amber, outlets=green,
  // AC=blue), same reasoning as the PZEM reading tiles above -- not
  // institute brand chrome, so deliberately NOT retheme'd.
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
}
