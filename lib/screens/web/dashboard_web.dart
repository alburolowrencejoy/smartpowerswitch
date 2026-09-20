import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:rxdart/rxdart.dart';

import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../utils/placeholder_data.dart';
import '../../viewmodels/dashboard_viewmodel.dart';
import '../../widgets/responsive_center.dart';
import '../../widgets/screen_skeleton.dart';
import 'automation_screen_web.dart';
import 'building_floor_screen_web.dart';
import '../shared/campus_map_screen.dart';
import 'device_detail_screen_web.dart';
import 'history_screen_web.dart';
import '../shared/manage_users_screen.dart';
import 'notifications_screen_web.dart';
import 'settings_screen_web.dart';

/// The desktop/wide-window dashboard shell: a fixed side nav plus a
/// content area, chosen over [DashboardScreen] by `DashboardPage` once the
/// window is wide enough. Shares [DashboardViewModel], the same Firebase
/// data, and the same routes/roles as the mobile dashboard -- only the
/// layout is desktop-native (grid of capped-width cards instead of a
/// stacked full-bleed column).
class DesktopDashboardScreen extends StatefulWidget {
  final String? role;
  final String? name;

  const DesktopDashboardScreen({super.key, this.role, this.name});

  @override
  State<DesktopDashboardScreen> createState() => _DesktopDashboardScreenState();
}

class _SideNavButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isActive;

  const _SideNavButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isActive = false,
  });

  @override
  State<_SideNavButton> createState() => _SideNavButtonState();
}

