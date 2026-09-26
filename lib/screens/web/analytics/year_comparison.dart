import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_fonts.dart';
import '../../../theme/institute_colors.dart';
import '../web_theme.dart';
import '../web_trend_chart.dart';
import 'analytics_data.dart';
import 'analytics_filter.dart';

/// Monthly totals of [year] for months [from]..[to] (1–12), using [f]'s
/// scope, utility and day-type filters and its kWh/₱ metric (not its date
/// range: the year picker replaces it). A month that hasn't started yet, or
/// that ends before the first recorded day in scope, is `NaN` ("no data"),
/// so the chart leaves a gap instead of drawing a false zero.
List<double> monthlyValues(AnalyticsFilter f, List<UsageRow> rows, int year,
    int from, int to, DateTime today) {
  final cost = f.metric == ValueMetric.cost;
  DateTime? first;
  final sums = List<double>.filled(12, 0);
  for (final r in rows) {
    if (!inScope(f, r) || !f.dayAllowed(r.date)) continue;
    if (first == null || r.date.isBefore(first)) first = r.date;
    if (r.date.year != year || r.date.isAfter(today)) continue;
    sums[r.date.month - 1] += cost ? r.cost : r.kwh;
  }
  return [
    for (var m = from; m <= to; m++)
      if (first == null ||
          DateTime(year, m, 1).isAfter(today) ||
          DateTime(year, m + 1, 0).isBefore(first))
        double.nan
      else
        sums[m - 1]
  ];
}

/// Two years of monthly usage drawn over each other (solid = the first
/// year, dashed = the year it is compared with), with pickers for both
/// years and the month range, and a total for each year over the months
/// both of them have data for.
class YearComparison extends StatefulWidget {
  /// Every parsed daily row (all dates); filtered here by [filter].
  final List<UsageRow> rows;
  final AnalyticsFilter filter;
  final InstitutePalette palette;
  final DateTime today;

  /// Phone layout: shorter chart, controls wrap onto more lines.
  final bool compact;

  const YearComparison({
    super.key,
    required this.rows,
    required this.filter,
    required this.palette,
    required this.today,
    this.compact = false,
  });

  @override
  State<YearComparison> createState() => _YearComparisonState();
}

class _YearComparisonState extends State<YearComparison> {
  int? _yearA;
  int? _yearB;
  int _from = 1;
  int _to = 12;
  int? _selected;

  static const _cmpColor = Color(0xFF8A9A90);

  /// Years with data in the current scope, newest first (always includes
  /// the current year so there is something to pick).
  List<int> _years() {
    final set = <int>{widget.today.year};
    for (final r in widget.rows) {
      if (inScope(widget.filter, r)) set.add(r.date.year);
    }
    return set.toList()..sort((a, b) => b.compareTo(a));
  }

  bool get _cost => widget.filter.metric == ValueMetric.cost;

  String _fmt(double v) {
    final s = v.toStringAsFixed(_cost ? 0 : (v.abs() < 100 ? 1 : 0));
    final parts = s.split('.');
    final whole = parts[0].replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    final n = parts.length > 1 ? '$whole.${parts[1]}' : whole;
    return _cost ? '₱$n' : '$n kWh';
  }

