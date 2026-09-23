import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'web_theme.dart';

/// One point of the Analytics consumption trend.
class TrendPoint {
  /// Short axis label, e.g. "Aug 25" or "Sep".
  final String label;

  /// Hover text, e.g. "Aug 25 · Mon · 33.1 kWh".
  final String tooltip;
  final double value;

  const TrendPoint(this.label, this.tooltip, this.value);
}

/// Line (area + dots) or bar chart with a rounded y-axis, evenly spaced
/// x labels and a hover crosshair / tooltip -- the Analytics trend chart
/// from the design preview.
class WebTrendChart extends StatefulWidget {
  final List<TrendPoint> points;
  final bool bars;
  final Color color;
  final double height;

  const WebTrendChart({
    super.key,
    required this.points,
    required this.bars,
    required this.color,
    this.height = 280,
  });

  @override
  State<WebTrendChart> createState() => _WebTrendChartState();
}

const _padL = 44.0, _padR = 12.0, _padT = 14.0, _padB = 30.0;

double niceAxisMax(double v) {
  if (v <= 0) return 10;
  final e = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
  final f = v / e;
  final n = f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10;
  return n * e;
}

class _WebTrendChartState extends State<WebTrendChart> {
  int? _hover;

  @override
  Widget build(BuildContext context) {
    final pts = widget.points;
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(builder: (context, c) {
        final n = pts.length;
        final pw = c.maxWidth - _padL - _padR;
        final maxV = niceAxisMax(pts.isEmpty ? 0 : pts.map((p) => p.value).reduce(math.max));
        final geo = _Geo(n, pw, c.maxHeight, maxV, widget.bars);

        return MouseRegion(
          onHover: (e) {
            if (n == 0) return;
            final i = geo.indexAt(e.localPosition.dx);
            if (i != _hover) setState(() => _hover = i);
          },
          onExit: (_) => setState(() => _hover = null),
          child: Stack(clipBehavior: Clip.none, children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _TrendPainter(
                  points: pts,
                  geo: geo,
                  color: widget.color,
                  hover: _hover,
                ),
              ),
            ),
            if (_hover != null && _hover! < n)
              Positioned(
                left: (geo.x(_hover!) - 95).clamp(0.0, math.max(0.0, c.maxWidth - 190)),
                top: math.max(0, geo.y(pts[_hover!].value) - 44),
                child: IgnorePointer(
                  child: Container(
                    width: 190,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: WebColors.ink,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(pts[_hover!].tooltip,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                  ),
                ),
              ),
          ]),
        );
      }),
    );
  }
}

/// Shared x/y mapping between the painter and the hover logic.
class _Geo {
  final int n;
  final double pw;
  final double height;
  final double maxV;
  final bool bars;

  _Geo(this.n, this.pw, this.height, this.maxV, this.bars);

  double get base => height - _padB;
  double get ph => base - _padT;

  /// Bars sit in the middle of equal slots; line points span the width.
  double x(int i) {
    if (bars) return _padL + pw * (i + 0.5) / math.max(1, n);
    return _padL + (n < 2 ? pw / 2 : pw * i / (n - 1));
  }

  double y(double v) => _padT + ph * (1 - (v / maxV).clamp(0.0, 1.0));

  int indexAt(double dx) {
    final raw = bars
        ? ((dx - _padL) / (pw / math.max(1, n)) - 0.5)
        : (n < 2 ? 0 : (dx - _padL) / (pw / (n - 1)));
    return raw.round().clamp(0, math.max(0, n - 1));
  }
}

class _TrendPainter extends CustomPainter {
  final List<TrendPoint> points;
  final _Geo geo;
  final Color color;
  final int? hover;

  _TrendPainter({
    required this.points,
    required this.geo,
    required this.color,
    required this.hover,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final g = geo;
    final grid = Paint()..color = const Color(0x1F4F6A58);
    for (var k = 0; k <= 4; k++) {
      final gy = _padT + g.ph * k / 4;
      canvas.drawLine(Offset(_padL, gy), Offset(size.width - _padR, gy), grid);
      final v = g.maxV * (4 - k) / 4;
      _text(canvas, v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1),
          Offset(_padL - 8, gy), align: 1);
    }
    final n = points.length;
    if (n == 0) return;

    if (g.bars) {
      final slot = g.pw / n;
      final w = (slot * 0.62).clamp(3.0, 26.0);
      for (var i = 0; i < n; i++) {
        final top = g.y(points[i].value);
        final r = RRect.fromRectAndCorners(
          Rect.fromLTRB(g.x(i) - w / 2, top, g.x(i) + w / 2, g.base),
          topLeft: const Radius.circular(4),
          topRight: const Radius.circular(4),
        );
        canvas.drawRRect(
            r, Paint()..color = i == hover ? color : color.withAlpha(185));
      }
    } else {
      final line = Path()..moveTo(g.x(0), g.y(points[0].value));
      for (var i = 1; i < n; i++) {
        line.lineTo(g.x(i), g.y(points[i].value));
      }
      final area = Path.from(line)
        ..lineTo(g.x(n - 1), g.base)
        ..lineTo(g.x(0), g.base)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withAlpha(90), color.withAlpha(6)],
          ).createShader(Rect.fromLTRB(0, _padT, size.width, g.base)),
      );
      canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round,
      );
      // Dots only while they stay legible.
      if (n <= 62) {
        for (var i = 0; i < n; i++) {
          final o = Offset(g.x(i), g.y(points[i].value));
          canvas.drawCircle(o, i == hover ? 6 : 4.2, Paint()..color = Colors.white);
          canvas.drawCircle(
              o,
              i == hover ? 6 : 4.2,
              Paint()
                ..color = color
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.8);
        }
      }
    }

    if (hover != null && hover! < n && !g.bars) {
      final hx = g.x(hover!);
      canvas.drawLine(Offset(hx, _padT), Offset(hx, g.base),
          Paint()..color = const Color(0x4D0E2E1A));
      canvas.drawCircle(Offset(hx, g.y(points[hover!].value)), 5, Paint()..color = color);
    }

    // About 8 evenly spaced x labels, always including the last point.
    final step = math.max(1, (n / 8).ceil());
    for (var i = 0; i < n; i += step) {
      if (n - 1 - i < step / 2 && i != n - 1) continue;
      _text(canvas, points[i].label, Offset(g.x(i), g.base + 16),
          align: g.bars ? 0 : (i == 0 ? -1 : 0));
    }
    _text(canvas, points[n - 1].label, Offset(g.x(n - 1), g.base + 16),
        align: g.bars ? 0 : 1);
  }

  /// [align]: -1 left of [at], 0 centred, 1 right-aligned; centred vertically.
  void _text(Canvas canvas, String s, Offset at, {int align = 0}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: const TextStyle(fontSize: 12, color: WebColors.muted)),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = align < 0
        ? at.dx
        : (align > 0 ? at.dx - tp.width : at.dx - tp.width / 2);
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.points != points ||
      old.hover != hover ||
      old.color != color ||
      old.geo.bars != geo.bars ||
      old.geo.pw != geo.pw;
}
