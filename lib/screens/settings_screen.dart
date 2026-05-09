import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_colors.dart';
import '../firebase_options.dart';
import '../services/github_update_service.dart';
import '../widgets/top_toast.dart';

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
  double _currentRate = 11.5;
  String _appVersion = '';
  GithubReleaseInfo? _githubRelease;
  bool _githubChecking = false;

  List<Map<String, dynamic>> _users = [];
  String _openSectionKey = _firstSectionKey;

  bool _isPermissionDenied(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') ||
        text.contains('permission_denied');
  }

  @override
  void initState() {
    super.initState();
    _loadRate();
    _listenUsers();
    _loadAppVersion();
    _checkGithubRelease(silent: true);
  }

  @override
  void dispose() {
    _rateController.dispose();
    _unassignedIotController.dispose();
    super.dispose();
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

  void _loadRate() {
    FirebaseDatabase.instance.ref('settings/electricityRate').onValue.listen(
        (event) {
      if (!mounted) return;
      final rate = (event.snapshot.value as num?)?.toDouble() ?? 11.5;
      setState(() {
        _currentRate = rate;
        _rateController.text = rate.toString();
      });
    }, onError: (Object error) {
      if (!mounted || _isPermissionDenied(error)) return;
    });
  }

  void _listenUsers() {
    FirebaseDatabase.instance.ref('users').onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) {
        setState(() => _users = []);
        return;
      }
      final list = data.entries.map((e) {
        final val = Map<String, dynamic>.from(e.value as Map);
        val['uid'] = e.key;
        return val;
      }).toList();
      setState(() => _users = list);
    }, onError: (Object error) {
      if (!mounted || _isPermissionDenied(error)) return;
    });
  }

  Future<void> _saveRate() async {
    final rate = double.tryParse(_rateController.text.trim());
    if (rate == null || rate <= 0) {
      TopToast.show(context, 'Enter a valid rate.', isError: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await FirebaseDatabase.instance.ref('settings/electricityRate').set(rate);
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
      TopToast.show(
        context,
        'Enter a valid Device ID (3-40 chars, A-Z, 0-9, _ or -).',
        isError: true,
      );
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
          TopToast.show(
            context,
            'Device already assigned to $assignedTo.',
            isError: true,
          );
          setState(() => _registeringIot = false);
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

    final url = release.assetUrl ?? release.releaseUrl;
    final launched = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!launched && mounted) {
      TopToast.show(context, 'Could not open the download link.',
          isError: true);
    }
  }

  // ── Get Web API Key from firebase options ────────────────────
  String get _apiKey => DefaultFirebaseOptions.currentPlatform.apiKey;

  // ── Create new account via REST API (doesn't sign out admin) ──
  Future<void> _addUser() async {
    final emailCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    String selectedRole = 'faculty';
    String? errorText;
    bool obscure = true;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Add New Account',
              style:
                  TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Name
              TextField(
                controller: nameCtrl,
                decoration: _inputDecoration('Full Name', Icons.person_outline),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              // Email
              TextField(
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: _inputDecoration(
                    'Email (e.g. juan@dnsc.edu.ph)', Icons.email_outlined),
              ),
              const SizedBox(height: 12),
              // Password
              TextField(
                controller: passwordCtrl,
                obscureText: obscure,
                decoration:
                    _inputDecoration('Password', Icons.lock_outline).copyWith(
                  suffixIcon: GestureDetector(
                    onTap: () => setS(() => obscure = !obscure),
                    child: Icon(
                        obscure ? Icons.visibility_off : Icons.visibility,
                        size: 18,
                        color: AppColors.textMuted),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Role selector
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.greenMid.withAlpha(51)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setS(() => selectedRole = 'faculty'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: selectedRole == 'faculty'
                              ? AppColors.greenDark
                              : Colors.transparent,
                          borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(11),
                              bottomLeft: Radius.circular(11)),
                        ),
                        child: Center(
                            child: Text('Faculty',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: selectedRole == 'faculty'
                                        ? Colors.white
                                        : AppColors.textMuted))),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setS(() => selectedRole = 'admin'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: selectedRole == 'admin'
                              ? AppColors.greenDark
                              : Colors.transparent,
                          borderRadius: const BorderRadius.only(
                              topRight: Radius.circular(11),
                              bottomRight: Radius.circular(11)),
                        ),
                        child: Center(
                            child: Text('Admin',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: selectedRole == 'admin'
                                        ? Colors.white
                                        : AppColors.textMuted))),
                      ),
                    ),
                  ),
                ]),
              ),
              if (errorText != null) ...[
                const SizedBox(height: 10),
                Text(errorText!,
                    style:
                        const TextStyle(fontSize: 12, color: AppColors.error)),
              ],
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel',
                    style: TextStyle(color: AppColors.textMuted))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.greenDark,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              onPressed: () async {
                final email = emailCtrl.text.trim();
                final password = passwordCtrl.text.trim();
                final name = nameCtrl.text.trim();

                if (name.isEmpty || email.isEmpty || password.isEmpty) {
                  setS(() => errorText = 'All fields are required');
                  return;
                }
                if (!email.endsWith('@dnsc.edu.ph')) {
                  setS(
                      () => errorText = 'Email must be a @dnsc.edu.ph address');
                  return;
                }
                if (password.length < 6) {
                  setS(() =>
                      errorText = 'Password must be at least 6 characters');
                  return;
                }

                setS(() => errorText = null);

                try {
                  // Create account via Firebase Auth REST API
                  final url = Uri.parse(
                      'https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$_apiKey');
                  final response = await http.post(url,
                      headers: {'Content-Type': 'application/json'},
                      body: jsonEncode({
                        'email': email,
                        'password': password,
                        'returnSecureToken': true,
                      }));

                  final body = jsonDecode(response.body);

                  if (response.statusCode != 200) {
                    final msg = body['error']['message'] as String? ?? 'Error';
                    setS(() => errorText = _friendlyError(msg));
                    return;
                  }

                  final uid = body['localId'] as String;

                  // Save user info to Firebase Database
                  await FirebaseDatabase.instance.ref('users/$uid').set({
                    'email': email,
                    'name': name,
                    'role': selectedRole,
                  });

                  if (!ctx.mounted || !mounted) return;
                  Navigator.pop(ctx);
                  TopToast.show(context, '$name added as $selectedRole.');
                } catch (e) {
                  setS(() => errorText = 'Failed: $e');
                }
              },
              child:
                  const Text('Create', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  // ── Change password via REST API ─────────────────────────────
  Future<void> _changePassword(String uid, String email) async {
    final passwordCtrl = TextEditingController();
    String? errorText;
    bool obscure = true;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Change Password',
              style:
                  TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Account: $email',
                style:
                    const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            const SizedBox(height: 12),
            TextField(
              controller: passwordCtrl,
              obscureText: obscure,
              decoration:
                  _inputDecoration('New Password', Icons.lock_outline).copyWith(
                suffixIcon: GestureDetector(
                  onTap: () => setS(() => obscure = !obscure),
                  child: Icon(obscure ? Icons.visibility_off : Icons.visibility,
                      size: 18, color: AppColors.textMuted),
                ),
              ),
              autofocus: true,
            ),
            if (errorText != null) ...[
              const SizedBox(height: 8),
              Text(errorText!,
                  style: const TextStyle(fontSize: 12, color: AppColors.error)),
            ],
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel',
                    style: TextStyle(color: AppColors.textMuted))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.greenDark,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              onPressed: () async {
                final password = passwordCtrl.text.trim();
                if (password.length < 6) {
                  setS(() =>
                      errorText = 'Password must be at least 6 characters');
                  return;
                }

                try {
                  // Use Firebase Auth REST API to update password
                  // Note: This updates the CURRENT user's password
                  // For other users, you need Admin SDK (server-side)
                  // Workaround: store a "resetPassword" flag in DB
                  await FirebaseDatabase.instance
                      .ref('users/$uid/passwordReset')
                      .set(password);

                  if (!ctx.mounted || !mounted) return;
                  Navigator.pop(ctx);
                  TopToast.show(
                    context,
                    'Password reset saved. User must re-login to apply.',
                  );
                } catch (e) {
                  setS(() => errorText = 'Failed: $e');
                }
              },
              child: const Text('Save', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  // ── Change role ──────────────────────────────────────────────
  Future<void> _changeRole(String uid, String currentRole) async {
    final userSnap = await FirebaseDatabase.instance.ref('users/$uid').get();
    final userData = userSnap.value is Map
        ? Map<String, dynamic>.from(userSnap.value as Map)
        : <String, dynamic>{};
    final email = (userData['email'] ?? '').toString().toLowerCase();
    final isMainAdminFlag = userData['isMainAdmin'] == true;
    final isMainAdminEmail = email == 'admin@dnsc.edu.ph';

    if (currentRole == 'admin' && (isMainAdminFlag || isMainAdminEmail)) {
      if (!mounted) return;
      TopToast.show(
        context,
        'Main admin role is protected and cannot be changed.',
        isError: true,
      );
      return;
    }

    final newRole = currentRole == 'admin' ? 'faculty' : 'admin';
    await FirebaseDatabase.instance.ref('users/$uid/role').set(newRole);
    if (!mounted) return;
    TopToast.show(context, 'Role changed to $newRole.');
  }

  // ── Delete user ──────────────────────────────────────────────
  Future<void> _deleteUser(String uid, String email) async {
    // Prevent deleting own account
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == currentUid) {
      TopToast.show(context, 'You cannot delete your own account.',
          isError: true);
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Account',
            style:
                TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
        content: Text('Delete account "$email"? This cannot be undone.',
            style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel',
                  style: TextStyle(color: AppColors.textMuted))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // Remove from database (Auth deletion requires Admin SDK)
    await FirebaseDatabase.instance.ref('users/$uid').remove();

    if (!mounted) return;
    TopToast.show(context, '$email removed from system.');
  }

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/login');
  }

  // ── Helpers ──────────────────────────────────────────────────
  InputDecoration _inputDecoration(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
      prefixIcon: Icon(icon, size: 18, color: AppColors.textMuted),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.greenMid.withAlpha(51))),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.greenMid.withAlpha(51))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.greenMid)),
    );
  }

  String _friendlyError(String code) {
    switch (code) {
      case 'EMAIL_EXISTS':
        return 'This email is already registered.';
      case 'INVALID_EMAIL':
        return 'Invalid email address.';
      case 'WEAK_PASSWORD':
        return 'Password is too weak.';
      case 'TOO_MANY_ATTEMPTS_TRY_LATER':
        return 'Too many attempts. Try later.';
      default:
        return code;
    }
  }

  // ── Build ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(children: [
          _buildHeader(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _buildIotInventorySection(),
                const SizedBox(height: 12),
                _buildRateSection(),
                const SizedBox(height: 12),
                _buildUsersSection(),
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
            child: TextField(
              controller: _unassignedIotController,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(fontSize: 14, color: AppColors.textDark),
              decoration: InputDecoration(
                hintText: 'e.g. ESP32-ROOM101-001',
                hintStyle: const TextStyle(color: AppColors.textMuted),
                filled: true,
                fillColor: Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        BorderSide(color: AppColors.greenMid.withAlpha(51))),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        BorderSide(color: AppColors.greenMid.withAlpha(51))),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppColors.greenMid)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 46,
            child: ElevatedButton(
              onPressed: _registeringIot ? null : _registerUnassignedIotDevice,
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.greenDark,
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
      decoration: const BoxDecoration(
        color: AppColors.greenDark,
        borderRadius: BorderRadius.only(
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
                  fontFamily: 'Outfit',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.greenLight.withAlpha(51),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text('Admin',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.greenLight)),
        ),
      ]),
    );
  }

  Widget _buildRateSection() {
    return _section(
      sectionKey: 'rate',
      title: 'Electricity Rate',
      icon: Icons.payments_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Current rate: ₱${_currentRate.toStringAsFixed(2)} / kWh',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _rateController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 14, color: AppColors.textDark),
              decoration: InputDecoration(
                prefixText: '₱ ',
                hintText: '11.5',
                hintStyle: const TextStyle(color: AppColors.textMuted),
                filled: true,
                fillColor: Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        BorderSide(color: AppColors.greenMid.withAlpha(51))),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        BorderSide(color: AppColors.greenMid.withAlpha(51))),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppColors.greenMid)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 46,
            child: ElevatedButton(
              onPressed: _saving ? null : _saveRate,
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.greenDark,
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
      ]),
    );
  }

  Widget _buildUsersSection() {
    return _section(
      sectionKey: 'users',
      title: 'Manage Users',
      icon: Icons.people_outline,
      child: Column(children: [
        // Add user button
        SizedBox(
          width: double.infinity,
          height: 44,
          child: ElevatedButton.icon(
            onPressed: _addUser,
            icon: const Icon(Icons.person_add_outlined,
                size: 18, color: Colors.white),
            label: const Text('Add New Account',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.greenDark,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Users list
        if (_users.isEmpty)
          const Text('No users found.',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted))
        else
          ..._users.map((user) {
            final role = user['role'] as String? ?? 'faculty';
            final email = user['email'] as String? ?? '';
            final name = user['name'] as String? ?? '';
            final uid = user['uid'] as String? ?? '';
            final isCurrentUser = uid == FirebaseAuth.instance.currentUser?.uid;
            final normalizedEmail = email.toLowerCase();
            final isProtectedMainAdmin = role == 'admin' &&
                ((user['isMainAdmin'] == true) ||
                    normalizedEmail == 'admin@dnsc.edu.ph');
            final canChangeRole = !isCurrentUser && !isProtectedMainAdmin;

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.greenMid.withAlpha(26)),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: role == 'admin'
                              ? AppColors.greenDark.withAlpha(20)
                              : AppColors.greenPale,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Text(
                            email.isNotEmpty ? email[0].toUpperCase() : 'U',
                            style: TextStyle(
                                fontFamily: 'Outfit',
                                fontWeight: FontWeight.w700,
                                color: role == 'admin'
                                    ? AppColors.greenDark
                                    : AppColors.greenMid),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(name.isNotEmpty ? name : email,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textDark),
                                overflow: TextOverflow.ellipsis),
                            Text(email,
                                style: const TextStyle(
                                    fontSize: 11, color: AppColors.textMuted),
                                overflow: TextOverflow.ellipsis),
                          ])),
                      // Role badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: role == 'admin'
                              ? AppColors.greenDark.withAlpha(20)
                              : AppColors.greenPale,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(role,
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: role == 'admin'
                                    ? AppColors.greenDark
                                    : AppColors.textMid)),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    // Action buttons
                    Row(children: [
                      // Change role
                      Expanded(
                        child: GestureDetector(
                          onTap: canChangeRole
                              ? () => _changeRole(uid, role)
                              : null,
                          child: Container(
                            height: 32,
                            decoration: BoxDecoration(
                              color: !canChangeRole
                                  ? AppColors.greenPale.withAlpha(100)
                                  : AppColors.greenPale,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Center(
                              child: Text(
                                isProtectedMainAdmin
                                    ? 'Main Admin (Locked)'
                                    : 'Change Role',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: !canChangeRole
                                        ? AppColors.textMuted
                                        : AppColors.greenDark),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Change password
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _changePassword(uid, email),
                          child: Container(
                            height: 32,
                            decoration: BoxDecoration(
                              color: AppColors.greenMid.withAlpha(20),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Center(
                              child: Text('Change Password',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.greenMid)),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Delete
                      if (!isCurrentUser)
                        GestureDetector(
                          onTap: () => _deleteUser(uid, email),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: AppColors.error.withAlpha(20),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.delete_outline,
                                size: 16, color: AppColors.error),
                          ),
                        ),
                    ]),
                  ]),
            );
          }),
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
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.greenDark,
                      ),
                    )
                  : const Icon(Icons.search_outlined, size: 18),
              label: Text(
                _githubChecking ? 'Checking...' : 'Check Latest',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.greenDark,
                side: BorderSide(color: AppColors.greenDark.withAlpha(90)),
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
                  backgroundColor: release.updateAvailable
                      ? AppColors.greenDark
                      : AppColors.greenMid,
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
          color: isOpen
              ? AppColors.greenDark.withAlpha(70)
              : AppColors.greenMid.withAlpha(18),
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
                  color: isOpen
                      ? AppColors.greenDark.withAlpha(20)
                      : AppColors.greenPale,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon,
                    size: 18,
                    color: isOpen ? AppColors.greenDark : AppColors.greenMid),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'Outfit',
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
