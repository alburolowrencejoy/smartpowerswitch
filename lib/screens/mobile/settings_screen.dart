import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:rxdart/rxdart.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_fonts.dart';
import '../../theme/app_text_styles.dart';
import '../../theme/institute_colors.dart';
import '../../services/download_open_service.dart';
import '../../services/github_update_service.dart';
import '../../services/davao_light_rate_monitor.dart';
import '../../services/automation_scheduler_service.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/app_top_bar.dart';
import '../../widgets/outline_icon_box.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';

/// Settings (handoff §4.13, institute-admin variant §5/§10.4).
///
/// Institute admins get the electricity rate section **read-only** ("Set by
/// the campus admin", no manual-entry field, no Save/Fetch buttons) -- this
/// is a settled product decision (handoff §10.4: "institute-admin
/// electricity rate is read-only, as in the preview"), enforced here at the
/// client level. Note: `database.rules.json`'s `settings` node currently
/// still grants `institute_admin` write access at the backend rule level --
/// tightening that to match this UI decision is a `database.rules.json`
/// change, out of this screen's scope (see the deletion-log-schema owner
/// for that file).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const String _fixedGithubRepo = 'alburolowrencejoy/smartpowerswitch';

  final _rateController = TextEditingController();
  final _unassignedIotController = TextEditingController();
  bool _saving = false;
  bool _registeringIot = false;
  String? _rateError;
  String? _iotError;
  int _rateShake = 0;
  int _iotShake = 0;
  double _currentRate = 11.5;
  DateTime? _lastRateUpdateTime;
  String _appVersion = '';
  GithubReleaseInfo? _githubRelease;
  bool _githubChecking = false;
  bool _fetchingLatestRate = false;
  int? _registeredDeviceCount;

  List<Map<String, dynamic>> _rateHistory = [];

  late DavaoLightRateMonitor _rateMonitor;

  StreamSubscription? _combinedSub;
  StreamSubscription<DatabaseEvent>? _deviceCountSub;

  // True until the first combined emission of this screen's 3 Firebase
  // streams (electricityRate, lastRateUpdate, rate_changes) has been
  // received; never reverts to true afterwards, so a transient null on any
  // one path can't blank out data already shown this session.
  bool _isLoading = true;

  // Set only if the combined listener fails (or times out) before the
  // first successful load ever completes -- gives the rate section's
  // skeleton shimmer a real escape hatch instead of spinning forever.
  String? _errorText;
  Timer? _loadTimeoutTimer;
  bool _postLoadErrorNotified = false;

  bool _isPermissionDenied(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') ||
        text.contains('permission_denied');
  }

  // ── Institute theming ──────────────────────────────────────────────────
  // This screen is a standalone pushed route (no role/institute constructor
  // args -- see main.dart's '/settings' route), so role/institute are
  // hydrated directly from the signed-in user's own record, mirroring
  // dashboard_screen.dart's _hydrateSessionFromAuth.
  String _role = 'faculty';
  String? _institute;

  InstitutePalette get _palette =>
      InstituteTheme.resolve(_role, _institute).palette;

  bool get _isInstituteAdmin =>
      _role == 'institute_admin' && (_institute?.trim().isNotEmpty ?? false);

  Future<void> _hydrateSessionFromAuth() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final snap =
          await FirebaseDatabase.instance.ref('users/${user.uid}').get();
      final data = snap.value;
      if (data is! Map) return;
      final map = Map<String, dynamic>.from(data);
      final role = (map['role'] as String?) ?? 'faculty';
      final institute = (map['institute'] as String?)?.trim();
      if (!mounted) return;
      setState(() {
        _role = role;
        _institute = institute;
      });
    } catch (_) {
      // Keep existing role defaults if role hydration fails.
    }
  }

  @override
  void initState() {
    super.initState();
    _hydrateSessionFromAuth();
    _rateMonitor = DavaoLightRateMonitor();
    _listenAll();
    _listenDeviceCount();
    _loadAppVersion();
    _checkGithubRelease(silent: true);
  }

  @override
  void dispose() {
    _rateController.dispose();
    _unassignedIotController.dispose();
    _combinedSub?.cancel();
    _deviceCountSub?.cancel();
    _loadTimeoutTimer?.cancel();
    super.dispose();
  }

  /// Clears the error state and re-attaches the combined listener from
  /// scratch. Used by the Retry button shown when the first load fails.
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

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _appVersion = info.version);
  }

  /// Independent, best-effort count of registered IoT devices (handoff
  /// §4.13: "N registered" next to Register device). Deliberately kept as
  /// its own tiny subscription rather than folded into the combined rate
  /// listener below -- a failure here should never affect the rate
  /// section's careful sticky-loading/error state, it should just leave the
  /// count blank.
  void _listenDeviceCount() {
    _deviceCountSub = FirebaseDatabase.instance
        .ref('master_devices')
        .onValue
        .listen((event) {
      if (!mounted) return;
      final value = event.snapshot.value;
      setState(() {
        _registeredDeviceCount = value is Map ? value.length : 0;
      });
    }, onError: (_) {
      // Leave _registeredDeviceCount null (hidden) on failure.
    });
  }

  // ── Listen to all 3 Firebase paths this screen needs (electricity rate,
  // last-rate-update timestamp, rate change history) in one combined
  // stream so a transient null on any single path can't blank out data
  // already shown this session.
  void _listenAll() {
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted || !_isLoading) return;
      setState(() {
        _isLoading = false;
        _errorText =
            'Taking too long to load rate settings. Check your connection.';
      });
    });

    _combinedSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('settings/electricityRate').onValue,
      FirebaseDatabase.instance.ref('settings/lastRateUpdate').onValue,
      FirebaseDatabase.instance
          .ref('rate_changes')
          .orderByChild('timestamp')
          .limitToLast(10)
          .onValue,
    ]).listen((events) {
      if (!mounted) return;
      _loadTimeoutTimer?.cancel();
      setState(() {
        // ── electricity rate ───────────────────────────────────────
        final rateRaw = events[0].snapshot.value;
        if (rateRaw is num) {
          _currentRate = rateRaw.toDouble();
          _rateController.text = _currentRate.toString();
        } else if (_isLoading) {
          _currentRate = 11.5;
          _rateController.text = _currentRate.toString();
        }

        // ── last rate update timestamp (already sticky before this
        // change: a missing value simply left the previous one in place,
        // never resetting it to null) ────────────────────────────────
        final lastUpdateRaw = events[1].snapshot.value;
        if (lastUpdateRaw is num) {
          _lastRateUpdateTime =
              DateTime.fromMillisecondsSinceEpoch(lastUpdateRaw.toInt());
        }

        // ── rate change history ────────────────────────────────────
        final historyRaw = events[2].snapshot.value as Map<dynamic, dynamic>?;
        if (historyRaw != null) {
          final list = historyRaw.entries.map((e) {
            final val = Map<String, dynamic>.from(e.value as Map);
            val['id'] = e.key;
            return val;
          }).toList();
          list.sort((a, b) {
            final aTime = (a['timestamp'] as num?)?.toInt() ?? 0;
            final bTime = (b['timestamp'] as num?)?.toInt() ?? 0;
            return bTime.compareTo(aTime);
          });
          _rateHistory = list;
        } else if (_isLoading) {
          _rateHistory = [];
        }

        _isLoading = false;
        _errorText = null;
        _postLoadErrorNotified = false;
      });
    }, onError: (Object error) {
      if (!mounted) return;
      debugPrint('[Settings] Combined listen error: $error');
      _loadTimeoutTimer?.cancel();
      if (_isLoading) {
        setState(() {
          _isLoading = false;
          _errorText = _isPermissionDenied(error)
              ? 'You do not have permission to view rate settings.'
              : 'Failed to load rate settings.';
        });
      } else if (!_postLoadErrorNotified) {
        _postLoadErrorNotified = true;
        TopToast.show(
          context,
          'Lost connection to live rate settings.',
          isError: true,
        );
      }
    });
  }

  Future<void> _saveRate() async {
    if (_isInstituteAdmin) return; // Client-side guard; see class doc.
    final rate = double.tryParse(_rateController.text.trim());
    if (rate == null || rate <= 0) {
      setState(() {
        _rateError = 'Enter a valid rate.';
        _rateShake++;
      });
      return;
    }
    setState(() => _saving = true);
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final db = FirebaseDatabase.instance.ref();

      await db.update({
        'settings/electricityRate': rate,
        'settings/lastRateUpdate': timestamp,
      });

      await db.child('rate_changes/$timestamp').set({
        'oldRate': _currentRate,
        'newRate': rate,
        'source': 'manual_update',
        'updatedBy': FirebaseAuth.instance.currentUser?.uid ?? 'unknown',
        'timestamp': timestamp,
      });

      await db.child('notifications').push().set({
        'type': 'rate_change_manual',
        'message':
            'Electricity rate updated to ₱${rate.toStringAsFixed(2)}/kWh',
        'oldRate': _currentRate,
        'newRate': rate,
        'updatedBy': FirebaseAuth.instance.currentUser?.uid ?? 'unknown',
        'updatedByEmail': FirebaseAuth.instance.currentUser?.email ?? 'admin',
        'timestamp': ServerValue.timestamp,
      });

      if (!mounted) return;
      setState(() {
        _saving = false;
        _currentRate = rate;
      });
      TopToast.show(context, 'Electricity rate updated.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final msg = _isPermissionDenied(e)
          ? 'Permission denied while saving rate.'
          : 'Failed to save rate: $e';
      TopToast.show(context, msg, isError: true);
    }
  }

  Future<void> _registerUnassignedIotDevice() async {
    if (_registeringIot) return;

    final id = _unassignedIotController.text.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9_-]{3,40}$').hasMatch(id)) {
      setState(() {
        _iotError = 'Enter a valid Device ID (3-40 chars, A-Z, 0-9, _ or -).';
        _iotShake++;
      });
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
        if (assignedTo.isNotEmpty) {
          if (!mounted) return;
          setState(() {
            _registeringIot = false;
            _iotError = 'Device already assigned to $assignedTo.';
            _iotShake++;
          });
          return;
        }

        await masterRef.update({
          'source': existing['source'] ?? 'real_iot',
          'updatedAt': ServerValue.timestamp,
        });

        if (!mounted) return;
        _unassignedIotController.clear();
        setState(() => _registeringIot = false);
        TopToast.show(context, '$id is already unassigned and ready to add.');
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
      TopToast.show(context, '$id is now unassigned and ready for assignment.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _registeringIot = false);
      final msg = _isPermissionDenied(e)
          ? 'Permission denied while registering IoT device.'
          : 'Failed to register IoT device: $e';
      TopToast.show(context, msg, isError: true);
    }
  }

  Future<void> _fetchLatestRate() async {
    if (_isInstituteAdmin) return; // Client-side guard; see class doc.
    setState(() => _fetchingLatestRate = true);
    try {
      final result = await _rateMonitor.monitorAndUpdateRate();
      if (!mounted) return;
      setState(() => _fetchingLatestRate = false);

      if (result.hasChanged) {
        TopToast.show(
          context,
          'Rate updated: ₱${result.oldRate.toStringAsFixed(2)} → ₱${result.newRate.toStringAsFixed(2)}/kWh',
        );
      } else {
        TopToast.show(context, 'No rate changes detected.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _fetchingLatestRate = false);
      TopToast.show(context, 'Failed to fetch rate: $e', isError: true);
    }
  }

  Future<void> _checkGithubRelease({bool silent = false}) async {
    setState(() => _githubChecking = true);
    try {
      final info = await GithubUpdateService.fetchLatestRelease(
        repositoryInput: _fixedGithubRepo,
        currentVersion: _appVersion.isEmpty ? '0.0.0' : _appVersion,
      );
      if (!mounted) return;
      setState(() => _githubRelease = info);
      if (!silent) {
        TopToast.success(
          context,
          info.updateAvailable
              ? 'Update found: ${info.latestVersion}.'
              : 'You are already on the latest version.',
        );
      }
    } catch (e) {
      if (!mounted || silent) return;
      final msg = e is FormatException
          ? e.message
          : 'Unable to check GitHub releases: $e';
      TopToast.show(context, msg, isError: true);
    } finally {
      if (mounted) setState(() => _githubChecking = false);
    }
  }

  Future<void> _openGithubDownload() async {
    final release = _githubRelease;
    if (release == null) {
      TopToast.show(context, 'Check for an update first.', isError: true);
      return;
    }

    final assetUrl = release.assetUrl ?? '';
    if (assetUrl.isEmpty) {
      // No direct asset — open the release page
      final openedUrl =
          await DownloadOpenService.openRemoteUrl(release.releaseUrl);
      if (!openedUrl && mounted) {
        TopToast.show(context, 'Could not open the release page.',
            isError: true);
      }
      return;
    }

    TopToast.threshold(context, 'Downloading update...');
    final opened = await DownloadOpenService.downloadAndOpenRemoteFile(
      assetUrl,
      suggestedFileName: release.assetName,
    );
    if (!opened && mounted) {
      TopToast.error(context,
          'Unable to download or open the update. Opening release page instead.');
      await DownloadOpenService.openRemoteUrl(release.releaseUrl);
    } else if (opened && mounted) {
      TopToast.success(context, 'Update downloaded and opened.');
    }
  }

  Future<void> _logout() async {
    await AutomationSchedulerService.stop();
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/login');
  }

  String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inSeconds < 60) {
      return 'Just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return '${dt.month}/${dt.day}/${dt.year}';
    }
  }

  static const _rateValueStyle = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 28,
    height: 34 / 28,
    fontWeight: FontWeight.w700,
  );

  // ── Build ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppTopBar(
          title: 'Settings',
          subtitle: _isInstituteAdmin
              ? 'Devices, updates, account'
              : 'Rate, devices, updates, account',
          variant: AppTopBarVariant.small,
          showBackButton: true,
          showInstituteLine: _isInstituteAdmin,
        ),
        body: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _errorText != null
                    ? _buildRateSectionError()
                    : ScreenSkeleton(
                        isLoading: _isLoading, child: _buildRateSection()),
                _buildRegisterDeviceSection(),
                _buildUpdaterSection(),
                _buildAccountSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionDivider() => Container(height: 1, color: _palette.line);

  Widget _sectionPadding(Widget child) =>
      Padding(padding: const EdgeInsets.fromLTRB(20, 20, 20, 20), child: child);

  Widget _buildRateSectionError() {
    return Column(
      children: [
        _sectionPadding(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Electricity rate',
                style: AppTextStyles.title.copyWith(color: AppColors.ink)),
            const SizedBox(height: 12),
            const Icon(Icons.wifi_off_rounded, size: 28, color: AppColors.inkMuted),
            const SizedBox(height: 10),
            Text(_errorText ?? 'Failed to load rate settings.',
                style: AppTextStyles.bodySm
                    .copyWith(color: AppColors.inkMuted)),
            const SizedBox(height: 12),
            AppOutlineButton(label: 'Retry', onPressed: _retryLoad, icon: Icons.refresh),
          ],
        )),
        _sectionDivider(),
      ],
    );
  }

  Widget _buildRateSection() {
    final lastUpdateText = _lastRateUpdateTime == null
        ? 'Never'
        : _formatDateTime(_lastRateUpdateTime!);
    final dateLabel = _lastRateUpdateTime == null
        ? ''
        : 'Davao Light · ${_lastRateUpdateTime!.month}/${_lastRateUpdateTime!.day}';

    return Column(
      children: [
        _sectionPadding(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Electricity rate',
                      style:
                          AppTextStyles.title.copyWith(color: AppColors.ink)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: AppColors.success.withAlpha(90)),
                  ),
                  child: Text('Auto',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.successText)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('Used for every cost in the app',
                style:
                    AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
            const SizedBox(height: 10),
            RichText(
              text: TextSpan(
                style: _rateValueStyle.copyWith(color: AppColors.ink),
                children: [
                  TextSpan(text: '₱${_currentRate.toStringAsFixed(2)}'),
                  TextSpan(
                    text: ' per kWh',
                    style: AppTextStyles.body.copyWith(color: AppColors.inkMuted),
                  ),
                ],
              ),
            ),
            if (dateLabel.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(dateLabel,
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.inkMuted)),
            ],
            const SizedBox(height: 6),
            Text('Last updated: $lastUpdateText',
                style:
                    AppTextStyles.caption.copyWith(color: AppColors.inkMuted)),
            const SizedBox(height: 16),
            if (_isInstituteAdmin)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _palette.line),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline, size: 18, color: AppColors.inkMid),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Set by the campus admin.',
                          style: AppTextStyles.bodySm
                              .copyWith(color: AppColors.inkMid)),
                    ),
                  ],
                ),
              )
            else ...[
              AppOutlineButton(
                label: _fetchingLatestRate ? 'Fetching...' : 'Fetch latest rate',
                icon: Icons.cloud_download_outlined,
                onPressed: _fetchingLatestRate ? null : _fetchLatestRate,
                expand: true,
              ),
              const SizedBox(height: 16),
              Text('Set manually',
                  style: AppTextStyles.label.copyWith(color: AppColors.ink)),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: AppTextField(
                      controller: _rateController,
                      shakeTrigger: _rateShake,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) {
                        if (_rateError != null) setState(() => _rateError = null);
                      },
                      decoration: InputDecoration(
                        prefixText: '₱ ',
                        errorText: _rateError,
                        hintText: 'e.g. 11.75',
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: _palette.line),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: _palette.line),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: _palette.dark),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  AppPrimaryButton(
                    label: 'Save rate',
                    onPressed: _saving ? null : _saveRate,
                  ),
                ],
              ),
            ],
          ],
        )),
        _sectionDivider(),
        if (_rateHistory.isNotEmpty) ...[
          _sectionPadding(Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Rate history',
                  style: AppTextStyles.title.copyWith(color: AppColors.ink)),
              const SizedBox(height: 12),
              ..._rateHistory.take(10).map((change) {
                final timestamp = (change['timestamp'] as num?)?.toInt() ?? 0;
                final dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
                final oldRate = (change['oldRate'] as num?)?.toDouble() ?? 0.0;
                final newRate = (change['newRate'] as num?)?.toDouble() ?? 0.0;
                final source = (change['source'] as String?) ?? 'unknown';
                final isManual = source == 'manual_update';
                final delta = newRate - oldRate;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      OutlineIconBox(
                        icon: isManual ? Icons.edit_outlined : Icons.cloud_download_outlined,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '₱${oldRate.toStringAsFixed(2)} → ₱${newRate.toStringAsFixed(2)}',
                              style: AppTextStyles.subtitle
                                  .copyWith(color: AppColors.ink),
                            ),
                            Text(
                              '${_formatDateTime(dateTime)} · ${isManual ? 'Manual' : 'Auto'}',
                              style: AppTextStyles.caption
                                  .copyWith(color: AppColors.inkMuted),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${delta >= 0 ? '↑' : '↓'} ${delta.abs().toStringAsFixed(2)}',
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.inkMid),
                      ),
                    ],
                  ),
                );
              }),
            ],
          )),
          _sectionDivider(),
        ],
      ],
    );
  }

  Widget _buildRegisterDeviceSection() {
    final countLabel = _registeredDeviceCount == null
        ? ''
        : '$_registeredDeviceCount registered';
    return Column(
      children: [
        _sectionPadding(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Register device',
                      style:
                          AppTextStyles.title.copyWith(color: AppColors.ink)),
                ),
                if (countLabel.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: _palette.line),
                    ),
                    child: Text(countLabel,
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.inkMid)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text('ID printed on the ESP32 label',
                style:
                    AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AppTextField(
                    controller: _unassignedIotController,
                    shakeTrigger: _iotShake,
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (_) {
                      if (_iotError != null) setState(() => _iotError = null);
                    },
                    decoration: InputDecoration(
                      hintText: 'DEV-2024-XXXX',
                      errorText: _iotError,
                      errorMaxLines: 2,
                      prefixIcon:
                          const Icon(Icons.memory, size: 18),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: _palette.line),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: _palette.line),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: _palette.dark),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                AppPrimaryButton(
                  label: 'Register',
                  onPressed: _registeringIot ? null : _registerUnassignedIotDevice,
                ),
              ],
            ),
          ],
        )),
        _sectionDivider(),
      ],
    );
  }

  Widget _buildAccountSection() {
    final user = FirebaseAuth.instance.currentUser;
    return Column(
      children: [
        _sectionPadding(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Account',
                style: AppTextStyles.title.copyWith(color: AppColors.ink)),
            const SizedBox(height: 12),
            _row(Icons.email_outlined, 'Email', user?.email ?? ''),
            const SizedBox(height: 16),
            AppOutlineButton(
              label: 'Sign out',
              icon: Icons.logout,
              onPressed: _logout,
              expand: true,
            ),
          ],
        )),
      ],
    );
  }

  Widget _buildUpdaterSection() {
    final release = _githubRelease;
    final statusLabel = release == null
        ? 'Ready to check latest release.'
        : release.updateAvailable
            ? '${release.latestVersion} available'
            : 'Already on the latest version.';

    return Column(
      children: [
        _sectionPadding(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('App update',
                      style:
                          AppTextStyles.title.copyWith(color: AppColors.ink)),
                ),
                if (release?.assetUrl != null)
                  AppOutlineButton(
                    label: release!.updateAvailable ? 'Install' : 'Open',
                    onPressed: _openGithubDownload,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(statusLabel,
                style:
                    AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
            const SizedBox(height: 12),
            _row(Icons.phone_android_outlined, 'Current version',
                _appVersion.isEmpty ? 'Loading...' : _appVersion),
            _row(Icons.system_update_alt, 'Latest release',
                release == null
                    ? 'Not checked yet'
                    : (release.releaseName.isNotEmpty
                        ? release.releaseName
                        : release.latestVersion)),
            const SizedBox(height: 12),
            AppOutlineButton(
              label: _githubChecking ? 'Checking...' : 'Check latest',
              icon: Icons.search_outlined,
              onPressed: _githubChecking ? null : _checkGithubRelease,
              expand: true,
            ),
          ],
        )),
        _sectionDivider(),
      ],
    );
  }

  Widget _row(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 16, color: AppColors.inkMuted),
        const SizedBox(width: 10),
        Text(label, style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
        const Spacer(),
        Flexible(
          child: Text(value,
              style: AppTextStyles.bodySm.copyWith(
                  color: AppColors.ink, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right),
        ),
      ]),
    );
  }
}
