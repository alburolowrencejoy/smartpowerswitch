// SmartSwitch "power-on" splash (mobile + web startup path, see main.dart).
//
// The emblem charges up in the middle of a white screen, slams on with a
// shockwave, then (signed out) swoops into its spot on the sign-in
// page while the sign-in card lands -- there's no separate splash page to
// leave. Signed in, the splash fades into the dashboard
// screen instead. Firebase starts at the same time as the intro and the
// splash only settles once both are done. Reduce-motion skips the intro.
//
// Timeline (ms) follows the login handoff spec: track 0–900, arc 500–1100,
// bar slam 950–1450, impact 1450, letters 1550+45/letter, nodes 2000/2120/
// 2240, charging footer 1700–3300, spark 2300; settle 3500–5600.

import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/app_mode.dart';
import '../../theme/app_fonts.dart';
import '../../theme/sps_colors.dart';
import '../../widgets/login_intro_scope.dart';
import '../../widgets/power_emblem.dart';
import 'auth_gate.dart';

const int _kIntroMs = 3500;
const int _kSwoopMs = 1150;

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.onInitialize});

  /// Real startup work (Firebase etc.). The splash waits for both this and
  /// the intro before it settles.
  final Future<void> Function() onInitialize;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

enum _Phase { intro, settle, fade, done }

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
      vsync: this, duration: const Duration(milliseconds: _kIntroMs));
  late final AnimationController _settle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: LoginIntroScope.settleMs));
  late final AnimationController _exit = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 500));

  /// Spark orbit: fast (1.4s/turn) during the intro, 9s/turn afterwards.
  /// The slow one is shared with the login emblem so the spark doesn't jump
  /// at hand-over.
  late final AnimationController _fastOrbit = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400));
  late final AnimationController _orbit =
      AnimationController(vsync: this, duration: const Duration(seconds: 9));

  final _slotKey = GlobalKey();
  final _overlayKey = GlobalKey();
  final _emblemHidden = ValueNotifier<bool>(true);

  _Phase _phase = _Phase.intro;
  bool _ready = false; // startup done -> AuthGate can be built
  bool _started = false;
  Rect? _from, _to; // emblem swoop, in overlay coordinates

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _boot(MediaQuery.disableAnimationsOf(context));
  }

  Future<bool> _startup() async {
    await widget.onInitialize();
    if (mounted) setState(() => _ready = true);
    if (kUseMockData) return true;
    try {
      // Wait for Firebase to restore any persisted session.
      final user = await FirebaseAuth.instance.authStateChanges().first.timeout(
          const Duration(seconds: 10),
          onTimeout: () => FirebaseAuth.instance.currentUser);
      return user != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _boot(bool reduceMotion) async {
    final startup = _startup();

    if (reduceMotion) {
      await startup;
      _finish();
      return;
    }

    _fastOrbit.repeat();
    // Running from the start so the login emblem (built underneath during
    // the intro) follows it.
    _orbit.repeat();
    final results = await Future.wait<Object?>([_intro.forward(), startup]);
    final signedIn = results[1] as bool;
    if (!mounted) return;

    // Hand the spark over to the slow orbit where it is now.
    _orbit.value = _fastOrbit.value;
    _fastOrbit.stop();
    _orbit.repeat();

    if (!signedIn && await _measureSwoop()) {
      if (!mounted) return;
      setState(() => _phase = _Phase.settle);
      await _settle.forward();
      _finish();
    } else {
      // Nothing to swoop into (signed in -> dashboard):
      // fade out onto the next screen.
      _settle.value = 1;
      _emblemHidden.value = false;
      setState(() => _phase = _Phase.fade);
      await _exit.forward();
      // No login emblem is following the orbit; don't keep it ticking
      // under the dashboard.
      _orbit.reset();
      _finish();
    }
  }

  /// Finds where the login screen put its emblem. The login may still be
  /// building (AuthGate resolving the session), so this waits up to ~1s of
  /// frames before giving up -- false means there is no login to land on.
  Future<bool> _measureSwoop() async {
    for (var i = 0; i < 60; i++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return false;
      final slot = _slotKey.currentContext?.findRenderObject() as RenderBox?;
      final overlay =
          _overlayKey.currentContext?.findRenderObject() as RenderBox?;
      if (slot != null &&
          overlay != null &&
          slot.attached &&
          slot.hasSize &&
          overlay.hasSize) {
        final topLeft = slot.localToGlobal(Offset.zero, ancestor: overlay);
        _to = topLeft & slot.size;
        _from = _introRect(overlay.size);
        return true;
      }
    }
    return false;
  }

  void _finish() {
    if (!mounted) return;
    _settle.value = 1;
    _emblemHidden.value = false;
    setState(() => _phase = _Phase.done);
  }

  /// Emblem rect during the intro: centered (40 above middle), 60% of the
  /// short side, at most 1.25 × its size on the login page.
  Rect _introRect(Size screen) {
    final loginSize =
        screen.width >= 800 ? 360.0 : math.min(260.0, screen.width - 80);
    final size =
        math.min(1.25 * loginSize, .6 * math.min(screen.width, screen.height));
    return Rect.fromCenter(
      center: Offset(screen.width / 2, screen.height / 2 - 40),
      width: size,
      height: size,
    );
  }

  @override
  void dispose() {
    _intro.dispose();
    _settle.dispose();
    _exit.dispose();
    _fastOrbit.dispose();
    _orbit.dispose();
    _emblemHidden.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_ready)
          LoginIntroScope(
            settle: _settle,
            emblemSlotKey: _slotKey,
            emblemHidden: _emblemHidden,
            orbit: _orbit,
            child: const AuthGate(),
          )
        else
          const ColoredBox(color: SpsColors.ground),
        if (_phase != _Phase.done)
          AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.dark,
            child: IgnorePointer(
              ignoring: _phase == _Phase.settle,
              child: Material(
                key: _overlayKey,
                type: MaterialType.transparency,
                child: DefaultTextStyle(
                  style: const TextStyle(
                      fontFamily: AppFonts.family, color: SpsColors.ink),
                  child: AnimatedBuilder(
                    animation: Listenable.merge(
                        [_intro, _settle, _exit, _fastOrbit, _orbit]),
                    builder: (context, _) => LayoutBuilder(
                      builder: (context, c) => _overlay(c.biggest),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── Overlay ──────────────────────────────────────────────────

  double get _ms => _intro.value * _kIntroMs;
  double get _settleMs => _settle.value * LoginIntroScope.settleMs;

  /// Progress of a [dur]-long step starting at [start] ms into the intro.
  double _seg(double start, double dur, [Curve curve = Curves.linear]) =>
      curve.transform(((_ms - start) / dur).clamp(0.0, 1.0));

  Widget _overlay(Size screen) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    final fade = Curves.easeOut.transform(_exit.value);
    final background = switch (_phase) {
      _Phase.settle => 0.0,
      _Phase.fade => 1 - fade,
      _ => 1.0,
    };

    // Emblem position and size.
    Rect rect = _introRect(screen);
    if (_phase == _Phase.settle && _from != null && _to != null) {
      final t = const Cubic(.75, -.3, .25, 1.25)
          .transform((_settleMs / _kSwoopMs).clamp(0.0, 1.0));
      rect = Rect.lerp(_from, _to, t)!;
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child:
              ColoredBox(color: SpsColors.ground.withValues(alpha: background)),
        ),
        if (!reduce) _flash(),
        Positioned.fromRect(
          rect: rect,
          child: Opacity(
            opacity: 1 - fade,
            child: Transform.scale(
              scale: 1 + .06 * fade,
              child: PowerEmblemView(
                size: rect.width,
                pose: reduce ? const EmblemPose(spark: 0) : _pose(),
              ),
            ),
          ),
        ),
        if (!reduce)
          Positioned(
            left: 0,
            right: 0,
            bottom: screen.height * .07,
            child: Opacity(opacity: 1 - fade, child: _footer()),
          ),
      ],
    );
  }

  EmblemPose _pose() {
    if (_phase != _Phase.intro) {
      return EmblemPose(sparkTurn: _orbit.value);
    }
    // Arc charge: glows in energy green, peaks at 35%, back to brand at 100%.
    final c = _seg(500, 1800, Curves.easeOut);
    final charge = c <= 0
        ? 0.0
        : c < .35
            ? .6 + .4 * c / .35
            : c < .7
                ? 1 - .4 * (c - .35) / .35
                : .6 * (1 - (c - .7) / .3);

    return EmblemPose(
      track: _seg(0, 900, const Cubic(.7, 0, .2, 1)),
      arc: _seg(500, 600, const Cubic(.5, 0, .2, 1)),
      arcCharge: charge,
      bar: _seg(950, 500, const Cubic(.5, 0, .75, 0)),
      shake: _shake(_seg(1450, 450, const Cubic(.36, .07, .19, .97))),
      wave1: _ms < 1450 ? -1 : _seg(1450, 1000, const Cubic(.1, .6, .3, 1)),
      wave2: _ms < 1600 ? -1 : _seg(1600, 1000, const Cubic(.1, .6, .3, 1)),
      letters: [
        for (var i = 0; i < 11; i++)
          _seg(1550 + 45.0 * i, 600, const Cubic(.2, 1.5, .4, 1)),
      ],
      switchGlow: _seg(2200, 1200, Curves.easeOut),
      nodes: [
        for (var i = 0; i < 3; i++)
          _seg(2000 + 120.0 * i, 550, const Cubic(.3, 1.7, .5, 1)),
      ],
      ripples: [
        for (var i = 0; i < 3; i++)
          _ms < 2300 + 120 * i
              ? -1
              : _seg(2300 + 120.0 * i, 800, Curves.easeOut),
      ],
      spark: _seg(2300, 300),
      sparkTurn: _fastOrbit.value,
    );
  }

  /// Impact shake keyframes (10% steps), ±6 units at the peak.
  static const _shakeKeys = [
    Offset.zero,
    Offset(-2, 1),
    Offset(4, -2),
    Offset(-6, 3),
    Offset(6, -3),
    Offset(-6, 3),
    Offset(6, -3),
    Offset(-6, 3),
    Offset(4, -2),
    Offset(-2, 1),
    Offset.zero,
  ];

  Offset _shake(double p) {
    if (p <= 0 || p >= 1) return Offset.zero;
    final x = p * 10;
    final i = x.floor();
    return Offset.lerp(_shakeKeys[i], _shakeKeys[i + 1], x - i)!;
  }

  /// Radial green flash behind the emblem at impact.
  Widget _flash() {
    if (_ms < 1450) return const SizedBox.shrink();
    final p = _seg(1450, 700, Curves.easeOut);
    if (p >= 1) return const SizedBox.shrink();
    final opacity = p < .25 ? p / .25 : 1 - (p - .25) / .75;
    return Positioned.fill(
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -.08),
                radius: .6,
                colors: [
                  SpsColors.energy.withValues(alpha: .55),
                  SpsColors.energy.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Charging counter + bar + DNSC line along the bottom.
  Widget _footer() {
    final rise = _seg(1700, 500, Curves.easeOut);
    final leave = (_settleMs / 350).clamp(0.0, 1.0);
    final load = _seg(1800, 1500, const Cubic(.7, 0, .2, 1));
    return Opacity(
      opacity: rise * (1 - leave),
      child: Transform.translate(
        offset: Offset(0, 10 * (1 - rise) + 20 * leave),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${(load * 100).round()}%',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: SpsColors.brand,
                letterSpacing: .06 * 13,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: 200,
              height: 6,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: SpsColors.brand.withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: load,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(99),
                        gradient: const LinearGradient(
                            colors: [SpsColors.brand, SpsColors.energy]),
                        boxShadow: [
                          BoxShadow(
                            color: SpsColors.energy.withValues(alpha: .8),
                            blurRadius: 12,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: SpsColors.energy,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: SpsColors.energy.withValues(alpha: .25),
                        spreadRadius: 3,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'DNSC · Davao del Norte State College',
                  style: TextStyle(fontSize: 12, color: SpsColors.muted),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
