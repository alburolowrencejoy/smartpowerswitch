import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../services/notification_seen.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../theme/institute_colors.dart';
import '../../services/automation_scheduler_service.dart';
import '../../widgets/app_top_bar.dart';
import '../../widgets/outline_icon_box.dart';

/// "More" (handoff §4.11, institute-admin variant §5).
///
/// Replaces the burger `PopupMenuButton` that used to hide Notifications /
/// Manage Users / Settings / Logout behind a single compact menu icon in
/// `dashboard_screen.dart` -- those destinations get their own real tab
/// here instead. This screen is self-contained (own Firebase Auth/role
/// hydration and its own lightweight unread-notifications count), so it can
/// be pushed or placed on a bottom-nav tab without any constructor args,
/// mirroring `NotificationsScreen`/`SettingsScreen`.
///
/// This screen is embedded directly as the dashboard shell's 5th root tab
/// (`dashboard_screen.dart`'s `IndexedStack`, `showBackButton: false`) so
/// the bottom nav and shell top bar stay visible while its content shows.
/// A `/more` named route is also registered in `main.dart` (default
/// `showBackButton: true`) so it remains reachable as a real pushed screen
/// with a back arrow for any other caller.
class MoreScreen extends StatefulWidget {
  const MoreScreen({super.key, this.showBackButton = true});

