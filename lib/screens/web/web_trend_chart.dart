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

  /// Optional earlier period, drawn as a dashed line aligned by index.
  final List<double>? compare;
  final Color compareColor;

  /// The tapped point, kept marked (ring, guide line and value bubble)
  /// until tapped again -- for touch screens, where there is no hover.
  final int? selected;

  /// Makes the chart tappable: called with the tapped index, or null when
  /// the selected point is tapped again.
  final ValueChanged<int?>? onSelect;

  const WebTrendChart({
    super.key,
    required this.points,
    required this.bars,
    required this.color,
    this.height = 280,
    this.compare,
    this.compareColor = const Color(0xFF8A9A90),
    this.selected,
    this.onSelect,
  });

  @override
  State<WebTrendChart> createState() => _WebTrendChartState();
}

const _padL = 44.0, _padR = 12.0, _padT = 14.0, _padB = 30.0;

double niceAxisMax(double v) {
  if (!v.isFinite || v <= 0) return 10;
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
        // Non-finite values would turn the whole axis into NaN (blank chart).
        final all = [...pts.map((p) => p.value), ...?widget.compare]
            .where((v) => v.isFinite)
            .toList();
        final maxV = niceAxisMax(all.isEmpty ? 0 : all.reduce(math.max));
        final geo = _Geo(n, pw, c.maxHeight, maxV, widget.bars);
        final sel = widget.selected != null && widget.selected! < n
            ? widget.selected
            : null;
        // The bubble follows the mouse; with none, it stays on the selection.
        final bubble = _hover ?? sel;

        final chart = MouseRegion(
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
                  selected: sel,
                  compare: widget.compare,
                  compareColor: widget.compareColor,
                ),
              ),
            ),
            if (bubble != null && bubble < n)
              Positioned(
                left: (geo.x(bubble) - 95).clamp(0.0, math.max(0.0, c.maxWidth - 190)),
                // Anchored by its bottom edge just above the point, clear of
                // its marker ring whatever the text height; below the point
                // when it is too near the top.
                bottom: geo.y(pts[bubble].value) >= 56
                    ? c.maxHeight - geo.y(pts[bubble].value) + 18
                    : null,
                top: geo.y(pts[bubble].value) >= 56
                    ? null
                    : geo.y(pts[bubble].value) + 18,
                child: IgnorePointer(
                  child: Container(
                    width: 190,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: WebColors.ink,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(pts[bubble].tooltip,
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
        final onSelect = widget.onSelect;
        if (onSelect == null) return chart;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            if (n == 0) return;
            final i = geo.indexAt(d.localPosition.dx);
            onSelect(i == sel ? null : i);
          },
          child: chart,
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

  double y(double v) =>
      _padT + ph * (1 - (v.isFinite ? v / maxV : 0.0).clamp(0.0, 1.0));

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
  final int? selected;
  final List<double>? compare;
  final Color compareColor;

  _TrendPainter({
    required this.points,
    required this.geo,
    required this.color,
    required this.hover,
    this.selected,
    this.compare,
    this.compareColor = const Color(0xFF8A9A90),
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
        final on = i == hover || i == selected;
        // With a selection, the other bars fade so the chosen one stands out.
        final alpha = on ? 255 : (selected != null ? 90 : 185);
        canvas.drawRRect(r, Paint()..color = color.withAlpha(alpha));
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
          final big = i == hover || i == selected;
          canvas.drawCircle(o, big ? 6 : 4.2, Paint()..color = Colors.white);
          canvas.drawCircle(
              o,
              big ? 6 : 4.2,
              Paint()
                ..color = color
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.8);
        }
      }
    }

    final cmp = compare;
    if (cmp != null && cmp.isNotEmpty) {
      final m = math.min(n, cmp.length);
      final path = Path()..moveTo(g.x(0), g.y(cmp[0]));
      for (var i = 1; i < m; i++) {
        path.lineTo(g.x(i), g.y(cmp[i]));
      }
      final dash = Paint()
        ..color = compareColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      for (final metric in path.computeMetrics()) {
        for (var d = 0.0; d < metric.length; d += 11) {
          canvas.drawPath(
              metric.extractPath(d, math.min(d + 6, metric.length)), dash);
        }
      }
    }

    final sel = selected;
    if (sel != null && sel < n) {
      // Selected point: a guide line down to the axis and a filled dot in a
      // soft halo, on the line point or on top of the bar.
      final sx = g.x(sel);
      final sy = g.y(points[sel].value);
      final guide = Paint()
        ..color = color.withAlpha(140)
        ..strokeWidth = 1.5;
      for (var d = sy + 10; d < g.base; d += 7) {
        canvas.drawLine(
            Offset(sx, d), Offset(sx, math.min(d + 4, g.base)), guide);
      }
      canvas.drawCircle(Offset(sx, sy), 13, Paint()..color = color.withAlpha(46));
      canvas.drawCircle(Offset(sx, sy), 7, Paint()..color = color);
      canvas.drawCircle(
          Offset(sx, sy),
          7,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5);
    }

    if (hover != null && hover! < n && hover != sel && !g.bars) {
      final hx = g.x(hover!);
      canvas.drawLine(Offset(hx, _padT), Offset(hx, g.base),
          Paint()..color = const Color(0x4D0E2E1A));
      canvas.drawCircle(Offset(hx, g.y(points[hover!].value)), 5, Paint()..color = color);
    }

    // Evenly spaced x labels -- as many as fit the plot width without
    // touching (at most 8, so a narrow phone chart of 30 days shows ~4),
    // always including the last point.
    const gap = 12.0;
    var widest = 0.0;
    for (final p in points) {
      widest = math.max(widest, _layout(p.label).width);
    }
    final fit = math.max(2, (g.pw / (widest + gap)).floor());
    final step = math.max(1, (n / math.min(8, fit)).ceil());
    // Place labels left to right, skipping any whose box would touch the
    // previous label or the (always shown) last one.
    double left(int i, double w, int align) => align < 0
        ? g.x(i)
        : (align > 0 ? g.x(i) - w : g.x(i) - w / 2);
    final lastAlign = g.bars ? 0 : 1;
    final lastLeft =
        left(n - 1, _layout(points[n - 1].label).width, lastAlign);
    var prevRight = double.negativeInfinity;
    for (var i = 0; i < n - 1; i += step) {
      final align = g.bars ? 0 : (i == 0 ? -1 : 0);
      final l = left(i, _layout(points[i].label).width, align);
      final r = l + _layout(points[i].label).width;
      if (r > lastLeft - gap) break;
      if (l < prevRight + gap) continue;
      _text(canvas, points[i].label, Offset(g.x(i), g.base + 16),
          align: align);
      prevRight = r;
    }
    _text(canvas, points[n - 1].label, Offset(g.x(n - 1), g.base + 16),
        align: lastAlign);
  }

  TextPainter _layout(String s) => TextPainter(
        text: TextSpan(
            text: s,
            style: const TextStyle(fontSize: 12, color: WebColors.muted)),
        textDirection: TextDirection.ltr,
      )..layout();

  /// [align]: -1 left of [at], 0 centred, 1 right-aligned; centred vertically.
  void _text(Canvas canvas, String s, Offset at, {int align = 0}) {
    final tp = _layout(s);
    final dx = align < 0
        ? at.dx
        : (align > 0 ? at.dx - tp.width : at.dx - tp.width / 2);
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.points != points ||
      old.hover != hover ||
      old.selected != selected ||
      old.compare != compare ||
      old.color != color ||
      old.geo.bars != geo.bars ||
      old.geo.pw != geo.pw;
}
