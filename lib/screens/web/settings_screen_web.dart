import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:rxdart/rxdart.dart';
import '../../services/davao_light_rate_monitor.dart';
import '../../services/download_open_service.dart';
import '../../services/github_update_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import 'web_theme.dart';
import 'web_widgets.dart';
import '../../theme/app_fonts.dart';

/// The desktop "Settings" section: the same actions as [SettingsScreen]
/// (electricity rate + history, IoT device registration, GitHub updater,
/// account, app info) but as a grid of always-expanded cards instead of a
/// single-open accordion -- desktop has the width for everything to be
/// visible at once. Independent Firebase/state from the mobile screen, so
/// [SettingsScreen] itself is never touched.
class SettingsScreenWeb extends StatefulWidget {
  const SettingsScreenWeb({super.key});

  @override
  State<SettingsScreenWeb> createState() => _SettingsScreenWebState();
}

class _SettingsScreenWebState extends State<SettingsScreenWeb> {
  static const String _fixedGithubRepo = 'alburolowrencejoy/smartpowerswitch';

  final _rateController = TextEditingController();
  final _unassignedIotController = TextEditingController();
  bool _saving = false;
  bool _registeringIot = false;

  // Inline field errors (red border + message + shake).
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

  late DavaoLightRateMonitor _rateMonitor;

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
  // This screen has no role/institute constructor params (it's pushed from
  // dashboard_web.dart with no arguments -- see DashboardWeb's IndexedStack),
  // so role/institute are hydrated directly from the signed-in user's own
  // record, mirroring mobile settings_screen.dart's _hydrateSessionFromAuth.
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

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _appVersion = info.version);
  }

  /// Combines this screen's 3 Firebase paths (electricity rate, last-update
  /// timestamp, rate change history) into one subscription with a sticky
  /// merge, so a transient null/empty snapshot never blanks data that
  /// already loaded once.
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
      FirebaseDatabase.instance.ref('settings/lastRateUpdate').onValue,
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
        _applyLastRateUpdate(events[1].snapshot.value);
        _applyRateHistory(events[2].snapshot.value);
        _hasLoadedOnce = true;
        _isLoading = false;
        _errorText = null;
      });
    }, onError: (Object error) {
      if (!mounted) return;
      if (_isPermissionDenied(error)) {
        if (!_hasLoadedOnce) {
          _timeoutTimer?.cancel();
          _timeoutTimer = null;
          setState(() {
            _isLoading = false;
            _errorText = 'You do not have permission to view settings.';
          });
        }
        return;
      }
      if (!_hasLoadedOnce) {
        _timeoutTimer?.cancel();
        _timeoutTimer = null;
        setState(() {
          _isLoading = false;
          _errorText = 'Failed to load settings.';
        });
      }
    });
  }

  void _applyRate(Object? raw) {
    // electricityRate already has a sensible default (11.5) -- a transient
    // null read must never overwrite an already-loaded rate.
    final rate = (raw as num?)?.toDouble();
    if (rate == null) return;
    _currentRate = rate;
    _rateController.text = rate.toString();
  }

  void _applyLastRateUpdate(Object? raw) {
    final timestamp = (raw as num?)?.toInt();
    if (timestamp == null) return;
    _lastRateUpdateTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
  }

  void _applyRateHistory(Object? raw) {
    if (raw is Map) {
      final list = raw.entries.map((e) {
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
  }

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
    void fail(String message) => setState(() {
          _iotError = message;
          _iotShake++;
        });
    if (id.isEmpty) {
      fail('Enter a Device ID.');
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
        if (assignedTo.isNotEmpty) {
          if (!mounted) return;
          setState(() => _registeringIot = false);
          fail('Already assigned to $assignedTo.');
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

  // ── Build (desktop grid layout) ───────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: ScreenSkeleton(
        isLoading: _isLoading,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Settings',
                  style: TextStyle(
                      fontFamily: AppFonts.family,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDark)),
              const SizedBox(height: 4),
              const Text('Rate, devices, updates, and account',
                  style: TextStyle(fontSize: 13, color: WebColors.muted)),
              const SizedBox(height: 24),
              if (_errorText != null)
                _buildError()
              else ...[
                _buildRateSection(),
                const SizedBox(height: 16),
                _equalRow(
                    [_buildIotInventorySection(), _buildUpdaterSection()]),
                const SizedBox(height: 16),
                _equalRow([_buildAccountSection(), _buildAppInfoSection()]),
              ],
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
              child: Icon(Icons.cloud_off_outlined,
                  size: 34, color: _palette.mid)),
          const SizedBox(height: 16),
          const Text('Cannot load settings',
              style: TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark)),
          const SizedBox(height: 8),
          Text(_errorText ?? 'Something went wrong.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: WebColors.muted)),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh, color: Colors.white, size: 18),
            label: const Text('Retry', style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
                backgroundColor: _palette.dark,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
          ),
        ]),
      ),
    );
  }

  /// Lays out [cards] in one row that always divides the full row width
  /// evenly between them (rather than a [Wrap] of fixed widths, which left
  /// large, uneven gaps depending on how much space was left over) and
  /// stretches every card in the row to match the tallest one.
  Widget _equalRow(List<Widget> cards) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(width: 16),
            Expanded(child: cards[i]),
          ],
        ],
      ),
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
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: _palette.pale,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: _palette.mid),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                    fontFamily: AppFonts.family,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _buildIotInventorySection() {
    return _card(
      title: 'IoT Device Inventory',
      icon: Icons.memory_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text(
          'Register a real IoT device ID as unassigned so it can be added to a room/floor later.',
          style: TextStyle(fontSize: 13, color: WebColors.muted),
        ),
        const SizedBox(height: 12),
        AppTextField(
          shakeTrigger: _iotShake,
          controller: _unassignedIotController,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(fontSize: 14, color: AppColors.textDark),
          decoration: webInputDecoration(_palette,
              label: 'Device ID',
              hint: 'e.g. ESP32-ROOM101-001',
              error: _iotError),
          onChanged: (_) {
            if (_iotError != null) setState(() => _iotError = null);
          },
          onSubmitted: (_) => _registerUnassignedIotDevice(),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
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
    );
  }

  Widget _buildRateSection() {
    final lastUpdateText = _lastRateUpdateTime == null
        ? 'Never'
        : _formatDateTime(_lastRateUpdateTime!);

    return _card(
      title: 'Electricity Rate',
      icon: Icons.payments_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Current rate: ₱${_currentRate.toStringAsFixed(2)} / kWh',
            style: const TextStyle(fontSize: 13, color: WebColors.muted)),
        const SizedBox(height: 6),
        Text('Last Updated: $lastUpdateText',
            style: const TextStyle(fontSize: 12, color: WebColors.muted)),
        const SizedBox(height: 12),
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
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textDark),
        ),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: AppTextField(
              shakeTrigger: _rateShake,
              controller: _rateController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 14, color: AppColors.textDark),
              decoration: webInputDecoration(_palette,
                      label: 'Rate per kWh', hint: '11.50', error: _rateError)
                  .copyWith(prefixText: '₱ '),
              onChanged: (_) {
                if (_rateError != null) setState(() => _rateError = null);
              },
              onSubmitted: (_) => _saveRate(),
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
        if (_rateHistory.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Rate Change History',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark,
                ),
              ),
              Text(
                '${_rateHistory.length} changes',
                style: const TextStyle(
                  fontSize: 12,
                  color: WebColors.muted,
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
                color: AppColors.surface,
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
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textDark,
                          ),
                        ),
                        Text(
                          '${_formatDateTime(dateTime)} • ${isManual ? 'Manual' : 'Auto'}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: WebColors.muted,
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
                  fontSize: 13,
                  color: WebColors.muted,
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _buildAccountSection() {
    final user = FirebaseAuth.instance.currentUser;
    return _card(
      title: 'Account',
      icon: Icons.person_outline,
      child: Column(children: [
        _settingRow(Icons.email_outlined, 'Email', user?.email ?? ''),
      ]),
    );
  }

  Widget _buildAppInfoSection() {
    final version = _appVersion.isEmpty ? 'Loading...' : _appVersion;
    return _card(
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

    return _card(
      title: 'App Updater',
      icon: Icons.system_update_alt_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Updates are sourced from the fixed project GitHub Releases.',
            style: TextStyle(fontSize: 13, color: WebColors.muted),
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
              style: const TextStyle(fontSize: 12, color: WebColors.muted),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _settingRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 16, color: WebColors.muted),
        const SizedBox(width: 10),
        Text(label,
            style: const TextStyle(fontSize: 14, color: WebColors.muted)),
        const Spacer(),
        Flexible(
          child: Text(value,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textDark),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right),
        ),
      ]),
    );
  }
}
