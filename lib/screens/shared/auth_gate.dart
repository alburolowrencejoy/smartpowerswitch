import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../config/app_mode.dart';
import '../../theme/app_colors.dart';
import 'dashboard_page.dart';
import 'login_screen.dart';

/// Decides between the login screen and the dashboard based on Firebase
/// Auth's *restored* session state.
///
/// Checking `FirebaseAuth.instance.currentUser` synchronously on app start
/// races Firebase's async persisted-session restore (especially on web,
/// where it reads from IndexedDB) — an already-logged-in user can see
/// `currentUser == null` for a moment and get bounced to `/login`.
/// `authStateChanges()` waits for that restore to finish before this
/// widget decides which screen to show.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    if (kUseMockData) {
      return const DashboardPage();
    }

    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: AppColors.greenDark,
            body: Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          );
        }
        if (snapshot.data == null) {
          return const LoginScreen();
        }
        return const DashboardPage();
      },
    );
  }
}
