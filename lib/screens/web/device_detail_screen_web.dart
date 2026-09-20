import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/responsive_center.dart';
import '../../widgets/screen_skeleton.dart';
import '../../services/readings_service.dart';
import '../../services/home_widget_service.dart';

/// The desktop "Device Detail" page: the same live PZEM readings, relay
/// control, cost, and device info as [DeviceDetailScreen], laid out as a
/// two-column desktop page instead of one stretched mobile column.
/// Independent Firebase listeners from the mobile screen, so
/// [DeviceDetailScreen] itself is never touched.
class DeviceDetailScreenWeb extends StatefulWidget {
  final String deviceId;
  final String utility;
  final String building;
  final String room;
  final String role;
  final int floor;

  /// When non-null, called instead of `Navigator.pop(context)` on back --
  /// lets the desktop dashboard shell return to the building-floor view
  /// in-place instead of popping a full-screen route.
  final VoidCallback? onBack;

  const DeviceDetailScreenWeb({
    super.key,
    required this.deviceId,
    required this.utility,
    required this.building,
    required this.room,
    required this.role,
    required this.floor,
    this.onBack,
  });

  @override
  State<DeviceDetailScreenWeb> createState() => _DeviceDetailScreenWebState();
}

class _DeviceDetailScreenWebState extends State<DeviceDetailScreenWeb> {
  Map<String, dynamic> _deviceData = {};
  bool _relay = false;
  bool _hasPzemReadings = false;
  bool _isOnline = false;
  bool _toggling = false;
  double _ratePhp = 11.5;
  double _lastValidEnergy = 0.0;
  double _lastReportedMeterKwh = -1.0;
  int? _lastRecordedSeen;
  DateTime? _lastToggleTime;

  /// True until the combined device+rate stream's first emission. The
  /// device stream is what actually gates this -- electricityRate already
  /// has a sensible default and never needs to block rendering.
  bool _isLoading = true;
  String? _errorText;
  bool _hasLoadedOnce = false;

  static const Duration _loadTimeout = Duration(seconds: 15);
  Timer? _timeoutTimer;

  StreamSubscription? _combinedSub;

