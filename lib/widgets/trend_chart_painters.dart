import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Draws a dashed vertical line spanning the chart's full height -- used by
/// [LineChartPainter]/[BarChartPainter] to mark a picked day/range's
/// x-position without obscuring the trend underneath it the way a solid
/// fill would.
void _drawDashedVerticalGuide(Canvas canvas, double x, double height,
    {Color color = AppColors.greenDark}) {
  final paint = Paint()
    ..color = color
    ..strokeWidth = 1.75;
  const dashHeight = 5.0;
  const gapHeight = 4.0;
  var y = 0.0;
  while (y < height) {
    final segmentEnd = (y + dashHeight).clamp(0.0, height);
    canvas.drawLine(Offset(x, y), Offset(x, segmentEnd), paint);
    y += dashHeight + gapHeight;
  }
}

/// Washes a translucent band over [left, right] spanning the chart's full
/// height -- the actual "highlighted region" for a picked day/range,
/// painted underneath the two [_drawDashedVerticalGuide] boundary lines so
/// the selection reads clearly at a glance instead of relying on two thin
/// dashed lines alone (easy to miss, especially for a wide range). A
/// single-day pick (`left == right`) draws no band -- the boundary lines
/// already mark it precisely.
void _drawHighlightBand(Canvas canvas, double left, double right, double height,
    {Color color = AppColors.greenDark}) {
  if (left == right) return;
  final band = left <= right
      ? Rect.fromLTRB(left, 0, right, height)
      : Rect.fromLTRB(right, 0, left, height);
  canvas.drawRect(band, Paint()..color = color.withAlpha(48));
}

/// Smoothed area/line chart for a series of kWh values, shared by the
/// mobile and desktop dashboards' Analytics trend chart.
///
/// [highlightStartIndex]/[highlightEndIndex] are used by the desktop
/// History page's Daily calendar picker: the chart always plots the full
/// trend, and these draw a translucent highlight band between the two
/// indices' x-positions plus a dashed vertical guide line at each one
/// (spanning the chart's full height) to mark where a picked day/range sits
/// *within* it, instead of filtering the dataset down to the selection. A
/// single-day pick (equal start/end) draws just the one guide line, no
/// band. Leave both null to disable it.
class LineChartPainter extends CustomPainter {
  final List<double> data;
  final double maxKwh;
  final int? highlightStartIndex;
  final int? highlightEndIndex;
  final Color highlightColor;
  LineChartPainter({
    required this.data,
    required this.maxKwh,
    this.highlightStartIndex,
    this.highlightEndIndex,
    this.highlightColor = AppColors.greenDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final safeMaxKwh = maxKwh <= 0 ? 1.0 : maxKwh;
    final linePaint = Paint()
      ..color = AppColors.greenMid
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fillPaint = Paint()
      ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.greenMid.withAlpha(80),
            AppColors.greenMid.withAlpha(0)
          ]).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;
    final stepX = size.width / (data.length - 1);
    Offset off(int i) => Offset(
        i * stepX,
        (size.height - (data[i] / safeMaxKwh) * size.height)
            .clamp(0.0, size.height));
    final gridPaint = Paint()
      ..color = AppColors.greenMid.withAlpha(20)
      ..strokeWidth = 1;
    for (int i = 1; i < 4; i++) {
      canvas.drawLine(Offset(0, size.height * i / 4),
          Offset(size.width, size.height * i / 4), gridPaint);
    }

    final fillPath = Path()
      ..moveTo(0, size.height)
      ..lineTo(off(0).dx, off(0).dy);
    for (int i = 1; i < data.length; i++) {
      final p = off(i - 1);
      final c = off(i);
      fillPath.cubicTo(
          (p.dx + c.dx) / 2, p.dy, (p.dx + c.dx) / 2, c.dy, c.dx, c.dy);
    }
    fillPath
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(fillPath, fillPaint);
    final linePath = Path()..moveTo(off(0).dx, off(0).dy);
    for (int i = 1; i < data.length; i++) {
      final p = off(i - 1);
      final c = off(i);
      linePath.cubicTo(
          (p.dx + c.dx) / 2, p.dy, (p.dx + c.dx) / 2, c.dy, c.dx, c.dy);
    }
    canvas.drawPath(linePath, linePaint);

