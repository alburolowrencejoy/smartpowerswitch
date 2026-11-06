import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_fonts.dart';

/// One model's line on a [ForecastComparisonChart].
class ForecastLine {
  final String name;
  final Color color;
  final List<double?> values;
  const ForecastLine(this.name, this.color, this.values);
}

/// Actual daily kWh over the test days (solid, green) with each model's
/// day-ahead predictions on top (thinner, coloured) -- the notebook's
/// "actual vs forecast" chart. The gap between the actual line and each
/// model's line is shaded in that model's colour, so the size of the miss
/// reads at a glance. Hover (mouse) or tap (touch) a day to read every
/// value; tap the same day again to clear it.
class ForecastComparisonChart extends StatefulWidget {
  final List<DateTime> labels;
  final List<double?> actual;
  final List<ForecastLine> lines;
  final Color actualColor;
  final Color axisColor;
  final Color tooltipColor;
  final double height;

  /// Unit shown above the y-axis numbers.
  final String unit;

  /// Index of the first day that hasn't happened yet: a dashed divider
  /// marked "Forecast" is drawn just before it. Null = all days are past.
  final int? forecastFrom;

  const ForecastComparisonChart({
    super.key,
    required this.labels,
    required this.actual,
    required this.lines,
    this.actualColor = AppColors.greenMid,
    this.axisColor = const Color(0xFF6B7C72),
    this.tooltipColor = const Color(0xFF14261B),
    this.height = 260,
    this.unit = 'kWh',
    this.forecastFrom,
  });

  @override
  State<ForecastComparisonChart> createState() =>
      _ForecastComparisonChartState();
}

const _l = 44.0, _r = 12.0, _t = 26.0, _b = 26.0;
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
String _fmt(DateTime d) => '${_months[d.month - 1]} ${d.day}';

class _ForecastComparisonChartState extends State<ForecastComparisonChart> {
  int? _hover;

  int get _n => widget.labels.length;

  int _indexAt(double dx, double width) {
    final pw = width - _l - _r;
    if (_n < 2) return 0;
    return ((dx - _l) / (pw / (_n - 1))).round().clamp(0, _n - 1);
  }

  @override
  Widget build(BuildContext context) {
    final all = [
      ...widget.actual,
      for (final l in widget.lines) ...l.values,
    ].whereType<double>().where((v) => v.isFinite);
    final maxV = _niceMax(all.isEmpty ? 0 : all.reduce(math.max));
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(builder: (context, c) {
        final pw = c.maxWidth - _l - _r;
        double xOf(int i) => _l + (_n < 2 ? pw / 2 : pw * i / (_n - 1));
        final h = _hover;
        return MouseRegion(
          onHover: (e) {
            if (_n == 0) return;
            final i = _indexAt(e.localPosition.dx, c.maxWidth);
            if (i != _hover) setState(() => _hover = i);
          },
          onExit: (_) => setState(() => _hover = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (e) {
              if (_n == 0) return;
              final i = _indexAt(e.localPosition.dx, c.maxWidth);
              setState(() => _hover = i == _hover ? null : i);
            },
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _Painter(
                    labels: widget.labels,
                    actual: widget.actual,
                    lines: widget.lines,
                    actualColor: widget.actualColor,
                    axisColor: widget.axisColor,
                    maxV: maxV,
                    hover: h,
                    unit: widget.unit,
                    forecastFrom: widget.forecastFrom,
                  ),
                ),
              ),
              if (h != null && h < _n)
                Positioned(
                  left: (xOf(h) + (xOf(h) > c.maxWidth / 2 ? -178 : 12))
                      .clamp(0.0, math.max(0.0, c.maxWidth - 170)),
                  top: 0,
                  child: IgnorePointer(child: _tooltip(h)),
                ),
            ]),
          ),
        );
      }),
    );
  }

  Widget _tooltip(int i) {
    const style = TextStyle(
        fontFamily: AppFonts.family,
        fontSize: 12,
        color: Colors.white,
        height: 1.35);
    String v(List<double?> vs) => i < vs.length && vs[i] != null
        ? '${vs[i]!.toStringAsFixed(vs[i]! < 10 ? 2 : 1)} ${widget.unit}'
        : '—';
    Widget row(Color c, String name, String value, {bool bold = false}) =>
        Row(children: [
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: c, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 6),
          Expanded(child: Text(name, style: style)),
          Text(value,
              style: style.copyWith(
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
        ]);
    return Container(
      width: 166,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
          color: widget.tooltipColor, borderRadius: BorderRadius.circular(8)),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_fmt(widget.labels[i]),
                style: style.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            row(widget.actualColor, 'Actual', v(widget.actual), bold: true),
            for (final l in widget.lines) row(l.color, l.name, v(l.values)),
          ]),
    );
  }
}

/// Top of the y-axis: four round steps (1, 2, 2.5 or 5 x 10^n each), so
/// every gridline lands on a value that prints exactly.
double _niceMax(double v) {
  if (!v.isFinite || v <= 0) return 10;
  final step = v / 4;
  final e = math.pow(10, (math.log(step) / math.ln10).floor()).toDouble();
  final f = step / e;
  final n = f <= 1
      ? 1
      : f <= 2
          ? 2
          : f <= 2.5
              ? 2.5
              : f <= 5
                  ? 5
                  : 10;
  return n * e * 4;
}

/// Decimals needed to print every multiple of [step] exactly (at most 3).
int _decimals(double step) {
  for (var d = 0; d < 3; d++) {
    final s = step * math.pow(10, d);
    if ((s - s.round()).abs() < 1e-6) return d;
  }
  return 3;
}

