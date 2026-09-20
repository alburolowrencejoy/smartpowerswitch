import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import 'package:rxdart/rxdart.dart';
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../firebase_options.dart';
import '../../utils/placeholder_data.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';

/// Oversees institutes and their members.
///
/// - Main admin (`admin`/`main_admin`/`super_admin`): sees every institute,
///   can add/remove admins for any of them, and manages any unassigned
///   account.
/// - Institute admin: sees only their own institute, can add "co-admins"
///   (peers with the same institute_admin role, distinguished by the
///   `coAdmin` flag) and manage their own institute's members, but can't
///   touch the admin the main admin originally assigned, nor see other
///   institutes.
class ManageUsersScreen extends StatefulWidget {
  final String role;
  final String? institute;

  const ManageUsersScreen({super.key, required this.role, this.institute});

  @override
  State<ManageUsersScreen> createState() => _ManageUsersScreenState();
}

class _ManageUsersScreenState extends State<ManageUsersScreen> {
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _institutes = [];
  String? _expandedCode;
  bool _otherAccountsOpen = false;

  bool get _viewerIsInstituteAdmin => widget.role == 'institute_admin';
  String? get _currentUid => FirebaseAuth.instance.currentUser?.uid;

  // ── Institute theming ──────────────────────────────────────────────────
  // Unlike the other "Must" phase screens, role/institute are already
  // passed in via the constructor (see main.dart's '/manage-users' route),
  // so no auth hydration is needed here. This is the viewer's own resolved
  // palette -- green for main_admin/super_admin, forCode(institute) for an
  // institute_admin -- used for all screen-wide chrome. Each institute
  // card's own accent uses a *different*, per-card palette (see
  // _buildInstituteCard's local `cardPalette`), by product-owner request.
  InstitutePalette get _palette =>
      InstituteTheme.resolve(widget.role, widget.institute).palette;

  StreamSubscription? _combinedSub;

  // True until the first combined emission of this screen's 2 Firebase
  // streams (users, buildings) has been received; never reverts to true
  // afterwards, so a transient null on either path can't blank out data
  // already shown this session.
  bool _isLoading = true;

  // Set only if the combined listener fails (or times out) before the
  // first successful load ever completes -- gives the skeleton shimmer a
  // real escape hatch instead of spinning forever.
  String? _errorText;
  Timer? _loadTimeoutTimer;
  bool _postLoadErrorNotified = false;

  bool _isPermissionDenied(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') ||
        text.contains('permission_denied');
  }

