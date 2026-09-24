import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:rxdart/rxdart.dart';
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../services/download_open_service.dart';
import '../../services/github_update_service.dart';
import '../../services/davao_light_rate_monitor.dart';
import '../../services/automation_scheduler_service.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import '../../theme/app_fonts.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const String _fixedGithubRepo = 'alburolowrencejoy/smartpowerswitch';
  static const String _firstSectionKey = 'iot';

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

  List<Map<String, dynamic>> _rateHistory = [];
  String _openSectionKey = _firstSectionKey;

  late DavaoLightRateMonitor _rateMonitor;

  StreamSubscription? _combinedSub;

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
    _loadAppVersion();
    _checkGithubRelease(silent: true);
  }

  @override
  void dispose() {
    _rateController.dispose();
    _unassignedIotController.dispose();
    _combinedSub?.cancel();
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

  void _toggleSection(String key) {
    setState(() {
      _openSectionKey = _openSectionKey == key ? '' : key;
    });
  }

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _appVersion = info.version);
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

  // ── Build ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: Scaffold(
        backgroundColor: AppColors.surface,
        body: SafeArea(
          child: Column(children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildIotInventorySection(),
                      const SizedBox(height: 12),
                      _errorText != null
                          ? _buildRateSectionError()
                          : ScreenSkeleton(
                              isLoading: _isLoading,
                              child: _buildRateSection()),
                      const SizedBox(height: 12),
                      _buildUpdaterSection(),
                      const SizedBox(height: 12),
                      _buildAccountSection(),
                      const SizedBox(height: 12),
                      _buildAppInfoSection(),
                    ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildIotInventorySection() {
    return _section(
      sectionKey: 'iot',
      title: 'IoT Device Inventory',
      icon: Icons.memory_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text(
          'Register a real IoT device ID as unassigned so it can be added to a room/floor later.',
          style: TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: AppTextField(
              controller: _unassignedIotController,
              shakeTrigger: _iotShake,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(fontSize: 14, color: AppColors.textDark),
              onChanged: (_) {
                if (_iotError != null) setState(() => _iotError = null);
              },
              decoration: InputDecoration(
                hintText: 'e.g. ESP32-ROOM101-001',
                errorText: _iotError,
                errorMaxLines: 2,
                hintStyle: const TextStyle(color: AppColors.textMuted),
                filled: true,
                fillColor: Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 46,
            child: ElevatedButton(
              onPressed: _registeringIot ? null : _registerUnassignedIotDevice,
              style: ElevatedButton.styleFrom(
                  backgroundColor: _palette.dark,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              child: _registeringIot
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Text('Register',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ]),
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
        const Expanded(
          child: Text('Settings',
              style: TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _palette.light.withAlpha(51),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text('Admin',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _palette.light)),
        ),
      ]),
    );
  }

  Widget _buildRateSectionError() {
    return _section(
      sectionKey: 'rate',
      title: 'Electricity Rate',
      icon: Icons.payments_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Icon(Icons.wifi_off_rounded, size: 28, color: _palette.mid),
        const SizedBox(height: 10),
        Text(_errorText ?? 'Failed to load rate settings.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
        const SizedBox(height: 12),
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
    );
  }

  Widget _buildRateSection() {
    final lastUpdateText = _lastRateUpdateTime == null
        ? 'Never'
        : _formatDateTime(_lastRateUpdateTime!);

    return _section(
      sectionKey: 'rate',
      title: 'Electricity Rate',
      icon: Icons.payments_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Current rate: ₱${_currentRate.toStringAsFixed(2)} / kWh',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
        const SizedBox(height: 6),
        Text('Last Updated: $lastUpdateText',
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
        const SizedBox(height: 12),

        // Fetch Latest Rate Button
        SizedBox(
          width: double.infinity,
          height: 44,
          child: OutlinedButton.icon(
            onPressed: _fetchingLatestRate ? null : _fetchLatestRate,
            icon: _fetchingLatestRate
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _palette.dark,
                    ),
                  )
                : const Icon(Icons.cloud_download_outlined, size: 18),
            label: Text(
              _fetchingLatestRate ? 'Fetching...' : 'Fetch Latest Rate',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: _palette.dark,
              side: BorderSide(color: _palette.dark.withAlpha(90)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),

        const SizedBox(height: 12),
        const Divider(height: 1),
        const SizedBox(height: 12),

        const Text(
          'Manual Update',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textDark),
        ),
        const SizedBox(height: 10),

        Row(children: [
          Expanded(
            child: AppTextField(
              controller: _rateController,
              shakeTrigger: _rateShake,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 14, color: AppColors.textDark),
              onChanged: (_) {
                if (_rateError != null) setState(() => _rateError = null);
              },
              decoration: InputDecoration(
                prefixText: '₱ ',
                errorText: _rateError,
                hintText: '11.5',
                hintStyle: const TextStyle(color: AppColors.textMuted),
                filled: true,
                fillColor: Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 46,
            child: ElevatedButton(
              onPressed: _saving ? null : _saveRate,
              style: ElevatedButton.styleFrom(
                  backgroundColor: _palette.dark,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Text('Save',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),

        const SizedBox(height: 12),
        const Divider(height: 1),
        const SizedBox(height: 12),

        // Rate Change History Section
        if (_rateHistory.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Rate Change History',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark,
                ),
              ),
              Text(
                '${_rateHistory.length} changes',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ..._rateHistory.take(10).map((change) {
            final timestamp = (change['timestamp'] as num?)?.toInt() ?? 0;
            final dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
            final oldRate = (change['oldRate'] as num?)?.toDouble() ?? 0.0;
            final newRate = (change['newRate'] as num?)?.toDouble() ?? 0.0;
            final source = (change['source'] as String?) ?? 'unknown';
            final isManual = source == 'manual_update';

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _palette.mid.withAlpha(26)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: isManual
                          ? _palette.dark.withAlpha(20)
                          : _palette.pale,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Icon(
                        isManual ? Icons.edit : Icons.cloud_download,
                        size: 16,
                        color: isManual ? _palette.dark : _palette.mid,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '₱${oldRate.toStringAsFixed(2)} → ₱${newRate.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textDark,
                          ),
                        ),
                        Text(
                          '${_formatDateTime(dateTime)} • ${isManual ? 'Manual' : 'Auto'}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        ] else
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: Text(
                'No rate changes yet',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _buildAccountSection() {
    final user = FirebaseAuth.instance.currentUser;
    return _section(
      sectionKey: 'account',
      title: 'Account',
      icon: Icons.person_outline,
      child: Column(children: [
        _settingRow(Icons.email_outlined, 'Email', user?.email ?? ''),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 46,
          child: OutlinedButton.icon(
            onPressed: _logout,
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Sign Out'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.error,
              side: BorderSide(color: AppColors.error.withAlpha(102)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildAppInfoSection() {
    final version = _appVersion.isEmpty ? 'Loading...' : _appVersion;
    return _section(
      sectionKey: 'appInfo',
      title: 'App Info',
      icon: Icons.info_outline,
      child: Column(children: [
        _settingRow(
            Icons.business, 'Institution', 'Davao del Norte State College'),
        _settingRow(
            Icons.location_on_outlined, 'Location', 'Davao del Norte, PH'),
        _settingRow(Icons.tag, 'Version', version),
      ]),
    );
  }

  Widget _buildUpdaterSection() {
    final release = _githubRelease;
    final latestLabel = release == null
        ? 'Not checked yet'
        : release.releaseName.isNotEmpty
            ? release.releaseName
            : release.latestVersion;
    final statusLabel = release == null
        ? 'Ready to check latest release.'
        : release.updateAvailable
            ? 'Update available: ${release.latestVersion}'
            : 'Already on the latest version.';

    return _section(
      sectionKey: 'updater',
      title: 'App Updater',
      icon: Icons.system_update_alt_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Updates are sourced from the fixed project GitHub Releases.',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: OutlinedButton.icon(
              onPressed: _githubChecking ? null : _checkGithubRelease,
              icon: _githubChecking
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _palette.dark,
                      ),
                    )
                  : const Icon(Icons.search_outlined, size: 18),
              label: Text(
                _githubChecking ? 'Checking...' : 'Check Latest',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: _palette.dark,
                side: BorderSide(color: _palette.dark.withAlpha(90)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _settingRow(Icons.phone_android_outlined, 'Current version',
              _appVersion.isEmpty ? 'Loading...' : _appVersion),
          _settingRow(Icons.source_outlined, 'GitHub repo', _fixedGithubRepo),
          _settingRow(Icons.system_update_alt, 'Latest release', latestLabel),
          _settingRow(Icons.info_outline, 'Status', statusLabel),
          if (release?.assetUrl != null) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton.icon(
                onPressed: _openGithubDownload,
                icon: Icon(
                  release!.updateAvailable
                      ? Icons.download_rounded
                      : Icons.open_in_new,
                  size: 18,
                  color: Colors.white,
                ),
                label: Text(
                  release.updateAvailable ? 'Download Update' : 'Open APK',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      release.updateAvailable ? _palette.dark : _palette.mid,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              release.assetName ?? release.releaseUrl,
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _section(
      {required String sectionKey,
      required String title,
      required IconData icon,
      required Widget child}) {
    final isOpen = _openSectionKey == sectionKey;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color:
              isOpen ? _palette.dark.withAlpha(70) : _palette.mid.withAlpha(18),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(isOpen ? 10 : 4),
            blurRadius: isOpen ? 16 : 10,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => _toggleSection(sectionKey),
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: isOpen ? _palette.dark.withAlpha(20) : _palette.pale,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon,
                    size: 18, color: isOpen ? _palette.dark : _palette.mid),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontFamily: AppFonts.family,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: isOpen ? AppColors.textDark : AppColors.textMid,
                  ),
                ),
              ),
            ]),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: child,
          ),
          crossFadeState:
              isOpen ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 180),
          sizeCurve: Curves.easeOut,
        ),
      ]),
    );
  }

  Widget _settingRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 16, color: AppColors.textMuted),
        const SizedBox(width: 10),
        Text(label,
            style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
        const Spacer(),
        Flexible(
          child: Text(value,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textDark),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right),
        ),
      ]),
    );
  }
}