class _SideNavButtonState extends State<_SideNavButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final backgroundColor = widget.isActive
        ? Colors.white12
        : _isHovered
            ? Colors.white10
            : null;
    final borderColor = widget.isActive
        ? Colors.white24
        : _isHovered
            ? Colors.white24
            : Colors.transparent;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: backgroundColor,
              border: Border.all(color: borderColor),
            ),
            child: Row(
              children: [
                Icon(
                  widget.icon,
                  color: _isHovered || widget.isActive
                      ? Colors.white
                      : Colors.white70,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.label,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopDashboardScreenState extends State<DesktopDashboardScreen> {
  late final DashboardViewModel vm;
  int _selectedIndex = 0;
  String _role = 'faculty';
  String? _institute;

  // In-place "drill down" view state: when set, these are rendered instead
  // of the tab IndexedStack in the content area to the right of the side
  // nav -- so navigating into a building/device never pops out of the
  // desktop shell (unlike the old Navigator.pushNamed('/building' | '/device')
  // full-screen routes, which have no side nav at all).
  Map<String, dynamic>? _viewingBuilding;
  Map<String, dynamic>? _viewingDevice;

  // ── Institute-scoped summary (institute_admin home tab only) ──────────
  // Populated by _listenInstituteScoped(), filtered strictly to `_institute`
  // -- never derived from `vm`'s system-wide totals, which are also shared
  // by main-admin's `_buildHomeTab()`. Mirrors mobile dashboard_screen.dart's
  // `_listenInstituteScoped()`/`_buildInstituteEnergyCard()` field-filtering
  // pattern exactly; this is a standalone listener, not an extension of the
  // shared `DashboardViewModel` (which has zero institute-awareness).
  double _instituteKwh = 0.0;
  double _instituteMonthlyKwh = 0.0;
  int _instituteAssignedDevices = 0;
  int _instituteOnlineDevices = 0;
  StreamSubscription? _instituteSub;

  String _monthKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';

  /// Institute-scoped combined listener (institute_admin only), mirroring
  /// mobile dashboard_screen.dart's `_listenInstituteScoped()`: `devices`
  /// filtered by `building == _institute` for today's kWh + online count
  /// (same <2min last_seen online window mobile uses), `master_devices`
  /// filtered by `assignedTo` starting with `"$code/"` for the assigned
  /// count, and `history/monthly/{monthKey}/buildings/{code}/kwh` for this
  /// month's institute energy (paired with `vm.electricityRate`, already
  /// tracked by the shared view model, for Month Cost). Every number here is
  /// scoped to `_institute` only -- never system-wide.
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

  /// Resolution now lives centrally in `InstituteTheme.resolve` (see
  /// theme/institute_colors.dart) instead of being recomputed here -- this
  /// mirrors the fix already applied to the mobile dashboard's `_palette`.
  /// Note this deliberately calls `InstituteTheme.resolve` directly rather
  /// than `context.institutePalette`: `build()` below wraps its *returned*
  /// subtree in a local `Theme` carrying the resolved `InstituteTheme`
  /// extension, but this State's own `context` sits above that locally
  /// created `Theme` in the element tree, so a lookup from here would never
  /// see it and would silently fall back to green.
  InstitutePalette get _palette =>
      InstituteTheme.resolve(_role, _institute).palette;

  Future<void> _loadRoleIfNeeded() async {
    // Route arguments (from the login screen) are a fast first paint, but
    // an institute admin's `institute` field only lives in Firebase, so we
    // always follow up with a real fetch rather than short-circuiting here.
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
      // Keep the default faculty role if role hydration fails, but log it so
      // permission-denied reads on users/{uid} are visible in the console.
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
    final safeIndex = (!showAnalytics && _selectedIndex == 2) ||
            (!showManagement && _selectedIndex == 4) ||
            (!showUserManagement && _selectedIndex == 5)
        ? 0
        : _selectedIndex;

    // Local theme override carrying the resolved InstituteTheme extension,
    // so any genuine descendant widget (its own BuildContext, below this
    // point in the tree) can read `context.institutePalette`. This State's
    // own `_palette` getter does not rely on this -- see its doc comment.
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: Scaffold(
        // Institute-admin's tab (and its own building drill-down, same
        // Scaffold) goes white so the new institute-scoped summary card's
        // gradient fill reads clearly against the page; main-admin keeps
        // the palette.pale wash exactly as before -- keyed off the same
        // `_isInstituteAdmin` flag that already picks the tab below.
        backgroundColor: _isInstituteAdmin ? AppColors.cardBg : palette.pale,
        body: SafeArea(
          child: Row(
            // Row defaults to centering children on the cross (vertical) axis,
            // which let the content pane's height float with its own content
            // instead of locking to the full window height -- shorter content
            // (fewer room rows) ended up vertically centered with a bigger gap
            // above it than taller content. Stretch pins both the side nav and
            // the content pane to the full height, so the header position is
            // fixed regardless of how much content follows it.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 260,
                color: palette.dark,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Image.asset(
                              'promo/img/logo.png',
                              fit: BoxFit.contain,
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'Smart Switch',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Divider(color: Colors.white24),
                      const SizedBox(height: 8),
                      _SideNavButton(
                        icon: Icons.dashboard,
                        label: 'Dashboard',
                        onTap: () => _selectTab(0),
                        isActive: safeIndex == 0 && !_isDrilledDown,
                      ),
                      _SideNavButton(
                        icon: Icons.map,
                        label: 'Map',
                        onTap: () => _selectTab(1),
                        isActive: safeIndex == 1 && !_isDrilledDown,
                      ),
                      if (showAnalytics)
                        _SideNavButton(
                          icon: Icons.bar_chart,
                          label: 'Analytics',
                          onTap: () => _selectTab(2),
                          isActive: safeIndex == 2 && !_isDrilledDown,
                        ),
                      _SideNavButton(
                        icon: Icons.schedule,
                        label: 'Automation',
                        onTap: () => _selectTab(3),
                        isActive: safeIndex == 3 && !_isDrilledDown,
                      ),
                      if (showManagement || showUserManagement) ...[
                        const SizedBox(height: 8),
                        const Divider(color: Colors.white24),
                        const SizedBox(height: 8),
                      ],
                      if (showUserManagement)
                        _SideNavButton(
                          icon: Icons.admin_panel_settings_outlined,
                          label: 'Manage Users',
                          onTap: () => _selectTab(5),
                          isActive: safeIndex == 5 && !_isDrilledDown,
                        ),
                      if (showManagement)
                        _SideNavButton(
                          icon: Icons.settings_outlined,
                          label: 'Settings',
                          onTap: () => _selectTab(4),
                          isActive: safeIndex == 4 && !_isDrilledDown,
                        ),
                      const Spacer(),
                      _SideNavButton(
                        icon: Icons.logout,
                        label: 'Logout',
                        onTap: () async {
                          await FirebaseAuth.instance.signOut();
                          if (!context.mounted) return;
                          Navigator.pushReplacementNamed(context, '/login');
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
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
                    // Floating overlay, not a layout row -- so it never pushes
                    // tab content down (that caused clipping) and its position
                    // never depends on that content's height. Sits roughly
                    // level with each screen's own title row (they all use
                    // ~20-24px top padding) so it reads as "inline" with it.
                    // Role badge, matching mobile's top-bar `_roleBadge()`
                    // (dashboard_screen.dart) -- the web shell has no single
                    // global top bar (side nav + per-tab content instead), so
                    // this is placed as a floating overlay just left of the
                    // notification bell, visible on every tab like mobile's
                    // version, rather than duplicated per-tab.
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

  /// The area to the right of the side nav: normally the tab [IndexedStack],
  /// but swapped in-place for the building-floor / device-detail "drill
  /// down" views when one is active -- so the side nav (and everything
  /// else in the shell) stays put instead of pushing a full-screen route.
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

    return IndexedStack(
      index: safeIndex,
      children: [
        _isInstituteAdmin ? _buildInstituteHomeTab() : _buildHomeTab(),
        Padding(
          padding: const EdgeInsets.all(12.0),
          child: CampusMapScreen(
            role: _role,
            showAppBar: false,
            onBuildingTap: _openBuilding,
          ),
        ),
        const Padding(
          padding: EdgeInsets.all(4.0),
          child: ResponsiveCenter(
            maxWidth: 1400,
            child: HistoryScreenWeb(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(4.0),
          child: ResponsiveCenter(
            maxWidth: 1400,
            child: AutomationScreenWeb(role: _role),
          ),
        ),
        if (showManagement)
          const Padding(
            padding: EdgeInsets.all(4.0),
            child: ResponsiveCenter(maxWidth: 1400, child: SettingsScreenWeb()),
          )
        else
          const SizedBox.shrink(),
        if (showUserManagement)
          ResponsiveCenter(
            maxWidth: 1100,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20.0),
              child: ManageUsersScreen(
                role: _role,
                institute: _institute,
              ),
            ),
          )
        else
          const SizedBox.shrink(),
      ],
    );
  }

  /// Web equivalent of mobile's top-bar role badge
  /// (dashboard_screen.dart's `_roleBadge()`), 3-way branched the same way
  /// off `_isSuperAdmin` / `_isInstituteAdmin` -- but with deliberately
  /// different copy for the top two tiers ("Super Admin" instead of
  /// "Admin", "Member" instead of "Faculty", matching the tier labels
  /// `manage_users_screen.dart`'s `_roleLabel()` already uses).
  ///
  /// Unlike mobile, this badge floats over web's light Scaffold background
  /// (see `backgroundColor` in `build()`), not a solid dark top bar -- so
  /// the non-highlighted "Member" tier can't reuse mobile's
  /// white-on-translucent-white styling (unreadable on a light backdrop).
  /// It uses `AppColors.textMuted`/a light grey chip instead, matching the
  /// muted-chrome treatment used elsewhere in this file (e.g.
  /// `_EnergyOverviewCard`'s labels before its gradient-card revert).
  Widget _buildRoleBadge() {
    final IconData icon;
    final String label;
    final Color color;
    final bool highlighted;
    if (_isSuperAdmin) {
      icon = Icons.star;
      label = 'Super Admin';
      color = _palette.light;
      highlighted = true;
    } else if (_isInstituteAdmin) {
      icon = Icons.school;
      label = 'Institute Admin';
      color = _palette.light;
      highlighted = true;
    } else {
      icon = Icons.person;
      label = 'Member';
      color = AppColors.textMuted;
      highlighted = false;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: highlighted ? color.withAlpha(51) : AppColors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: highlighted ? color.withAlpha(102) : Colors.black12),
        boxShadow: highlighted
            ? null
            : [
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
                fontSize: 11, fontWeight: FontWeight.w600, color: color)),
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
                        fontSize: 9,
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
                // Bug fix: this dropdown-style panel's header border was
                // hardcoded to the main-admin green instead of following
                // `_palette`, so an institute-themed viewer (e.g. IC/violet)
                // got a notification bell/side nav that went violet
                // everywhere except this popup, which silently stayed green
                // -- same class of bug as mobile's burger-menu popup.
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
                        fontFamily: 'Outfit',
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

  /// The main "Dashboard" section for everyone but institute admins: a
  /// desktop-grid overview -- a hero energy tile plus stat tiles, a grid of
  /// campus buildings (not a stretched full-width list), and a recent
  /// activity card.
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
                    'Dashboard',
                    style: TextStyle(
                        fontFamily: 'Outfit',
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textDark),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Live overview of campus energy usage',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
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
                      Text('${displayBuildings.length} buildings',
                          style: const TextStyle(color: AppColors.textMuted)),
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
        // Bug fix: was hardcoded green regardless of viewer -- matches
        // mobile's `_buildBuildingCard`/`_buildInstituteEnergyCard` fix,
        // which routes the same card-border tint through `_palette`.
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: displayHistory.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text('No data yet',
                    style: TextStyle(color: AppColors.textMuted)),
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
                      onPressed: () => setState(() => _selectedIndex = 2),
                      // Bug fix: this had no explicit style, so its resting
                      // color fell back to ThemeData's seed-green
                      // ColorScheme.primary (main.dart) regardless of the
                      // viewer's institute -- always green even for a
                      // violet/maroon/gold/blue institute theme. `_palette`
                      // is already resolved for this exact viewer above.
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
                                  const TextStyle(color: AppColors.textMuted),
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
    );
  }

  /// Shown in place of the dashboard's content (side nav stays put) when
  /// [DashboardViewModel.hasError] is true -- either a real stream error or
  /// the load-timeout safety net, both surfaced before any successful load.
  /// Matches the error-card convention used by [AutomationScreenWeb] and
  /// [NotificationsScreenWeb].
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
            // Bug fix: this error card is reachable from both
            // `_buildHomeTab` and `_buildInstituteHomeTab`, so an
            // institute-themed viewer could hit a load error and see a
            // green card here while the side nav/bell stayed per-institute
            // -- matches mobile's `_buildError`, already migrated to
            // `_palette`.
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
                      fontFamily: 'Outfit',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textDark)),
              const SizedBox(height: 8),
              Text(vm.errorMessage ?? 'Something went wrong.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textMuted)),
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
        child: Text(text, style: const TextStyle(color: AppColors.textMuted)),
      );

  /// An institute admin's "Dashboard" tab: an institute-scoped summary card
  /// (`_InstituteSummaryCard`, fed by `_listenInstituteScoped()` -- every
  /// number filtered to `_institute` only, never system-wide) above their
  /// institute's rooms directly, no campus-wide buildings list.
  ///
  /// The summary card is handed to `BuildingFloorScreenWeb` as
  /// `embeddedSummaryCard` rather than stacked above it here -- that keeps
  /// it inside that screen's own `SingleChildScrollView`, alongside the
  /// floor tabs and rooms grid, so it scrolls away with the rest of the
  /// content instead of staying pinned (and getting visually cut off)
  /// above an independently-scrolling rooms list. That screen already
  /// hides the card once a room is selected, matching mobile's behavior of
  /// pushing a full-screen `RoomDevicesScreen` that naturally covers it.
  Widget _buildInstituteHomeTab() {
    return AnimatedBuilder(
      animation: vm,
      builder: (context, _) {
        if (vm.hasError) {
          return _buildDashboardError();
        }
        final code = _institute ?? '';
        if (code.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(40.0),
              child: Text(
                'Your account has no institute assigned yet.\nAsk your main admin to assign one.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted),
              ),
            ),
          );
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

/// The home tab's energy summary: today's kWh as the headline figure, with
/// month cost and device counts as a secondary breakdown row underneath --
/// one cohesive card instead of four separate tiles competing for space.
/// The institute admin home tab's summary card: same headline-kWh +
/// 3-item mini-stat shape as [_EnergyOverviewCard] (main-admin's card), but
/// with a colored/gradient fill using the institute's palette instead of a
/// white background -- matching mobile dashboard_screen.dart's
/// `_buildInstituteEnergyCard()`. Every value passed in must already be
/// filtered to the viewer's institute; this widget does no filtering of its
/// own, see `_DesktopDashboardScreenState._listenInstituteScoped()`.
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Energy consumed today',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              // The role badge building_floor_screen_web.dart's own header
              // used to show (hidden there via `showRoleBadge: false` when
              // embedded below this card) -- this tab only ever renders for
              // an institute_admin viewer, so it's always "Admin".
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(46),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'Admin',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                kwh.toStringAsFixed(2),
                style: const TextStyle(
                  fontFamily: 'Outfit',
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
                style: const TextStyle(fontSize: 11, color: Colors.white70)),
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
        // Restored to the original gradient-fill hero card (green for
        // super/main admin, since `palette` resolves to
        // `InstituteColors.admin`), matching `_InstituteSummaryCard`'s
        // visual language instead of the white-surface/bordered treatment.
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
                  fontSize: 13,
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
                  fontFamily: 'Outfit',
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
                style: const TextStyle(fontSize: 11, color: Colors.white70)),
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
          // Bug fix: was hardcoded green regardless of viewer -- matches
          // mobile's `_buildBuildingCard` fix (card border + code-badge
          // bg/text all route through `_palette`). `levelColor` below is
          // deliberately untouched: it's the HIGH/MID/LOW severity
          // indicator, a semantic color, not brand chrome.
          border: Border.all(color: palette.mid.withAlpha(20)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: palette.pale,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          code,
                          maxLines: 1,
                          softWrap: false,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: palette.dark,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(),
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
                      fontSize: 11,
                    ),
                  ),
                ),
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
              '$floors ${floors == '1' ? 'floor' : 'floors'} · $devices devices',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
              ),
            ),
            const Spacer(),
            Text(
              '${kwh.toStringAsFixed(1)} kWh this month',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.textDark,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
