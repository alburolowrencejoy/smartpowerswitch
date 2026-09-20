import 'package:flutter/material.dart';

import '../mobile/dashboard_screen.dart';
import '../web/dashboard_web.dart';

/// Picks the phone UI or the desktop UI by available width, not by
/// platform -- so a resized browser window, a native Windows/macOS/Linux
/// build, and a tablet in landscape all get the desktop layout once
/// there's room for it, while phones (on any platform) keep the mobile
/// layout. Both layouts share the same Firebase data, roles, and routes;
/// only the UI differs.
class DashboardPage extends StatelessWidget {
  /// Matches the width [ResponsiveCenter] centers content above elsewhere
  /// in the app, widened slightly since the desktop layout also needs room
  /// for the 260px side nav.
  static const double desktopBreakpoint = 900;

  final String? role;
  final String? name;

  const DashboardPage({super.key, this.role, this.name});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= desktopBreakpoint) {
          return DesktopDashboardScreen(role: role, name: name);
        }
        return const DashboardScreen();
      },
    );
  }
}