    // Daily picker's day/range highlight -- a translucent band across the
    // whole selected span, plus one dashed guide line per boundary index,
    // drawn on top so the selection reads clearly against the trend
    // line/fill. A single-day pick (equal start/end) only draws the one
    // line and no band.
    if (highlightStartIndex != null && highlightEndIndex != null) {
      final s = highlightStartIndex!.clamp(0, data.length - 1);
      final e = highlightEndIndex!.clamp(0, data.length - 1);
      _drawHighlightBand(canvas, off(s).dx, off(e).dx, size.height,
          color: highlightColor);
      _drawDashedVerticalGuide(canvas, off(s).dx, size.height,
          color: highlightColor);
      if (e != s) {
        _drawDashedVerticalGuide(canvas, off(e).dx, size.height,
            color: highlightColor);
      }
    }
  }

  @override
  bool shouldRepaint(LineChartPainter old) =>
      old.data != data ||
      old.maxKwh != maxKwh ||
      old.highlightStartIndex != highlightStartIndex ||
      old.highlightEndIndex != highlightEndIndex ||
      old.highlightColor != highlightColor;
}

/// Bar chart for a series of kWh values, shared by the mobile and desktop
/// dashboards' Analytics trend chart. See [LineChartPainter] re:
/// [highlightStartIndex]/[highlightEndIndex].
class BarChartPainter extends CustomPainter {
  final List<double> data;
  final double maxKwh;
  final int? highlightStartIndex;
  final int? highlightEndIndex;
  final Color highlightColor;
  BarChartPainter({
    required this.data,
    required this.maxKwh,
    this.highlightStartIndex,
    this.highlightEndIndex,
    this.highlightColor = AppColors.greenDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;
    final safeMaxKwh = maxKwh <= 0 ? 1.0 : maxKwh;
    final gridPaint = Paint()
      ..color = AppColors.greenMid.withAlpha(20)
      ..strokeWidth = 1;

    for (int i = 1; i < 4; i++) {
      canvas.drawLine(Offset(0, size.height * i / 4),
          Offset(size.width, size.height * i / 4), gridPaint);
    }

    final slotWidth = size.width / data.length;
    final barWidth = (slotWidth * 0.62).clamp(2.0, 18.0);
    final barPaint = Paint()..color = AppColors.greenMid;

    for (int i = 0; i < data.length; i++) {
      final normalized = (data[i] / safeMaxKwh).clamp(0.0, 1.0);
      final barHeight = normalized * size.height;
      final left = i * slotWidth + (slotWidth - barWidth) / 2;
      final top = size.height - barHeight;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, barWidth, barHeight),
        const Radius.circular(4),
      );
      canvas.drawRRect(rect, barPaint);
    }

    // Daily picker's day/range highlight -- same translucent band + dashed
    // vertical guide treatment as LineChartPainter, positioned across the
    // full width of the highlighted slots (not just their centers) so the
    // band visually contains the bars it covers. A single-day pick (equal
    // start/end) only draws the one line and no band.
    if (highlightStartIndex != null && highlightEndIndex != null) {
      final s = highlightStartIndex!.clamp(0, data.length - 1);
      final e = highlightEndIndex!.clamp(0, data.length - 1);
      double slotCenterX(int i) => i * slotWidth + slotWidth / 2;
      _drawHighlightBand(canvas, s * slotWidth, (e + 1) * slotWidth, size.height,
          color: highlightColor);
      _drawDashedVerticalGuide(canvas, slotCenterX(s), size.height,
          color: highlightColor);
      if (e != s) {
        _drawDashedVerticalGuide(canvas, slotCenterX(e), size.height,
            color: highlightColor);
      }
    }
  }

  @override
  bool shouldRepaint(BarChartPainter old) =>
      old.data != data ||
      old.maxKwh != maxKwh ||
      old.highlightStartIndex != highlightStartIndex ||
      old.highlightEndIndex != highlightEndIndex ||
      old.highlightColor != highlightColor;
}

