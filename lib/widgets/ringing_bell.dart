import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Swings [child] (a bell icon) like a ringing bell, on a loop, while
/// [ringing] is true: a short burst of swings, then a pause, repeated, so
/// unread notifications catch the eye without constant motion. Still when
/// [ringing] is false, and when the platform asks for reduced motion.
class RingingBell extends StatefulWidget {
  const RingingBell({super.key, required this.ringing, required this.child});

  final bool ringing;
  final Widget child;

  @override
  State<RingingBell> createState() => _RingingBellState();
}

class _RingingBellState extends State<RingingBell>
    with SingleTickerProviderStateMixin {
  /// One cycle: ~0.9 s of swinging, then a rest until 2.6 s.
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  static const _swingPart = 0.35;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant RingingBell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ringing != widget.ringing) _sync();
  }

  void _sync() {
    if (widget.ringing) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Angle in radians: a decaying swing during the first [_swingPart] of
  /// the cycle, still for the rest.
  double _angle(double t) {
    if (t >= _swingPart) return 0;
    final p = t / _swingPart; // 0..1 through the burst
    const swings = 4; // back-and-forth swings per burst
    const maxAngle = 0.32; // ~18°
    return maxAngle * (1 - p) * math.sin(p * swings * 2 * math.pi);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!widget.ringing || reduceMotion) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      // Pivot at the top, where a bell hangs.
      builder: (context, child) => Transform.rotate(
        angle: _angle(_c.value),
        alignment: Alignment.topCenter,
        child: child,
      ),
      child: widget.child,
    );
  }
}
