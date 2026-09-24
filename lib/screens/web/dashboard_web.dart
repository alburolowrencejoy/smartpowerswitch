import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:rxdart/rxdart.dart';

import '../../services/automation_scheduler_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../utils/placeholder_data.dart';
import '../../viewmodels/dashboard_viewmodel.dart';
import '../../widgets/responsive_center.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import 'automation_screen_web.dart';
import 'building_floor_screen_web.dart';
import 'campus_map_screen_web.dart';
import 'device_detail_screen_web.dart';
import 'history_screen_web.dart';
import 'manage_users_screen_web.dart';
import 'notifications_screen_web.dart';
import 'settings_screen_web.dart';
import 'web_overview_tab.dart';
import 'web_theme.dart';
import 'web_widgets.dart';
import '../../theme/app_fonts.dart';

/// The desktop/wide-window dashboard shell: a floating side nav plus a
/// content area, chosen over [DashboardScreen] by `DashboardPage` once the
/// window is wide enough. Shares [DashboardViewModel], the same Firebase
/// data, and the same routes/roles as the mobile dashboard -- only the
/// layout is desktop-native.
///
/// Tabs (IndexedStack index -> screen):
///   0 Dashboard  -> [WebOverviewTab] (stat cards + charts)
///   1 Map
///   2 Analytics  (hidden for institute admins)
///   3 Automation
///   4 Settings   (admins only)
///   5 Manage Users (admins only)
///   6 Devices    -> the previous home tab (hero card, building grid,
///                   recent entries; institute admins get their rooms)
/// Devices is 6 rather than 1 so every existing index (e.g. "View full
/// analytics" jumping to 2) keeps working unchanged.
class DesktopDashboardScreen extends StatefulWidget {
  final String? role;
  final String? name;

  const DesktopDashboardScreen({super.key, this.role, this.name});

  @override
  State<DesktopDashboardScreen> createState() => _DesktopDashboardScreenState();
}

const int _tabDashboard = 0;
const int _tabMap = 1;
const int _tabAnalytics = 2;
const int _tabAutomation = 3;
const int _tabSettings = 4;
const int _tabUsers = 5;
const int _tabDevices = 6;

/// A side-nav item. Active = solid white pill with the palette's dark
/// color for icon/text (like the reference's highlighted "Dashboard"),
/// hover = faint white wash.
class _SideNavButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isActive;
  final Color activeColor;

  const _SideNavButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.activeColor,
    this.isActive = false,
  });

  @override
  State<_SideNavButton> createState() => _SideNavButtonState();
}

