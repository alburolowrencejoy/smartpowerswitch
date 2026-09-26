import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/responsive_center.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/delete_flow.dart';
import '../../widgets/delete_row_transition.dart';
import '../../widgets/top_toast.dart';
import '../../services/readings_service.dart';
import '../../services/home_widget_service.dart';
import 'web_theme.dart';
import 'web_trend_chart.dart';
import 'web_widgets.dart';
import '../../theme/app_fonts.dart';
import '../../services/history_clock.dart';

/// The desktop device page: live PZEM readings (voltage, current, power,
/// energy today), a 7-day energy trend, and the relay Control panel.
/// Independent Firebase listeners from the mobile [DeviceDetailScreen].
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
    _listenHistory();
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _combinedSub?.cancel();
    _weekSub?.cancel();
    _monthSub?.cancel();
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

  // ── Build (preview layout) ────────────────────────────────────────────

  /// The device's recorded kWh for each of the last 7 days (oldest first),
  /// from `history/daily/{date}/devices/{id}/kwh`; 0 when a day has none.
  List<({DateTime date, double kwh})> _week = const [];

  /// This month's recorded kWh, from `history/monthly/{month}/devices/{id}`.
  double? _monthKwh;

  StreamSubscription<DatabaseEvent>? _weekSub;
  StreamSubscription<DatabaseEvent>? _monthSub;

  void _listenHistory() {
    final now = HistoryClock.instance.now();
    final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    _weekSub = FirebaseDatabase.instance
        .ref('history/daily')
        .orderByKey()
        .limitToLast(10)
        .onValue
        .listen((e) {
      if (!mounted) return;
      final raw = e.snapshot.value;
      final byDay = <String, double>{};
      if (raw is Map) {
        raw.forEach((day, v) {
          final d = v is Map ? v['devices'] : null;
          final dev = d is Map ? d[widget.deviceId] : null;
          final k = dev is Map ? dev['kwh'] : null;
          if (k is num) byDay[day.toString()] = k.toDouble();
        });
      }
      final today = DateTime(now.year, now.month, now.day);
      setState(() {
        _week = [
          for (var i = 6; i >= 0; i--)
            (() {
              final d = DateTime(today.year, today.month, today.day - i);
              final key = '${d.year}-${d.month.toString().padLeft(2, '0')}-'
                  '${d.day.toString().padLeft(2, '0')}';
              return (date: d, kwh: byDay[key] ?? 0.0);
            })(),
        ];
      });
    }, onError: (_) {});
    _monthSub = FirebaseDatabase.instance
        .ref('history/monthly/$month/devices/${widget.deviceId}/kwh')
        .onValue
        .listen((e) {
      if (!mounted) return;
      final v = e.snapshot.value;
      setState(() => _monthKwh = v is num ? v.toDouble() : null);
    }, onError: (_) {});
  }

  static const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  bool get _canToggle => const {
        'admin',
        'main_admin',
        'super_admin',
        'institute_admin'
      }.contains(widget.role);

  // Edit / remove live here on the device page, not on the building's
  // device rows. [_utility] starts from the caller's value and follows edits.
  late String _utility = widget.utility;
  static const _utilityOptions = ['Lights', 'Outlets', 'AC'];

  String get _deviceRefPath =>
      'buildings/${widget.building}/floorData/${widget.floor}/devices/${widget.deviceId}';

  /// Changes the device's utility type (Lights / Outlets / AC).
  Future<void> _editDevice() async {
    final current = _utilityOptions.firstWhere(
        (o) => o.toLowerCase() == _utility.toLowerCase(),
        orElse: () => _utilityOptions.first);
    String? saved;
    final ok = await showWebFormDialog(
      context: context,
      title: 'Edit device',
      subtitle: widget.deviceId,
      fields: [
        WebField(
            id: 'utility',
            label: 'Utility type',
            options: _utilityOptions,
            initial: current),
      ],
      onSubmit: (v) async {
        final next = v['utility']!;
        if (next == current) return null;
        await FirebaseDatabase.instance.ref().update({
          '$_deviceRefPath/utility': next,
          'devices/${widget.deviceId}/utility': next,
        });
        saved = next;
        return null;
      },
    );
    if (!ok || !mounted) return;
    if (saved != null) setState(() => _utility = saved!);
    TopToast.success(context, '${widget.deviceId} updated.');
  }

  /// Unassigns the device from its room (it stays registered and can be
  /// reused), then returns to the building.
  ///
  /// Same two-step confirm -> reason flow, deferred commit and 5s Undo as
  /// mobile (`showDeleteFlow`); the page returns to the building as soon as
  /// the reason is confirmed, and the write happens once Undo expires.
  Future<void> _removeDevice() async {
    // The shell's context outlives this page, which is gone by commit time.
    final messengerContext =
        Navigator.of(context, rootNavigator: true).context;
    final rowKey = 'device:${widget.deviceId}';
    final committed = await showDeleteFlow(
      context,
      type: DeleteType.device,
      itemName: '${_utilityLabel(_utility)} · ${widget.deviceId}',
      impact: [
        'The device will be unassigned from ${widget.building} · '
            'Floor ${widget.floor} · ${widget.room}',
        'Schedules for this device will stop',
        'It can be registered again later',
      ],
      onOptimisticRemove: () {
        (widget.onBack ?? () => Navigator.pop(context))();
        markPendingRowDelete(rowKey);
      },
      onRestore: () => clearPendingRowDelete(rowKey),
      onCommit: (reason, otherText) async {
        final user = FirebaseAuth.instance.currentUser;
        final db = FirebaseDatabase.instance.ref();
        final logRef = db.child('deletion_log').push();
        try {
          await db.update({
            _deviceRefPath: null,
            'master_devices/${widget.deviceId}/assignedTo': '',
            'devices/${widget.deviceId}/building': '',
            'devices/${widget.deviceId}/floor': '',
            'devices/${widget.deviceId}/room': '',
            'devices/${widget.deviceId}/status': 'offline',
            'deletion_log/${logRef.key}': {
              'type': 'device',
              'deviceId': widget.deviceId,
              'utility': _utility,
              'buildingCode': widget.building,
              'floor': widget.floor,
              'room': widget.room,
              'reason': reason,
              'otherText': otherText,
              'deletedBy': user?.uid,
              'deletedByEmail': user?.email,
              'timestamp': ServerValue.timestamp,
            },
          });
        } catch (e) {
          if (messengerContext.mounted) {
            TopToast.error(messengerContext, 'Failed to remove device: $e');
          }
          rethrow;
        } finally {
          clearPendingRowDelete(rowKey);
        }
      },
    );
    if (committed && messengerContext.mounted) {
      TopToast.success(messengerContext, 'Device removed');
    }
  }

  Widget _headerAction(IconData icon, String tooltip, VoidCallback onTap,
      {bool danger = false}) {
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
          width: 34,
          height: 34,
          child: Icon(icon, size: 19, color: fg),
        ),
      ),
    );
  }

  double get _todayKwh {
    final k = _deviceData['kwh'];
    return k is num ? k.toDouble() : 0.0;
  }

  String _lastSeenText() {
    final seen = _deviceData['last_seen'];
    if (seen is! num || seen == 0) return 'Never';
    final t = DateTime.fromMillisecondsSinceEpoch(seen.toInt());
    final ago = DateTime.now().difference(t);
    if (ago.inMinutes < 1) return 'Just now';
    if (ago.inMinutes < 60) return '${ago.inMinutes} min ago';
    final hm = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    final today = DateTime.now();
    if (t.year == today.year && t.month == today.month && t.day == today.day) {
      return 'Today $hm';
    }
    final y = today.subtract(const Duration(days: 1));
    if (t.year == y.year && t.month == y.month && t.day == y.day) {
      return 'Yesterday $hm';
    }
    return '${_monthNames[t.month - 1]} ${t.day}, $hm';
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(widget.role, _institute)],
      ),
      child: ScreenSkeleton(
        isLoading: _isLoading,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 18, 28, 32),
          child: ResponsiveCenter(
            maxWidth: 1320,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: WebBackLink(
                    label: 'Back to ${widget.building}',
                    onTap: widget.onBack ?? () => Navigator.pop(context),
                  ),
                ),
                const SizedBox(height: 6),
                _buildHeader(),
                const SizedBox(height: 22),
                if (_errorText != null)
                  _buildLoadError()
                else ...[
                  _buildReadings(),
                  const SizedBox(height: 22),
                  LayoutBuilder(builder: (context, c) {
                    final trend = _buildTrendCard();
                    final control = _buildControlCard();
                    if (c.maxWidth < 900) {
                      return Column(children: [
                        trend,
                        const SizedBox(height: 22),
                        control,
                      ]);
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 6, child: trend),
                        const SizedBox(width: 22),
                        Expanded(flex: 4, child: control),
                      ],
                    );
                  }),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final isAc = _utility.toLowerCase() == 'ac';
    return Padding(
      // Clear of the shell's floating role badge and bell.
      padding: const EdgeInsets.only(right: 180),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 6,
          children: [
            Text('${_utilityLabel(_utility)} · ${widget.room}',
                style: const TextStyle(
                    fontFamily: AppFonts.family,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: WebColors.ink)),
            WebStatusPill(text: _isOnline ? 'Online' : 'Offline', on: _isOnline),
            if (_canToggle)
              Row(mainAxisSize: MainAxisSize.min, children: [
                _headerAction(Icons.edit_outlined, 'Edit device', _editDevice),
                _headerAction(Icons.delete_outline_rounded, 'Remove device',
                    _removeDevice,
                    danger: true),
              ]),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${widget.deviceId} · ${widget.building} · Floor ${widget.floor} · '
          '${isAc ? 'Contactor' : 'Relay'}',
          style: const TextStyle(fontSize: 14, color: WebColors.muted),
        ),
      ]),
    );
  }

  Widget _buildLoadError() {
    return WebCard(
      child: Column(children: [
        const SizedBox(height: 24),
        const Icon(Icons.cloud_off_outlined, size: 44, color: WebColors.muted),
        const SizedBox(height: 12),
        const Text('Cannot load this device',
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
    );
  }

  Widget _buildReadings() {
    final power = _relay ? _safeFormatPzem(_deviceData['power'], 0) : '0';
    final boxes = [
      _readingBox('Voltage', _safeFormatPzem(_deviceData['voltage'], 1), 'V'),
      _readingBox('Current',
          _relay ? _safeFormatPzem(_deviceData['current'], 2) : '0.00', 'A'),
      _readingBox('Power', power, 'W'),
      _readingBox('Energy today', _todayKwh.toStringAsFixed(2), 'kWh'),
    ];
    return LayoutBuilder(builder: (context, c) {
      const gap = 14.0;
      final cols = c.maxWidth >= 700 ? 4 : 2;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final b in boxes) SizedBox(width: w, child: b)],
      );
    });
  }

  Widget _readingBox(String label, String value, String unit) {
    return WebCard(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(fontSize: 13, color: WebColors.muted)),
        const SizedBox(height: 4),
        Text.rich(TextSpan(children: [
          TextSpan(
              text: value,
              style: const TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: WebColors.ink)),
          TextSpan(
              text: ' $unit',
              style: const TextStyle(fontSize: 13, color: WebColors.muted)),
        ])),
      ]),
    );
  }

  Widget _panelTitle(String title, String subtitle, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(
                    fontFamily: AppFonts.family,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: WebColors.ink)),
            const SizedBox(height: 3),
            Text(subtitle,
                style: const TextStyle(fontSize: 13, color: WebColors.muted)),
          ]),
        ),
        if (trailing != null) trailing,
      ]),
    );
  }

  Widget _buildTrendCard() {
    return WebCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _panelTitle('Energy trend', 'kWh per day, last 7 days'),
        if (_week.isEmpty)
          const SizedBox(
            height: 240,
            child: Center(
              child: Text('No history yet',
                  style: TextStyle(fontSize: 14, color: WebColors.muted)),
            ),
          )
        else
          WebTrendChart(
            height: 240,
            bars: false,
            color: AppColors.greenMid,
            points: [
              for (final p in _week)
                TrendPoint(
                  _dayNames[p.date.weekday - 1],
                  '${_monthNames[p.date.month - 1]} ${p.date.day} · '
                      '${_dayNames[p.date.weekday - 1]} · '
                      '${p.kwh.toStringAsFixed(2)} kWh',
                  p.kwh,
                ),
            ],
          ),
      ]),
    );
  }

  Widget _buildControlCard() {
    final warning = _voltageWarningMessage(_deviceData);
    final String subtitle;
    if (!_canToggle) {
      subtitle = 'Only admins can switch this device';
    } else if (!_isOnline) {
      subtitle = 'Device is offline';
    } else {
      subtitle = 'Switch this device on or off';
    }
    final month = _monthKwh;
    return WebCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _panelTitle('Control', subtitle,
            trailing: WebStatusPill(
                text: _relay ? 'Turned ON' : 'Turned OFF', on: _relay)),
        Row(children: [
          WebSwitch(
            value: _relay,
            semanticLabel: 'Device switch',
            onChanged: _canToggle && _isOnline && !_toggling
                ? (_) => _toggleRelay()
                : null,
          ),
          const SizedBox(width: 14),
          Text(_relay ? 'ON' : 'OFF',
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: WebColors.ink)),
          if (_toggling) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: _palette.mid),
            ),
          ],
        ]),
        if (warning != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFE8922A).withAlpha(30),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE8922A).withAlpha(100)),
            ),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 18, color: Color(0xFF9A5A0E)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(warning,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF9A5A0E))),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 18),
        _kvRow('Estimated Cost',
            '₱${(_todayKwh * _ratePhp).toStringAsFixed(2)} today'),
        _kvRow('Total Energy',
            month == null ? '—' : '${month.toStringAsFixed(1)} kWh this month'),
        _kvRow('PZEM reading', _hasPzemReadings ? 'Detected' : 'Not detected'),
        _kvRow('Last seen', _lastSeenText(), last: true),
      ]),
    );
  }

  Widget _kvRow(String label, String value, {bool last = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(
                bottom:
                    BorderSide(color: const Color(0xFF2E9E52).withAlpha(33))),
      ),
      child: Row(children: [
        Text(label,
            style: const TextStyle(fontSize: 14, color: WebColors.muted)),
        const Spacer(),
        Flexible(
          child: Text(value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: WebColors.ink)),
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
