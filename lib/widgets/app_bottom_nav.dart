import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/institute_colors.dart';

/// One of the app's 5 bottom-nav destinations (handoff §2: "Home · Devices
/// · Analytics · Automation · More" for both campus admin and institute
/// admin -- the same 5 tabs).
enum AppNavTab { home, devices, analytics, automation, more }

class _NavTabSpec {
  const _NavTabSpec(this.icon, this.activeIcon, this.label);
  final IconData icon;
  final IconData activeIcon;
  final String label;
}

const Map<AppNavTab, _NavTabSpec> _kNavSpecs = {
  AppNavTab.home: _NavTabSpec(Icons.home_outlined, Icons.home, 'Home'),
  AppNavTab.devices: _NavTabSpec(
      Icons.devices_other_outlined, Icons.devices_other, 'Devices'),
  AppNavTab.analytics:
      _NavTabSpec(Icons.insights_outlined, Icons.insights, 'Analytics'),
  AppNavTab.automation:
      _NavTabSpec(Icons.schedule_outlined, Icons.schedule, 'Automation'),
  AppNavTab.more: _NavTabSpec(Icons.menu, Icons.menu, 'More'),
};

/// The redesign's bottom nav (handoff §2/§3.2/§3.7, preview `bnav()`): 5
/// tabs, active tab = a white pill with a 1.5px institute-color ring, icon +
/// label colored in the institute's 700 [InstitutePalette.dark]; inactive
/// tabs use [AppColors.inkMid].
class AppBottomNav extends StatelessWidget {
  const AppBottomNav({
    super.key,
    required this.selected,
    required this.onSelect,
    this.palette,
    this.hiddenTabs = const {},
  });

  final AppNavTab selected;
  final ValueChanged<AppNavTab> onSelect;
  final InstitutePalette? palette;

  /// Tabs to omit entirely (not just disable) -- e.g. a future screen that
  /// hides Analytics for a role that shouldn't see it.
  final Set<AppNavTab> hiddenTabs;

  @override
  Widget build(BuildContext context) {
    final resolvedPalette = palette ?? context.institutePalette;
    final tabs = AppNavTab.values.where((t) => !hiddenTabs.contains(t)).toList();

    return Container(
      height: 80,
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: resolvedPalette.line, width: 1)),
      ),
      child: Row(
        children: [
          for (final tab in tabs)
            Expanded(
              child: _NavItem(
                spec: _kNavSpecs[tab]!,
                active: tab == selected,
                palette: resolvedPalette,
                onTap: () => onSelect(tab),
              ),
            ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.spec,
    required this.active,
    required this.palette,
    required this.onTap,
  });

  final _NavTabSpec spec;
  final bool active;
  final InstitutePalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? palette.dark : AppColors.inkMid;
    return Semantics(
      button: true,
      selected: active,
      label: spec.label,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                border: active ? Border.all(color: palette.dark, width: 1.5) : null,
              ),
              child: Icon(active ? spec.activeIcon : spec.icon, color: color, size: 24),
            ),
            const SizedBox(height: 4),
            Text(
              spec.label,
              style: TextStyle(
                fontSize: 12,
                height: 16 / 12,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