  @override
  Widget build(BuildContext context) {
    final years = _years();
    final a = (_yearA != null && years.contains(_yearA)) ? _yearA! : years.first;
    final defaultB = years.length > 1 ? years[1] : a - 1;
    final b = _yearB ?? defaultB;
    final p = widget.palette;

    final va = monthlyValues(widget.filter, widget.rows, a, _from, _to, widget.today);
    final vb = monthlyValues(widget.filter, widget.rows, b, _from, _to, widget.today);
    final months = [for (var m = _from; m <= _to; m++) m];

    String cell(double v) => v.isFinite ? _fmt(v) : 'no data';
    final points = [
      for (var i = 0; i < months.length; i++)
        TrendPoint(
          kMonths[months[i] - 1],
          '${kMonths[months[i] - 1]} · $a: ${cell(va[i])} · $b: ${cell(vb[i])}',
          va[i],
        ),
    ];

    // Totals over the months both years have data for, so a year in
    // progress is compared like for like.
    final both = [
      for (var i = 0; i < months.length; i++)
        if (va[i].isFinite && vb[i].isFinite) i
    ];
    final totalA = both.fold<double>(0, (s, i) => s + va[i]);
    final totalB = both.fold<double>(0, (s, i) => s + vb[i]);
    final pct = totalB > 0 ? (totalA - totalB) / totalB * 100 : null;
    final sel = _selected != null && _selected! < months.length ? _selected : null;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _label('Compare'),
          _picker<int>(
            value: a,
            items: years,
            text: (y) => '$y',
            color: p.dark,
            onChanged: (y) => setState(() {
              _yearA = y;
              _selected = null;
            }),
          ),
          _label('with'),
          _picker<int>(
            value: b,
            items: {...years, b}.toList()..sort((x, y) => y.compareTo(x)),
            text: (y) => '$y',
            color: _cmpColor,
            dashed: true,
            onChanged: (y) => setState(() {
              _yearB = y;
              _selected = null;
            }),
          ),
          const SizedBox(width: 6),
          _label('Months'),
          _picker<int>(
            value: _from,
            items: [for (var m = 1; m <= 12; m++) m],
            text: (m) => kMonths[m - 1],
            onChanged: (m) => setState(() {
              _from = m;
              if (_to < m) _to = m;
              _selected = null;
            }),
          ),
          _label('to'),
          _picker<int>(
            value: _to,
            items: [for (var m = _from; m <= 12; m++) m],
            text: (m) => kMonths[m - 1],
            onChanged: (m) => setState(() {
              _to = m;
              _selected = null;
            }),
          ),
        ],
      ),
      const SizedBox(height: 16),
      WebTrendChart(
        points: points,
        bars: false,
        color: p.mid,
        height: widget.compact ? 210 : 260,
        compare: vb,
        compareColor: _cmpColor,
        selected: sel,
        onSelect: (i) => setState(() => _selected = i),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 18, runSpacing: 6, children: [
        _legend(p.mid, false, '$a'),
        _legend(_cmpColor, true, '$b'),
      ]),
      const SizedBox(height: 14),
      _summary(a, b, totalA, totalB, pct, both, months),
    ]);
  }

  Widget _summary(int a, int b, double totalA, double totalB, double? pct,
      List<int> both, List<int> months) {
    if (both.isEmpty) {
      return Text(
          'No months with data in both $a and $b for this range and filter.',
          style: const TextStyle(fontSize: 13, color: AppColors.inkMid));
    }
    final span = both.length == months.length
        ? '${kMonths[months.first - 1]}–${kMonths[months.last - 1]}'
        : '${kMonths[months[both.first] - 1]}–${kMonths[months[both.last] - 1]}'
            ' (months both years have)';
    final up = (pct ?? 0) > 0;
    final pctColor = pct == null || pct.abs() < 0.05
        ? AppColors.inkMid
        : (up ? AppColors.errorText : AppColors.successText);
    Widget total(String year, double v, Color c, bool dashed) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: WebColors.outline),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
                width: 16,
                height: 10,
                child: CustomPaint(painter: _SwatchPainter(c, dashed))),
            const SizedBox(width: 8),
            Text('$year  ',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.inkMid)),
            Text(_fmt(v),
                style: const TextStyle(
                    fontFamily: AppFonts.family,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: AppColors.ink)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        total('$a', totalA, widget.palette.mid, false),
        total('$b', totalB, _cmpColor, true),
        if (pct != null)
          Text(
              pct.abs() < 0.05
                  ? 'Same as $b'
                  : '${up ? '▲' : '▼'} ${pct.abs().toStringAsFixed(1)}% vs $b',
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: pctColor)),
      ]),
      const SizedBox(height: 6),
      Text(span,
          style: const TextStyle(fontSize: 12.5, color: AppColors.inkMuted)),
    ]);
  }

  Widget _label(String s) => Text(s,
      style: const TextStyle(
          fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.inkMid));

  /// A compact outlined dropdown; [color] draws a swatch before the value
  /// (solid or [dashed]) so the year pickers double as the legend.
  Widget _picker<T>({
    required T value,
    required List<T> items,
    required String Function(T) text,
    required ValueChanged<T> onChanged,
    Color? color,
    bool dashed = false,
  }) {
    return Container(
      height: 38,
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: WebColors.outline),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (color != null) ...[
          SizedBox(
              width: 14,
              height: 10,
              child: CustomPaint(painter: _SwatchPainter(color, dashed))),
          const SizedBox(width: 6),
        ],
        DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isDense: true,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(10),
            icon: const Icon(Icons.expand_more,
                size: 18, color: AppColors.inkMuted),
            style: const TextStyle(
                fontFamily: AppFonts.family,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.ink),
            items: [
              for (final i in items)
                DropdownMenuItem<T>(value: i, child: Text(text(i))),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ]),
    );
  }

  Widget _legend(Color c, bool dashed, String label) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
            width: 18,
            height: 10,
            child: CustomPaint(painter: _SwatchPainter(c, dashed))),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(fontSize: 13, color: AppColors.inkMuted)),
      ]);
}

/// A short solid or dashed line, matching how each year is drawn.
class _SwatchPainter extends CustomPainter {
  final Color color;
  final bool dashed;
  const _SwatchPainter(this.color, this.dashed);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    if (!dashed) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      return;
    }
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawLine(
          Offset(x, y), Offset(math.min(x + 4, size.width), y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SwatchPainter old) =>
      old.color != color || old.dashed != dashed;
}
