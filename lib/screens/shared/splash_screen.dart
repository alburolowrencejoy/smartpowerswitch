// lib/screens/splash_screen.dart
//
// SmartPowerSwitch preloader — native Flutter port of the HTML animation.
// No packages required: AnimationController + CustomPainter only.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../theme/app_fonts.dart';

import '../../theme/app_colors.dart';
import 'auth_gate.dart';

/// The four brand colours, sourced from the shared app theme.
class Sps {
  static const p1 = AppColors.greenDark; // deep green  — ground / unlit
  static const p2 = AppColors.greenMid; // green       — active surfaces
  static const p3 = AppColors.greenLight; // mint        — signal / edges
  static const p4 = AppColors.greenPale; // pale mint   — light / type
}

const int _kTotalMs = 5800; // full timeline, matches --seq in the HTML
const int _kPulseMs = 2000; // sonar + breathe loop
const String _kWordmark = 'SmartPowerSwitch';
const int _kAccentStart = 5; // "Power" starts at index 5
const int _kAccentEnd = 10;

class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
    required this.onInitialize,
  });

  /// Real startup work. The splash waits for both this future and the
  /// animation, so the bulb moment is never cut off by a fast boot.
  final Future<void> Function() onInitialize;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _timeline = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _kTotalMs),
  );
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _kPulseMs),
  )..repeat();

  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await Future.wait<void>([
      _timeline.forward(),
      widget.onInitialize(),
    ]);
    if (!mounted) return;
    setState(() => _exiting = true);
    await Future<void>.delayed(const Duration(milliseconds: 620));
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AuthGate()),
      );
    }
  }

  @override
  void dispose() {
    _timeline.dispose();
    _pulse.dispose();
    super.dispose();
  }

  double get _t => _timeline.value * _kTotalMs;

  String get _status {
    if (_t >= 5400) return 'Ready';
    if (_t >= 4700) return 'Reading device meters';
    if (_t >= 4000) return 'Connecting to the network';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final sceneWidth = math.min(340.0, w * 0.88);

    return Scaffold(
      body: AnimatedOpacity(
        opacity: _exiting ? 0 : 1,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOut,
        child: AnimatedScale(
          scale: _exiting ? 1.06 : 1.0,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOut,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.28),
                radius: 0.95,
                colors: [Sps.p2, Sps.p1],
                stops: [0.0, 0.72],
              ),
            ),
            child: Stack(
              children: [
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: sceneWidth,
                        child: AspectRatio(
                          aspectRatio: 360 / 316,
                          child: AnimatedBuilder(
                            animation: Listenable.merge([_timeline, _pulse]),
                            builder: (_, __) => CustomPaint(
                              painter: _ScenePainter(
                                t: _t,
                                pulse: _pulse.value,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      _Wordmark(timeline: _timeline),
                    ],
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: math.max(44, MediaQuery.sizeOf(context).height * .07),
                  child: Center(
                    child: SizedBox(
                      width: math.min(240.0, w * .72),
                      child: AnimatedBuilder(
                        animation: _timeline,
                        builder: (_, __) => _LoadingBar(
                          t: _t,
                          status: _status,
                        ),
                      ),
                    ),
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

double _seg(double t, double startMs, double durMs,
    {Curve curve = Curves.easeOut}) {
  final x = ((t - startMs) / durMs).clamp(0.0, 1.0);
  return curve.transform(x);
}

class _ScenePainter extends CustomPainter {
  _ScenePainter({required this.t, required this.pulse});

  final double t;
  final double pulse;

  static const double _vw = 360, _vh = 316;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _vw);

    _bulb(canvas, const Offset(66, 86), 250, 'IC');
    _bulb(canvas, const Offset(180, 58), 0, 'ILEGG');
    _bulb(canvas, const Offset(294, 86), 360, 'ADMIN');

    _sonar(canvas);
    _phone(canvas);

    canvas.restore();
  }

  void _bulb(Canvas canvas, Offset at, double delay, String tag) {
    final lit = _seg(t, 2300 + delay, 700);
    final fil = _seg(t, 2280 + delay, 560);
    final rays = _seg(t, 2340 + delay, 1100, curve: Curves.easeOutCubic);
    final tagP = _seg(t, 2600 + delay, 600);

    final breathe = lit >= 1
        ? 1 - 0.16 * (0.5 - 0.5 * math.cos(pulse * 2 * math.pi)).abs()
        : 1.0;

    canvas.save();
    canvas.translate(at.dx, at.dy);

    if (rays > 0 && rays < 1) {
      final double sc, op;
      if (rays < .35) {
        final k = rays / .35;
        sc = .5 + .5 * k;
        op = k;
      } else {
        final k = (rays - .35) / .65;
        sc = 1 + .32 * k;
        op = 1 - k;
      }
      final p = Paint()
        ..color = Sps.p3.withValues(alpha: op)
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
      canvas.save();
      canvas.scale(sc);
      for (var i = 0; i < 6; i++) {
        final a = i * math.pi / 3;
        canvas.drawLine(
          Offset(math.cos(a) * 26, math.sin(a) * 26),
          Offset(math.cos(a) * 35, math.sin(a) * 35),
          p,
        );
      }
      canvas.restore();
    }

    canvas.saveLayer(
      Rect.fromCircle(center: Offset.zero, radius: 44),
      Paint()..color = Colors.white.withValues(alpha: breathe),
    );

    const glass = Rect.fromLTRB(-19, -19, 19, 19);
    canvas.drawCircle(
      Offset.zero,
      19,
      Paint()..color = Sps.p1.withValues(alpha: .8),
    );
    if (lit > 0) {
      canvas.saveLayer(
        glass.inflate(6),
        Paint()..color = Colors.white.withValues(alpha: lit),
      );
      canvas.drawCircle(
        Offset.zero,
        19,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(0, -0.16),
            radius: .62,
            colors: [Sps.p4, Sps.p3, Sps.p2],
            stops: [0, .45, 1],
          ).createShader(glass),
      );
      canvas.restore();
    }
    canvas.drawCircle(
      Offset.zero,
      19,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Color.lerp(Sps.p3.withValues(alpha: .4), Sps.p4, lit)!,
    );

    final filament = Path()
      ..moveTo(-5, 11)
      ..lineTo(-5, 4)
      ..lineTo(0, -4)
      ..lineTo(5, 4)
      ..lineTo(5, 11);
    canvas.drawPath(
      filament,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = Color.lerp(Sps.p3.withValues(alpha: .5), Sps.p4, fil)!
        ..maskFilter =
            fil > .5 ? const MaskFilter.blur(BlurStyle.solid, 2.5) : null,
    );

    final capStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Color.lerp(Sps.p3.withValues(alpha: .4), Sps.p2, lit)!;
    final capFill = Paint()..color = Sps.p2.withValues(alpha: .35);
    for (final r in const [
      Rect.fromLTWH(-8, 9, 16, 11),
      Rect.fromLTWH(-5, 20, 10, 5),
    ]) {
      final rr = RRect.fromRectAndRadius(r, const Radius.circular(2.5));
      canvas.drawRRect(rr, capFill);
      canvas.drawRRect(rr, capStroke);
    }
    final thread = Paint()
      ..color = Sps.p3.withValues(alpha: .45)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(-6, 13), const Offset(6, 13), thread);
    canvas.drawLine(const Offset(-6, 17), const Offset(6, 17), thread);

    canvas.restore();

    if (tagP > 0) {
      final tp = TextPainter(
        text: TextSpan(
          text: tag,
          style: TextStyle(
            fontFamily: AppFonts.family,
            fontSize: 10,
            letterSpacing: .6,
            color: Sps.p4.withValues(alpha: .55 * tagP),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(-tp.width / 2, 38));
    }

    canvas.restore();
  }

  void _sonar(Canvas canvas) {
    if (t < 1600) return;
    const origin = Offset(180, 192);

    final arc = Path()
      ..moveTo(164.5, 186.5)
      ..arcToPoint(const Offset(195.5, 186.5),
          radius: const Radius.circular(16), clockwise: true);

    for (final offset in const [0.0, .335, .67]) {
      final phase = ((pulse + offset) % 1.0);
      final k = 0.3 + 1.9 * Curves.easeOutCubic.transform(phase);
      double op;
      if (phase < .16) {
        op = .9 * (phase / .16);
      } else if (phase < .6) {
        op = .9 - .48 * ((phase - .16) / .44);
      } else {
        op = .42 * (1 - (phase - .6) / .4);
      }
      canvas.save();
      canvas.translate(origin.dx, origin.dy);
      canvas.scale(k);
      canvas.translate(-origin.dx, -origin.dy);
      canvas.drawPath(
        arc,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 2.2 / k
          ..color = Sps.p3.withValues(alpha: op.clamp(0, 1)),
      );
      canvas.restore();
    }

    final e = 0.5 - 0.5 * math.cos(pulse * 2 * math.pi);
    canvas.drawCircle(
      const Offset(180, 190),
      3.6 * (0.8 + 0.5 * e),
      Paint()..color = Sps.p3.withValues(alpha: .35 + .65 * e),
    );
  }

  void _phone(Canvas canvas) {
    final rise = _seg(t, 200, 820, curve: Curves.easeOutCubic);
    if (rise <= 0) return;

    canvas.saveLayer(
      const Rect.fromLTWH(120, 180, 120, 140),
      Paint()..color = Colors.white.withValues(alpha: rise),
    );
    canvas.translate(0, 16 * (1 - rise));

    canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(138, 196, 84, 112), const Radius.circular(15)),
      Paint()..color = Sps.p2.withValues(alpha: .22),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(138, 196, 84, 112), const Radius.circular(15)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Sps.p3.withValues(alpha: .5),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(146, 205, 68, 94), const Radius.circular(9)),
      Paint()..color = Sps.p1.withValues(alpha: .92),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(156, 217, 28, 4), const Radius.circular(2)),
      Paint()..color = Sps.p3.withValues(alpha: .35),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(156, 226, 44, 4), const Radius.circular(2)),
      Paint()..color = Sps.p3.withValues(alpha: .19),
    );

    final track = _seg(t, 1480, 420);
    final knob = _seg(t, 1450, 500, curve: Curves.easeOutBack);
    final trackRect = RRect.fromRectAndRadius(
        const Rect.fromLTWH(160, 244, 40, 20), const Radius.circular(10));
    canvas.drawRRect(
      trackRect,
      Paint()
        ..color = Color.lerp(Sps.p1.withValues(alpha: .95), Sps.p2, track)!,
    );
    canvas.drawRRect(
      trackRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Color.lerp(Sps.p3.withValues(alpha: .4), Sps.p3, track)!,
    );
    canvas.drawCircle(
      Offset(170 + 20 * knob, 254),
      7,
      Paint()..color = Color.lerp(Sps.p3.withValues(alpha: .55), Sps.p4, knob)!,
    );

    final rp = _seg(t, 1480, 820);
    if (rp > 0 && rp < 1) {
      canvas.drawCircle(
        const Offset(190, 254),
        10 * (0.4 + 3.0 * rp),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Sps.p3.withValues(alpha: .9 * (1 - rp)),
      );
    }

    final tap = ((t - 850) / 1000).clamp(0.0, 1.0);
    if (tap > 0 && tap < 1) {
      double sc, op;
      if (tap < .45) {
        final k = tap / .45;
        sc = 2.4 - 1.4 * Curves.easeOutCubic.transform(k);
        op = k;
      } else if (tap < .72) {
        sc = 1 - .14 * ((tap - .45) / .27);
        op = 1;
      } else {
        final k = (tap - .72) / .28;
        sc = .86 + .24 * k;
        op = 1 - k;
      }
      const c = Offset(190, 254);
      canvas.drawCircle(
          c, 11 * sc, Paint()..color = Sps.p4.withValues(alpha: .3 * op));
      canvas.drawCircle(
        c,
        11 * sc,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Sps.p4.withValues(alpha: .6 * op),
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScenePainter old) => old.t != t || old.pulse != pulse;
}

class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.timeline});

  final AnimationController timeline;

  @override
  Widget build(BuildContext context) {
    final letters = _kWordmark.split('');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: timeline,
          builder: (_, __) {
            final t = timeline.value * _kTotalMs;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < letters.length; i++)
                  _Letter(
                    char: letters[i],
                    progress: ((t - (3150 + i * 34)) / 760).clamp(0.0, 1.0),
                    accent: i >= _kAccentStart && i < _kAccentEnd,
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 9),
        AnimatedBuilder(
          animation: timeline,
          builder: (_, __) {
            final p = _seg(timeline.value * _kTotalMs, 3900, 800);
            return Opacity(
              opacity: p,
              child: Transform.translate(
                offset: Offset(0, 16 * (1 - p)),
                child: Text(
                  'Campus energy monitoring · DNSC',
                  style: TextStyle(
                    fontFamily: AppFonts.family,
                    fontSize: 12,
                    color: Sps.p4.withValues(alpha: .7),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _Letter extends StatelessWidget {
  const _Letter({
    required this.char,
    required this.progress,
    required this.accent,
  });

  final String char;
  final double progress;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final p = Curves.easeOutBack.transform(progress);
    final opacity = (progress / .5).clamp(0.0, 1.0);

    return Opacity(
      opacity: opacity,
      child: Transform.translate(
        offset: Offset(0, -22 * (1 - p)),
        child: Transform.scale(
          scale: 1 + 0.9 * (1 - p),
          child: Text(
            char,
            style: TextStyle(
              fontFamily: AppFonts.family,
              fontWeight: FontWeight.w800,
              fontSize: 22,
              height: 1,
              color: accent ? Sps.p3 : Sps.p4,
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingBar extends StatelessWidget {
  const _LoadingBar({required this.t, required this.status});

  final double t;
  final String status;

  @override
  Widget build(BuildContext context) {
    final show = _seg(t, 4000, 700);
    final fill = _seg(t, 4000, 1800, curve: Curves.easeInOutCubic);

    return Opacity(
      opacity: show,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Container(
              height: 2,
              color: Sps.p4.withValues(alpha: .2),
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: fill,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(colors: [Sps.p3, Sps.p4]),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 13),
          SizedBox(
            height: 16,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              child: Text(
                status,
                key: ValueKey(status),
                style: TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 12.5,
                  color: Sps.p4.withValues(alpha: .72),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
