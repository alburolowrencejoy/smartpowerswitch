import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../web_theme.dart';
import 'analytics_ui.dart';
import '../../../theme/app_fonts.dart';

/// The "Top Consuming Utilities" donut. Slices are hoverable and clickable.
class UtilityDonut extends StatefulWidget {
  /// Utility -> value, in the display metric.
  final List<MapEntry<String, double>> data;
  final String centerValue;
  final String centerCaption;
  final ValueChanged<String> onTap;

  const UtilityDonut({
    super.key,
    required this.data,
    required this.centerValue,
    required this.centerCaption,
    required this.onTap,
  });

  @override
  State<UtilityDonut> createState() => _UtilityDonutState();
}

const _size = 148.0, _radius = 56.0, _stroke = 20.0;

class _UtilityDonutState extends State<UtilityDonut> {
  int? _hover;

  int? _sliceAt(Offset p) {
    const c = Offset(_size / 2, _size / 2);
    final d = p - c;
    final dist = d.distance;
    if (dist < _radius - _stroke / 2 - 2 || dist > _radius + _stroke / 2 + 2) {
      return null;
    }
    var a = math.atan2(d.dy, d.dx) + math.pi / 2;
    if (a < 0) a += 2 * math.pi;
    final total = widget.data.fold<double>(0, (s, e) => s + e.value);
    if (total <= 0) return null;
    var acc = 0.0;
    for (var i = 0; i < widget.data.length; i++) {
      acc += widget.data[i].value / total * 2 * math.pi;
      if (a <= acc) return i;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final h = _hover;
    return Semantics(
      label: 'Utility split: ${widget.data.map((e) => e.key).join(', ')}',
      child: Tooltip(
        message: h == null || h >= widget.data.length
            ? ''
            : '${widget.data[h].key}: ${widget.data[h].value.toStringAsFixed(1)}',
        child: MouseRegion(
          cursor: h == null ? MouseCursor.defer : SystemMouseCursors.click,
          onHover: (e) {
            final i = _sliceAt(e.localPosition);
            if (i != _hover) setState(() => _hover = i);
          },
          onExit: (_) => setState(() => _hover = null),
          child: GestureDetector(
            onTapUp: (e) {
              final i = _sliceAt(e.localPosition);
              if (i != null) widget.onTap(widget.data[i].key);
            },
            child: SizedBox(
              width: _size,
              height: _size,
              child: CustomPaint(
                painter: _DonutPainter(widget.data, _hover),
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(widget.centerValue,
                        style: const TextStyle(
                            fontFamily: AppFonts.family,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: WebColors.ink)),
                    Text(widget.centerCaption,
                        style: const TextStyle(
                            fontSize: 12, color: WebColors.muted)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<MapEntry<String, double>> data;
  final int? hover;
  _DonutPainter(this.data, this.hover);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: c, radius: _radius);
    final total = data.fold<double>(0, (s, e) => s + e.value);
    if (total <= 0) {
      canvas.drawCircle(
          c,
          _radius,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = _stroke
            ..color = AnalyticsUi.track);
      return;
    }
    // Same 3 px gap between slices as the design preview.
    final gap = data.length > 1 ? 3 / (2 * math.pi * _radius) * 2 * math.pi : 0;
    var start = -math.pi / 2;
    for (var i = 0; i < data.length; i++) {
      final sweep = data[i].value / total * 2 * math.pi;
      canvas.drawArc(
        rect,
        start,
        math.max(0, sweep - gap),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = i == hover ? _stroke + 4 : _stroke
          ..color = AnalyticsUi.utilityColor(data[i].key),
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.data != data || old.hover != hover;
}