class _SideNavButtonState extends State<_SideNavButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.isActive;
    final hovered = _isHovered && !active;
    final fg = active
        ? widget.activeColor
        : Colors.white.withAlpha(hovered ? 255 : 210);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.0),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: active
                    ? Colors.white
                    : hovered
                        ? Colors.white.withAlpha(22)
                        : Colors.transparent,
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: Colors.black.withAlpha(30),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                children: [
                  Icon(widget.icon, size: 20, color: fg),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        color: fg,
                        fontSize: 14,
                        fontWeight:
                            active ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (active)
                    Icon(Icons.chevron_right_rounded, size: 18, color: fg),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopDashboardScreenState extends State<DesktopDashboardScreen> {
  late final DashboardViewModel vm;
  int _selectedIndex = _tabDashboard;
  String _role = 'faculty';
  String? _institute;

  // In-place "drill down" view state: when set, these are rendered instead
  // of the tab IndexedStack in the content area to the right of the side
  // nav -- so navigating into a building/device never pops out of the
  // desktop shell.
  Map<String, dynamic>? _viewingBuilding;
  Map<String, dynamic>? _viewingDevice;

  // ── Institute-scoped summary (institute_admin Devices tab only) ───────
  // Populated by _listenInstituteScoped(), filtered strictly to `_institute`
  // -- never derived from `vm`'s system-wide totals.
  double _instituteKwh = 0.0;
  double _instituteMonthlyKwh = 0.0;
  int _instituteAssignedDevices = 0;
  int _instituteOnlineDevices = 0;
  StreamSubscription? _instituteSub;

  String _monthKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';

  /// Institute-scoped combined listener (institute_admin only), mirroring
  /// mobile dashboard_screen.dart's `_listenInstituteScoped()`. Every number
  /// here is scoped to `_institute` only -- never system-wide.
  void _listenInstituteScoped() {
    final code = _institute;
    if (code == null || code.isEmpty) return;

    _instituteSub?.cancel();
    final monthKey = _monthKey(DateTime.now());
    _instituteSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('devices').onValue,
      FirebaseDatabase.instance.ref('master_devices').onValue,
      FirebaseDatabase.instance
          .ref('history/monthly/$monthKey/buildings/$code/kwh')
          .onValue,
    ]).listen((events) {
      if (!mounted) return;
      setState(() {
        // ── devices: today's institute kWh + online count ──────────
        final devicesRaw = events[0].snapshot.value;
        if (devicesRaw is Map) {
          final data = Map<String, dynamic>.from(devicesRaw);
          double kwh = 0;
          int online = 0;
          data.forEach((id, val) {
            if (val is! Map) return;
            final device = Map<String, dynamic>.from(val);
            final building = (device['building'] ?? '').toString();
            if (building != code) return;
            kwh += ((device['kwh'] ?? 0.0) as num).toDouble();

            final lastSeen = device['last_seen'];
            if (lastSeen != null && lastSeen != 0) {
              final dt =
                  DateTime.fromMillisecondsSinceEpoch(lastSeen as int);
              if (DateTime.now().difference(dt).inMinutes < 2) online++;
            }
          });
          _instituteKwh = kwh;
          _instituteOnlineDevices = online;
        } else {
          _instituteKwh = 0;
          _instituteOnlineDevices = 0;
        }

        // ── master_devices: assigned count for this institute only ─
        final masterRaw = events[1].snapshot.value;
        if (masterRaw is Map) {
          final data = Map<String, dynamic>.from(masterRaw);
          int assigned = 0;
          data.forEach((id, val) {
            if (val is! Map) return;
            final assignedTo = (val['assignedTo'] ?? '').toString();
            if (assignedTo.startsWith('$code/')) assigned++;
          });
          _instituteAssignedDevices = assigned;
        } else {
          _instituteAssignedDevices = 0;
        }

        // ── this month's institute energy from history ──────────────
        final historyRaw = events[2].snapshot.value;
        if (historyRaw is num) {
          _instituteMonthlyKwh = historyRaw.toDouble();
        } else {
          _instituteMonthlyKwh = 0;
        }
      });
    }, onError: (Object error) {
      debugPrint('[DashboardWeb] Institute-scoped listen error: $error');
    });
  }

  void _openBuilding(String code, String name, int floors) {
    setState(() {
      _viewingBuilding = {
        'buildingCode': code,
        'buildingName': name,
        'floors': floors,
      };
      _viewingDevice = null;
    });
  }

  // ── Building management (super admins) ───────────────────────────────
  // Same Firebase writes as mobile dashboard_screen.dart. `ctx` must sit
  // below the shell's local Theme so dialogs pick up the web styling.

  static final _buildingCodePattern = RegExp(r'^[A-Z0-9]{2,8}$');

  String? _floorsError(String raw) {
    final f = int.tryParse(raw);
    if (f == null || f < 1 || f > 20) return 'Enter a whole number from 1 to 20.';
    return null;
  }

  Future<void> _addBuilding(BuildContext ctx) async {
    final existing = {
      for (final b in vm.buildings) (b['code'] ?? '').toString().toUpperCase()
    };
    String? added;
    await showWebFormDialog(
      context: ctx,
      title: 'Add building',
      okLabel: 'Add',
      fields: const [
        WebField(
            id: 'code', label: 'Building code', hint: 'e.g. CLINIC', uppercase: true),
        WebField(id: 'name', label: 'Building name', hint: 'e.g. Clinic Building'),
        WebField(
            id: 'floors',
            label: 'Floors',
            initial: '1',
            keyboardType: TextInputType.number),
      ],
      onSubmit: (v) async {
        final code = v['code']!.toUpperCase();
        final e = <String, String>{};
        if (code.isEmpty) {
          e['code'] = 'Building code is required.';
        } else if (!_buildingCodePattern.hasMatch(code)) {
          e['code'] = 'Use 2–8 letters or numbers, no spaces.';
        } else if (existing.contains(code)) {
          e['code'] = 'That code already exists.';
        }
        if (v['name']!.isEmpty) e['name'] = 'Building name is required.';
        final fe = _floorsError(v['floors']!);
        if (fe != null) e['floors'] = fe;
        if (e.isNotEmpty) return e;
        await FirebaseDatabase.instance.ref('buildings/$code').set({
          'name': v['name'],
          'floors': int.parse(v['floors']!),
        });
        added = code;
        return null;
      },
    );
    if (added != null && ctx.mounted) TopToast.show(ctx, '$added added.');
  }

  Future<void> _editBuilding(
      BuildContext ctx, String code, String name, int floors) async {
    final ok = await showWebFormDialog(
      context: ctx,
      title: 'Edit building',
      subtitle: code,
      fields: [
        WebField(id: 'name', label: 'Building name', initial: name),
        WebField(
            id: 'floors',
            label: 'Floors',
            initial: '$floors',
            keyboardType: TextInputType.number),
      ],
      onSubmit: (v) async {
        final e = <String, String>{};
        if (v['name']!.isEmpty) e['name'] = 'Building name is required.';
        final fe = _floorsError(v['floors']!);
        if (fe != null) e['floors'] = fe;
        if (e.isNotEmpty) return e;
        await FirebaseDatabase.instance.ref('buildings/$code').update({
          'name': v['name'],
          'floors': int.parse(v['floors']!),
        });
        return null;
      },
    );
    if (ok && ctx.mounted) TopToast.show(ctx, '$code updated.');
  }

  Future<void> _deleteBuilding(BuildContext ctx, String code, String name) async {
    final db = FirebaseDatabase.instance;
    final assigned = <String>{};
    final devicesSnap = await db.ref('devices').get();
    if (devicesSnap.value is Map) {
      (devicesSnap.value as Map).forEach((id, val) {
        if (val is Map && (val['building'] ?? '').toString() == code) {
          assigned.add(id.toString());
        }
      });
    }
    final masterSnap = await db.ref('master_devices').get();
    if (masterSnap.value is Map) {
      (masterSnap.value as Map).forEach((id, val) {
        if (val is Map &&
            (val['assignedTo'] ?? '').toString().startsWith('$code/')) {
          assigned.add(id.toString());
        }
      });
    }
    if (!ctx.mounted) return;
    final n = assigned.length;
    final ok = await showWebConfirmDialog(
      context: ctx,
      title: 'Delete building?',
      message: n > 0
          ? '$name and its $n assigned device${n == 1 ? '' : 's'} will be '
              "unassigned, and its map zone removed. This can't be undone."
          : "$name and its map zone will be removed. This can't be undone.",
      onConfirm: () async {
        final updates = <String, dynamic>{
          'buildings/$code': null,
          'hotspots/$code': null,
        };
        for (final id in assigned) {
          updates['master_devices/$id/assignedTo'] = '';
          updates['devices/$id/building'] = '';
          updates['devices/$id/floor'] = '';
          updates['devices/$id/room'] = '';
          updates['devices/$id/status'] = 'offline';
        }
        await db.ref().update(updates);
      },
    );
    if (ok && ctx.mounted) {
      TopToast.show(
          ctx,
          n > 0
              ? '$code removed. $n device${n == 1 ? '' : 's'} unassigned.'
              : '$code removed.');
    }
  }

  void _openDevice(String deviceId, String utility, String building,
      String room, int floor) {
    setState(() {
      _viewingDevice = {
        'deviceId': deviceId,
        'utility': utility,
        'building': building,
        'room': room,
        'floor': floor,
      };
    });
  }

  void _closeBuilding() => setState(() {
        _viewingBuilding = null;
        _viewingDevice = null;
      });

  void _closeDevice() => setState(() => _viewingDevice = null);

  bool get _isDrilledDown => _viewingBuilding != null || _viewingDevice != null;

  void _selectTab(int index) => setState(() {
        _selectedIndex = index;
        _viewingBuilding = null;
        _viewingDevice = null;
      });

  bool get _isSuperAdmin =>
      _role == 'main_admin' || _role == 'admin' || _role == 'super_admin';
  bool get _isInstituteAdmin => _role == 'institute_admin';
  bool get _canAccessManagement => _isSuperAdmin || _isInstituteAdmin;

  /// Resolution lives centrally in `InstituteTheme.resolve` (see
  /// theme/institute_colors.dart). Called directly rather than via
  /// `context.institutePalette`, because this State's own `context` sits
  /// above the local `Theme` that `build()` creates.
  InstitutePalette get _palette =>
      InstituteTheme.resolve(_role, _institute).palette;

  Future<void> _loadRoleIfNeeded() async {
    final routeRole = widget.role?.trim();
    if (routeRole != null && routeRole.isNotEmpty) {
      _role = routeRole.toLowerCase();
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/login');
      return;
    }

    try {
      final snap =
          await FirebaseDatabase.instance.ref('users/${user.uid}').get();
      if (!snap.exists || snap.value is! Map) {
        debugPrint('[DashboardWeb] users/${user.uid} missing or not a map; '
            'keeping default role "$_role"');
        return;
      }
      final data = Map<String, dynamic>.from(snap.value as Map);
      if (!mounted) return;
      setState(() {
        _role = (data['role'] as String? ?? _role).toLowerCase();
        _institute = (data['institute'] as String?)?.trim();
      });
      if (_isInstituteAdmin) {
        _listenInstituteScoped();
      }
    } catch (e) {
      debugPrint('[DashboardWeb] Failed to load role for ${user.uid}: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    vm = DashboardViewModel();
    vm.initialize();
    _loadRoleIfNeeded();
  }

  @override
  void dispose() {
    vm.disposeViewModel();
    _instituteSub?.cancel();
    super.dispose();
  }

  bool _showNotificationPanel = false;

  void _toggleNotificationPanel() {
    final opening = !_showNotificationPanel;
    setState(() => _showNotificationPanel = opening);
    if (opening) vm.markNotificationsSeen();
  }

  @override
  Widget build(BuildContext context) {
    final palette = _palette;
    final showAnalytics = !_isInstituteAdmin;
    final showManagement = _canAccessManagement;
    final showUserManagement = _isSuperAdmin || _isInstituteAdmin;
    final safeIndex = (!showAnalytics && _selectedIndex == _tabAnalytics) ||
            (!showManagement && _selectedIndex == _tabSettings) ||
            (!showUserManagement && _selectedIndex == _tabUsers)
        ? _tabDashboard
        : _selectedIndex;

    // A soft neutral page wash tinted by the palette -- lets the white
    // cards (and the gradient hero card on the Devices tab) read clearly.
    final pageBg = Color.alphaBlend(
      palette.pale.withAlpha(60),
      const Color(0xFFF6F8F7),
    );

    // Web typography (app font, readable muted text)
    // plus the resolved InstituteTheme extension for descendants.
    return Theme(
      data: webTheme(Theme.of(context)).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: Scaffold(
        backgroundColor: pageBg,
        body: SafeArea(
          child: Row(
            // Stretch pins both the side nav and the content pane to the
            // full height, so the header position never floats.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSideNav(palette, safeIndex, showAnalytics, showManagement,
                  showUserManagement),
              Expanded(
                child: Stack(
                  children: [
                    _buildContentArea(
                        safeIndex, showManagement, showUserManagement),
                    if (_showNotificationPanel)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () =>
                              setState(() => _showNotificationPanel = false),
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                    // Floating overlays level with each screen's title row:
                    // the bell on every tab, the role badge (the app's only
                    // role tag) on the Dashboard tab only.
                    if (safeIndex == _tabDashboard && !_isDrilledDown)
                      Positioned(
                        top: 22,
                        right: 76,
                        child: _buildRoleBadge(),
                      ),
                    Positioned(
                      top: 12,
                      right: 20,
                      child: _buildNotificationBell(palette),
                    ),
                    if (_showNotificationPanel)
                      Positioned(
                        top: 60,
                        right: 20,
                        child: _buildNotificationPanel(),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navSectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Text(
          text,
          style: TextStyle(
            color: Colors.white.withAlpha(140),
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
          ),
        ),
      );

  /// The floating, rounded side nav (reference-style): brand block, MAIN /
  /// MANAGE groups, a white info card and Logout pinned to the bottom.
  Widget _buildSideNav(InstitutePalette palette, int safeIndex,
      bool showAnalytics, bool showManagement, bool showUserManagement) {
    bool active(int i) => safeIndex == i && !_isDrilledDown;
    Widget item(IconData icon, String label, int index) => _SideNavButton(
          icon: icon,
          label: label,
          activeColor: palette.dark,
          isActive: active(index),
          onTap: () => _selectTab(index),
        );

    return Container(
      width: 248,
      margin: const EdgeInsets.fromLTRB(16, 16, 0, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            palette.dark,
            Color.lerp(palette.dark, palette.mid, 0.45)!,
          ],
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: palette.dark.withAlpha(64),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 22, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Column(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(38),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withAlpha(50)),
                  ),
                  child: Image.asset(
                    'promo/img/logo.png',
                    fit: BoxFit.contain,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Smart Switch',
                  style: TextStyle(
                    fontFamily: AppFonts.family,
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Campus Energy Monitor',
                  style: TextStyle(
                    color: Colors.white.withAlpha(170),
                    fontSize: 12,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _navSectionLabel('MAIN'),
                  item(Icons.space_dashboard_outlined, 'Dashboard',
                      _tabDashboard),
                  item(Icons.devices_other_outlined, 'Devices', _tabDevices),
                  item(Icons.map_outlined, 'Map', _tabMap),
                  if (showAnalytics)
                    item(Icons.insights_outlined, 'Analytics', _tabAnalytics),
                  item(Icons.schedule_outlined, 'Automation', _tabAutomation),
                  if (showManagement || showUserManagement) ...[
                    const SizedBox(height: 14),
                    _navSectionLabel('MANAGE'),
                  ],
                  if (showUserManagement)
                    item(Icons.admin_panel_settings_outlined, 'Manage Users',
                        _tabUsers),
                  if (showManagement)
                    item(Icons.settings_outlined, 'Settings', _tabSettings),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _SideNavButton(
              icon: Icons.logout_rounded,
              label: 'Logout',
              activeColor: palette.dark,
              onTap: () async {
                await AutomationSchedulerService.stop();
                await FirebaseAuth.instance.signOut();
                if (!mounted) return;
                Navigator.pushReplacementNamed(context, '/login');
              },
            ),
          ],
        ),
      ),
    );
  }

  /// The area to the right of the side nav: normally the tab [IndexedStack],
  /// swapped in-place for the building-floor / device-detail drill-down.
  Widget _buildContentArea(
      int safeIndex, bool showManagement, bool showUserManagement) {
    if (_viewingDevice != null) {
      final d = _viewingDevice!;
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
        child: DeviceDetailScreenWeb(
          key: ValueKey('device-${d['deviceId']}'),
          deviceId: d['deviceId'] as String,
          utility: d['utility'] as String,
          building: d['building'] as String,
          room: d['room'] as String,
          floor: d['floor'] as int,
          role: _role,
          onBack: _closeDevice,
        ),
      );
    }

    if (_viewingBuilding != null) {
      final b = _viewingBuilding!;
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
        child: BuildingFloorScreenWeb(
          key: ValueKey('building-${b['buildingCode']}'),
          buildingCode: b['buildingCode'] as String,
          buildingName: b['buildingName'] as String,
          floors: b['floors'] as int,
          role: _role,
          onBack: _closeBuilding,
          onDeviceTap: _openDevice,
        ),
      );
    }

    // Children order MUST match the _tab* constants above.
    return IndexedStack(
      index: safeIndex,
      children: [
        // 0 Dashboard
        _buildOverviewTab(),
        // 1 Map
        CampusMapScreenWeb(
          role: _role,
          onBuildingTap: _openBuilding,
          onDeviceTap: _openDevice,
        ),
        // 2 Analytics
        Padding(
          padding: const EdgeInsets.all(4.0),
          child: ResponsiveCenter(
            maxWidth: 1400,
            child: HistoryScreenWeb(onOpenDevice: _openDevice),
          ),
        ),
        // 3 Automation
        Padding(
          padding: const EdgeInsets.all(4.0),
          child: ResponsiveCenter(
            maxWidth: 1400,
            child: AutomationScreenWeb(role: _role),
          ),
        ),
        // 4 Settings
        if (showManagement)
          const Padding(
            padding: EdgeInsets.all(4.0),
            child: ResponsiveCenter(maxWidth: 1400, child: SettingsScreenWeb()),
          )
        else
          const SizedBox.shrink(),
        // 5 Manage Users
        if (showUserManagement)
          ManageUsersScreenWeb(
            key: ValueKey('users-$_role-$_institute'),
            role: _role,
            institute: _institute,
          )
        else
          const SizedBox.shrink(),
        // 6 Devices (the previous home tab)
        _isInstituteAdmin ? _buildInstituteHomeTab() : _buildHomeTab(),
      ],
    );
  }

  /// The new reference-style Dashboard. Institute admins get the same
  /// layout scoped to their own building.
  Widget _buildOverviewTab() {
    if (_isInstituteAdmin && (_institute ?? '').isEmpty) {
      return _noInstituteMessage();
    }
    return AnimatedBuilder(
      animation: vm,
      builder: (context, _) {
        if (vm.hasError) return _buildDashboardError();
        return WebOverviewTab(
          vm: vm,
          palette: _palette,
          instituteCode: _isInstituteAdmin ? _institute : null,
          userName: widget.name,
          onOpenDevices: () => _selectTab(_tabDevices),
          onOpenAnalytics:
              _isInstituteAdmin ? null : () => _selectTab(_tabAnalytics),
          onBuildingTap: _openBuilding,
        );
      },
    );
  }

  Widget _noInstituteMessage() => const Center(
        child: Padding(
          padding: EdgeInsets.all(40.0),
          child: Text(
            'Your account has no institute assigned yet.\nAsk your main admin to assign one.',
            textAlign: TextAlign.center,
            style: TextStyle(color: WebColors.muted),
          ),
        ),
      );

  /// Web equivalent of mobile's top-bar role badge.
  Widget _buildRoleBadge() {
    final IconData icon;
    final String label;
    final Color color;
    final bool highlighted;
    if (_isSuperAdmin) {
      icon = Icons.star;
      label = 'Super Admin';
      color = _palette.dark;
      highlighted = true;
    } else if (_isInstituteAdmin) {
      icon = Icons.school;
      label = 'Institute Admin';
      color = _palette.dark;
      highlighted = true;
    } else {
      icon = Icons.person;
      label = 'Member';
      color = WebColors.muted;
      highlighted = false;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: highlighted ? _palette.pale : AppColors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: highlighted ? _palette.mid.withAlpha(90) : Colors.black12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(15),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }

  Widget _buildNotificationBell(InstitutePalette palette) {
    final count = vm.unreadNotificationCount;
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 4,
      shadowColor: Colors.black26,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _toggleNotificationPanel,
        child: Padding(
          padding: const EdgeInsets.all(10.0),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(Icons.notifications_outlined, color: palette.dark, size: 22),
              if (count > 0)
                Positioned(
                  right: -3,
                  top: -3,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    constraints: const BoxConstraints(minWidth: 16),
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: Text(
                      count > 99 ? '99+' : '$count',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNotificationPanel() {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 400,
        height: 520,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(40),
              blurRadius: 30,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              decoration: BoxDecoration(
                color: AppColors.cardBg,
                border: Border(
                  bottom: BorderSide(color: _palette.mid.withAlpha(26)),
                ),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Notifications',
                      style: TextStyle(
                        fontFamily: AppFonts.family,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textDark,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () =>
                        setState(() => _showNotificationPanel = false),
                  ),
                ],
              ),
            ),
            const Expanded(child: NotificationsScreenWeb()),
          ],
        ),
      ),
    );
  }

  /// The "Devices" tab for everyone but institute admins (previously the
  /// home tab): hero energy card, campus building grid, recent entries.
  Widget _buildHomeTab() {
    return AnimatedBuilder(
      animation: vm,
      builder: (context, _) {
        if (vm.hasError) {
          return _buildDashboardError();
        }
        final buildingsEmpty = vm.buildings.isEmpty && vm.isLoading;
        final displayBuildings =
            buildingsEmpty ? placeholderBuildingList() : vm.buildings;
        final canManage = _isSuperAdmin && !buildingsEmpty;
        return ScreenSkeleton(
          isLoading: vm.isLoading,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: ResponsiveCenter(
              maxWidth: 1240,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Devices',
                    style: TextStyle(
                        fontFamily: AppFonts.family,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textDark),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Buildings, device counts and recent readings',
                    style: TextStyle(fontSize: 13, color: WebColors.muted),
                  ),
                  const SizedBox(height: 24),
                  _EnergyOverviewCard(
                    palette: _palette,
                    totalKwh: vm.totalKwh,
                    monthlyCostPhp: vm.monthlyCostPhp,
                    assignedDevices: vm.assignedDevices,
                    unassignedDevices: vm.unassignedDevices,
                  ),
                  const SizedBox(height: 28),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Campus Buildings',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textDark)),
                      const Spacer(),
                      Text('${displayBuildings.length} buildings',
                          style: const TextStyle(color: WebColors.muted)),
                      if (_isSuperAdmin) ...[
                        const SizedBox(width: 12),
                        Builder(
                          builder: (ctx) => WebIconButton(
                            icon: Icons.add_rounded,
                            tooltip: 'Add building',
                            solid: true,
                            onPressed: () => _addBuilding(ctx),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (displayBuildings.isEmpty)
                    _emptyCard('No buildings yet')
                  else
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final crossAxisCount = responsiveColumnCount(
                          constraints.maxWidth,
                          mobileColumns: 1,
                          idealTileWidth: 260,
                          maxColumns: 4,
                        );
                        return GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossAxisCount,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 16,
                            childAspectRatio: 1.35,
                          ),
                          itemCount: displayBuildings.length,
                          itemBuilder: (context, i) {
                            final b = displayBuildings[i];
                            final code = (b['code'] ?? '').toString();
                            final name = (b['name'] ?? code).toString();
                            final floors = (b['floors'] ?? 1).toString();
                            final devices = vm.buildingDeviceCounts[code] ?? 0;
                            final kwh = vm.buildingEnergy[code] ?? 0.0;
                            final level = _energyLevelForValue(kwh);
                            final color = _energyColorForLevel(level);
                            return _WebBuildingCard(
                              palette: _palette,
                              code: code,
                              name: name,
                              floors: floors,
                              devices: devices,
                              kwh: kwh,
                              role: _role,
                              levelLabel: level,
                              levelColor: color,
                              onTap: () => _openBuilding(
                                  code, name, int.tryParse(floors) ?? 1),
                              onEdit: canManage
                                  ? (ctx) => _editBuilding(ctx, code, name,
                                      int.tryParse(floors) ?? 1)
                                  : null,
                              onDelete: canManage
                                  ? (ctx) => _deleteBuilding(ctx, code, name)
                                  : null,
                            );
                          },
                        );
                      },
                    ),
                  const SizedBox(height: 28),
                  _buildRecentEntriesCard(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRecentEntriesCard() {
    final historyEmpty = vm.historyData.isEmpty && vm.isLoading;
    final displayHistory =
        historyEmpty ? placeholderHistoryList() : vm.historyData;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: displayHistory.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text('No data yet',
                    style: TextStyle(color: WebColors.muted)),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Recent entries',
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: AppColors.textDark)),
                    TextButton(
                      onPressed: () => _selectTab(_tabAnalytics),
                      child: Text('View full analytics',
                          style: TextStyle(color: _palette.dark)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ...displayHistory.reversed.take(5).map(
                      (e) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                                child: Text(e['label'],
                                    style: const TextStyle(
                                        color: AppColors.textDark))),
                            Text(
                              '${(e['kwh'] as num).toDouble().toStringAsFixed(2)} kWh',
                              style:
                                  const TextStyle(color: WebColors.muted),
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
    );
  }

  /// Shown in place of a tab's content (side nav stays put) when
  /// [DashboardViewModel.hasError] is true.
  Widget _buildDashboardError() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: ResponsiveCenter(
        maxWidth: 1240,
        child: Container(
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
              const Text('Cannot load dashboard',
                  style: TextStyle(
                      fontFamily: AppFonts.family,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textDark)),
              const SizedBox(height: 8),
              Text(vm.errorMessage ?? 'Something went wrong.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 14, color: WebColors.muted)),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: vm.retry,
                icon: const Icon(Icons.refresh, color: Colors.white, size: 18),
                label:
                    const Text('Retry', style: TextStyle(color: Colors.white)),
                style: ElevatedButton.styleFrom(
                    backgroundColor: _palette.dark,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _emptyCard(String text) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(text, style: const TextStyle(color: WebColors.muted)),
      );

  /// An institute admin's "Devices" tab: the institute-scoped summary card
  /// embedded above their institute's rooms (see BuildingFloorScreenWeb's
  /// `embeddedSummaryCard`).
  Widget _buildInstituteHomeTab() {
    return AnimatedBuilder(
      animation: vm,
      builder: (context, _) {
        if (vm.hasError) {
          return _buildDashboardError();
        }
        final code = _institute ?? '';
        if (code.isEmpty) {
          return _noInstituteMessage();
        }
        final match = vm.buildings.firstWhere(
          (b) => (b['code'] ?? '').toString() == code,
          orElse: () => <String, dynamic>{},
        );
        final floors = (match['floors'] as int?) ?? 1;
        final name = (match['name'] as String?) ?? code;
        return BuildingFloorScreenWeb(
          key: ValueKey('dash-institute-$code'),
          buildingCode: code,
          buildingName: name,
          floors: floors,
          role: _role,
          showBackButton: false,
          onDeviceTap: _openDevice,
          showDashboardSummary: false,
          showRoleBadge: false,
          embeddedSummaryCard: _InstituteSummaryCard(
            palette: _palette,
            kwh: _instituteKwh,
            monthlyCostPhp: _instituteMonthlyKwh * vm.electricityRate,
            assignedDevices: _instituteAssignedDevices,
            onlineDevices: _instituteOnlineDevices,
          ),
        );
      },
    );
  }
}

String _energyLevelForValue(double kwh) {
  if (kwh >= 100) return 'HIGH';
  if (kwh >= 50) return 'MID';
  return 'LOW';
}

Color _energyColorForLevel(String level) {
  switch (level) {
    case 'HIGH':
      return AppColors.error;
    case 'MID':
      return AppColors.warning;
    default:
      return AppColors.greenMid;
  }
}

/// The institute admin Devices tab's summary card: headline kWh + 3
/// mini-stats on a palette gradient. Every value passed in must already be
/// filtered to the viewer's institute.
class _InstituteSummaryCard extends StatelessWidget {
  final InstitutePalette palette;
  final double kwh;
  final double monthlyCostPhp;
  final int assignedDevices;
  final int onlineDevices;

  const _InstituteSummaryCard({
    required this.palette,
    required this.kwh,
    required this.monthlyCostPhp,
    required this.assignedDevices,
    required this.onlineDevices,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [palette.dark, palette.mid],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: palette.dark.withAlpha(77),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Energy consumed today',
            style: TextStyle(
              fontSize: 14,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                kwh.toStringAsFixed(2),
                style: const TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 38,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 6, left: 6),
                child: Text(
                  'kWh',
                  style: TextStyle(
                    fontSize: 15,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Container(height: 1, color: Colors.white.withAlpha(51)),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _miniStat(Icons.payments_outlined, 'Month Cost',
                    '₱ ${monthlyCostPhp.toStringAsFixed(0)}'),
              ),
              _divider(),
              Expanded(
                child: _miniStat(Icons.check_circle_outline, 'Assigned',
                    '$assignedDevices devices'),
              ),
              _divider(),
              Expanded(
                child: _miniStat(Icons.wifi_tethering, 'Online',
                    '$onlineDevices devices'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _divider() => Container(
        width: 1,
        height: 34,
        margin: const EdgeInsets.symmetric(horizontal: 16),
        color: Colors.white.withAlpha(60),
      );

  Widget _miniStat(IconData icon, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 13, color: Colors.white70),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}

/// The Devices tab's energy summary for main/super admins: today's kWh as
/// the headline, with month cost and device counts underneath.
class _EnergyOverviewCard extends StatelessWidget {
  final InstitutePalette palette;
  final double totalKwh;
  final double monthlyCostPhp;
  final int assignedDevices;
  final int unassignedDevices;

  const _EnergyOverviewCard({
    required this.palette,
    required this.totalKwh,
    required this.monthlyCostPhp,
    required this.assignedDevices,
    required this.unassignedDevices,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [palette.dark, palette.mid],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: palette.dark.withAlpha(77),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(46),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.bolt, size: 18, color: Colors.white),
              ),
              const SizedBox(width: 12),
              const Text(
                'Energy consumed today',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                totalKwh.toStringAsFixed(2),
                style: const TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 38,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 6, left: 6),
                child: Text(
                  'kWh',
                  style: TextStyle(
                    fontSize: 15,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Container(height: 1, color: Colors.white.withAlpha(51)),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _miniStat(Icons.payments_outlined, 'Month Cost',
                    '₱ ${monthlyCostPhp.toStringAsFixed(0)}'),
              ),
              _divider(),
              Expanded(
                child: _miniStat(Icons.check_circle_outline, 'Assigned',
                    '$assignedDevices devices'),
              ),
              _divider(),
              Expanded(
                child: _miniStat(Icons.device_unknown_outlined, 'Unassigned',
                    '$unassignedDevices devices'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _divider() => Container(
        width: 1,
        height: 34,
        margin: const EdgeInsets.symmetric(horizontal: 16),
        color: Colors.white.withAlpha(60),
      );

  Widget _miniStat(IconData icon, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 13, color: Colors.white70),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}

class _WebBuildingCard extends StatelessWidget {
  final InstitutePalette palette;
  final String code;
  final String name;
  final String floors;
  final int devices;
  final double kwh;
  final String role;
  final String levelLabel;
  final Color levelColor;
  final VoidCallback onTap;

  /// Null hides the edit / delete buttons (non-admin viewers).
  final void Function(BuildContext context)? onEdit;
  final void Function(BuildContext context)? onDelete;

  const _WebBuildingCard({
    required this.palette,
    required this.code,
    required this.name,
    required this.floors,
    required this.devices,
    required this.kwh,
    required this.role,
    required this.levelLabel,
    required this.levelColor,
    required this.onTap,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(16),
          // `levelColor` below is the HIGH/MID/LOW severity indicator, a
          // semantic color, not brand chrome.
          border: Border.all(color: palette.mid.withAlpha(20)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Tooltip(
                  message: code,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: palette.pale,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.apartment_rounded,
                        size: 22, color: palette.dark),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: levelColor.withAlpha(26),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: levelColor.withAlpha(77)),
                  ),
                  child: Text(
                    levelLabel,
                    style: TextStyle(
                      color: levelColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
                const Spacer(),
                if (onEdit != null)
                  WebIconButton(
                    icon: Icons.edit_outlined,
                    tooltip: 'Edit building',
                    size: 32,
                    onPressed: () => onEdit!(context),
                  ),
                if (onDelete != null) ...[
                  const SizedBox(width: 6),
                  WebIconButton(
                    icon: Icons.delete_outline_rounded,
                    tooltip: 'Delete building',
                    size: 32,
                    danger: true,
                    onPressed: () => onDelete!(context),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textDark,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '$code · $floors ${floors == '1' ? 'floor' : 'floors'} · $devices devices',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: WebColors.muted,
                fontSize: 13,
              ),
            ),
            const Spacer(),
            Text(
              '${kwh.toStringAsFixed(1)} kWh this month',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.textDark,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
