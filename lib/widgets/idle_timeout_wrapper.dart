import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/automation_scheduler_service.dart';

/// Signs the user out after [timeout] of no touch/mouse/keyboard activity.
///
/// Wraps the whole app (see `MaterialApp.builder` in `main.dart`) so every
/// authenticated route is covered by a single timer, not just the initial
/// `AuthGate` widget instance. The timer only runs while a user is actually
/// signed in (gated by `authStateChanges()`), so it's inert on the login
/// screen itself.
///
/// A `Timer` alone isn't enough on mobile: a backgrounded/suspended app
/// (especially iOS) won't reliably keep firing timers, so elapsed wall-clock
/// time is also checked on `resumed`.
class IdleTimeoutWrapper extends StatefulWidget {
  static const Duration timeout = Duration(minutes: 20);

  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;

  const IdleTimeoutWrapper({
    super.key,
    required this.child,
    required this.navigatorKey,
  });

  @override
  State<IdleTimeoutWrapper> createState() => _IdleTimeoutWrapperState();
}

class _IdleTimeoutWrapperState extends State<IdleTimeoutWrapper>
    with WidgetsBindingObserver {
  // On the mobile/web splash startup path (see `main.dart`), Firebase.initializeApp()
  // is deferred into `SplashScreen.onInitialize` so the splash can animate
  // immediately -- but this wrapper sits above the Navigator/SplashScreen
  // subtree in `MaterialApp.builder`, so its `initState()` runs before that
  // deferred init has had a chance to run. Calling `FirebaseAuth.instance`
  // before any Firebase app exists throws synchronously (`[core/no-app]`),
  // and since that would happen inside a parent's `initState()`, it takes
  // down the whole first frame (white screen). Guard on `Firebase.apps` and
  // retry briefly instead of subscribing unconditionally.
  static const Duration _authSubRetryInterval = Duration(milliseconds: 300);
  // 100 * 300ms = 30s. Generous enough to cover a slow (e.g. cold-cache,
  // poor network) Firebase.initializeApp() on the splash path, but bounded
  // so a genuinely failed init doesn't retry forever.
  static const int _authSubMaxRetries = 100;

  Timer? _timer;
  Timer? _authSubRetryTimer;
  DateTime? _lastActivityAt;
  StreamSubscription<User?>? _authSub;
  bool _signedIn = false;
  int _authSubRetryAttempts = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    _subscribeToAuthChanges();
  }

  void _subscribeToAuthChanges() {
    if (Firebase.apps.isEmpty) {
      if (_authSubRetryAttempts >= _authSubMaxRetries) {
        // Firebase never came up (e.g. initializeApp itself failed/hung).
        // Give up instead of polling forever -- there's no session to log
        // out of if there's no Firebase app. Idle-logout is simply inactive
        // for the rest of this run in that scenario.
        debugPrint(
          'IdleTimeoutWrapper: Firebase never became ready after '
          '${_authSubMaxRetries * _authSubRetryInterval.inMilliseconds}ms; '
          'idle-logout disabled for this session.',
        );
        return;
      }
      _authSubRetryAttempts++;
      _authSubRetryTimer = Timer(_authSubRetryInterval, () {
        if (!mounted) return;
        _subscribeToAuthChanges();
      });
      return;
    }
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      _signedIn = user != null;
      if (_signedIn) {
        _registerActivity();
      } else {
        _timer?.cancel();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _authSubRetryTimer?.cancel();
    _authSub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    _registerActivity();
    return false; // never consume -- just observing for activity
  }

  void _registerActivity() {
    if (!_signedIn) return;
    _lastActivityAt = DateTime.now();
    _timer?.cancel();
    _timer = Timer(IdleTimeoutWrapper.timeout, _forceLogout);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!_signedIn || _lastActivityAt == null) return;
    if (DateTime.now().difference(_lastActivityAt!) >= IdleTimeoutWrapper.timeout) {
      _forceLogout();
    } else {
      _registerActivity();
    }
  }

  Future<void> _forceLogout() async {
    if (!_signedIn) return;
    _signedIn = false;
    _timer?.cancel();
    await AutomationSchedulerService.stop();
    await FirebaseAuth.instance.signOut();
    widget.navigatorKey.currentState?.pushNamedAndRemoveUntil(
      '/login',
      (route) => false,
      arguments: const {'forceLogoutReason': 'inactivity'},
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _registerActivity(),
      onPointerMove: (_) => _registerActivity(),
      onPointerSignal: (_) => _registerActivity(),
      child: widget.child,
    );
  }
}
