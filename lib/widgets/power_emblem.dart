import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/sps_colors.dart';

/// Power-symbol (⏻) emblem with the SmartSwitch wordmark inside, used on
/// the web sign-in screen. Geometry is authored on a 360 × 360 canvas and
/// scaled proportionally to [size]. The spark orbits once every 9s (parked
/// when reduce-motion is on).
class PowerEmblem extends StatefulWidget {
  const PowerEmblem({super.key, this.size = 360, this.orbit});

  final double size;

  /// Drive the spark from an existing orbit (0 → 1 per turn) instead of
  /// this widget's own -- used when the splash hands its emblem over.
  final Animation<double>? orbit;

  @override
  State<PowerEmblem> createState() => _PowerEmblemState();
}

class _PowerEmblemState extends State<PowerEmblem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ownOrbit =
      AnimationController(vsync: this, duration: const Duration(seconds: 9));

  /// Only follow [PowerEmblem.orbit] while it is actually running.
  bool get _shared => widget.orbit?.status == AnimationStatus.forward;

  void _syncOwnOrbit() {
    final reduce = MediaQuery.of(context).disableAnimations;
    if (reduce || _shared) {
      _ownOrbit.stop();
    } else if (!_ownOrbit.isAnimating) {
      _ownOrbit.repeat();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncOwnOrbit();
  }

  @override
  void didUpdateWidget(covariant PowerEmblem oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncOwnOrbit();
  }

  @override
  void dispose() {
    _ownOrbit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final orbit = _shared ? widget.orbit! : _ownOrbit;
    return AnimatedBuilder(
      animation: orbit,
      builder: (_, __) => PowerEmblemView(
        size: widget.size,
        pose: EmblemPose(sparkTurn: orbit.value),
      ),
    );
  }
}

/// Every animatable part of the emblem. The defaults are the finished,
/// resting emblem; the power-on splash drives each field from 0 → 1.
@immutable
class EmblemPose {
  const EmblemPose({
    this.track = 1,
    this.arc = 1,
    this.arcCharge = 0,
    this.bar = 1,
    this.shake = Offset.zero,
    this.wave1 = -1,
    this.wave2 = -1,
    this.letters,
    this.switchGlow = 0,
    this.nodes = const [1, 1, 1],
    this.ripples = const [-1, -1, -1],
    this.spark = 1,
    this.sparkTurn = 0,
  });

  /// Track drawn, 0 → 1 (of its 310°).
  final double track;

  /// Arc swept, 0 → 1 (of its 130°).
  final double arc;

  /// 1 = arc glowing in energy green, 0 = resting brand green.
  final double arcCharge;

  /// Bar slam, 0 (140 units above, invisible) → 1 (in place).
  final double bar;

  /// Impact shake applied to the ring, in 360-canvas units.
  final Offset shake;

  /// Shockwave progress 0 → 1; negative = not showing.
  final double wave1, wave2;

  /// Per-letter entrance 0 → 1 for "SmartSwitch" (11 letters); null = all in.
  final List<double>? letters;

  /// Glow behind "Switch", 0 → 1.
  final double switchGlow;

  /// Node pop-in 0 → 1 for left / bottom / right.
  final List<double> nodes;

  /// Node ripple 0 → 1; negative = not showing.
  final List<double> ripples;

  /// Spark opacity.
  final double spark;

  /// Spark position in turns (0 = 12 o'clock, clockwise).
  final double sparkTurn;
}

const _wordTop = 'Smart';
const _wordBottom = 'Switch';

/// Stateless renderer for an [EmblemPose].
class PowerEmblemView extends StatelessWidget {
  const PowerEmblemView({
    super.key,
    required this.size,
    this.pose = const EmblemPose(),
  });

  final double size;
  final EmblemPose pose;

