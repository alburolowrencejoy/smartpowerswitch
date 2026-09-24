import 'dart:async';
import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:rxdart/rxdart.dart';

import '../../firebase_options.dart';
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/responsive_center.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import 'web_theme.dart';
import 'web_widgets.dart';
import '../../theme/app_fonts.dart';

/// Web "Manage Users": one card per institute (admins first, then members)
/// plus an Other Accounts card, with icon-only row actions. Same data,
/// rules and backend calls as the shared mobile [ManageUsersScreen]:
///
/// - Main admin (`admin`/`main_admin`/`super_admin`): every institute and
///   every unassigned or high-tier account.
/// - Institute admin: only their own institute. They can add co-admins and
///   members, and remove co-admins, but never the admin the main admin
///   assigned, nor themselves.
class ManageUsersScreenWeb extends StatefulWidget {
  final String role;
  final String? institute;

  const ManageUsersScreenWeb({super.key, required this.role, this.institute});

  @override
  State<ManageUsersScreenWeb> createState() => _ManageUsersScreenWebState();
}

class _ManageUsersScreenWebState extends State<ManageUsersScreenWeb> {
  static const _emailDomain = '@dnsc.edu.ph';

  List<Map<String, dynamic>> _users = [];
  List<Map<String, String>> _institutes = [];
  bool _isLoading = true;
  String? _errorText;
  StreamSubscription? _sub;

