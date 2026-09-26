import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:rxdart/rxdart.dart';

import '../../services/davao_light_rate_monitor.dart';
import '../../services/web_version_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_fonts.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/responsive_center.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import 'web_theme.dart';
import 'web_widgets.dart';

/// The website's Settings page, laid out like the design preview: a 2×2
/// grid of panels -- Electricity Rate (manual update, fetch latest, change
/// history), IoT Device Inventory (register + counts), Account, and App
/// Info (with a check for a newer *website* deployment). The phone app's
/// GitHub/APK updater lives only in the mobile [SettingsScreen].
class SettingsScreenWeb extends StatefulWidget {
  const SettingsScreenWeb({super.key});

  @override
  State<SettingsScreenWeb> createState() => _SettingsScreenWebState();
}

enum _ReleaseState { notChecked, checking, upToDate, available, failed }

class _SettingsScreenWebState extends State<SettingsScreenWeb> {
  final _rateController = TextEditingController();
  final _unassignedIotController = TextEditingController();
  bool _saving = false;
  bool _registeringIot = false;
  bool _fetchingLatestRate = false;

  // Inline field errors (red border + message + shake).
  String? _rateError;
  String? _iotError;
  int _rateShake = 0;
  int _iotShake = 0;

  double _currentRate = 11.5;
  List<Map<String, dynamic>> _rateHistory = [];

  // IoT inventory counts, from master_devices.
  int? _registered;
  int? _assigned;
  StreamSubscription<DatabaseEvent>? _inventorySub;

  // Website version check.
  WebVersion? _runningVersion;
  WebVersion? _deployedVersion;
  _ReleaseState _release = _ReleaseState.notChecked;

  late final DavaoLightRateMonitor _rateMonitor = DavaoLightRateMonitor();

  /// True until the combined stream's first emission. Never reverts to
  /// true afterwards -- a fresh instance of this screen is the only
  /// legitimate reset.
  bool _isLoading = true;
  String? _errorText;
  bool _hasLoadedOnce = false;

  static const Duration _loadTimeout = Duration(seconds: 15);
  Timer? _timeoutTimer;
  StreamSubscription? _combinedSub;

  bool _isPermissionDenied(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') ||
        text.contains('permission_denied');
  }

  // ── Institute theming ──────────────────────────────────────────────────
  // No role/institute constructor params (pushed from dashboard_web.dart
  // with no arguments), so they're hydrated from the signed-in user's own
  // record.
  String _role = 'faculty';
  String? _institute;
  bool _coAdmin = false;

  InstitutePalette get _palette =>
      InstituteTheme.resolve(_role, _institute).palette;