  @override
  Widget build(BuildContext context) {
    final s = size;
    final k = s / 360;
    final node = s * .15;

    Widget n(int i, Offset c, IconData icon, String label,
        {bool filled = false}) {
      final t = pose.nodes[i];
      final ripple = pose.ripples[i];
      return Positioned(
        left: c.dx * k - node / 2,
        top: c.dy * k - node / 2,
        child: Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.rotate(
            angle: -math.pi * (1 - t),
            child: Transform.scale(
              scale: math.max(0, t),
              child: Tooltip(
                message: label,
                child: Semantics(
                  label: label,
                  child: Container(
                    width: node,
                    height: node,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled ? SpsColors.brand : SpsColors.ground,
                      border: Border.all(color: SpsColors.brand, width: 2),
                      boxShadow: [
                        if (ripple >= 0 && ripple < 1)
                          BoxShadow(
                            color: SpsColors.energy
                                .withValues(alpha: .7 * (1 - ripple)),
                            spreadRadius: 18 * k * ripple,
                          ),
                      ],
                    ),
                    child: ExcludeSemantics(
                      child: Icon(icon,
                          size: node * .42,
                          color: filled ? SpsColors.energy : SpsColors.brand),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget wave(double t, Color color, double width) {
      if (t < 0 || t >= 1) return const SizedBox.shrink();
      // Opacity 0 → .9 over the first 6%, then fades out as it grows.
      final opacity = t < .06 ? t / .06 * .9 : .9 * (1 - (t - .06) / .94);
      final scale = t < .06 ? .7 + t / .06 * .05 : .75 + (t - .06) / .94 * 1.15;
      return Positioned.fill(
        child: Padding(
          padding: EdgeInsets.all(s * .08),
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: scale,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: width),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: s,
      height: s,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Transform.translate(
              offset: pose.shake * k,
              child: RepaintBoundary(
                child: CustomPaint(painter: _RingPainter(pose)),
              ),
            ),
          ),
          wave(pose.wave1, SpsColors.energy, 3),
          wave(pose.wave2, SpsColors.brand, 2),
          Center(
            child: Semantics(
              header: true,
              label: 'SmartSwitch',
              child: ExcludeSemantics(child: _wordmark(k)),
            ),
          ),
          n(0, const Offset(30, 180), Icons.show_chart, 'Monitor'),
          n(1, const Offset(180, 330), Icons.toggle_on_outlined, 'Control',
              filled: true),
          n(2, const Offset(330, 180), Icons.schedule, 'Schedule'),
        ],
      ),
    );
  }

  /// "Smart" over "Switch", one widget per letter so the splash can
  /// stagger them. The resting emblem uses the same layout, so nothing
  /// shifts when the splash hands over to the login screen.
  Widget _wordmark(double k) {
    final fontSize = 58 * k;
    final base = TextStyle(
      fontSize: fontSize,
      height: .92,
      fontWeight: FontWeight.w700,
      letterSpacing: -.045 * fontSize,
    );
    var index = 0;

    Widget line(String word, Color color, {double glow = 0}) {
      final style = base.copyWith(
        color: color,
        shadows: [
          if (glow > 0)
            Shadow(
              color: SpsColors.energy.withValues(alpha: .9 * glow),
              blurRadius: 22 * k,
            ),
        ],
      );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final ch in word.split(''))
            _Letter(ch, style, pose.letters?[index++] ?? 1, k),
        ],
      );
    }

    // Glow peaks 40% of the way through, then fades.
    final g = pose.switchGlow;
    final glow = g <= 0 || g >= 1 ? 0.0 : (g < .4 ? g / .4 : (1 - g) / .6);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        line(_wordTop, SpsColors.ink),
        line(_wordBottom, SpsColors.brand, glow: glow),
      ],
    );
  }
}

class _Letter extends StatelessWidget {
  const _Letter(this.ch, this.style, this.t, this.k);

  final String ch;
  final TextStyle style;
  final double t;
  final double k;

  @override
  Widget build(BuildContext context) {
    final text = Text(ch, style: style);
    if (t == 1) return text;
    final blur = 10 * k * (1 - t).clamp(0.0, 1.0);
    return Opacity(
      opacity: t.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(0, 40 * k * (1 - t)),
        child: Transform.scale(
          scale: .6 + .4 * t,
          child: blur > .1
              ? ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                  child: text,
                )
              : text,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.pose);

  final EmblemPose pose;

  static double _rad(double deg) => deg * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 360;
    final c = Offset(180 * k, 180 * k);
    final rect = Rect.fromCircle(center: c, radius: 150 * k);

    // 0° = 3 o'clock, clockwise. Gap is 245°..295° (centered on 12 o'clock).
    if (pose.track > 0) {
      canvas.drawArc(
        rect,
        _rad(-65),
        _rad(310 * pose.track.clamp(0.0, 1.0)),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 * k
          ..color = SpsColors.brand.withValues(alpha: .3),
      );
    }

    final brand = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10 * k
      ..strokeCap = StrokeCap.round
      ..color = SpsColors.brand;

    if (pose.arc > 0) {
      final sweep = _rad(130 * pose.arc.clamp(0.0, 1.0));
      final charge = pose.arcCharge.clamp(0.0, 1.0);
      if (charge > 0) {
        canvas.drawArc(
          rect,
          _rad(-65),
          sweep,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 10 * k
            ..strokeCap = StrokeCap.round
            ..color = SpsColors.energy.withValues(alpha: .95 * charge)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 14 * k * charge),
        );
      }
      canvas.drawArc(
        rect,
        _rad(-65),
        sweep,
        false,
        brand..color = Color.lerp(SpsColors.brand, SpsColors.energy, charge)!,
      );
    }

    if (pose.bar > 0) {
      final t = pose.bar.clamp(0.0, 1.0);
      final dy = -140 * k * (1 - t);
      canvas.drawLine(
        Offset(180 * k, 6 * k + dy),
        Offset(180 * k, 86 * k + dy),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10 * k
          ..strokeCap = StrokeCap.round
          ..color = SpsColors.brand.withValues(alpha: (t / .7).clamp(0.0, 1.0)),
      );
    }

    if (pose.spark > 0) {
      final a = _rad(-90 + 360 * pose.sparkTurn);
      final p = c + Offset(math.cos(a), math.sin(a)) * 150 * k;
      canvas.drawCircle(
        p,
        10 * k,
        Paint()
          ..color = SpsColors.energy.withValues(alpha: .35 * pose.spark)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawCircle(
        p,
        6 * k,
        Paint()..color = SpsColors.energy.withValues(alpha: pose.spark),
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => true;
}