class _Painter extends CustomPainter {
  final List<DateTime> labels;
  final List<double?> actual;
  final List<ForecastLine> lines;
  final Color actualColor, axisColor;
  final double maxV;
  final int? hover;
  final String unit;
  final int? forecastFrom;

  _Painter({
    required this.labels,
    required this.actual,
    required this.lines,
    required this.actualColor,
    required this.axisColor,
    required this.maxV,
    required this.hover,
    required this.unit,
    this.forecastFrom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final pw = size.width - _l - _r, ph = size.height - _t - _b, base = _t + ph;
    final n = labels.length;
    double x(int i) => _l + (n < 2 ? pw / 2 : pw * i / (n - 1));
    double y(double v) => _t + ph * (1 - (v / maxV).clamp(0.0, 1.0));

    final grid = Paint()..color = axisColor.withAlpha(40);
    final decimals = _decimals(maxV / 4);
    for (var g = 0; g <= 4; g++) {
      final gy = _t + ph * g / 4;
      canvas.drawLine(Offset(_l, gy), Offset(size.width - _r, gy), grid);
      final v = maxV * (4 - g) / 4;
      _text(canvas, v == 0 ? '0' : v.toStringAsFixed(decimals),
          Offset(_l - 6, gy),
          align: 1);
    }
    _text(canvas, unit, const Offset(_l - 6, _t - 16), align: 1, bold: true);
    if (n == 0) return;

    final f = forecastFrom;
    if (f != null && f > 0 && f < n) {
      final fx = (x(f - 1) + x(f)) / 2;
      final dash = Paint()
        ..color = axisColor.withAlpha(150)
        ..strokeWidth = 1;
      for (var dy = _t; dy < base; dy += 8) {
        canvas.drawLine(
            Offset(fx, dy), Offset(fx, math.min(dy + 4, base)), dash);
      }
      _text(canvas, 'Forecast', Offset(fx + 6, _t - 16),
          align: -1, bold: true);
    }

    void drawSeries(List<double?> vs, Color color, double width) {
      final path = Path();
      var pen = false;
      for (var i = 0; i < n && i < vs.length; i++) {
        final v = vs[i];
        if (v == null || !v.isFinite) {
          pen = false;
          continue;
        }
        pen ? path.lineTo(x(i), y(v)) : path.moveTo(x(i), y(v));
        pen = true;
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = width
            ..strokeJoin = StrokeJoin.round);
    }

    // The gap between the actual line and each model's line, filled in the
    // model's colour. Where the lines cross, the band is split at the
    // crossing so it narrows to a point there.
    for (final l in lines) {
      final band = Path();
      for (var i = 0; i + 1 < n; i++) {
        if (i + 1 >= actual.length || i + 1 >= l.values.length) break;
        final a0 = actual[i], a1 = actual[i + 1];
        final m0 = l.values[i], m1 = l.values[i + 1];
        if (a0 == null || a1 == null || m0 == null || m1 == null) continue;
        if (![a0, a1, m0, m1].every((v) => v.isFinite)) continue;
        final d0 = m0 - a0, d1 = m1 - a1;
        if (d0 * d1 < 0) {
          final t = d0 / (d0 - d1);
          final c = Offset(x(i) + (x(i + 1) - x(i)) * t, y(a0 + (a1 - a0) * t));
          band
            ..addPolygon([Offset(x(i), y(a0)), c, Offset(x(i), y(m0))], true)
            ..addPolygon(
                [c, Offset(x(i + 1), y(a1)), Offset(x(i + 1), y(m1))], true);
        } else {
          band.addPolygon([
            Offset(x(i), y(a0)),
            Offset(x(i + 1), y(a1)),
            Offset(x(i + 1), y(m1)),
            Offset(x(i), y(m0)),
          ], true);
        }
      }
      canvas.drawPath(band, Paint()..color = l.color.withAlpha(110));
    }

    drawSeries(actual, actualColor, 2.6);
    for (final l in lines) {
      drawSeries(l.values, l.color, 1.8);
    }

    // Fewer date labels on a narrow chart, so they don't run together.
    final parts = size.width < 420 ? 2 : 4;
    final step = math.max(1, ((n - 1) / parts).round());
    for (final i in {for (var k = 0; k < parts; k++) step * k, n - 1}) {
      if (i < 0 || i >= n) continue;
      if (i != n - 1 && n - 1 - i < step / 2) continue;
      _text(canvas, _fmt(labels[i]), Offset(x(i), base + 14),
          align: i == 0 ? -1 : (i == n - 1 ? 1 : 0));
    }

    final h = hover;
    if (h != null && h < n) {
      final hx = x(h);
      canvas.drawLine(Offset(hx, _t), Offset(hx, base),
          Paint()..color = axisColor.withAlpha(120));
      void dot(List<double?> vs, Color c) {
        if (h >= vs.length || vs[h] == null) return;
        canvas.drawCircle(
            Offset(hx, y(vs[h]!)), 4.5, Paint()..color = Colors.white);
        canvas.drawCircle(Offset(hx, y(vs[h]!)), 3, Paint()..color = c);
      }

      for (final l in lines) {
        dot(l.values, l.color);
      }
      dot(actual, actualColor);
    }
  }

  /// [align]: -1 left, 0 centre, 1 right of [at]; vertically centred.
  void _text(Canvas canvas, String s, Offset at,
      {int align = 0, bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: TextStyle(
              fontFamily: AppFonts.family,
              fontSize: 12,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
              color: axisColor)),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = align < 0
        ? at.dx
        : (align > 0 ? at.dx - tp.width : at.dx - tp.width / 2);
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _Painter old) =>
      old.labels != labels ||
      old.actual != actual ||
      old.lines != lines ||
      old.hover != hover ||
      old.maxV != maxV ||
      old.unit != unit ||
      old.forecastFrom != forecastFrom;
}
