import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../../theme/app_fonts.dart';
import '../../theme/institute_colors.dart';
import 'web_theme.dart';
import 'web_widgets.dart';

/// "History": the latest recorded days with each day's energy, cost and
/// trend versus the day before. Shown on the web Dashboard (linking into
/// Analytics) and at the bottom of Analytics.
///
/// Loads only the newest `days + 1` keys of `history/daily` (the extra day
/// gives the oldest row something to compare against), so it always shows
/// the most recent data even when that is weeks old.
class HistoryTrendPanel extends StatefulWidget {
  const HistoryTrendPanel({
    super.key,
    required this.palette,
    this.instituteCode,
    this.onOpen,
    this.days = 10,
  });

  final InstitutePalette palette;

  /// Limit to one building (institute admins); null = campus-wide.
  final String? instituteCode;

  /// When set, the panel links to where it lives in Analytics.
  final VoidCallback? onOpen;

  final int days;

  @override
  State<HistoryTrendPanel> createState() => _HistoryTrendPanelState();
}

class _HistoryDay {
  const _HistoryDay(this.date, this.kwh, this.cost);
  final DateTime date;
  final double kwh;
  final double cost;
}

enum _Trend { baseline, stable, increasing, decreasing }

class _HistoryTrendPanelState extends State<HistoryTrendPanel> {
  StreamSubscription<DatabaseEvent>? _daysSub;
  StreamSubscription<DatabaseEvent>? _rateSub;
  Object? _raw;
  double _rate = 11.5;
  bool _loaded = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _daysSub = FirebaseDatabase.instance
        .ref('history/daily')
        .orderByKey()
        .limitToLast(widget.days + 1)
        .onValue
        .listen((e) {
      if (mounted) {
        setState(() {
          _raw = e.snapshot.value;
          _loaded = true;
        });
      }
    }, onError: (Object e) {
      debugPrint('[HistoryTrendPanel] $e');
      if (mounted) setState(() => _failed = true);
    });
    _rateSub = FirebaseDatabase.instance
        .ref('settings/electricityRate')
        .onValue
        .listen((e) {
      final v = e.snapshot.value;
      if (v is num && mounted) setState(() => _rate = v.toDouble());
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _daysSub?.cancel();
    _rateSub?.cancel();
    super.dispose();
  }

  static double _num(Object? v) => v is num ? v.toDouble() : 0;

  /// Oldest first.
  List<_HistoryDay> _days() {
    final raw = _raw;
    if (raw is! Map) return const [];
    final code = widget.instituteCode;
    final out = <_HistoryDay>[];
    raw.forEach((key, value) {
      final date = DateTime.tryParse(key.toString());
      if (date == null || value is! Map) return;
      double kwh;
      double? cost;
      if (code != null) {
        final b = value['buildings'];
        final node = b is Map ? b[code] : null;
        kwh = node is Map ? _num(node['kwh']) : 0;
        cost = node is Map && node['cost'] is num ? _num(node['cost']) : null;
      } else if (value['total_kwh'] is num) {
        kwh = _num(value['total_kwh']);
        cost = value['total_cost'] is num ? _num(value['total_cost']) : null;
      } else {
        kwh = 0;
        final devices = value['devices'];
        if (devices is Map) {
          for (final d in devices.values) {
            if (d is Map) kwh += _num(d['kwh']);
          }
        }
      }
      out.add(_HistoryDay(date, kwh, cost ?? kwh * _rate));
    });
    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  /// ±5% versus the previous recorded day counts as a change.
  static _Trend _trend(double value, double? previous) {
    if (previous == null) return _Trend.baseline;
    if (previous == 0) return value > 0 ? _Trend.increasing : _Trend.stable;
    final delta = (value - previous) / previous;
    if (delta >= .05) return _Trend.increasing;
    if (delta <= -.05) return _Trend.decreasing;
    return _Trend.stable;
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  String _dateLabel(DateTime d) {
    final year = d.year == DateTime.now().year ? '' : ', ${d.year}';
    return '${_months[d.month - 1]} ${d.day}$year · ${_weekdays[d.weekday - 1]}';
  }

  static String _money(double v) {
    final s = v.toStringAsFixed(2);
    final parts = s.split('.');
    final whole = parts[0]
        .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
    return '₱ $whole.${parts[1]}';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final days = _days();
    final shown = days.length > widget.days
        ? days.sublist(days.length - widget.days)
        : days;
    final offset = days.length - shown.length;
    final rows = [
      for (var i = shown.length - 1; i >= 0; i--)
        (
          shown[i],
          _trend(
              shown[i].kwh, i + offset > 0 ? days[i + offset - 1].kwh : null),
        ),
    ];

    final card = WebCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('History',
                      style: TextStyle(
                          fontFamily: AppFonts.family,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: WebColors.ink)),
                  const SizedBox(height: 3),
                  Text(
                    'Latest ${widget.days} days with trend versus the '
                    'previous day',
                    style:
                        const TextStyle(fontSize: 13, color: WebColors.muted),
                  ),
                ],
              ),
            ),
            if (widget.onOpen != null)
              TextButton(
                onPressed: widget.onOpen,
                style: TextButton.styleFrom(
                  foregroundColor: p.dark,
                  textStyle: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
                child: const Text('Analytics ›'),
              ),
          ]),
          const SizedBox(height: 18),
          if (_failed)
            const _Note('Could not load history.')
          else if (!_loaded)
            _Note('Loading…', color: p.mid)
          else if (rows.isEmpty)
            const _Note('No history recorded yet.')
          else
            _table(rows),
        ],
      ),
    );

    if (widget.onOpen == null) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: widget.onOpen, child: card),
    );
  }

  Widget _table(List<(_HistoryDay, _Trend)> rows) {
    final line = widget.palette.mid.withAlpha(33);
    const headStyle = TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: WebColors.muted,
        letterSpacing: .3);

    Widget row(List<Widget> cells, {bool header = false}) => Container(
          padding: EdgeInsets.fromLTRB(6, header ? 0 : 11, 6, header ? 9 : 11),
          decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(
                    color: header ? line : widget.palette.mid.withAlpha(15))),
          ),
          child: Row(children: [
            Expanded(flex: 10, child: cells[0]),
            Expanded(flex: 9, child: cells[1]),
            Expanded(flex: 7, child: cells[2]),
            Expanded(flex: 8, child: cells[3]),
          ]),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row(const [
          Text('Date', style: headStyle),
          Text('Energy', style: headStyle),
          Text('Cost', style: headStyle),
          Text('Trend', style: headStyle),
        ], header: true),
        for (final (day, trend) in rows)
          row([
            Text(_dateLabel(day.date),
                style: const TextStyle(fontSize: 14, color: WebColors.ink)),
            Text('${day.kwh.toStringAsFixed(2)} kWh',
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: WebColors.ink,
                    fontFeatures: [FontFeature.tabularFigures()])),
            Text(_money(day.cost),
                style: const TextStyle(
                    fontSize: 14,
                    color: WebColors.ink,
                    fontFeatures: [FontFeature.tabularFigures()])),
            Align(
                alignment: Alignment.centerLeft,
                child: _TrendPill(trend, widget.palette)),
          ]),
      ],
    );
  }
}

class _TrendPill extends StatelessWidget {
  const _TrendPill(this.trend, this.palette);

  final _Trend trend;
  final InstitutePalette palette;

  @override
  Widget build(BuildContext context) {
    final (label, fg, bg, border) = switch (trend) {
      _Trend.increasing => (
          'Increasing',
          const Color(0xFF9A5A0E),
          const Color(0x1FE8922A),
          const Color(0x66E8922A),
        ),
      _Trend.decreasing => (
          'Decreasing',
          palette.dark,
          palette.mid.withAlpha(26),
          palette.mid.withAlpha(77),
        ),
      _Trend.stable => (
          'Stable',
          WebColors.mid,
          const Color(0xFFEEF3F0),
          const Color(0xFFDFE8E2),
        ),
      _Trend.baseline => (
          'Baseline',
          WebColors.muted,
          Colors.transparent,
          Colors.transparent,
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11.5, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.color = WebColors.muted});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(text, style: TextStyle(fontSize: 14, color: color)),
      );
}