/// Actual-vs-forecast trend chart (solid line for known history, amber line
/// for the projected values) used by the History page's prediction card.
class ForecastChartPainter extends CustomPainter {
  final List<double> actualData;
  final List<double> forecastData;
  final double maxKwh;

  ForecastChartPainter({
    required this.actualData,
    required this.forecastData,
    required this.maxKwh,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (actualData.isEmpty) return;

    final safeMaxKwh = maxKwh <= 0 ? 1.0 : maxKwh;
    final allData = <double>[...actualData, ...forecastData];
    final totalCount = allData.length;
    final stepX = totalCount < 2 ? 0.0 : size.width / (totalCount - 1);

    Offset off(int i) {
      final x = totalCount == 1 ? size.width / 2 : i * stepX;
      final y = size.height - (allData[i] / safeMaxKwh) * size.height;
      return Offset(x, y.clamp(0.0, size.height));
    }

    final gridPaint = Paint()
      ..color = AppColors.greenMid.withAlpha(18)
      ..strokeWidth = 1;
    for (int i = 1; i < 5; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final boundaryIndex = actualData.length - 1;
    if (boundaryIndex >= 0) {
      final boundaryX = off(boundaryIndex).dx;
      canvas.drawLine(
        Offset(boundaryX, 0),
        Offset(boundaryX, size.height),
        Paint()
          ..color = const Color(0xFFF59E0B).withAlpha(60)
          ..strokeWidth = 1,
      );
    }

    if (actualData.length >= 2) {
      final actualPath = Path()..moveTo(off(0).dx, off(0).dy);
      for (int i = 1; i < actualData.length; i++) {
        final prev = off(i - 1);
        final curr = off(i);
        final cp1 = Offset((prev.dx + curr.dx) / 2, prev.dy);
        final cp2 = Offset((prev.dx + curr.dx) / 2, curr.dy);
        actualPath.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, curr.dx, curr.dy);
      }

      final fillPath = Path()
        ..moveTo(off(0).dx, size.height)
        ..lineTo(off(0).dx, off(0).dy);
      for (int i = 1; i < actualData.length; i++) {
        final prev = off(i - 1);
        final curr = off(i);
        final cp1 = Offset((prev.dx + curr.dx) / 2, prev.dy);
        final cp2 = Offset((prev.dx + curr.dx) / 2, curr.dy);
        fillPath.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, curr.dx, curr.dy);
      }
      fillPath
        ..lineTo(off(actualData.length - 1).dx, size.height)
        ..close();

      canvas.drawPath(
        fillPath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.greenMid.withAlpha(70),
              AppColors.greenMid.withAlpha(0),
            ],
          ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
      );
      canvas.drawPath(
        actualPath,
        Paint()
          ..color = AppColors.greenMid
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    } else {
      canvas.drawCircle(off(0), 4.0, Paint()..color = AppColors.greenMid);
    }

    if (forecastData.isNotEmpty) {
      final forecastPath = Path();
      final startIndex = actualData.length - 1;
      forecastPath.moveTo(off(startIndex).dx, off(startIndex).dy);
      for (int i = actualData.length; i < allData.length; i++) {
        final prev = off(i - 1);
        final curr = off(i);
        final cp1 = Offset((prev.dx + curr.dx) / 2, prev.dy);
        final cp2 = Offset((prev.dx + curr.dx) / 2, curr.dy);
        forecastPath.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, curr.dx, curr.dy);
      }
      canvas.drawPath(
        forecastPath,
        Paint()
          ..color = const Color(0xFFF59E0B)
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );

      canvas.drawCircle(
        off(actualData.length - 1),
        4.5,
        Paint()..color = const Color(0xFFF59E0B),
      );
    }
  }

  @override
  bool shouldRepaint(ForecastChartPainter old) =>
      old.actualData != actualData ||
      old.forecastData != forecastData ||
      old.maxKwh != maxKwh;
}