  /// Whether this screen's own [AppTopBar] (title "More" + bell) renders at
  /// all. Defaults to `true` (the standalone `/more` pushed-route case) --
  /// pass `false` when this is embedded as a dashboard tab, matching the
  /// convention already used by `BuildingFloorScreen`'s and `HistoryScreen`'s
  /// `showBackButton` param: when `false`, NO top bar is drawn here at all
  /// (not just a hidden chevron), since the shell supplies its own top bar
  /// for this tab instead (title "More" + bell + avatar).
  final bool showBackButton;

  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {

  String _role = 'faculty';
  String? _institute;
  String _name = '';
  String _email = '';
  String _appVersion = '';
  int _unreadCount = 0;

  StreamSubscription<DatabaseEvent>? _notificationsSub;

  InstitutePalette get _palette =>
      InstituteTheme.resolve(_role, _institute).palette;

  bool get _isSuperAdmin =>
      _role == 'main_admin' || _role == 'admin' || _role == 'super_admin';
  bool get _isInstituteAdmin =>
      _role == 'institute_admin' && (_institute?.trim().isNotEmpty ?? false);
  bool get _canAccessManagement => _isSuperAdmin || _isInstituteAdmin;

  @override
  void initState() {
    super.initState();
    _hydrateSessionFromAuth();
    _loadAppVersion();
    _listenUnreadCount();
  }

  @override
  void dispose() {
    NotificationSeen.instance.lastSeen.removeListener(_recountUnread);
    _notificationsSub?.cancel();
    super.dispose();
  }

  Future<void> _hydrateSessionFromAuth() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _email = user.email ?? '');
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
        _name = (map['name'] as String?)?.trim() ?? '';
      });
    } catch (_) {
      // Keep existing defaults if role hydration fails.
    }
  }

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _appVersion = info.version);
  }

  /// A lightweight, best-effort unread count -- same derivation as
  /// [NotificationsScreen] (shared list, no per-notification read flag; a
  /// row counts as unread if newer than the locally-stored "last seen"
  /// timestamp), scoped to this institute for an institute admin. Kept
  /// independent of [NotificationsScreen]'s own listener since this screen
  /// can be alive at the same time as that one is not.
  Map<dynamic, dynamic>? _notificationsRaw;

  void _recountUnread() {
    if (!mounted) return;
    final data = _notificationsRaw;
    setState(() => _unreadCount = data == null
        ? 0
        : NotificationSeen.instance.unreadCount(data.values,
            instituteCode: _isInstituteAdmin ? _institute : null));
  }

  void _listenUnreadCount() {
    NotificationSeen.instance.ensureLoaded().then((_) {
      NotificationSeen.instance.lastSeen.addListener(_recountUnread);
      _recountUnread();
    });
    _notificationsSub = FirebaseDatabase.instance
        .ref('notifications')
        .orderByChild('timestamp')
        .limitToLast(50)
        .onValue
        .listen((event) {
      if (!mounted) return;
      _notificationsRaw = event.snapshot.value as Map<dynamic, dynamic>?;
      _recountUnread();
    }, onError: (_) {
      // Leave the badge at its last known value on failure.
    });
  }

  Future<void> _logout() async {
    await AutomationSchedulerService.stop();
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
  }

  String get _initials {
    final source = _name.isNotEmpty ? _name : _email;
    if (source.isEmpty) return '?';
    final parts = source.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return (parts[0][0] + parts[1][0]).toUpperCase();
    }
    return source.substring(0, source.length >= 2 ? 2 : 1).toUpperCase();
  }

  String get _rolePillLabel {
    if (_isInstituteAdmin) return 'Institute admin · ${_institute!.trim().toUpperCase()}';
    if (_isSuperAdmin) return 'Super admin';
    return 'Member';
  }

  String get _manageLabel =>
      _isInstituteAdmin ? 'Manage ${_institute!.trim().toUpperCase()}' : 'Manage';

  void _showAbout() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: _palette.mid.withAlpha(90),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text('About',
                    style: AppTextStyles.title.copyWith(color: AppColors.ink)),
                const SizedBox(height: 14),
                _aboutRow('SmartSwitch',
                    _appVersion.isEmpty ? 'Loading...' : 'Version $_appVersion'),
                _aboutRow('Institution', 'Davao del Norte State College'),
                _aboutRow('Location', 'Davao del Norte, PH'),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _aboutRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Text(label, style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
          const Spacer(),
          Text(value,
              style: AppTextStyles.bodySm
                  .copyWith(color: AppColors.ink, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Column(children: [
            // Skipped when embedded directly as the dashboard's More tab --
            // the parent shell already shows an equivalent top bar (title
            // "More" + bell + avatar) just above this screen (see class doc
            // on `showBackButton`).
            if (widget.showBackButton)
              AppTopBar(
                title: 'More',
                showBackButton: true,
                showInstituteLine: _isInstituteAdmin,
                actions: [
                  AppTopBarAction(
                    icon: Icons.notifications_outlined,
                    tooltip: 'Notifications',
                    badgeCount: _unreadCount,
                    onTap: () => Navigator.pushNamed(context, '/notifications'),
                  ),
                ],
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(color: _palette.mid, width: 1.5),
                          ),
                          child: Text(_initials,
                              style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: _palette.dark)),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  _name.isNotEmpty
                                      ? _name
                                      : (_email.isEmpty
                                          ? 'Loading...'
                                          : _email),
                                  style: AppTextStyles.subtitle.copyWith(
                                      color: AppColors.ink,
                                      fontSize: 18,
                                      height: 22 / 18)),
                              if (_email.isNotEmpty && _name.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(_email,
                                    style: AppTextStyles.bodySm
                                        .copyWith(color: AppColors.inkMuted)),
                              ],
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(color: _palette.dark),
                                ),
                                child: Text(_rolePillLabel,
                                    style: AppTextStyles.caption
                                        .copyWith(color: _palette.dark)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_canAccessManagement) ...[
                    _sectionLabel(_manageLabel),
                    _menuRow(
                      icon: Icons.group_outlined,
                      title: _isInstituteAdmin ? 'Members' : 'Users',
                      subtitle: _isInstituteAdmin
                          ? '${_institute!.trim().toUpperCase()} accounts only'
                          : 'Members, roles, institutes',
                      onTap: () => Navigator.pushNamed(context, '/manage-users',
                          arguments: {'role': _role, 'institute': _institute}),
                    ),
                    _menuRow(
                      icon: Icons.settings_outlined,
                      title: 'Settings',
                      subtitle: 'Rate, devices, updates',
                      onTap: () => Navigator.pushNamed(context, '/settings'),
                    ),
                    _menuRow(
                      icon: Icons.notifications_outlined,
                      title: 'Notifications',
                      trailing: _unreadCount > 0 ? '$_unreadCount' : null,
                      onTap: () =>
                          Navigator.pushNamed(context, '/notifications'),
                    ),
                  ],
                  _sectionLabel('App'),
                  _menuRow(
                    icon: Icons.info_outline,
                    title: 'About',
                    subtitle: _appVersion.isEmpty ? '' : 'Version $_appVersion',
                    onTap: _showAbout,
                  ),
                  const SizedBox(height: 12),
                  _menuRow(
                    icon: Icons.logout,
                    title: 'Sign out',
                    variant: OutlineIconBoxVariant.error,
                    titleColor: AppColors.errorText,
                    onTap: _logout,
                  ),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _sectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Text(label,
          style: AppTextStyles.label.copyWith(color: AppColors.ink)),
    );
  }

  Widget _menuRow({
    required IconData icon,
    required String title,
    String? subtitle,
    String? trailing,
    OutlineIconBoxVariant variant = OutlineIconBoxVariant.normal,
    Color? titleColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: _palette.line)),
        ),
        child: Row(
          children: [
            OutlineIconBox(icon: icon, variant: variant),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: AppTextStyles.subtitle
                          .copyWith(color: titleColor ?? AppColors.ink)),
                  if (subtitle != null && subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: AppTextStyles.bodySm
                            .copyWith(color: AppColors.inkMuted)),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: AppColors.warning),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(trailing,
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.warningText)),
              ),
              const SizedBox(width: 8),
            ],
            if (titleColor == null)
              const Icon(Icons.chevron_right, color: AppColors.inkMuted),
          ],
        ),
      ),
    );
  }
}
