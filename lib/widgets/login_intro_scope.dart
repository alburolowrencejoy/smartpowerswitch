import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

/// Links the power-on splash to the web sign-in screen underneath it, so
/// the splash's emblem can fly into the login layout while the sign-in
/// card lands (see `lib/screens/shared/splash_screen.dart`).
///
/// Outside the splash (e.g. after a logout or a `/login` route) there is
/// no scope and the login screen simply shows fully.
class LoginIntroScope extends InheritedWidget {
  const LoginIntroScope({
    super.key,
    required this.settle,
    required this.emblemSlotKey,
    required this.emblemHidden,
    required this.orbit,
    required super.child,
  });

  /// 0 → 1 over the settle phase (2.1s). 0 = card hidden, 1 = fully shown.
  final Animation<double> settle;

  /// Attach to the login screen's emblem so the splash can measure where to
  /// fly to.
  final GlobalKey emblemSlotKey;

  /// True while the splash's own emblem stands in for the login one.
  final ValueListenable<bool> emblemHidden;

  /// The splash's slow spark orbit, reused by the login emblem so the spark
  /// carries on from where the flying emblem left it.
  final Animation<double> orbit;

  /// Settle-phase length; intervals below are fractions of it.
  static const settleMs = 2100;

  static LoginIntroScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LoginIntroScope>();

  @override
  bool updateShouldNotify(LoginIntroScope old) =>
      settle != old.settle ||
      emblemSlotKey != old.emblemSlotKey ||
      emblemHidden != old.emblemHidden ||
      orbit != old.orbit;
}