  // ── Institute theming ──────────────────────────────────────────────────
  // `widget.role` is already passed in by the caller (see dashboard_web.dart's
  // DeviceDetailScreenWeb(role: _role, ...)), but no institute is threaded
  // through, so it's hydrated here directly from the signed-in user's own
  // record, mirroring mobile device_detail_screen.dart's _hydrateInstitute.
  // This is purely cosmetic (chrome colors) and never touches relay/readings
  // state.
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
    _timeoutTimer?.cancel();
    _combinedSub?.cancel();
    super.dispose();
  }

  /// Clears the error state, resets the loading flag, and re-attaches the
  /// combined listener from scratch.
  void _retry() {
    setState(() {
      _errorText = null;
      _isLoading = true;
    });
    _timeoutTimer?.cancel();
    _combinedSub?.cancel();
    _listenAll();
  }

  void _listenAll() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(_loadTimeout, () {
      if (!mounted || _hasLoadedOnce) return;
      setState(() {
        _isLoading = false;
        _errorText =
            'Loading is taking too long. Check your connection and try again.';
      });
    });

    _combinedSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('devices/${widget.deviceId}').onValue,
      FirebaseDatabase.instance.ref('settings/electricityRate').onValue,
    ]).listen((events) {
      if (!mounted) return;
      _applyDevice(events[0].snapshot.value);
      _applyRate(events[1].snapshot.value);
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      setState(() {
        _hasLoadedOnce = true;
        _isLoading = false;
        _errorText = null;
      });
    }, onError: (Object error) {
      if (!mounted || _hasLoadedOnce) return;
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      final text = error.toString().toLowerCase();
      final denied = text.contains('permission-denied') ||
          text.contains('permission_denied') ||
          text.contains('permission');
      setState(() {
        _isLoading = false;
        _errorText = denied
            ? 'You do not have permission to view this device.'
            : 'Failed to load device data.';
      });
    });
  }

  void _applyDevice(Object? raw) {
    // A transient null/empty snapshot (reconnect blip) must never blank
    // already-loaded device data -- only accept it before first load.
    if (raw == null) {
      return;
    }
    final data = Map<String, dynamic>.from(raw as Map);
    final lastSeen = (data['last_seen'] as num?)?.toInt();

    if (lastSeen != null && lastSeen == _lastRecordedSeen) {
      return;
    }

    final meterKwh = (data['kwh'] as num?)?.toDouble() ?? 0.0;
    final relay = (data['relay'] as bool?) ?? false;

    final now = DateTime.now();
    final ignoreRelayUpdate = _lastToggleTime != null &&
        now.difference(_lastToggleTime!).inMilliseconds < 3000;

    double kwhDelta = 0.0;
    if (_lastReportedMeterKwh >= 0.0) {
      kwhDelta = meterKwh - _lastReportedMeterKwh;
      if (kwhDelta < 0.0) {
        kwhDelta = meterKwh;
      }
    }

    // Only record if delta is significant (avoid noise). History itself is
    // written once, globally, by GlobalReadingsListener -- this screen
    // never duplicates that write.
    if (kwhDelta >= 0.000001) {
      _lastValidEnergy = meterKwh;

      ReadingsService.recordReading(
        deviceId: widget.deviceId,
        building: widget.building,
        room: widget.room,
        kwh: _lastValidEnergy,
        relay: relay,
      );

      _lastReportedMeterKwh = meterKwh;
    }

    _deviceData = data;
    _hasPzemReadings = _checkHasPzemReadings(data);
    _isOnline = _checkOnline(data);
    if (!ignoreRelayUpdate) {
      _relay = relay;
    }

    unawaited(HomeWidgetService.updateWidget());

    if (lastSeen != null) {
      _lastRecordedSeen = lastSeen;
    }
  }

  void _applyRate(Object? raw) {
    final rate = (raw as num?)?.toDouble();
    if (rate == null) return;
    _ratePhp = rate;
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
      debugPrint('[DeviceDetailWeb] Failed to load persisted reading: $e');
    }
  }

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

  Future<void> _toggleRelay() async {
    if (_toggling) return;
    final previousRelay = _relay;
    final newRelay = !previousRelay;

    _lastToggleTime = DateTime.now();

    setState(() {
      _relay = newRelay;
      _toggling = true;
    });

    final db = FirebaseDatabase.instance.ref();
    Object? lastError;
    var success = false;

    for (var attempt = 0; attempt < 2 && !success; attempt++) {
      try {
        await db
            .child('devices/${widget.deviceId}/relay')
            .set(newRelay)
            .timeout(const Duration(milliseconds: 1200));

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
        _lastToggleTime = null;
      }
    });

    if (!success) {
      debugPrint('[DeviceDetailWeb] Relay update failed: $lastError');
    }
  }

  // ── Build (desktop two-column layout) ─────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final energy = _lastValidEnergy;
    final cost = energy * _ratePhp;

    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(widget.role, _institute)],
      ),
      child: ScreenSkeleton(
      isLoading: _isLoading,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: ResponsiveCenter(
          maxWidth: 1200,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 24),
              if (_errorText != null)
                _buildLoadError()
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildRelayCard(),
                          const SizedBox(height: 16),
                          _buildReadingsGrid(energy),
                        ],
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      flex: 1,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildStatusCard(),
                          const SizedBox(height: 16),
                          _buildCostCard(energy, cost),
                          const SizedBox(height: 16),
                          _buildDeviceInfoCard(),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
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
              size: 48, color: AppColors.textMuted),
          const SizedBox(height: 12),
          const Text('Cannot load this device',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark)),
          const SizedBox(height: 6),
          Text(_errorText ?? 'Something went wrong.',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
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
    // dashboard shell floats over the top-right corner, so the
    // Online/Offline chip never sits underneath it.
    return Padding(
      padding: const EdgeInsets.only(right: 64),
      child: Row(
      children: [
        Material(
          color: AppColors.cardBg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: widget.onBack ?? () => Navigator.pop(context),
            child: const Padding(
              padding: EdgeInsets.all(10.0),
              child:
                  Icon(Icons.arrow_back, size: 18, color: AppColors.textDark),
            ),
          ),
        ),
        const SizedBox(width: 16),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_utilityLabel(widget.utility),
                  style: const TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDark)),
              const SizedBox(height: 2),
              Text(
                  '${widget.deviceId} · ${widget.building} · Floor ${widget.floor} · ${widget.room}',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textMuted)),
            ],
          ),
        ),
        // Semantic: this whole badge (background/dot/text) is a live
        // online/offline device-status indicator paired against
        // AppColors.offline for the offline state -- deliberately NOT
        // retheme'd (see also _buildRelayCard's relay-state coloring below,
        // which follows the same reasoning; matches mobile
        // device_detail_screen.dart's header badge).
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _isOnline
                ? AppColors.greenMid.withAlpha(31)
                : AppColors.offline.withAlpha(31),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isOnline ? AppColors.greenMid : AppColors.offline,
              ),
            ),
            const SizedBox(width: 5),
            Text(_isOnline ? 'Online' : 'Offline',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _isOnline ? AppColors.greenDark : AppColors.offline,
                )),
          ]),
        ),
      ],
      ),
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

    return _card(
      title: 'Status',
      icon: Icons.info_outline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoRow('Last seen', lastSeenText),
          _infoRow(
              'PZEM reading', _hasPzemReadings ? 'Detected' : 'Not detected'),
        ],
      ),
    );
  }

  Widget _buildRelayCard() {
    final isAc = widget.utility == 'ac';
    final relayVisible = _relay;
    final warningMessage = _voltageWarningMessage(_deviceData);
    final canToggle = widget.role == 'admin' ||
        widget.role == 'main_admin' ||
        widget.role == 'super_admin' ||
        widget.role == 'institute_admin';

    // Semantic: this entire card's coloring (background, border, text, the
    // toggle track/knob further down) is driven by `relayVisible` (live
    // relay ON/OFF hardware state) and `_isOnline` -- this is the canonical
    // case the institute-theming rollout heuristic calls out (enabled/
    // disabled state), so none of it is retheme'd below. Matches mobile
    // device_detail_screen.dart's _buildRelayCard.
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: relayVisible ? AppColors.greenDark : AppColors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: relayVisible
              ? AppColors.greenMid
              : AppColors.greenMid.withAlpha(26),
        ),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isAc ? 'Contactor' : 'Relay',
                  style: TextStyle(
                      fontSize: 13,
                      color: relayVisible
                          ? AppColors.greenPale
                          : AppColors.textMuted)),
              const SizedBox(height: 4),
              Text(relayVisible ? 'Turned ON' : 'Turned OFF',
                  style: TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: relayVisible ? Colors.white : AppColors.textDark)),
              const SizedBox(height: 4),
              Text(
                !canToggle
                    ? 'You do not have permission to control this device'
                    : (!_hasPzemReadings
                        ? 'No PZEM reading'
                        : (!_isOnline
                            ? 'Device is offline'
                            : (relayVisible
                                ? 'Click to turn off'
                                : 'Click to turn on'))),
                style: TextStyle(
                    fontSize: 12,
                    color: relayVisible
                        ? AppColors.greenPale.withAlpha(179)
                        : AppColors.textMuted),
              ),
              if (warningMessage != null) ...[
                const SizedBox(height: 6),
                Text(
                  warningMessage,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFFFC107),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 16),
        if (canToggle)
          GestureDetector(
            onTap: !_toggling ? _toggleRelay : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 72,
              height: 38,
              decoration: BoxDecoration(
                color: !_isOnline
                    ? Colors.grey.withAlpha(80)
                    : (relayVisible
                        ? AppColors.greenLight
                        : const Color(0xFFE0E0E0)),
                borderRadius: BorderRadius.circular(19),
              ),
              child: Stack(children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 250),
                  left: relayVisible ? 36 : 2,
                  top: 2,
                  bottom: 2,
                  child: Container(
                    width: 34,
                    decoration: const BoxDecoration(
                        color: Colors.white, shape: BoxShape.circle),
                    child: Center(
                      child: _toggling
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: AppColors.greenMid),
                            )
                          : Icon(
                              relayVisible
                                  ? Icons.power_rounded
                                  : Icons.power_off_rounded,
                              size: 17,
                              color: relayVisible
                                  ? AppColors.greenMid
                                  : AppColors.textMuted,
                            ),
                    ),
                  ),
                ),
              ]),
            ),
          )
        else
          Container(
            width: 72,
            height: 38,
            decoration: BoxDecoration(
              color: Colors.grey.withAlpha(40),
              borderRadius: BorderRadius.circular(19),
            ),
            child: const Icon(Icons.lock_outline,
                size: 18, color: AppColors.textMuted),
          ),
      ]),
    );
  }

  Widget _buildReadingsGrid(double energyFromMeter) {
    final voltage = _safeFormatPzem(_deviceData['voltage'], 1);
    final current = _safeFormatPzem(_deviceData['current'], 2);
    final power = _safeFormatPzem(_deviceData['power'], 1);
    final powerFactor = _safeFormatPzem(_deviceData['powerFactor'], 2);
    final frequency = _safeFormatPzem(_deviceData['frequency'], 1);
    final energyValue = energyFromMeter > 0
        ? energyFromMeter
        : ((_deviceData['kwh'] is num)
            ? (_deviceData['kwh'] as num).toDouble()
            : 0.0);
    final energy = energyValue.toStringAsFixed(2);

    return _card(
      title: 'PZEM-004T Readings',
      icon: Icons.speed_outlined,
      child: LayoutBuilder(
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
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.15,
            // Semantic: fixed per-metric color key (voltage/current/power/
            // energy/frequency/power factor each get their own hue so the
            // 6 tiles stay visually distinguishable), mixing AppColors.green*
            // with literal hex colors (blue/purple) -- not institute brand
            // chrome, so deliberately NOT retheme'd (matches mobile
            // device_detail_screen.dart).
            children: [
              _readingTile('Voltage', voltage, 'V', Icons.electrical_services,
                  AppColors.greenMid),
              _readingTile(
                  'Current', current, 'A', Icons.bolt, AppColors.warning),
              _readingTile(
                  'Power', power, 'W', Icons.power, AppColors.greenDark),
              _readingTile('Energy', energy, 'kWh', Icons.battery_charging_full,
                  const Color(0xFF2196F3)),
              _readingTile(
                  'Freq.', frequency, 'Hz', Icons.waves, AppColors.greenLight),
              _readingTile('P.Factor', powerFactor, '', Icons.speed,
                  const Color(0xFF9C27B0)),
            ],
          );
        },
      ),
    );
  }

  Widget _readingTile(
      String label, String value, String unit, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
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
                      fontFamily: 'Outfit',
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDark)),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 3),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(unit,
                      style: const TextStyle(
                          fontSize: 10, color: AppColors.textMuted)),
                ),
              ],
            ]),
            Text(label,
                style:
                    const TextStyle(fontSize: 11, color: AppColors.textMuted)),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Estimated Cost',
              style: TextStyle(fontSize: 12, color: AppColors.textMid)),
          const SizedBox(height: 4),
          Text('₱ ${cost.toStringAsFixed(2)}',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: _palette.dark)),
          Text('at ₱${_ratePhp.toStringAsFixed(2)} / kWh',
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
          const SizedBox(height: 14),
          Container(height: 1, color: _palette.mid.withAlpha(40)),
          const SizedBox(height: 14),
          const Text('Total Energy',
              style: TextStyle(fontSize: 11, color: AppColors.textMid)),
          Text('${energy.toStringAsFixed(2)} kWh',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: _palette.dark)),
        ],
      ),
    );
  }

  Widget _buildDeviceInfoCard() {
    return _card(
      title: 'Device Info',
      icon: Icons.description_outlined,
      child: Column(children: [
        _infoRow('Device ID', widget.deviceId),
        _infoRow('Building', widget.building),
        _infoRow('Floor', 'Floor ${widget.floor}'),
        _infoRow('Room', widget.room),
        _infoRow('Utility', _utilityLabel(widget.utility)),
        _infoRow('Control',
            widget.utility == 'ac' ? 'Contactor 220V' : 'Relay 220V'),
        _infoRow('Sensor', 'PZEM-004T + CT Clamp'),
      ]),
    );
  }

  Widget _card(
      {required String title, required IconData icon, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 16, color: _palette.mid),
            const SizedBox(width: 8),
            Text(title,
                style: const TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark)),
          ]),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Text(label,
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
        const Spacer(),
        Flexible(
          child: Text(value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark)),
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
  // institute brand chrome, so deliberately NOT retheme'd (matches mobile
  // device_detail_screen.dart).
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
