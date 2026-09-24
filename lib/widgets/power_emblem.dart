import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/sps_colors.dart';

/// Power-symbol (⏻) emblem with the SmartSwitch wordmark inside, used on
/// the web sign-in screen. Geometry is authored on a 360 × 360 canvas and
/// scaled proportionally to [size].
class PowerEmblem extends StatefulWidget {
  const PowerEmblem({super.key, this.size = 360});

  final double size;

  @override
  State<PowerEmblem> createState() => _PowerEmblemState();
}

class _PowerEmblemState extends State<PowerEmblem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _orbit =
      AnimationController(vsync: this, duration: const Duration(seconds: 9));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect reduce-motion: park the spark instead of orbiting.
    final reduce = MediaQuery.of(context).disableAnimations;
    if (reduce) {
      _orbit.stop();
    } else if (!_orbit.isAnimating) {
      _orbit.repeat();
    }
  }

  @override
  void dispose() {
    _orbit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final k = s / 360;
    final node = s * .15;

    Widget n(Offset c, IconData icon, String label, {bool filled = false}) {
      return Positioned(
        left: c.dx * k - node / 2,
        top: c.dy * k - node / 2,
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
              ),
              child: ExcludeSemantics(
                child: Icon(icon,
                    size: node * .42,
                    color: filled ? SpsColors.energy : SpsColors.brand),
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
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _orbit,
                builder: (_, __) =>
                    CustomPaint(painter: _RingPainter(_orbit.value)),
              ),
            ),
          ),
          Center(
            child: Semantics(
              header: true,
              label: 'SmartSwitch',
              child: ExcludeSemantics(
                child: Text.rich(
                  const TextSpan(children: [
                    TextSpan(
                        text: 'Smart\n',
                        style: TextStyle(color: SpsColors.ink)),
                    TextSpan(
                        text: 'Switch',
                        style: TextStyle(color: SpsColors.brand)),
                  ]),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 58 * k,
                    height: .92,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.045 * 58 * k,
                  ),
                ),
              ),
            ),
          ),
          n(const Offset(30, 180), Icons.show_chart, 'Monitor'),
          n(const Offset(180, 330), Icons.toggle_on_outlined, 'Control',
              filled: true),
          n(const Offset(330, 180), Icons.schedule, 'Schedule'),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.t);

  final double t;

  static double _rad(double deg) => deg * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 360;
    final c = Offset(180 * k, 180 * k);
    final rect = Rect.fromCircle(center: c, radius: 150 * k);

    // 0° = 3 o'clock, clockwise. Gap is 245°..295° (centered on 12 o'clock).
    canvas.drawArc(
      rect,
      _rad(-65),
      _rad(310),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 * k
        ..color = SpsColors.brand.withValues(alpha: .3),
    );

    final bold = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10 * k
      ..strokeCap = StrokeCap.round
      ..color = SpsColors.brand;
    canvas.drawArc(rect, _rad(-65), _rad(130), false, bold);
    canvas.drawLine(Offset(180 * k, 6 * k), Offset(180 * k, 86 * k), bold);

    // Orbiting spark, starting at 12 o'clock.
    final a = _rad(-90 + 360 * t);
    final p = c + Offset(math.cos(a), math.sin(a)) * 150 * k;
    canvas.drawCircle(
      p,
      10 * k,
      Paint()
        ..color = SpsColors.energy.withValues(alpha: .35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(p, 6 * k, Paint()..color = SpsColors.energy);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.t != t;
}
