import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/building_floor_screen.dart';
import 'screens/device_detail_screen.dart';
import 'screens/history_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/settings_screen.dart';
import 'theme/app_colors.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const SmartPowerSwitchApp());
}

class SmartPowerSwitchApp extends StatelessWidget {
  const SmartPowerSwitchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartPowerSwitch',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: 'Outfit',
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.greenDark),
        scaffoldBackgroundColor: AppColors.greenPale,
        useMaterial3: true,
      ),
      initialRoute: '/login',
      routes: {
        '/login':         (_) => const LoginScreen(),
        '/dashboard':     (_) => const DashboardScreen(),
        '/history':       (_) => const HistoryScreen(),
        '/notifications': (_) => const NotificationsScreen(),
        '/settings':      (_) => const SettingsScreen(),
      },
      onGenerateRoute: (settings) {
        if (settings.name == '/building') {
          final args = settings.arguments as Map<String, dynamic>;
          return MaterialPageRoute(
            builder: (_) => BuildingFloorScreen(
              buildingCode: args['buildingCode'],
              buildingName: args['buildingName'],
              floors:       args['floors'],
              role:         args['role'] ?? 'faculty',
            ),
          );
        }
        if (settings.name == '/device') {
          final args = settings.arguments as Map<String, dynamic>;
          return MaterialPageRoute(
            builder: (_) => DeviceDetailScreen(
              deviceId: args['deviceId'],
              utility:  args['utility'],
              building: args['building'],
              floor:    args['floor'],
              role:     args['role'] ?? 'faculty',
            ),
          );
        }
        return null;
      },
    );
  }
}
