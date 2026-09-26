import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import 'package:rxdart/rxdart.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../theme/institute_colors.dart';
import '../../firebase_options.dart';
import '../../utils/placeholder_data.dart';
import '../../widgets/app_bottom_sheet.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_segmented_control.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/app_top_bar.dart';
import '../../widgets/delete_flow.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import '../../theme/app_fonts.dart';

/// Users / "Manage users" (handoff §4.12, institute-admin "Members" variant
/// §5).
///
/// Despite its `screens/shared/` folder location, this file is used
/// **mobile-only in practice**: it's pushed only from
/// `dashboard_screen.dart`'s (mobile) burger menu via the `/manage-users`
/// named route in `main.dart`, which renders it directly (no width-based
/// `LayoutBuilder`/`DashboardPage.desktopBreakpoint` branch the way
/// `/building` and `/device` have). The desktop side has its own,
/// completely separate implementation --
/// `lib/screens/web/manage_users_screen_web.dart`'s `ManageUsersScreenWeb`,
/// embedded directly in `dashboard_web.dart` -- which is untouched here.
/// Confirmed by searching the whole `lib/` tree: nothing outside
/// `main.dart` and this file's own class declaration references
/// `ManageUsersScreen` (the web screen is a distinct class,
/// `ManageUsersScreenWeb`). So the full restyle below is safe: there is no
/// web caller that could regress from it.
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
  String _searchQuery = '';
  int _segment = 0; // 0 = Members, 1 = Others (campus/main admin view only).
  final _searchCtrl = TextEditingController();

  bool get _viewerIsInstituteAdmin => widget.role == 'institute_admin';
  String? get _currentUid => FirebaseAuth.instance.currentUser?.uid;

  // ── Institute theming ──────────────────────────────────────────────────
  // Role/institute are passed in via the constructor (see main.dart's
  // '/manage-users' route), so no auth hydration is needed here. This is
  // the viewer's own resolved palette -- green for main_admin/super_admin,
  // forCode(institute) for an institute_admin -- used for screen-wide
  // chrome. Each row's own avatar/pill accent uses a *different*, per-user
  // palette (that user's own institute), same product-owner request as
  // before this redesign.
  InstitutePalette get _palette =>
      InstituteTheme.resolve(widget.role, widget.institute).palette;

  StreamSubscription? _combinedSub;

  bool _isLoading = true;
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
    _listenAll();
  }

  @override
  void dispose() {
    _combinedSub?.cancel();
    _loadTimeoutTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

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

  void _listenAll() {
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted || !_isLoading) return;
      setState(() {
        _isLoading = false;
        _errorText = 'Taking too long to load users. Check your connection.';
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
            };
          }).toList()
            ..sort(
                (a, b) => (a['code'] as String).compareTo(b['code'] as String));
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

  bool _isProtected(Map<String, dynamic> u) {
    final email = (u['email'] as String? ?? '').toLowerCase();
    return u['isMainAdmin'] == true || email == 'admin@dnsc.edu.ph';
  }

  bool _matchesSearch(Map<String, dynamic> u) {
    if (_searchQuery.trim().isEmpty) return true;
    final q = _searchQuery.trim().toLowerCase();
    final name = (u['name'] as String? ?? '').toLowerCase();
    final email = (u['email'] as String? ?? '').toLowerCase();
    return name.contains(q) || email.contains(q);
  }

  /// Institute-admin viewer: every account in their own institute (admins
  /// and members together), self first.
  List<Map<String, dynamic>> get _instituteAccounts {
    final code = (widget.institute ?? '').trim();
    final list = _users
        .where((u) => _instituteOf(u) == code)
        .where(_matchesSearch)
        .toList()
      ..sort((a, b) {
        final aSelf = a['uid'] == _currentUid ? 0 : 1;
        final bSelf = b['uid'] == _currentUid ? 0 : 1;
        return aSelf.compareTo(bSelf);
      });
    return list;
  }

  /// Campus/main-admin viewer: "Members" = every account assigned to an
  /// institute (any role); "Others" = unassigned accounts (no institute --
  /// e.g. a newly created faculty account, or an admin-tier account with no
  /// institute of its own).
  List<Map<String, dynamic>> get _members =>
      _users.where((u) => _instituteOf(u).isNotEmpty).where(_matchesSearch).toList();

  List<Map<String, dynamic>> get _others =>
      _users.where((u) => _instituteOf(u).isEmpty).where(_matchesSearch).toList();

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

  // ── Actions ────────────────────────────────────────────────────

  Future<void> _makeAdmin(Map<String, dynamic> user) async {
    final institute = _instituteOf(user);
    if (institute.isEmpty) {
      TopToast.show(context, 'Assign an institute to this account first.',
          isError: true);
      return;
    }
    final label = (user['name'] as String?)?.isNotEmpty == true
        ? user['name']
        : user['email'];
    try {
      await FirebaseDatabase.instance.ref('users/${user['uid']}').update({
        'role': 'institute_admin',
        'coAdmin': _viewerIsInstituteAdmin,
      });
      if (!mounted) return;
      TopToast.show(context, '$label is now an admin.');
    } catch (e) {
      if (!mounted) return;
      TopToast.show(context, 'Failed to update role: $e', isError: true);
    }
  }

  Future<void> _showChangeInstituteSheet(Map<String, dynamic> user) async {
    if (_institutes.isEmpty) {
      TopToast.show(context, 'No institutes exist yet.', isError: true);
      return;
    }
    final current = _instituteOf(user);
    await showAppBottomSheet(
      context,
      builder: (ctx) => BottomSheetScaffold(
        title: 'Change institute',
        palette: _palette,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: _institutes.map((i) {
            final code = i['code'] as String;
            final selected = code == current;
            return InkWell(
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  await FirebaseDatabase.instance
                      .ref('users/${user['uid']}/institute')
                      .set(code);
                  if (!mounted) return;
                  TopToast.show(context, 'Moved to $code.');
                } catch (e) {
                  if (!mounted) return;
                  TopToast.show(context, 'Failed to move account: $e',
                      isError: true);
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: _palette.line)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('$code · ${i['name']}',
                          style: AppTextStyles.subtitle
                              .copyWith(color: AppColors.ink)),
                    ),
                    if (selected)
                      Icon(Icons.check, color: _palette.dark, size: 20),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Future<void> _changePassword(String uid, String email) async {
    final passwordCtrl = TextEditingController();
    String? passwordError;
    int shake = 0;
    bool obscure = true;
    bool submitting = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Reset password',
              style: AppTextStyles.title.copyWith(color: AppColors.ink)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Account: $email',
                style:
                    AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
            const SizedBox(height: 12),
            AppTextField(
              shakeTrigger: shake,
              controller: passwordCtrl,
              obscureText: obscure,
              decoration: InputDecoration(
                hintText: 'New password',
                errorText: passwordError,
                prefixIcon: const Icon(Icons.lock_outline, size: 18),
                suffixIcon: GestureDetector(
                  onTap: () => setS(() => obscure = !obscure),
                  child: Icon(obscure ? Icons.visibility_off : Icons.visibility,
                      size: 18, color: AppColors.inkMuted),
                ),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              autofocus: true,
            ),
          ]),
          actions: [
            TextButton(
                onPressed: submitting ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel',
                    style: TextStyle(color: AppColors.inkMuted))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: _palette.dark,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              onPressed: submitting
                  ? null
                  : () async {
                      final password = passwordCtrl.text.trim();
                      if (password.length < 6) {
                        setS(() {
                          passwordError =
                              'Password must be at least 6 characters';
                          shake++;
                        });
                        return;
                      }
                      setS(() {
                        passwordError = null;
                        submitting = true;
                      });
                      try {
                        await FirebaseFunctions.instance
                            .httpsCallable('changeUserPassword')
                            .call({'uid': uid, 'newPassword': password});
                        if (!ctx.mounted || !mounted) return;
                        Navigator.pop(ctx);
                        TopToast.show(context, 'Password updated.');
                      } on FirebaseFunctionsException catch (e) {
                        setS(() {
                          submitting = false;
                          passwordError = _friendlyFunctionsError(e);
                        });
                      } catch (e) {
                        setS(() {
                          submitting = false;
                          passwordError = 'Failed: $e';
                        });
                      }
                    },
              child: submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Text('Save', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  /// Delete account (handoff §4.12/§7): two-step confirm+reason dialog, 5s
  /// floating Undo, and only once that window elapses does this actually
  /// call the `deleteUser` Cloud Function (which removes the Firebase Auth
  /// account *and* the `users/{uid}` record server-side -- see
  /// `functions/index.js`) and write the `deletion_log` entry. Unlike a
  /// plain-data delete, the removal itself can't be folded into the same
  /// atomic RTDB `update()` as the log write (it requires the Admin SDK),
  /// so this does the Cloud Function call first, then the log write.
  Future<void> _deleteAccount(Map<String, dynamic> user) async {
    final uid = user['uid'] as String;
    final email = (user['email'] as String? ?? '').trim();
    final name = (user['name'] as String? ?? '').trim();
    if (uid == _currentUid) {
      TopToast.show(context, 'You cannot delete your own account.',
          isError: true);
      return;
    }

    await showDeleteFlow(
      context,
      type: DeleteType.account,
      itemName: name.isNotEmpty ? name : email,
      onCommit: (reason, otherText) async {
        try {
          await FirebaseFunctions.instance
              .httpsCallable('deleteUser')
              .call({'uid': uid});
          final db = FirebaseDatabase.instance.ref();
          await db.child('deletion_log').push().set({
            'type': 'account',
            'itemName': email.isNotEmpty ? email : uid,
            'reason': reason,
            if (otherText != null && otherText.trim().isNotEmpty)
              'otherText': otherText.trim(),
            'deletedBy': _currentUid ?? 'unknown',
            'deletedByEmail': FirebaseAuth.instance.currentUser?.email ?? '',
            'timestamp': ServerValue.timestamp,
          });
          if (!mounted) return;
          TopToast.show(context, '$email removed from system.');
        } on FirebaseFunctionsException catch (e) {
          if (!mounted) return;
          TopToast.show(context, _friendlyFunctionsError(e), isError: true);
        }
      },
    );
  }

  void _openUserActions(Map<String, dynamic> user) {
    final isSelf = user['uid'] == _currentUid;
    final role = _roleOf(user);
    final canMakeAdmin = role != 'institute_admin' && _instituteOf(user).isNotEmpty;
    final canDelete = !isSelf && !_isProtected(user);

    showAppBottomSheet(
      context,
      builder: (ctx) => BottomSheetScaffold(
        title: (user['name'] as String?)?.isNotEmpty == true
            ? user['name'] as String
            : (user['email'] as String? ?? 'Account'),
        palette: _palette,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canMakeAdmin)
              _actionRow(
                icon: Icons.upgrade,
                label: 'Make admin',
                color: _palette.dark,
                onTap: () {
                  Navigator.pop(ctx);
                  _makeAdmin(user);
                },
              ),
            if (!_viewerIsInstituteAdmin)
              _actionRow(
                icon: Icons.swap_horiz,
                label: 'Change institute',
                color: _palette.dark,
                onTap: () {
                  Navigator.pop(ctx);
                  _showChangeInstituteSheet(user);
                },
              ),
            _actionRow(
              icon: Icons.key_outlined,
              label: 'Reset password',
              color: _palette.dark,
              onTap: () {
                Navigator.pop(ctx);
                _changePassword(user['uid'] as String, user['email'] as String? ?? '');
              },
            ),
            if (canDelete)
              _actionRow(
                icon: Icons.person_remove_outlined,
                label: 'Delete account',
                // Neutral grey, not red -- handoff §4.12/§3.7 ("Delete =
                // icon only, grey ... not red"). Red only appears inside
                // the delete dialog itself.
                color: AppColors.inkMid,
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteAccount(user);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _actionRow({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 14),
            Text(label, style: AppTextStyles.subtitle.copyWith(color: color)),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddAccountSheet() async {
    if (!_viewerIsInstituteAdmin && _institutes.isEmpty) {
      TopToast.show(context, 'Add an institute (building) first.',
          isError: true);
      return;
    }

    String? selectedInstitute = _viewerIsInstituteAdmin
        ? widget.institute
        : (_institutes.first['code'] as String);
    var asAdmin = false;
    final nameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    String? nameError, emailError, passwordError, formError;
    var shake = 0;
    var obscure = true;
    var submitting = false;
    final adminLabel = _viewerIsInstituteAdmin ? 'Co-admin' : 'Admin';

    await showAppBottomSheet(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => BottomSheetScaffold(
          title: 'Add account',
          palette: _palette,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_viewerIsInstituteAdmin) ...[
                Text('Institute',
                    style: AppTextStyles.label.copyWith(color: AppColors.ink)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _institutes.map((i) {
                    final code = i['code'] as String;
                    return AppFilterChip(
                      label: code,
                      selected: selectedInstitute == code,
                      onTap: () => setS(() => selectedInstitute = code),
                      palette: InstituteColors.forCode(code),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
              ],
              Text('Role',
                  style: AppTextStyles.label.copyWith(color: AppColors.ink)),
              const SizedBox(height: 8),
              AppSegmentedControl(
                segments: [
                  const AppSegment(label: 'Member'),
                  AppSegment(label: adminLabel),
                ],
                selectedIndex: asAdmin ? 1 : 0,
                onChanged: (i) => setS(() => asAdmin = i == 1),
                palette: _palette,
              ),
              const SizedBox(height: 16),
              AppTextField(
                shakeTrigger: shake,
                controller: nameCtrl,
                decoration: InputDecoration(
                  hintText: 'Full name',
                  errorText: nameError,
                  prefixIcon: const Icon(Icons.person_outline, size: 18),
                  border:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              AppTextField(
                shakeTrigger: shake,
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: 'Email (e.g. juan@dnsc.edu.ph)',
                  errorText: emailError,
                  prefixIcon: const Icon(Icons.email_outlined, size: 18),
                  border:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              AppTextField(
                shakeTrigger: shake,
                controller: passwordCtrl,
                obscureText: obscure,
                decoration: InputDecoration(
                  hintText: 'Password',
                  errorText: passwordError,
                  prefixIcon: const Icon(Icons.lock_outline, size: 18),
                  suffixIcon: GestureDetector(
                    onTap: () => setS(() => obscure = !obscure),
                    child: Icon(
                        obscure ? Icons.visibility_off : Icons.visibility,
                        size: 18,
                        color: AppColors.inkMuted),
                  ),
                  border:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              if (formError != null) ...[
                const SizedBox(height: 10),
                Text(formError!,
                    style: AppTextStyles.bodySm
                        .copyWith(color: AppColors.errorText)),
              ],
            ],
          ),
          footer: BottomSheetFooter(
            palette: _palette,
            applyLabel: submitting ? 'Adding...' : 'Add',
            onCancel: () => Navigator.pop(ctx),
            onApply: submitting
                ? null
                : () async {
                    final name = nameCtrl.text.trim();
                    final email = emailCtrl.text.trim();
                    final password = passwordCtrl.text.trim();
                    final nameErr = name.isEmpty ? 'Name is required' : null;
                    final emailErr = email.isEmpty
                        ? 'Email is required'
                        : !email.endsWith('@dnsc.edu.ph')
                            ? 'Email must be a @dnsc.edu.ph address'
                            : null;
                    final passErr = password.isEmpty
                        ? 'Password is required'
                        : password.length < 6
                            ? 'Password must be at least 6 characters'
                            : null;
                    if (nameErr != null || emailErr != null || passErr != null) {
                      setS(() {
                        nameError = nameErr;
                        emailError = emailErr;
                        passwordError = passErr;
                        formError = null;
                        shake++;
                      });
                      return;
                    }
                    if (selectedInstitute == null || selectedInstitute!.isEmpty) {
                      setS(() => formError = 'Choose an institute.');
                      return;
                    }
                    setS(() {
                      nameError = emailError = passwordError = formError = null;
                      submitting = true;
                    });
                    try {
                      final err = await _createAccount(
                        email: email,
                        password: password,
                        name: name,
                        role: asAdmin ? 'institute_admin' : 'faculty',
                        institute: selectedInstitute,
                        coAdmin: asAdmin && _viewerIsInstituteAdmin,
                      );
                      if (err != null) {
                        setS(() {
                          submitting = false;
                          formError = _friendlyAuthError(err);
                        });
                        return;
                      }
                      if (!ctx.mounted || !mounted) return;
                      Navigator.pop(ctx);
                      TopToast.show(context, '$name added to $selectedInstitute.');
                    } catch (e) {
                      setS(() {
                        submitting = false;
                        formError = 'Failed: $e';
                      });
                    }
                  },
          ),
        ),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(widget.role, widget.institute)],
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppTopBar(
          title: _viewerIsInstituteAdmin ? 'Members' : 'Users',
          subtitle: _viewerIsInstituteAdmin
              ? '${(widget.institute ?? '').toUpperCase()} · ${_instituteAccounts.length} accounts'
              : '${_members.length} members · ${_others.length} other accounts',
          variant: AppTopBarVariant.small,
          showBackButton: true,
          showInstituteLine: _viewerIsInstituteAdmin,
          actions: [
            AppTopBarAction(
              icon: Icons.person_add_alt_1_outlined,
              tooltip: 'Add account',
              onTap: _showAddAccountSheet,
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: _errorText != null ? _buildError() : _buildContent(),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final usingPlaceholder = _users.isEmpty && _isLoading;
    return ScreenSkeleton(
      isLoading: _isLoading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: AppTextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: 'Search name or email',
                prefixIcon: const Icon(Icons.search, size: 20),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
          if (!_viewerIsInstituteAdmin) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: AppSegmentedControl(
                segments: [
                  AppSegment(label: 'Members ${_members.length}'),
                  AppSegment(label: 'Others ${_others.length}'),
                ],
                selectedIndex: _segment,
                onChanged: (i) => setState(() => _segment = i),
                palette: _palette,
              ),
            ),
          ],
          Expanded(
            child: _viewerIsInstituteAdmin
                ? _buildInstituteList(usingPlaceholder)
                : _buildCampusList(usingPlaceholder),
          ),
        ],
      ),
    );
  }

  Widget _buildInstituteList(bool usingPlaceholder) {
    final list = usingPlaceholder ? placeholderUserList() : _instituteAccounts;
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        if (list.isEmpty)
          _emptyState('No accounts in this institute yet.')
        else
          ...list.map((u) => _userRow(u, isSelf: u['uid'] == _currentUid)),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lock_outline, size: 16, color: AppColors.inkMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    'You can only see and manage ${(widget.institute ?? '').toUpperCase()} accounts.',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.inkMuted)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCampusList(bool usingPlaceholder) {
    final source = usingPlaceholder
        ? placeholderUserList()
        : (_segment == 0 ? _members : _others);
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        if (source.isEmpty)
          _emptyState(_segment == 0
              ? 'No members yet.'
              : 'No unassigned accounts.')
        else
          ...source.map((u) => _userRow(u, isSelf: u['uid'] == _currentUid)),
      ],
    );
  }

  Widget _emptyState(String message) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Text(message,
            style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
      ),
    );
  }

  Widget _userRow(Map<String, dynamic> user, {required bool isSelf}) {
    final role = _roleOf(user);
    final institute = _instituteOf(user);
    final name = (user['name'] as String? ?? '').trim();
    final email = (user['email'] as String? ?? '').trim();
    final displayName = name.isNotEmpty ? name : (email.isNotEmpty ? email : 'Unnamed');
    final cardPalette =
        institute.isNotEmpty ? InstituteColors.forCode(institute) : _palette;
    final isAdminRole = role != 'faculty';
    final initialsSource = name.isNotEmpty ? name : email;
    final initials = initialsSource.isEmpty
        ? '?'
        : initialsSource.substring(0, 1).toUpperCase();

    return InkWell(
      onTap: () => _openUserActions(user),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: _palette.line)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: cardPalette.dark, width: 1.5),
              ),
              child: Text(initials,
                  style: TextStyle(
                      fontFamily: AppFonts.family,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: cardPalette.dark)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(displayName,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.subtitle
                                .copyWith(color: AppColors.ink)),
                      ),
                      if (isSelf) ...[
                        const SizedBox(width: 6),
                        Text('(you)',
                            style: AppTextStyles.bodySm
                                .copyWith(color: AppColors.inkMuted)),
                      ],
                    ],
                  ),
                  if (email.isNotEmpty && name.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(email,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodySm
                            .copyWith(color: AppColors.inkMuted)),
                  ],
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _pill(
                        _roleLabel(role, _isCoAdmin(user)),
                        color: isAdminRole ? cardPalette.dark : AppColors.inkMid,
                      ),
                      if (institute.isNotEmpty) _pill(institute),
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.more_vert, color: AppColors.inkMid),
          ],
        ),
      ),
    );
  }

  Widget _pill(String text, {Color? color}) {
    final c = color ?? AppColors.inkMid;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withAlpha(160)),
      ),
      child: Text(text, style: AppTextStyles.caption.copyWith(color: c)),
    );
  }

  String _roleLabel(String role, bool isCoAdmin) {
    switch (role) {
      case 'main_admin':
        return 'Main admin';
      case 'super_admin':
        return 'Super admin';
      case 'admin':
        return 'Admin';
      case 'institute_admin':
        return isCoAdmin ? 'Co-admin' : 'Institute admin';
      default:
        return 'Member';
    }
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_outline, size: 44, color: AppColors.inkMuted),
            const SizedBox(height: 16),
            Text('Cannot load users',
                style: AppTextStyles.subtitle.copyWith(color: AppColors.ink)),
            const SizedBox(height: 8),
            Text(_errorText ?? 'Something went wrong.',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _retryLoad,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Retry'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _palette.dark,
                side: BorderSide(color: _palette.dark),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
