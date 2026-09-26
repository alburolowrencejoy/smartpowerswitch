import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'screens/shared/auth_gate.dart';
import 'screens/shared/login_screen.dart';
import 'screens/shared/dashboard_page.dart';
import 'screens/shared/splash_screen.dart';
import 'screens/mobile/building_floor_screen.dart';
import 'screens/web/building_floor_screen_web.dart';
import 'screens/mobile/device_detail_screen.dart';
import 'screens/web/device_detail_screen_web.dart';
import 'screens/mobile/history_screen.dart';
import 'screens/shared/manage_users_screen.dart';
import 'screens/mobile/notifications_screen.dart';
import 'screens/mobile/settings_screen.dart';
import 'screens/mobile/more_screen.dart';
import 'screens/shared/campus_map_screen.dart';
import 'services/runtime_mode_service.dart';
import 'services/device_service.dart';
import 'services/update_notification_service.dart';
import 'services/home_widget_service.dart';
import 'services/global_readings_listener.dart';
import 'services/prediction_service.dart';
import 'theme/app_colors.dart';
import 'widgets/idle_timeout_wrapper.dart';
import 'theme/app_fonts.dart';
import 'services/web_version_service.dart';

void main() async {
  // Splash is mobile (Android/iOS) + web only -- desktop native builds are
  // explicitly deferred and must keep today's exact startup sequence.
  // `kIsWeb ||` short-circuits before `Platform.isAndroid`/`isIOS` ever run,
  // which is what makes this safe on web (where `dart:io`'s `Platform`
  // getters throw if actually evaluated).
  final isMobileOrWeb = kIsWeb || Platform.isAndroid || Platform.isIOS;

  if (!isMobileOrWeb) {
    // Desktop (Windows/macOS/Linux): unchanged. No SplashScreen on this
    // path -- reaches AuthGate exactly as it did before the splash existed.
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await RuntimeModeService.initialize();
    // Start global background listener (updates everywhere, no screen required)
    unawaited(() async {
      await GlobalReadingsListener().initialize();
    }());
    // Start background device listener (continues regardless of screen state)
    DeviceService().initialize();
    // Start in-app periodic prediction service (computes fallback forecasts and
    // writes them to RTDB). Interval default: 6 hours.
    unawaited(() async {
      try {
        await PredictionService().initialize();
      } catch (_) {}
    }());
    // Initialize home screen widget
    await HomeWidgetService.initialize();
    unawaited(() async {
      await UpdateNotificationService.checkAndNotifyIfNewRelease();
    }());
    runApp(const SmartPowerSwitchApp());
    return;
  }

  // Mobile + web: run the app immediately so SplashScreen can actually
  // animate. Firebase and the supporting services are brought up from
  // inside the splash's `onInitialize` callback instead (see
  // `_initializeMobileWeb` below and the `'/'` route in
  // `SmartPowerSwitchApp`).
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SmartPowerSwitchApp(useSplash: true));
}

/// Firebase + background service bring-up for the mobile/web splash path,
/// invoked as `SplashScreen.onInitialize` while the splash animates.
///
/// Order matters and mirrors the pre-splash `main()` sequence above:
/// Firebase must fully resolve first (no timeout -- `AuthGate` calls
/// `FirebaseAuth.instance` unconditionally, so falling through without
/// Firebase ready is the one hard-crash scenario to avoid), then
/// `RuntimeModeService`/`HomeWidgetService` (each already degrades safely
/// internally, so a caught timeout here just lets the splash proceed
/// instead of hanging), and only then the same four fire-and-forget
/// service kickoffs as before, in the same relative order.
Future<void> _initializeMobileWeb() async {
  // Remember the website version this tab loaded with (Settings compares it
  // with the deployed one). Cheap, and never blocks start-up.
  unawaited(WebVersionService.running().then((_) {}, onError: (_) {}));
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  await RuntimeModeService.initialize()
      .timeout(const Duration(seconds: 10))
      .catchError((Object e) {
    debugPrint('RuntimeModeService.initialize timed out/failed: $e');
  });
  await HomeWidgetService.initialize()
      .timeout(const Duration(seconds: 10))
      .catchError((Object e) {
    debugPrint('HomeWidgetService.initialize timed out/failed: $e');
  });

  // Start global background listener (updates everywhere, no screen required)
  unawaited(() async {
    await GlobalReadingsListener().initialize();
  }());
  // Start background device listener (continues regardless of screen state)
  DeviceService().initialize();
  // Start in-app periodic prediction service (computes fallback forecasts and
  // writes them to RTDB). Interval default: 6 hours.
  unawaited(() async {
    try {
      await PredictionService().initialize();
    } catch (_) {}
  }());
  unawaited(() async {
    await UpdateNotificationService.checkAndNotifyIfNewRelease();
  }());
}