  Future<void> _hydrateSessionFromAuth() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final snap =
          await FirebaseDatabase.instance.ref('users/${user.uid}').get();
      final data = snap.value;
      if (data is! Map) return;
      final map = Map<String, dynamic>.from(data);
      if (!mounted) return;
      setState(() {
        _role = (map['role'] as String?) ?? 'faculty';
        _institute = (map['institute'] as String?)?.trim();
        _coAdmin = map['coAdmin'] == true;
      });
    } catch (_) {
      // Keep existing role defaults if role hydration fails.
    }
  }

  @override
  void initState() {
    super.initState();
    _hydrateSessionFromAuth();
    _listenAll();
    _listenInventory();
    WebVersionService.running().then((v) {
      if (mounted) setState(() => _runningVersion = v);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _rateController.dispose();
    _unassignedIotController.dispose();
    _timeoutTimer?.cancel();
    _combinedSub?.cancel();
    _inventorySub?.cancel();
    super.dispose();
  }

  // ── Data ─────────────────────────────────────────────────────────────

  void _retry() {
    setState(() {
      _errorText = null;
      _isLoading = true;
    });
    _timeoutTimer?.cancel();
    _combinedSub?.cancel();
    _listenAll();
  }

  /// Electricity rate + rate change history in one subscription with a
  /// sticky merge, so a transient null never blanks already-loaded data.
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
      FirebaseDatabase.instance.ref('settings/electricityRate').onValue,
      FirebaseDatabase.instance
          .ref('rate_changes')
          .orderByChild('timestamp')
          .limitToLast(10)
          .onValue,
    ]).listen((events) {
      if (!mounted) return;
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      setState(() {
        _applyRate(events[0].snapshot.value);
        _applyRateHistory(events[1].snapshot.value);
        _hasLoadedOnce = true;
        _isLoading = false;
        _errorText = null;
      });
    }, onError: (Object error) {
      if (!mounted || _hasLoadedOnce) return;
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      setState(() {
        _isLoading = false;
        _errorText = _isPermissionDenied(error)
            ? 'You do not have permission to view settings.'
            : 'Failed to load settings.';
      });
    });
  }

  /// Registered / assigned / unassigned counts for the IoT panel. Kept
  /// separate so a failure here never blocks the rest of the page.
  void _listenInventory() {
    _inventorySub =
        FirebaseDatabase.instance.ref('master_devices').onValue.listen((event) {
      final raw = event.snapshot.value;
      var registered = 0, assigned = 0;
      if (raw is Map) {
        raw.forEach((_, v) {
          registered++;
          if (v is Map && (v['assignedTo'] ?? '').toString().isNotEmpty) {
            assigned++;
          }
        });
      }
      if (mounted) {
        setState(() {
          _registered = registered;
          _assigned = assigned;
        });
      }
    }, onError: (Object e) {
      debugPrint('[SettingsWeb] master_devices listen error: $e');
    });
  }

  void _applyRate(Object? raw) {
    final rate = (raw as num?)?.toDouble();
    if (rate == null) return;
    _currentRate = rate;
    _rateController.text = rate.toStringAsFixed(2);
  }

  void _applyRateHistory(Object? raw) {
    if (raw is Map) {
      final list = raw.entries.map((e) {
        final val = Map<String, dynamic>.from(e.value as Map);
        val['id'] = e.key;
        return val;
      }).toList()
        ..sort((a, b) => ((b['timestamp'] as num?)?.toInt() ?? 0)
            .compareTo((a['timestamp'] as num?)?.toInt() ?? 0));
      _rateHistory = list;
    } else if (_isLoading) {
      _rateHistory = [];
    }
  }

  // ── Actions ──────────────────────────────────────────────────────────

  Future<void> _saveRate() async {
    final raw = _rateController.text.trim();
    final rate = double.tryParse(raw);
    String? err;
    if (raw.isEmpty) {
      err = 'Enter a rate.';
    } else if (rate == null || !RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(raw)) {
      err = 'Use a number like 11.50 (up to 2 decimals).';
    } else if (rate < 1 || rate > 100) {
      err = 'Rate must be between ₱1 and ₱100 per kWh.';
    }
    if (err != null || rate == null) {
      setState(() {
        _rateError = err;
        _rateShake++;
      });
      return;
    }
    setState(() => _saving = true);
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final db = FirebaseDatabase.instance.ref();
      final user = FirebaseAuth.instance.currentUser;

      await db.update({
        'settings/electricityRate': rate,
        'settings/lastRateUpdate': timestamp,
      });
      await db.child('rate_changes/$timestamp').set({
        'oldRate': _currentRate,
        'newRate': rate,
        'source': 'manual_update',
        'updatedBy': user?.uid ?? 'unknown',
        'timestamp': timestamp,
      });
      await db.child('notifications').push().set({
        'type': 'rate_change_manual',
        'message':
            'Electricity rate updated to ₱${rate.toStringAsFixed(2)}/kWh',
        'oldRate': _currentRate,
        'newRate': rate,
        'updatedBy': user?.uid ?? 'unknown',
        'updatedByEmail': user?.email ?? 'admin',
        'timestamp': ServerValue.timestamp,
      });

      if (!mounted) return;
      setState(() {
        _saving = false;
        _currentRate = rate;
      });
      TopToast.show(context, 'Rate saved: ₱${rate.toStringAsFixed(2)}/kWh');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      TopToast.show(
        context,
        _isPermissionDenied(e)
            ? 'Permission denied while saving rate.'
            : 'Failed to save rate: $e',
        isError: true,
      );
    }
  }

  Future<void> _registerUnassignedIotDevice() async {
    if (_registeringIot) return;

    final id = _unassignedIotController.text.trim().toUpperCase();
    void fail(String message) => setState(() {
          _iotError = message;
          _iotShake++;
        });
    if (id.isEmpty) {
      fail('Device ID is required.');
      return;
    }
    if (!RegExp(r'^[A-Z0-9_-]{3,40}$').hasMatch(id)) {
      fail('Use 3–40 characters: letters, numbers, _ or -.');
      return;
    }

    setState(() => _registeringIot = true);
    try {
      final db = FirebaseDatabase.instance.ref();
      final masterRef = db.child('master_devices/$id');
      final masterSnap = await masterRef.get();

      if (masterSnap.exists) {
        final existing = masterSnap.value is Map
            ? Map<String, dynamic>.from(masterSnap.value as Map)
            : <String, dynamic>{};
        final assignedTo = (existing['assignedTo'] ?? '').toString();
        if (!mounted) return;
        setState(() => _registeringIot = false);
        fail(assignedTo.isNotEmpty
            ? 'That device is already assigned to $assignedTo.'
            : 'That device ID is already registered.');
        return;
      }

      await db.update({
        'master_devices/$id': {
          'assignedTo': '',
          'utility': 'Unassigned',
          'source': 'real_iot',
          'createdAt': ServerValue.timestamp,
        },
        'devices/$id': {
          'building': '',
          'floor': '',
          'room': '',
          'utility': 'Unassigned',
          'relay': false,
          'status': 'offline',
          'kwh': 0,
          'voltage': 0,
          'current': 0,
          'power': 0,
          'powerFactor': 0,
          'last_seen': 0,
          'last_updated': ServerValue.timestamp,
        },
      });

      if (!mounted) return;
      _unassignedIotController.clear();
      setState(() => _registeringIot = false);
      TopToast.show(context, '$id registered');
    } catch (e) {
      if (!mounted) return;
      setState(() => _registeringIot = false);
      TopToast.show(
        context,
        _isPermissionDenied(e)
            ? 'Permission denied while registering the device.'
            : 'Failed to register the device: $e',
        isError: true,
      );
    }
  }

  Future<void> _fetchLatestRate() async {
    setState(() => _fetchingLatestRate = true);
    try {
      final result = await _rateMonitor.monitorAndUpdateRate();
      if (!mounted) return;
      setState(() => _fetchingLatestRate = false);
      TopToast.show(
        context,
        result.hasChanged
            ? 'Rate updated: ₱${result.oldRate.toStringAsFixed(2)} → '
                '₱${result.newRate.toStringAsFixed(2)}/kWh'
            : 'Latest Davao Light rate: '
                '₱${result.newRate.toStringAsFixed(2)}/kWh (no change)',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _fetchingLatestRate = false);
      TopToast.show(context, 'Failed to fetch rate: $e', isError: true);
    }
  }

  Future<void> _checkLatestRelease() async {
    if (!kIsWeb) {
      TopToast.show(
          context,
          'Website updates can only be checked in the '
          'browser.');
      return;
    }
    setState(() => _release = _ReleaseState.checking);
    try {
      final deployed = await WebVersionService.deployed();
      final running = _runningVersion ?? await WebVersionService.running();
      if (!mounted) return;
      setState(() {
        _runningVersion = running;
        _deployedVersion = deployed;
        _release = deployed == running
            ? _ReleaseState.upToDate
            : _ReleaseState.available;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _release = _ReleaseState.failed);
      TopToast.show(context, 'Could not check for updates: $e', isError: true);
    }
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: ScreenSkeleton(
        isLoading: _isLoading,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
          child: ResponsiveCenter(
            maxWidth: 1320,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Settings',
                    style: TextStyle(
                        fontFamily: AppFonts.family,
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: WebColors.ink)),
                const SizedBox(height: 4),
                const Text('Rate, devices, updates, and account',
                    style: TextStyle(fontSize: 14, color: WebColors.muted)),
                const SizedBox(height: 22),
                if (_errorText != null) _buildError() else _grid(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Two columns (top-aligned, like the preview's grid) on wide windows;
  /// one column below 800px of content width.
  Widget _grid() {
    final panels = [
      _ratePanel(),
      _iotPanel(),
      _accountPanel(),
      _appInfoPanel(),
    ];
    return LayoutBuilder(builder: (context, c) {
      const gap = 22.0;
      if (c.maxWidth < 800) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < panels.length; i++) ...[
              if (i > 0) const SizedBox(height: gap),
              panels[i],
            ],
          ],
        );
      }
      Widget row(Widget a, Widget b) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: a),
              const SizedBox(width: gap),
              Expanded(child: b),
            ],
          );
      return Column(children: [
        row(panels[0], panels[1]),
        const SizedBox(height: gap),
        row(panels[2], panels[3]),
      ]);
    });
  }

  Widget _buildError() {
    return WebCard(
      padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 24),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
                color: Colors.white, border: Border.all(color: WebColors.outline), borderRadius: BorderRadius.circular(20)),
            child:
                Icon(Icons.cloud_off_outlined, size: 34, color: _palette.mid),
          ),
          const SizedBox(height: 16),
          const Text('Cannot load settings',
              style: TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: WebColors.ink)),
          const SizedBox(height: 8),
          Text(_errorText ?? 'Something went wrong.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: WebColors.muted)),
          const SizedBox(height: 20),
          _primaryButton('Retry', _retry, icon: Icons.refresh),
        ]),
      ),
    );
  }

  // ── Panels ───────────────────────────────────────────────────────────

  Widget _ratePanel() {
    return _panel(
      title: 'Electricity Rate',
      subtitle: 'Used for every cost on the dashboard',
      trailing: _softChip('₱${_currentRate.toStringAsFixed(2)} / kWh'),
      children: [
        _field(
          label: 'Manual Update (₱ per kWh)',
          error: _rateError,
          child: AppTextField(
            controller: _rateController,
            shakeTrigger: _rateShake,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: _inputStyle,
            decoration: _inputDeco(error: _rateError),
            onChanged: (_) {
              if (_rateError != null) setState(() => _rateError = null);
            },
            onSubmitted: (_) => _saveRate(),
          ),
        ),
        Wrap(spacing: 10, runSpacing: 10, children: [
          _primaryButton('Save', _saving ? null : _saveRate, loading: _saving),
          _ghostButton(
            _fetchingLatestRate ? 'Fetching…' : 'Fetch Latest Rate',
            _fetchingLatestRate ? null : _fetchLatestRate,
          ),
        ]),
        const SizedBox(height: 22),
        const Text('Rate Change History',
            style: TextStyle(
                fontFamily: AppFonts.family,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: WebColors.ink)),
        const SizedBox(height: 8),
        if (_rateHistory.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 9),
            child: Text('No rate changes yet',
                style: TextStyle(fontSize: 14, color: WebColors.muted)),
          )
        else
          _kvList([
            for (final change in _rateHistory.take(10))
              (
                '${_fmtDate(DateTime.fromMillisecondsSinceEpoch((change['timestamp'] as num?)?.toInt() ?? 0))}'
                    ' · ${change['source'] == 'manual_update' ? 'Manual' : 'Davao Light'}',
                '₱${((change['newRate'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}',
              ),
          ]),
      ],
    );
  }

  Widget _iotPanel() {
    String count(int? n) => n == null ? '—' : '$n';
    final registered = _registered;
    final assigned = _assigned;
    return _panel(
      title: 'IoT Device Inventory',
      subtitle: 'Register a device ID burned into an ESP32',
      children: [
        _field(
          label: 'Device ID',
          error: _iotError,
          child: AppTextField(
            controller: _unassignedIotController,
            shakeTrigger: _iotShake,
            textCapitalization: TextCapitalization.characters,
            style: _inputStyle,
            decoration:
                _inputDeco(hint: 'e.g. ESP32-ROOM101-001', error: _iotError),
            onChanged: (_) {
              if (_iotError != null) setState(() => _iotError = null);
            },
            onSubmitted: (_) => _registerUnassignedIotDevice(),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: _primaryButton(
            'Register',
            _registeringIot ? null : _registerUnassignedIotDevice,
            loading: _registeringIot,
          ),
        ),
        const SizedBox(height: 18),
        _kvList([
          ('Registered', count(registered)),
          ('Assigned', count(assigned)),
          (
            'Unassigned',
            registered == null || assigned == null
                ? '—'
                : '${registered - assigned}'
          ),
        ]),
      ],
    );
  }

  Widget _accountPanel() {
    final user = FirebaseAuth.instance.currentUser;
    return _panel(
      title: 'Account',
      children: [
        _kvList([
          ('Email', user?.email ?? '—'),
          ('Role', _roleLabel()),
        ]),
      ],
    );
  }

  Widget _appInfoPanel() {
    final running = _runningVersion;
    final latest = switch (_release) {
      _ReleaseState.notChecked => 'Not checked yet',
      _ReleaseState.checking => 'Checking…',
      _ReleaseState.upToDate => 'Up to date',
      _ReleaseState.available =>
        '${_deployedVersion?.label ?? 'New version'} available',
      _ReleaseState.failed => 'Could not check',
    };
    return _panel(
      title: 'App Info',
      children: [
        _kvList([
          ('Institution', 'Davao del Norte State College'),
          ('Location', 'Panabo City, Davao del Norte'),
          ('Version', running?.label ?? '—'),
          ('Latest release', latest),
        ]),
        const SizedBox(height: 16),
        Wrap(spacing: 10, runSpacing: 10, children: [
          _ghostButton(
            'Check Latest',
            _release == _ReleaseState.checking ? null : _checkLatestRelease,
          ),
          if (_release == _ReleaseState.available)
            _primaryButton('Reload to update', WebVersionService.reload,
                icon: Icons.refresh),
        ]),
        if (_release == _ReleaseState.available) ...[
          const SizedBox(height: 10),
          const Text(
            'A newer version of the website has been published. Reload the '
            'page to start using it.',
            style: TextStyle(fontSize: 12.5, color: WebColors.muted),
          ),
        ],
      ],
    );
  }

  // ── Building blocks (styled after the preview) ───────────────────────

  String _roleLabel() {
    switch (_role) {
      case 'admin':
      case 'main_admin':
      case 'super_admin':
        return 'Super Admin';
      case 'institute_admin':
        final code = (_institute ?? '').isEmpty ? '' : ' · $_institute';
        return '${_coAdmin ? 'Co-Admin' : 'Institute Admin'}$code';
      default:
        return 'Member';
    }
  }

  static const _monthsShort = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _fmtDate(DateTime d) =>
      '${_monthsShort[d.month - 1]} ${d.day}, ${d.year}';

  /// Card with the preview's title / subtitle / trailing header.
  Widget _panel({
    required String title,
    String? subtitle,
    Widget? trailing,
    required List<Widget> children,
  }) {
    return WebCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontFamily: AppFonts.family,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: WebColors.ink)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(subtitle,
                        style: const TextStyle(
                            fontSize: 13, color: WebColors.muted)),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 12), trailing],
          ]),
          const SizedBox(height: 18),
          ...children,
        ],
      ),
    );
  }

  /// "₱11.50 / kWh" pill in the panel header.
  Widget _softChip(String text) {
    final p = _palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white, border: Border.all(color: WebColors.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: p.dark)),
    );
  }

  /// Label above an input; the label turns red with the field's error.
  Widget _field({required String label, required Widget child, String? error}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color:
                      error != null ? const Color(0xFFA83434) : WebColors.mid)),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }

  static const _inputStyle =
      TextStyle(fontSize: 14.5, color: AppColors.textDark);

  InputDecoration _inputDeco({String? hint, String? error}) {
    final p = _palette;
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: c, width: w),
        );
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 14.5, color: WebColors.muted),
      isDense: true,
      filled: true,
      fillColor: const Color(0xFFFBFEFC),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      enabledBorder: border(p.mid.withAlpha(77)),
      focusedBorder: border(p.mid, 1.5),
      errorBorder: border(const Color(0xFFC43D3D), 1.2),
      focusedErrorBorder: border(const Color(0xFFC43D3D), 1.5),
      error: error == null ? null : _ErrorLine(error),
    );
  }

  Widget _primaryButton(String label, VoidCallback? onPressed,
      {bool loading = false, IconData? icon}) {
    final p = _palette;
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: p.dark,
        foregroundColor: Colors.white,
        disabledBackgroundColor: p.dark.withAlpha(150),
        disabledForegroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (loading) ...[
          const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white)),
          const SizedBox(width: 8),
        ] else if (icon != null) ...[
          Icon(icon, size: 18),
          const SizedBox(width: 8),
        ],
        Text(label),
      ]),
    );
  }

  Widget _ghostButton(String label, VoidCallback? onPressed) {
    final p = _palette;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: p.dark,
        side: BorderSide(color: p.mid.withAlpha(90)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }

  /// Label-left / bold-value-right rows with hairline dividers.
  Widget _kvList(List<(String, String)> rows) {
    final line = _palette.mid.withAlpha(33);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (label, value) in rows)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: line)),
            ),
            child: Row(children: [
              Expanded(
                child: Text(label,
                    style:
                        const TextStyle(fontSize: 14, color: WebColors.muted)),
              ),
              const SizedBox(width: 12),
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
          ),
      ],
    );
  }
}

/// The preview's field error: a small red "!" badge and the message.
class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 15,
          height: 15,
          margin: const EdgeInsets.only(top: 1),
          alignment: Alignment.center,
          decoration: const BoxDecoration(
              color: Color(0xFFC43D3D), shape: BoxShape.circle),
          child: const Text('!',
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1)),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(message,
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFA83434))),
        ),
      ]),
    );
  }
}