  @override
  void initState() {
    super.initState();
    if (_viewerIsInstituteAdmin) _expandedCode = widget.institute;
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

  // ── Listen to the 2 Firebase paths this screen needs (users, buildings)
  // in one combined stream so a transient null on either path can't blank
  // out data already shown this session.
  void _listenAll() {
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted || !_isLoading) return;
      setState(() {
        _isLoading = false;
        _errorText =
            'Taking too long to load users. Check your connection.';
      });
    });

    _combinedSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('users').onValue,
      FirebaseDatabase.instance.ref('buildings').onValue,
    ]).listen((events) {
      if (!mounted) return;
      _loadTimeoutTimer?.cancel();
      setState(() {
        final usersRaw = events[0].snapshot.value as Map<dynamic, dynamic>?;
        if (usersRaw != null) {
          _users = usersRaw.entries.map((e) {
            final val = Map<String, dynamic>.from(e.value as Map);
            val['uid'] = e.key;
            return val;
          }).toList();
        } else if (_isLoading) {
          _users = [];
        }

        final buildingsRaw = events[1].snapshot.value;
        if (buildingsRaw is Map) {
          final data = Map<String, dynamic>.from(buildingsRaw);
          _institutes = data.entries.map((e) {
            final b = e.value is Map
                ? Map<String, dynamic>.from(e.value as Map)
                : <String, dynamic>{};
            return {
              'code': e.key.toString(),
              'name': (b['name'] ?? e.key).toString(),
              'floors': (b['floors'] ?? 1),
            };
          }).toList()
            ..sort((a, b) =>
                (a['code'] as String).compareTo(b['code'] as String));
        } else if (_isLoading) {
          _institutes = [];
        }

        _isLoading = false;
        _errorText = null;
        _postLoadErrorNotified = false;
      });
    }, onError: (Object error) {
      if (!mounted) return;
      debugPrint('[ManageUsers] Combined listen error: $error');
      _loadTimeoutTimer?.cancel();
      if (_isLoading) {
        setState(() {
          _isLoading = false;
          _errorText = _isPermissionDenied(error)
              ? 'You do not have permission to view users.'
              : 'Failed to load users.';
        });
      } else if (!_postLoadErrorNotified) {
        _postLoadErrorNotified = true;
        TopToast.show(
          context,
          'Lost connection to live user data.',
          isError: true,
        );
      }
    });
  }

  // ── Derived groupings ─────────────────────────────────────────
  String _instituteOf(Map<String, dynamic> u) =>
      (u['institute'] as String? ?? '').trim();
  String _roleOf(Map<String, dynamic> u) => (u['role'] as String? ?? 'faculty');
  bool _isCoAdmin(Map<String, dynamic> u) => u['coAdmin'] == true;

  /// All institute_admins for [code], primary admin(s) first.
  List<Map<String, dynamic>> _adminsOf(String code) {
    final admins = _users
        .where(
            (u) => _instituteOf(u) == code && _roleOf(u) == 'institute_admin')
        .toList()
      ..sort((a, b) {
        final aCo = _isCoAdmin(a) ? 1 : 0;
        final bCo = _isCoAdmin(b) ? 1 : 0;
        return aCo.compareTo(bCo);
      });
    return admins;
  }

  List<Map<String, dynamic>> _membersOf(String code) => _users
      .where((u) => _instituteOf(u) == code && _roleOf(u) != 'institute_admin')
      .toList();

  List<Map<String, dynamic>> get _otherAccounts => _users.where((u) {
        final institute = _instituteOf(u);
        final role = _roleOf(u);
        if (role == 'institute_admin' || role == 'faculty') {
          return institute.isEmpty;
        }
        return true; // admin / main_admin / super_admin tiers
      }).toList();

  bool _isProtected(Map<String, dynamic> u) {
    final email = (u['email'] as String? ?? '').toLowerCase();
    return u['isMainAdmin'] == true || email == 'admin@dnsc.edu.ph';
  }

  // ── Firebase Auth REST create (doesn't disturb the current admin session) ─
  String get _apiKey => DefaultFirebaseOptions.currentPlatform.apiKey;

  Future<String?> _createAccount({
    required String email,
    required String password,
    required String name,
    required String role,
    String? institute,
    bool coAdmin = false,
  }) async {
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
      return body['error']['message'] as String? ?? 'Error';
    }

    final uid = body['localId'] as String;
    await FirebaseDatabase.instance.ref('users/$uid').set({
      'email': email,
      'name': name,
      'role': role,
      if (institute != null) 'institute': institute,
      if (role == 'institute_admin') 'coAdmin': coAdmin,
    });
    return null;
  }

  String _friendlyAuthError(String code) {
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

  // ── Actions ────────────────────────────────────────────────────
  Future<void> _addAdmin(String code, String instituteName,
      {required bool asCoAdmin}) async {
    final members = _membersOf(code);
    bool createNew = members.isEmpty;
    final nameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    String? selectedUid = members.isNotEmpty ? members.first['uid'] : null;
    String? errorText;
    bool obscure = true;
    bool submitting = false;
    final actionLabel = asCoAdmin ? 'Co-Admin' : 'Admin';

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Add $actionLabel · $instituteName',
              style: const TextStyle(
                  fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (members.isNotEmpty)
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: _palette.mid.withAlpha(51)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setS(() => createNew = false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: !createNew
                                ? _palette.dark
                                : Colors.transparent,
                            borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(11),
                                bottomLeft: Radius.circular(11)),
                          ),
                          child: Center(
                              child: Text('Promote Member',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: !createNew
                                          ? Colors.white
                                          : AppColors.textMuted))),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setS(() => createNew = true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: createNew
                                ? _palette.dark
                                : Colors.transparent,
                            borderRadius: const BorderRadius.only(
                                topRight: Radius.circular(11),
                                bottomRight: Radius.circular(11)),
                          ),
                          child: Center(
                              child: Text('New Account',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: createNew
                                          ? Colors.white
                                          : AppColors.textMuted))),
                        ),
                      ),
                    ),
                  ]),
                ),
              const SizedBox(height: 12),
              if (!createNew) ...[
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: _palette.mid.withAlpha(51)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: DropdownButton<String>(
                        value: selectedUid,
                        isExpanded: true,
                        items: members
                            .map((m) => DropdownMenuItem(
                                  value: m['uid'] as String,
                                  child: Text(
                                      (m['name'] as String? ?? '').isNotEmpty
                                          ? m['name']
                                          : m['email'] ?? '',
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: AppColors.textDark)),
                                ))
                            .toList(),
                        onChanged: (v) => setS(() => selectedUid = v),
                      ),
                    ),
                  ),
                ),
              ] else ...[
                TextField(
                  controller: nameCtrl,
                  decoration:
                      _inputDecoration('Full Name', Icons.person_outline),
                  autofocus: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: _inputDecoration(
                      'Email (e.g. juan@dnsc.edu.ph)', Icons.email_outlined),
                ),
                const SizedBox(height: 12),
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
              ],
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
                onPressed: submitting ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel',
                    style: TextStyle(color: AppColors.textMuted))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: _palette.dark,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              onPressed: submitting
                  ? null
                  : () async {
                      if (!createNew) {
                        if (selectedUid == null) {
                          setS(() => errorText = 'Select a member to promote');
                          return;
                        }
                        setS(() => submitting = true);
                        await FirebaseDatabase.instance
                            .ref('users/$selectedUid')
                            .update({
                          'role': 'institute_admin',
                          'coAdmin': asCoAdmin
                        });
                        if (!ctx.mounted || !mounted) return;
                        Navigator.pop(ctx);
                        TopToast.show(context, '$actionLabel assigned.');
                        return;
                      }

                      final name = nameCtrl.text.trim();
                      final email = emailCtrl.text.trim();
                      final password = passwordCtrl.text.trim();
                      if (name.isEmpty || email.isEmpty || password.isEmpty) {
                        setS(() => errorText = 'All fields are required');
                        return;
                      }
                      if (!email.endsWith('@dnsc.edu.ph')) {
                        setS(() =>
                            errorText = 'Email must be a @dnsc.edu.ph address');
                        return;
                      }
                      if (password.length < 6) {
                        setS(() => errorText =
                            'Password must be at least 6 characters');
                        return;
                      }
                      setS(() {
                        errorText = null;
                        submitting = true;
                      });
                      try {
                        final err = await _createAccount(
                          email: email,
                          password: password,
                          name: name,
                          role: 'institute_admin',
                          institute: code,
                          coAdmin: asCoAdmin,
                        );
                        if (err != null) {
                          setS(() {
                            submitting = false;
                            errorText = _friendlyAuthError(err);
                          });
                          return;
                        }
                        if (!ctx.mounted || !mounted) return;
                        Navigator.pop(ctx);
                        TopToast.show(context, '$name added as $actionLabel.');
                      } catch (e) {
                        setS(() {
                          submitting = false;
                          errorText = 'Failed: $e';
                        });
                      }
                    },
              child: submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Text('Add', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addMember(String code, String instituteName) async {
    final nameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    String? errorText;
    bool obscure = true;
    bool submitting = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Add Member · $instituteName',
              style: const TextStyle(
                  fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: nameCtrl,
                decoration: _inputDecoration('Full Name', Icons.person_outline),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: _inputDecoration(
                    'Email (e.g. juan@dnsc.edu.ph)', Icons.email_outlined),
              ),
              const SizedBox(height: 12),
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
                onPressed: submitting ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel',
                    style: TextStyle(color: AppColors.textMuted))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: _palette.dark,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              onPressed: submitting
                  ? null
                  : () async {
                      final name = nameCtrl.text.trim();
                      final email = emailCtrl.text.trim();
                      final password = passwordCtrl.text.trim();
                      if (name.isEmpty || email.isEmpty || password.isEmpty) {
                        setS(() => errorText = 'All fields are required');
                        return;
                      }
                      if (!email.endsWith('@dnsc.edu.ph')) {
                        setS(() =>
                            errorText = 'Email must be a @dnsc.edu.ph address');
                        return;
                      }
                      if (password.length < 6) {
                        setS(() => errorText =
                            'Password must be at least 6 characters');
                        return;
                      }
                      setS(() {
                        errorText = null;
                        submitting = true;
                      });
                      try {
                        final err = await _createAccount(
                          email: email,
                          password: password,
                          name: name,
                          role: 'faculty',
                          institute: code,
                        );
                        if (err != null) {
                          setS(() {
                            submitting = false;
                            errorText = _friendlyAuthError(err);
                          });
                          return;
                        }
                        if (!ctx.mounted || !mounted) return;
                        Navigator.pop(ctx);
                        TopToast.show(
                            context, '$name added to $instituteName.');
                      } catch (e) {
                        setS(() {
                          submitting = false;
                          errorText = 'Failed: $e';
                        });
                      }
                    },
              child: submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Text('Add', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _removeAdmin(Map<String, dynamic> admin) async {
    await FirebaseDatabase.instance
        .ref('users/${admin['uid']}')
        .update({'role': 'faculty', 'coAdmin': false});
    if (!mounted) return;
    TopToast.show(
        context, '${admin['name'] ?? admin['email']} demoted to member.');
  }

  Future<void> _assignToInstitute(Map<String, dynamic> user) async {
    String? selectedCode =
        _institutes.isNotEmpty ? _institutes.first['code'] as String : null;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Assign to Institute',
              style:
                  TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
          content: _institutes.isEmpty
              ? const Text('No institutes exist yet.',
                  style: TextStyle(fontSize: 13, color: AppColors.textMuted))
              : Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: _palette.mid.withAlpha(51)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: DropdownButton<String>(
                        value: selectedCode,
                        isExpanded: true,
                        items: _institutes
                            .map((i) => DropdownMenuItem(
                                  value: i['code'] as String,
                                  child: Text('${i['code']} · ${i['name']}',
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: AppColors.textDark)),
                                ))
                            .toList(),
                        onChanged: (v) => setS(() => selectedCode = v),
                      ),
                    ),
                  ),
                ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel',
                    style: TextStyle(color: AppColors.textMuted))),
            if (_institutes.isNotEmpty)
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                    backgroundColor: _palette.dark,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
                child:
                    const Text('Assign', style: TextStyle(color: Colors.white)),
              ),
          ],
        ),
      ),
    );

    if (confirmed != true || selectedCode == null) return;
    await FirebaseDatabase.instance
        .ref('users/${user['uid']}/institute')
        .set(selectedCode);
    if (!mounted) return;
    TopToast.show(context, 'Assigned to $selectedCode.');
  }

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
                  backgroundColor: _palette.dark,
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
                  await FirebaseFunctions.instance
                      .httpsCallable('changeUserPassword')
                      .call({'uid': uid, 'newPassword': password});
                  if (!ctx.mounted || !mounted) return;
                  Navigator.pop(ctx);
                  TopToast.show(context, 'Password updated.');
                } on FirebaseFunctionsException catch (e) {
                  setS(() => errorText = _friendlyFunctionsError(e));
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

  Future<void> _deleteUser(String uid, String email) async {
    if (uid == _currentUid) {
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
    try {
      await FirebaseFunctions.instance
          .httpsCallable('deleteUser')
          .call({'uid': uid});
      if (!mounted) return;
      TopToast.show(context, '$email removed from system.');
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      TopToast.show(context, _friendlyFunctionsError(e), isError: true);
    }
  }

  String _friendlyFunctionsError(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'permission-denied':
        return 'You do not have permission to do this.';
      case 'unauthenticated':
        return 'Your session expired. Please sign in again.';
      case 'invalid-argument':
        return e.message ?? 'Invalid request.';
      default:
        return e.message ?? 'Something went wrong. Please try again.';
    }
  }

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
          borderSide: BorderSide(color: _palette.mid.withAlpha(51))),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _palette.mid.withAlpha(51))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _palette.mid)),
    );
  }

  // ── Build ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(widget.role, widget.institute)],
      ),
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_errorText != null) {
      return _buildError();
    }

    if (_viewerIsInstituteAdmin) {
      final code = widget.institute;
      // While still loading, show a skeleton card for this admin's own
      // institute (matched by code) instead of the real -- currently
      // empty -- `_institutes` list.
      final institutesSource = _institutes.isEmpty && _isLoading
          ? [placeholderBuilding(code: code ?? 'B1')]
          : _institutes;
      final match = institutesSource.firstWhere(
        (i) => i['code'] == code,
        orElse: () => <String, dynamic>{},
      );
      return ScreenSkeleton(
        isLoading: _isLoading,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 16),
            if (code == null || code.isEmpty || match.isEmpty)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _palette.mid.withAlpha(26)),
                ),
                child: const Center(
                  child: Text(
                      'No institute assigned to your account yet. Ask your main admin to assign one.',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 13, color: AppColors.textMuted)),
                ),
              )
            else
              _buildInstituteCard(match),
          ],
        ),
      );
    }

    final institutesSource = _institutes.isEmpty && _isLoading
        ? placeholderBuildingList()
        : _institutes;

    return ScreenSkeleton(
      isLoading: _isLoading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 16),
          ...institutesSource.map(_buildInstituteCard),
          if (institutesSource.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _palette.mid.withAlpha(26)),
              ),
              child: const Center(
                child: Text('No institutes (buildings) yet.',
                    style: TextStyle(fontSize: 13, color: AppColors.textMuted)),
              ),
            ),
          const SizedBox(height: 16),
          _buildOtherAccountsSection(),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(),
        const SizedBox(height: 40),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                      color: _palette.pale,
                      borderRadius: BorderRadius.circular(20)),
                  child: Icon(Icons.lock_outline, size: 34, color: _palette.mid)),
              const SizedBox(height: 16),
              const Text('Cannot load users',
                  style: TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textDark)),
              const SizedBox(height: 8),
              Text(_errorText ?? 'Something went wrong.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textMuted)),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _retryLoad,
                icon:
                    const Icon(Icons.refresh, size: 16, color: Colors.white),
                label:
                    const Text('Retry', style: TextStyle(color: Colors.white)),
                style: ElevatedButton.styleFrom(
                    backgroundColor: _palette.dark,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Row(children: [
      Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: _palette.dark.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.admin_panel_settings_outlined,
            color: _palette.dark, size: 22),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Manage Users',
                style: TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textDark)),
            const SizedBox(height: 2),
            Text(
              _viewerIsInstituteAdmin
                  ? 'Manage your own institute\'s members and co-admins.'
                  : 'Institute admins oversee their own institute only.',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: _palette.pale,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(_viewerIsInstituteAdmin ? 'Institute Admin' : 'Main Admin',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: _palette.dark)),
      ),
    ]);
  }

  Widget _buildInstituteCard(Map<String, dynamic> institute) {
    final code = institute['code'] as String;
    final name = institute['name'] as String;
    final floors = institute['floors'];
    final admins = _adminsOf(code);
    final members = _membersOf(code);
    final isOpen = _expandedCode == code;
    final actionLabel = _viewerIsInstituteAdmin ? 'Co-Admin' : 'Admin';

    // Per-card theming (product-owner requested, distinct from every other
    // screen's flat single-`_palette` pattern): this card's own accent
    // (badge, border, icon tint below) always reflects *this institute's*
    // own color ramp via InstituteColors.forCode(code), independent of the
    // viewer's role. For a main_admin/super_admin viewer (whose `_palette`
    // always resolves to green), this makes each card in the list show its
    // own institute's color. For an institute_admin viewer, `_palette`
    // already equals `InstituteColors.forCode(widget.institute)` and they
    // only ever see their own institute's card here, so `cardPalette` and
    // `_palette` are the same value in that case -- no special-casing by
    // role is needed.
    final cardPalette = InstituteColors.forCode(code);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isOpen
              ? cardPalette.dark.withAlpha(70)
              : cardPalette.mid.withAlpha(26),
        ),
      ),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() => _expandedCode = isOpen ? null : code),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: cardPalette.pale,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(code,
                          maxLines: 1,
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: cardPalette.dark,
                              fontSize: 13)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppColors.textDark,
                            fontSize: 14)),
                    const SizedBox(height: 3),
                    Text(
                        '$floors ${floors == 1 ? 'floor' : 'floors'} · ${members.length} member${members.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textMuted)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Semantic: admins.isNotEmpty coverage badge, paired against
              // AppColors.warning for the "no admin" state -- data-coverage
              // status, not brand chrome, so deliberately NOT retheme'd even
              // though the rest of this card picks up cardPalette above
              // (per requirements review).
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: admins.isNotEmpty
                      ? AppColors.greenPale
                      : AppColors.warning.withAlpha(20),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                      admins.isNotEmpty
                          ? Icons.verified_user_outlined
                          : Icons.warning_amber_outlined,
                      size: 13,
                      color: admins.isNotEmpty
                          ? AppColors.greenDark
                          : AppColors.warning),
                  const SizedBox(width: 5),
                  Text(
                    admins.isEmpty
                        ? 'No admin'
                        : '${admins.length} admin${admins.length == 1 ? '' : 's'}',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: admins.isNotEmpty
                            ? AppColors.greenDark
                            : AppColors.warning),
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              Icon(isOpen ? Icons.expand_less : Icons.expand_more,
                  color: AppColors.textMuted),
            ]),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(height: 1),
                const SizedBox(height: 12),
                Row(children: [
                  const Text('Institute Admins',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textDark)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _addAdmin(code, name,
                        asCoAdmin: _viewerIsInstituteAdmin),
                    icon: const Icon(Icons.person_add_alt_1_outlined, size: 15),
                    label: Text('Add $actionLabel',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    // Icon tint picks up this card's own institute color
                    // (see cardPalette above), not the viewer's `_palette`.
                    style: TextButton.styleFrom(
                        foregroundColor: cardPalette.dark,
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  ),
                ]),
                const SizedBox(height: 8),
                if (admins.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withAlpha(15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'No admin assigned. Members can still be added, but nobody can manage this institute\'s devices yet.',
                      style: TextStyle(fontSize: 11, color: AppColors.warning),
                    ),
                  )
                else
                  ...admins.map((a) {
                    final isCo = _isCoAdmin(a);
                    // An institute admin may only remove their co-admin
                    // peers — never the admin the main admin assigned, and
                    // never themselves.
                    final canRemove = a['uid'] != _currentUid &&
                        (!_viewerIsInstituteAdmin || isCo);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _buildUserRow(
                        a,
                        badgeOverride: isCo ? 'CO-ADMIN' : 'ADMIN',
                        paletteOverride: cardPalette,
                        trailing: [
                          _rowActionButton(
                              'Change Password',
                              () => _changePassword(
                                  a['uid'], a['email'] ?? ''),
                              palette: cardPalette),
                          if (canRemove) ...[
                            const SizedBox(width: 8),
                            _rowActionButton('Remove', () => _removeAdmin(a),
                                isDanger: true, palette: cardPalette),
                          ],
                        ],
                      ),
                    );
                  }),
                const SizedBox(height: 14),
                Row(children: [
                  const Text('Members',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textDark)),
                  const SizedBox(width: 6),
                  Text('${members.length}',
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textMuted)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _addMember(code, name),
                    icon: const Icon(Icons.person_add_outlined, size: 15),
                    label: const Text('Add Member',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    // Icon tint picks up this card's own institute color
                    // (see cardPalette above), not the viewer's `_palette`.
                    style: TextButton.styleFrom(
                        foregroundColor: cardPalette.dark,
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  ),
                ]),
                const SizedBox(height: 8),
                if (members.isEmpty)
                  const Text('No members yet.',
                      style:
                          TextStyle(fontSize: 12, color: AppColors.textMuted))
                else
                  ...members.map((m) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _buildUserRow(
                          m,
                          paletteOverride: cardPalette,
                          trailing: [
                            _rowActionButton(
                                'Change Password',
                                () => _changePassword(
                                    m['uid'], m['email'] ?? ''),
                                palette: cardPalette),
                            const SizedBox(width: 8),
                            _rowIconButton(Icons.delete_outline,
                                () => _deleteUser(m['uid'], m['email'] ?? ''),
                                isDanger: true, palette: cardPalette),
                          ],
                        ),
                      )),
              ],
            ),
          ),
          crossFadeState:
              isOpen ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 180),
          sizeCurve: Curves.easeOut,
        ),
      ]),
    );
  }

  Widget _buildOtherAccountsSection() {
    final others = _otherAccounts;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _otherAccountsOpen
              ? _palette.dark.withAlpha(70)
              : _palette.mid.withAlpha(26),
        ),
      ),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() => _otherAccountsOpen = !_otherAccountsOpen),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: _palette.pale,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.groups_outlined, size: 18, color: _palette.dark),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Other Accounts (${others.length})',
                    style: const TextStyle(
                        fontFamily: 'Outfit',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark)),
              ),
              Icon(_otherAccountsOpen ? Icons.expand_less : Icons.expand_more,
                  color: AppColors.textMuted),
            ]),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: others.isEmpty
                ? const Text('No unassigned accounts.',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted))
                : Column(
                    children: others
                        .map((u) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _buildUserRow(
                                u,
                                trailing: [
                                  if (_roleOf(u) == 'faculty')
                                    _rowActionButton('Assign to Institute',
                                        () => _assignToInstitute(u)),
                                  if (_roleOf(u) == 'faculty')
                                    const SizedBox(width: 8),
                                  _rowActionButton(
                                      'Change Password',
                                      () => _changePassword(
                                          u['uid'], u['email'] ?? '')),
                                  if (!_isProtected(u) &&
                                      u['uid'] != _currentUid) ...[
                                    const SizedBox(width: 8),
                                    _rowIconButton(
                                        Icons.delete_outline,
                                        () => _deleteUser(
                                            u['uid'], u['email'] ?? ''),
                                        isDanger: true),
                                  ],
                                ],
                              ),
                            ))
                        .toList(),
                  ),
          ),
          crossFadeState: _otherAccountsOpen
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 180),
          sizeCurve: Curves.easeOut,
        ),
      ]),
    );
  }

  Widget _buildUserRow(Map<String, dynamic> user,
      {required List<Widget> trailing,
      String? badgeOverride,
      InstitutePalette? paletteOverride}) {
    final role = _roleOf(user);
    final email = (user['email'] as String? ?? '');
    final name = (user['name'] as String? ?? '');
    final isHighTier = role != 'faculty';
    final palette = paletteOverride ?? _palette;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.mid.withAlpha(18)),
      ),
      child: Row(children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: isHighTier
                ? palette.dark.withAlpha(20)
                : palette.pale,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Center(
            child: Text(email.isNotEmpty ? email[0].toUpperCase() : 'U',
                style: TextStyle(
                    fontFamily: 'Outfit',
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color:
                        isHighTier ? palette.dark : palette.mid)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name.isNotEmpty ? name : email,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textDark)),
              Text(email,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 10, color: AppColors.textMuted)),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: isHighTier
                ? palette.dark.withAlpha(20)
                : palette.pale,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(badgeOverride ?? _roleLabel(role),
              style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: isHighTier ? palette.dark : AppColors.textMid)),
        ),
        const SizedBox(width: 8),
        ...trailing,
      ]),
    );
  }

  String _roleLabel(String role) {
    switch (role) {
      case 'main_admin':
        return 'MAIN ADMIN';
      case 'super_admin':
        return 'SUPER ADMIN';
      case 'admin':
        return 'ADMIN';
      case 'institute_admin':
        return 'INST. ADMIN';
      default:
        return 'MEMBER';
    }
  }

  // Semantic: only the isDanger (Remove/Delete) branch is a genuine
  // live-state signal, paired against AppColors.error -- that side stays
  // fixed. The non-danger branch is just this button's default/chrome
  // style (a "primary vs destructive" variant, not a status pairing), so
  // it follows the resolved institute palette like the rest of the row.
  Widget _rowActionButton(String label, VoidCallback onTap,
      {bool isDanger = false, InstitutePalette? palette}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isDanger
              ? AppColors.error.withAlpha(18)
              : (palette ?? _palette).pale,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(label,
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: isDanger
                      ? AppColors.error
                      : (palette ?? _palette).dark)),
        ),
      ),
    );
  }

  Widget _rowIconButton(IconData icon, VoidCallback onTap,
      {bool isDanger = false, InstitutePalette? palette}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: isDanger
              ? AppColors.error.withAlpha(18)
              : (palette ?? _palette).pale,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon,
            size: 14,
            color: isDanger ? AppColors.error : (palette ?? _palette).dark),
      ),
    );
  }
}