class SmartPowerSwitchApp extends StatelessWidget {
  /// True only on the mobile/web startup path built in `main()` above; the
  /// desktop path never passes this, so it defaults to `false` and desktop
  /// keeps going straight to [AuthGate] with no [SplashScreen] involved.
  final bool useSplash;

  const SmartPowerSwitchApp({super.key, this.useSplash = false});

  static final GlobalKey<NavigatorState> _navigatorKey =
      GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartSwitch',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      builder: (context, child) => IdleTimeoutWrapper(
        navigatorKey: _navigatorKey,
        child: child!,
      ),
      theme: ThemeData(
        fontFamily: AppFonts.family,
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.greenDark),
        scaffoldBackgroundColor: Colors.white,
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (_) => useSplash
            ? const SplashScreen(onInitialize: _initializeMobileWeb)
            : const AuthGate(),
        '/login': (_) => const LoginScreen(),
        '/history': (_) => const HistoryScreen(),
        '/notifications': (_) => const NotificationsScreen(),
        '/settings': (_) => const SettingsScreen(),
        '/more': (_) => const MoreScreen(),
        '/map': (_) => const CampusMapScreen(),
      },
      onGenerateRoute: (settings) {
        if (settings.name == '/dashboard') {
          final args = settings.arguments;
          final role = args is Map ? args['role'] as String? : null;
          final name = args is Map ? args['name'] as String? : null;
          return MaterialPageRoute(
            builder: (_) => DashboardPage(role: role, name: name),
            settings: settings,
          );
        }
        if (settings.name == '/building') {
          final args = settings.arguments as Map<String, dynamic>;
          return MaterialPageRoute(
            // Width-based, not platform-based -- matches DashboardPage, so a
            // resized browser window, a native desktop build, and a phone
            // all get the right layout.
            builder: (_) => LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth >= DashboardPage.desktopBreakpoint) {
                  return BuildingFloorScreenWeb(
                    buildingCode: args['buildingCode'],
                    buildingName: args['buildingName'],
                    floors: args['floors'],
                    role: args['role'] ?? 'faculty',
                  );
                }
                return BuildingFloorScreen(
                  buildingCode: args['buildingCode'],
                  buildingName: args['buildingName'],
                  floors: args['floors'],
                  role: args['role'] ?? 'faculty',
                );
              },
            ),
            settings: settings,
          );
        }
        if (settings.name == '/device') {
          final args = settings.arguments as Map<String, dynamic>;
          return MaterialPageRoute(
            builder: (_) => LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth >= DashboardPage.desktopBreakpoint) {
                  return DeviceDetailScreenWeb(
                    deviceId: args['deviceId'],
                    utility: args['utility'],
                    building: args['building'],
                    room: args['room'] ?? 'unknown',
                    floor: args['floor'],
                    role: args['role'] ?? 'faculty',
                  );
                }
                return DeviceDetailScreen(
                  deviceId: args['deviceId'],
                  utility: args['utility'],
                  building: args['building'],
                  room: args['room'] ?? 'unknown',
                  floor: args['floor'],
                  role: args['role'] ?? 'faculty',
                );
              },
            ),
            settings: settings,
          );
        }
        if (settings.name == '/manage-users') {
          final args = settings.arguments as Map<String, dynamic>? ?? {};
          return MaterialPageRoute(
            // ManageUsersScreen owns its full Scaffold (AppTopBar, white
            // background) as of the mobile redesign -- no extra
            // Scaffold/AppBar wrapper here anymore (that used to double up
            // the top bar).
            builder: (_) => ManageUsersScreen(
              role: args['role'] as String? ?? 'faculty',
              institute: args['institute'] as String?,
            ),
            settings: settings,
          );
        }
        return null;
      },
    );
  }
}