  bool get _viewerIsInstituteAdmin => widget.role == 'institute_admin';
  String? get _currentUid => FirebaseAuth.instance.currentUser?.uid;
  InstitutePalette get _palette =>
      InstituteTheme.resolve(widget.role, widget.institute).palette;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _listen() {
    _sub?.cancel();
    _sub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('users').onValue,
      FirebaseDatabase.instance.ref('buildings').onValue,
    ]).timeout(const Duration(seconds: 15), onTimeout: (sink) {
      if (_isLoading) {
        sink.addError('Taking too long to load users. Check your connection.');
      }
    }).listen((events) {
      if (!mounted) return;
      setState(() {
        final usersRaw = events[0].snapshot.value;
        if (usersRaw is Map) {
          _users = [
            for (final e in usersRaw.entries)
              if (e.value is Map)
                {...Map<String, dynamic>.from(e.value as Map), 'uid': e.key},
          ];
        } else if (_isLoading) {
          _users = [];
        }
        final bRaw = events[1].snapshot.value;
        if (bRaw is Map) {
          _institutes = [
            for (final e in bRaw.entries)
              {
                'code': e.key.toString(),
                'name': (e.value is Map ? (e.value as Map)['name'] : null)
                        ?.toString() ??
                    e.key.toString(),
              },
          ]..sort((a, b) => a['code']!.compareTo(b['code']!));
        } else if (_isLoading) {
          _institutes = [];
        }
        _isLoading = false;
        _errorText = null;
      });
    }, onError: (Object error) {
      if (!mounted) return;
      final text = error.toString();
      if (_isLoading) {
        setState(() {
          _isLoading = false;
          _errorText = text.toLowerCase().contains('permission')
              ? 'You do not have permission to view users.'
              : text.startsWith('Taking too long')
                  ? text
                  : 'Failed to load users.';
        });
      } else {
        TopToast.show(context, 'Lost connection to live user data.',
            isError: true);
      }
    });
  }

  // ── Groupings ──────────────────────────────────────────────────────────

  String _instituteOf(Map<String, dynamic> u) =>
      (u['institute'] as String? ?? '').trim();
  String _roleOf(Map<String, dynamic> u) => u['role'] as String? ?? 'faculty';
  bool _isCoAdmin(Map<String, dynamic> u) => u['coAdmin'] == true;
  bool _isAdmin(Map<String, dynamic> u) => _roleOf(u) == 'institute_admin';
  String _nameOf(Map<String, dynamic> u) {
    final n = (u['name'] as String? ?? '').trim();
    return n.isNotEmpty ? n : (u['email'] as String? ?? 'Unnamed');
  }

  List<Map<String, dynamic>> _peopleOf(String code) => _users
      .where((u) => _instituteOf(u) == code)
      .toList()
    ..sort((a, b) {
      int rank(Map<String, dynamic> u) =>
          !_isAdmin(u) ? 2 : (_isCoAdmin(u) ? 1 : 0);
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : _nameOf(a).compareTo(_nameOf(b));
    });

  List<Map<String, dynamic>> get _otherAccounts {
    final codes = {for (final i in _institutes) i['code']};
    return _users.where((u) {
      final role = _roleOf(u);
      if (role != 'institute_admin' && role != 'faculty') return true;
      return !codes.contains(_instituteOf(u));
    }).toList()
      ..sort((a, b) => _nameOf(a).compareTo(_nameOf(b)));
  }

  bool _isProtected(Map<String, dynamic> u) =>
      u['isMainAdmin'] == true ||
      (u['email'] as String? ?? '').toLowerCase() == 'admin@dnsc.edu.ph';

  List<String> get _instituteOptions => [
        for (final i in _institutes)
          if (!_viewerIsInstituteAdmin || i['code'] == widget.institute)
            '${i['code']} · ${i['name']}',
      ];

  String _codeFromOption(String option) => option.split(' · ').first;

  // ── Backend calls (same as the mobile screen) ──────────────────────────

  /// Creates the Auth user over REST so the signed-in admin stays signed
  /// in, then writes `users/{uid}`. Returns an Auth error code or null.
  Future<String?> _createAccount({
    required String email,
    required String password,
    required String name,
    required String role,
    String? institute,
    bool coAdmin = false,
  }) async {
    final key = DefaultFirebaseOptions.currentPlatform.apiKey;
    final response = await http.post(
      Uri.parse(
          'https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$key'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(
          {'email': email, 'password': password, 'returnSecureToken': true}),
    );
    final body = jsonDecode(response.body);
    if (response.statusCode != 200) {
      return body['error']?['message'] as String? ?? 'ERROR';
    }
    await FirebaseDatabase.instance.ref('users/${body['localId']}').set({
      'email': email,
      'name': name,
      'role': role,
      if (institute != null) 'institute': institute,
      if (role == 'institute_admin') 'coAdmin': coAdmin,
    });
    return null;
  }

  /// Maps an Auth REST error onto the form field it belongs to.
  Map<String, String> _authError(String code) {
    if (code.startsWith('EMAIL_EXISTS')) {
      return {'email': 'That email already has an account.'};
    }
    if (code.startsWith('INVALID_EMAIL')) {
      return {'email': 'Enter a valid email address.'};
    }
    if (code.startsWith('WEAK_PASSWORD')) {
      return {'pw': 'Password is too weak. Use at least 6 characters.'};
    }
    if (code.startsWith('TOO_MANY_ATTEMPTS')) {
      return {'': 'Too many attempts. Try again later.'};
    }
    return {'': 'Could not create the account ($code).'};
  }

  String _functionsError(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'permission-denied':
        return 'You do not have permission to do this.';
      case 'unauthenticated':
        return 'Your session expired. Please sign in again.';
      default:
        return e.message ?? 'Something went wrong. Please try again.';
    }
  }

  /// Validates name / email / password fields shared by the create forms.
  Map<String, String> _checkPerson(Map<String, String> v) {
    final e = <String, String>{};
    final name = v['name']!;
    final email = v['email']!.toLowerCase();
    if (name.isEmpty) {
      e['name'] = 'Full name is required.';
    } else if (name.length < 2) {
      e['name'] = 'Enter the full name.';
    }
    if (email.isEmpty) {
      e['email'] = 'Email is required.';
    } else if (!RegExp(r'^[^@\s]+@[^@\s]+$').hasMatch(email) ||
        !email.endsWith(_emailDomain)) {
      e['email'] = 'Use a $_emailDomain address, like juan$_emailDomain.';
    } else if (_users.any(
        (u) => (u['email'] as String? ?? '').toLowerCase() == email)) {
      e['email'] = 'That email already has an account.';
    }
    if (v['pw']!.isEmpty) {
      e['pw'] = 'Temporary password is required.';
    } else if (v['pw']!.length < 6) {
      e['pw'] = 'Password needs at least 6 characters.';
    }
    return e;
  }

  // ── Actions ────────────────────────────────────────────────────────────

  Future<void> _addMember() async {
    final options = _instituteOptions;
    if (options.isEmpty) {
      TopToast.show(context, 'Add a building first.', isError: true);
      return;
    }
    String? added;
    await showWebFormDialog(
      context: context,
      title: 'Add member',
      okLabel: 'Add',
      fields: [
        const WebField(id: 'name', label: 'Full name', hint: 'e.g. Juan Dela Cruz'),
        const WebField(
            id: 'email',
            label: 'Email',
            hint: 'name$_emailDomain',
            keyboardType: TextInputType.emailAddress),
        WebField(id: 'inst', label: 'Institute', options: options),
        const WebField(
            id: 'pw',
            label: 'Temporary password',
            hint: 'At least 6 characters',
            obscure: true),
      ],
      onSubmit: (v) async {
        final e = _checkPerson(v);
        if (e.isNotEmpty) return e;
        final err = await _createAccount(
          email: v['email']!.toLowerCase(),
          password: v['pw']!,
          name: v['name']!,
          role: 'faculty',
          institute: _codeFromOption(v['inst']!),
        );
        if (err != null) return _authError(err);
        added = v['name'];
        return null;
      },
    );
    if (added != null && mounted) TopToast.show(context, '$added added.');
  }

  Future<void> _newAccount() async {
    final institutes = _instituteOptions;
    final options = _viewerIsInstituteAdmin
        ? institutes
        : ['Unassigned', ...institutes];
    if (options.isEmpty) {
      TopToast.show(context, 'Add a building first.', isError: true);
      return;
    }
    String? created;
    await showWebFormDialog(
      context: context,
      title: 'New account',
      subtitle: _viewerIsInstituteAdmin
          ? 'Create a member or co-admin for your institute.'
          : 'Leave it unassigned to place it under Other Accounts.',
      okLabel: 'Create',
      fields: [
        const WebField(id: 'name', label: 'Full name'),
        const WebField(
            id: 'email',
            label: 'Email',
            hint: 'name$_emailDomain',
            keyboardType: TextInputType.emailAddress),
        WebField(
            id: 'role',
            label: 'Role',
            options: [
              'Member',
              _viewerIsInstituteAdmin ? 'Co-admin' : 'Institute admin'
            ]),
        WebField(id: 'inst', label: 'Institute', options: options),
        const WebField(
            id: 'pw',
            label: 'Temporary password',
            hint: 'At least 6 characters',
            obscure: true),
      ],
      onSubmit: (v) async {
        final e = _checkPerson(v);
        final admin = v['role'] != 'Member';
        final unassigned = v['inst'] == 'Unassigned';
        if (admin && unassigned) {
          e['inst'] = 'An institute admin must belong to an institute.';
        }
        if (e.isNotEmpty) return e;
        final err = await _createAccount(
          email: v['email']!.toLowerCase(),
          password: v['pw']!,
          name: v['name']!,
          role: admin ? 'institute_admin' : 'faculty',
          institute: unassigned ? null : _codeFromOption(v['inst']!),
          coAdmin: admin && _viewerIsInstituteAdmin,
        );
        if (err != null) return _authError(err);
        created = v['name'];
        return null;
      },
    );
    if (created != null && mounted) {
      TopToast.show(context, 'Account created for $created.');
    }
  }

  Future<void> _promote(Map<String, dynamic> u, String code) async {
    final asCo = _viewerIsInstituteAdmin;
    final ok = await showWebConfirmDialog(
      context: context,
      title: 'Promote member?',
      message: 'Make ${_nameOf(u)} ${asCo ? 'a co-admin' : 'an admin'} of '
          "$code? They'll be able to manage this institute's devices and "
          'members.',
      okLabel: 'Promote',
      danger: false,
      onConfirm: () => FirebaseDatabase.instance
          .ref('users/${u['uid']}')
          .update({'role': 'institute_admin', 'coAdmin': asCo}),
    );
    if (ok && mounted) TopToast.show(context, '${_nameOf(u)} promoted.');
  }

  Future<void> _demote(Map<String, dynamic> u) async {
    final ok = await showWebConfirmDialog(
      context: context,
      title: _isCoAdmin(u) ? 'Remove co-admin?' : 'Remove admin?',
      message: '${_nameOf(u)} will become a regular member of '
          '${_instituteOf(u)}.',
      okLabel: 'Remove',
      onConfirm: () => FirebaseDatabase.instance
          .ref('users/${u['uid']}')
          .update({'role': 'faculty', 'coAdmin': false}),
    );
    if (ok && mounted) {
      TopToast.show(context, '${_nameOf(u)} is now a member.');
    }
  }

  Future<void> _changePassword(Map<String, dynamic> u) async {
    final ok = await showWebFormDialog(
      context: context,
      title: 'Change password',
      subtitle: 'Account: ${u['email'] ?? ''}',
      fields: const [
        WebField(
            id: 'pw',
            label: 'New password',
            hint: 'At least 6 characters',
            obscure: true),
        WebField(id: 'pw2', label: 'Confirm new password', obscure: true),
      ],
      onSubmit: (v) async {
        final e = <String, String>{};
        if (v['pw']!.isEmpty) {
          e['pw'] = 'Enter a new password.';
        } else if (v['pw']!.length < 6) {
          e['pw'] = 'Password needs at least 6 characters.';
        }
        if (v['pw2']!.isEmpty) {
          e['pw2'] = 'Type the password again.';
        } else if (v['pw']!.isNotEmpty && v['pw'] != v['pw2']) {
          e['pw2'] = 'Passwords do not match.';
        }
        if (e.isNotEmpty) return e;
        try {
          await FirebaseFunctions.instance
              .httpsCallable('changeUserPassword')
              .call({'uid': u['uid'], 'newPassword': v['pw']});
        } on FirebaseFunctionsException catch (err) {
          return {'': _functionsError(err)};
        }
        return null;
      },
    );
    if (ok && mounted) TopToast.show(context, 'Password updated.');
  }

  Future<void> _assign(Map<String, dynamic> u) async {
    final options = _instituteOptions;
    if (options.isEmpty) {
      TopToast.show(context, 'No institutes exist yet.', isError: true);
      return;
    }
    String? code;
    await showWebFormDialog(
      context: context,
      title: 'Assign to institute',
      subtitle: u['email'] as String? ?? '',
      okLabel: 'Assign',
      fields: [WebField(id: 'inst', label: 'Institute', options: options)],
      onSubmit: (v) async {
        code = _codeFromOption(v['inst']!);
        await FirebaseDatabase.instance
            .ref('users/${u['uid']}/institute')
            .set(code);
        return null;
      },
    );
    if (code != null && mounted) TopToast.show(context, 'Assigned to $code.');
  }

  Future<void> _delete(Map<String, dynamic> u) async {
    final email = u['email'] as String? ?? '';
    final ok = await showWebConfirmDialog(
      context: context,
      title: 'Delete account?',
      message: '"$email" will be removed from the system. '
          "This can't be undone.",
      onConfirm: () async {
        try {
          await FirebaseFunctions.instance
              .httpsCallable('deleteUser')
              .call({'uid': u['uid']});
        } on FirebaseFunctionsException catch (err) {
          throw _functionsError(err);
        }
      },
    );
    if (ok && mounted) TopToast.show(context, '$email removed.');
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(widget.role, widget.institute)],
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
                _header(),
                const SizedBox(height: 18),
                if (_errorText != null) _error() else _grid(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final p = _palette;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Manage Users',
          style: TextStyle(
              fontFamily: AppFonts.family,
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: WebColors.ink)),
      const SizedBox(height: 4),
      Text(
        _viewerIsInstituteAdmin
            ? "Your institute's admins, co-admins and members"
            : 'Institute admins, members and account access · grouped by '
                'institute',
        style: const TextStyle(fontSize: 14, color: WebColors.muted),
      ),
      const SizedBox(height: 16),
      Wrap(spacing: 10, runSpacing: 10, children: [
        ElevatedButton.icon(
          onPressed: _isLoading ? null : _addMember,
          icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
          label: const Text('Add member'),
          style: ElevatedButton.styleFrom(
            backgroundColor: p.dark,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _isLoading ? null : _newAccount,
          icon: const Icon(Icons.manage_accounts_outlined, size: 18),
          label: const Text('New account'),
          style: OutlinedButton.styleFrom(
            foregroundColor: p.dark,
            side: BorderSide(color: p.mid.withAlpha(90)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
          ),
        ),
      ]),
    ]);
  }

  Widget _error() {
    return _Card(
      palette: _palette,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 30),
        child: Column(children: [
          Icon(Icons.lock_outline, size: 34, color: _palette.mid),
          const SizedBox(height: 12),
          Text(_errorText!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: WebColors.mid)),
          const SizedBox(height: 14),
          TextButton.icon(
            onPressed: () {
              setState(() {
                _errorText = null;
                _isLoading = true;
              });
              _listen();
            },
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Retry'),
          ),
        ]),
      ),
    );
  }

  Widget _grid() {
    final visible = _viewerIsInstituteAdmin
        ? _institutes.where((i) => i['code'] == widget.institute).toList()
        : _institutes;
    final cards = <Widget>[
      for (final i in visible) _instituteCard(i['code']!, i['name']!),
      if (!_viewerIsInstituteAdmin) _otherAccountsCard(),
    ];
    if (cards.isEmpty) {
      return _Card(
        palette: _palette,
        child: const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
              'No institute is assigned to your account yet. Ask your main '
              'admin to assign one.',
              textAlign: TextAlign.center,
              style: TextStyle(color: WebColors.muted)),
        ),
      );
    }
    return LayoutBuilder(builder: (context, c) {
      const gap = 20.0;
      final cols = c.maxWidth >= 980 ? 2 : 1;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final card in cards) SizedBox(width: w, child: card)],
      );
    });
  }

  Widget _instituteCard(String code, String name) {
    final cp = InstituteColors.forCode(code);
    final people = _peopleOf(code);
    final admins = people.where(_isAdmin).length;
    final members = people.length - admins;
    return _Card(
      palette: cp,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
                color: cp.pale, borderRadius: BorderRadius.circular(6)),
            child: Text(code,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: cp.dark)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: AppFonts.family,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: WebColors.ink)),
              Text(
                  '$admins admin${admins == 1 ? '' : 's'} · '
                  '$members member${members == 1 ? '' : 's'}',
                  style:
                      const TextStyle(fontSize: 13, color: WebColors.muted)),
            ]),
          ),
          if (admins == 0)
            const _Pill(text: 'No admin', color: AppColors.warning),
        ]),
        const SizedBox(height: 12),
        if (people.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No members yet.',
                style: TextStyle(fontSize: 13.5, color: WebColors.muted)),
          )
        else
          for (final u in people) _userRow(u, cp, actions: _instituteActions(u, code)),
      ]),
    );
  }

  List<Widget> _instituteActions(Map<String, dynamic> u, String code) {
    final isSelf = u['uid'] == _currentUid;
    final admin = _isAdmin(u);
    final co = _isCoAdmin(u);
    final canRemoveAdmin = admin && !isSelf && (!_viewerIsInstituteAdmin || co);
    return [
      if (!admin)
        WebIconButton(
          icon: Icons.arrow_upward_rounded,
          tooltip: _viewerIsInstituteAdmin ? 'Make co-admin' : 'Promote to admin',
          size: 32,
          onPressed: () => _promote(u, code),
        ),
      WebIconButton(
        icon: Icons.key_outlined,
        tooltip: 'Change password',
        size: 32,
        onPressed: () => _changePassword(u),
      ),
      if (canRemoveAdmin)
        WebIconButton(
          icon: Icons.person_remove_outlined,
          tooltip: co ? 'Remove co-admin' : 'Remove admin',
          size: 32,
          danger: true,
          onPressed: () => _demote(u),
        ),
      if (!admin && !isSelf && !_isProtected(u))
        WebIconButton(
          icon: Icons.delete_outline_rounded,
          tooltip: 'Delete account',
          size: 32,
          danger: true,
          onPressed: () => _delete(u),
        ),
    ];
  }

  Widget _otherAccountsCard() {
    final others = _otherAccounts;
    final p = _palette;
    return _Card(
      palette: p,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Other Accounts',
            style: TextStyle(
                fontFamily: AppFonts.family,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: WebColors.ink)),
        const Text('Main admins and accounts not assigned to an institute',
            style: TextStyle(fontSize: 13, color: WebColors.muted)),
        const SizedBox(height: 12),
        if (others.isEmpty)
          const Text('No unassigned accounts.',
              style: TextStyle(fontSize: 13.5, color: WebColors.muted))
        else
          for (final u in others)
            _userRow(u, p, actions: [
              if (_roleOf(u) == 'faculty' || _roleOf(u) == 'institute_admin')
                WebIconButton(
                  icon: Icons.person_add_alt_outlined,
                  tooltip: 'Assign to institute',
                  size: 32,
                  onPressed: () => _assign(u),
                ),
              WebIconButton(
                icon: Icons.key_outlined,
                tooltip: 'Change password',
                size: 32,
                onPressed: () => _changePassword(u),
              ),
              if (!_isProtected(u) && u['uid'] != _currentUid)
                WebIconButton(
                  icon: Icons.delete_outline_rounded,
                  tooltip: 'Delete account',
                  size: 32,
                  danger: true,
                  onPressed: () => _delete(u),
                ),
            ]),
      ]),
    );
  }

  Widget _userRow(Map<String, dynamic> u, InstitutePalette p,
      {required List<Widget> actions}) {
    final name = _nameOf(u);
    final words = name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final initials = words.isEmpty
        ? '?'
        : (words.first[0] + (words.length > 1 ? words.last[0] : ''))
            .toUpperCase();
    final role = _roleOf(u);
    final badge = switch (role) {
      'institute_admin' => _isCoAdmin(u) ? 'CO-ADMIN' : 'ADMIN',
      'main_admin' => 'MAIN ADMIN',
      'super_admin' => 'SUPER ADMIN',
      'admin' => 'ADMIN',
      _ => 'MEMBER',
    };
    final high = role != 'faculty';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.mid.withAlpha(22))),
      ),
      child: Row(children: [
        CircleAvatar(
          radius: 17,
          backgroundColor: high ? p.dark.withAlpha(28) : p.pale,
          child: Text(initials,
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w700, color: p.dark)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: WebColors.ink)),
            Text(u['email'] as String? ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: WebColors.muted)),
          ]),
        ),
        const SizedBox(width: 8),
        _Pill(text: badge, color: high ? p.dark : WebColors.mid),
        const SizedBox(width: 10),
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          actions[i],
        ],
      ]),
    );
  }
}

class _Card extends StatelessWidget {
  final InstitutePalette palette;
  final Widget child;

  const _Card({required this.palette, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.mid.withAlpha(30)),
      ),
      child: child,
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;

  const _Pill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(22),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }
}
