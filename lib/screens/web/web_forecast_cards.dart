import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/forecast_comparison.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_fonts.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/forecast_comparison_chart.dart';
import 'web_theme.dart';

/// Model colours (the notebook's chart colours; LSTM keeps its old blue).
/// ARIMA takes the notebook's orange because green is the actual readings.
const kForecastColors = {
  'arima': Color(0xFFDD8452),
  'xgboost': Color(0xFFC44E52),
  'gru': Color(0xFF8172B2),
  'lstm': Color(0xFF3B6FD8),
};

/// The forecast section of the web Analytics screen: ARIMA, XGBoost, GRU
/// and LSTM, compared the way the research notebook does it.
///
/// Everything comes from `history/predictions/comparison/{series}`, written
/// daily by `tools/forecast_comparison.py`; nothing is trained here.
///
/// "Tomorrow" is the notebook's comparison: the chart shows the test days
/// (the last 20 % of the history), what was actually used and what each
/// model predicted for it from the real readings up to the day before.
/// "Next 7 days" / "Next 30 days" show the same models forecasting further
/// ahead, one day at a time on their own predictions: scored on the last
/// test days, then run for the coming days. The chart and the table follow
/// the selected horizon; the forecast card beside the chart shows the
/// model picked in the dropdown for all three horizons.
class ForecastComparison extends StatefulWidget {
  final InstitutePalette palette;
  final double rate;

  /// 'campus', an institute code, or null when the Analytics filter is
  /// narrower than any published series.
  final String? series;

  /// Shown in titles, e.g. "Whole campus" or "IC Building".
  final String seriesName;

  /// Defaults to the live database; tests pass a fixed stream.
  final Stream<Map<String, SeriesComparison>>? source;

  const ForecastComparison({
    super.key,
    required this.palette,
    required this.rate,
    required this.series,
    required this.seriesName,
    this.source,
  });

  @override
  State<ForecastComparison> createState() => _ForecastComparisonState();
}

/// One horizon of a [SeriesComparison]: 1 (tomorrow, the day-ahead
/// comparison) or 7 / 30 days. Answers every "what does this horizon show"
/// question so the cards don't each branch on it.
class _View {
  final SeriesComparison c;
  final int days;
  const _View(this.c, this.days);

  bool get dayAhead => days == 1;
  HorizonInfo? get info => dayAhead ? null : c.horizons[days];
  String? get best => dayAhead ? c.best : info?.best;

  HorizonScore? _h(ModelScore m) => dayAhead ? null : m.horizons[days];
  bool ok(ModelScore m) => dayAhead ? m.ok : _h(m) != null;
  double? rmse(ModelScore m) => dayAhead ? m.rmse : _h(m)?.rmse;
  double? mape(ModelScore m) => dayAhead ? m.mape : _h(m)?.mape;
  int? rank(ModelScore m) => dayAhead ? m.rank : _h(m)?.rank;

  /// Models with a result, lowest RMSE first, then the ones without.
  List<ModelScore> get rows {
    final good = [
      for (final m in c.models.values)
        if (ok(m) && rmse(m) != null) m
    ]..sort((a, b) => rmse(a)!.compareTo(rmse(b)!));
    return [
      ...good,
      for (final k in ForecastComparisons.models)
        if (c.models[k] case final m? when !good.contains(m)) m,
    ];
  }

  /// The scored test days: all of them for tomorrow, the last few for a
  /// horizon (they sit at the end of the test period).
  int get scoredDays => dayAhead
      ? c.actual.length
      : math.min(info?.testDays ?? 0, c.actual.length);
  List<double?> get scoredActual =>
      c.actual.sublist(c.actual.length - scoredDays);
  List<double?> scoredPredicted(ModelScore m) =>
      dayAhead ? m.values : (_h(m)?.backtest ?? const []);

  // ── Chart: the test days, then (for a horizon) the forecast days ──

  List<DateTime> get labels => [
        ...c.labels,
        if (!dayAhead && info?.start != null)
          for (var i = 0; i < days; i++) info!.start!.add(Duration(days: i)),
      ];

  List<double?> get actual =>
      [...c.actual, if (!dayAhead) ...List<double?>.filled(days, null)];

  List<double?> line(ModelScore m) => dayAhead
      ? m.values
      : [
          ...List<double?>.filled(c.actual.length - scoredDays, null),
          ...scoredPredicted(m),
          ...?_h(m)?.values,
        ];

  int? get forecastFrom => dayAhead ? null : c.actual.length;
}

class _ForecastComparisonState extends State<ForecastComparison> {
  StreamSubscription<Map<String, SeriesComparison>>? _sub;
  Map<String, SeriesComparison> _all = const {};
  bool _loaded = false;

  /// The model drawn against the actual readings; null = the best one.
  String? _model;

  /// Days ahead: 1 (tomorrow), 7 or 30.
  int _days = 1;

  @override
  void initState() {
    super.initState();
    _sub = (widget.source ?? ForecastComparisons.watch()).listen((v) {
      if (!mounted) return;
      setState(() {
        _all = v;
        _loaded = true;
      });
    }, onError: (_) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final key = widget.series;
    final String? message;
    final s = key == null ? null : _all[key];
    if (key == null) {
      message =
          'Forecasts are made for the whole campus and for each institute. '
          'Clear the floor, room, device and utility filters to see them.';
    } else if (!_loaded) {
      message = 'Loading…';
    } else if (s == null) {
      message = 'Not trained yet. The daily job (Train Forecast Models and '
          'Publish Comparison) publishes the comparison every morning.';
    } else if (s.unavailable != null || s.models.isEmpty) {
      message = s.unavailable ?? 'No model has been trained yet.';
    } else {
      message = null;
    }
    if (message != null) {
      return _card(
        title: 'Forecast',
        subtitle: widget.seriesName,
        child: Container(
          height: 160,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(20),
          child: Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: WebColors.mid)),
        ),
      );
    }
    final c = s!;
    // A horizon the job hasn't published (yet) falls back to tomorrow.
    final v = _View(c, c.horizons.containsKey(_days) ? _days : 1);
    final pick = c.models[_model];
    final selected = pick != null && v.ok(pick)
        ? pick
        : (c.models[v.best] ??
            c.models.values
                .firstWhere(v.ok, orElse: () => c.models.values.first));

    final info = v.info;
    final chart = _card(
      title: v.dayAhead
          ? 'Actual vs day-ahead forecast'
          : 'Actual vs ${v.days}-day forecast',
      subtitle: v.dayAhead
          ? '${widget.seriesName} · test period ${_range(c.testStart, c.testEnd)} '
              '(${c.testDays} days)'
          : '${widget.seriesName} · next ${v.days} days ${_range(info?.start, info?.end)} · '
              'tested on ${_range(info?.testStart, info?.testEnd)}',
      trailing: _picker(v, selected),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (c.horizons.isNotEmpty) ...[
          Align(alignment: Alignment.centerLeft, child: _horizonSwitch(c)),
          const SizedBox(height: 14),
        ],
        if (v.ok(selected))
          ForecastComparisonChart(
            labels: v.labels,
            actual: v.actual,
            lines: [
              ForecastLine(selected.name, kForecastColors[selected.key]!,
                  v.line(selected)),
            ],
            actualColor: AppColors.greenMid,
            axisColor: WebColors.muted,
            tooltipColor: WebColors.ink,
            height: 280,
            forecastFrom: v.forecastFrom,
          )
        else
          Container(
            height: 280,
            alignment: Alignment.center,
            child: Text(selected.unavailable ?? 'Not available.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: WebColors.mid)),
          ),
        const SizedBox(height: 10),
        Wrap(spacing: 18, runSpacing: 6, children: [
          _legendItem(AppColors.greenMid, 'Actual'),
          _legendItem(
              kForecastColors[selected.key]!,
              v.dayAhead
                  ? '${selected.name} · day-ahead'
                  : '${selected.name} · ${v.days}-day forecast'),
          _legendItem(kForecastColors[selected.key]!.withAlpha(110),
              'Gap between them'),
        ]),
      ]),
    );
    final ahead = _forecastCard(v, selected);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, box) {
        if (box.maxWidth < kWebWideContent) {
          return Column(children: [chart, const SizedBox(height: 16), ahead]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 2, child: chart),
          const SizedBox(width: 16),
          Expanded(child: ahead),
        ]);
      }),
      const SizedBox(height: 16),
      _tableCard(v),
      const SizedBox(height: 8),
      Text(
        v.dayAhead
            ? 'Each model is trained on the first ${c.trainDays} days '
                '(${_range(c.trainStart, c.trainEnd)}) and tested on the last ${c.testDays}: '
                'every test day is predicted from the real readings up to the day before. '
                'Actual and Predicted are the kWh totals over those test days; '
                'Accuracy is 100% minus the average daily error (MAPE). Models are '
                'ranked by RMSE, the notebook\'s measure.'
            : 'Each model forecasts the next ${v.days} days one day at a time, '
                'feeding its own predictions back in. It was tested the same way on '
                '${v.scoredDays} days (${_range(info?.testStart, info?.testEnd)}): '
                'forecast from the day before, without seeing any of them. '
                'Actual and Predicted are the kWh totals over those days; Accuracy is '
                '100% minus the average daily error (MAPE). The further ahead, the '
                'less certain the forecast.'
                '${v.days > v.scoredDays ? ' Only ${v.scoredDays} test days exist, so the last ${v.days - v.scoredDays} forecast days are untested.' : ''}',
        style: const TextStyle(fontSize: 12.5, color: WebColors.muted),
      ),
      if (c.incompleteDays > 0 || c.generatedAt != null)
        Text(
          '${c.incompleteDays > 0 ? '${c.incompleteDays} of ${c.days} days had no readings (meter offline) and were filled in from the days around them. ' : ''}'
          '${c.generatedAt != null ? 'Trained ${_ago(c.generatedAt!)}.' : ''}',
          style: const TextStyle(fontSize: 12.5, color: WebColors.muted),
        ),
    ]);
  }

  /// Tomorrow / Next 7 days / Next 30 days.
  Widget _horizonSwitch(SeriesComparison c) {
    final options = {
      1: 'Tomorrow',
      for (final h in kForecastHorizons)
        if (c.horizons.containsKey(h)) h: 'Next $h days',
    };
    final current = c.horizons.containsKey(_days) ? _days : 1;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
          color: WebColors.track, borderRadius: BorderRadius.circular(11)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final e in options.entries)
          Material(
            color: e.key == current ? Colors.white : Colors.transparent,
            elevation: e.key == current ? 1 : 0,
            shadowColor: Colors.black26,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _days = e.key),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                child: Text(e.value,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: e.key == current
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: e.key == current
                            ? widget.palette.dark
                            : WebColors.mid)),
              ),
            ),
          ),
      ]),
    );
  }

  /// The model picker in the chart card's header (the pre-notebook
  /// "Compare with" dropdown): each model with its RMSE on the selected
  /// horizon, ★ on the best.
  Widget _picker(_View v, ModelScore cur) {
    return PopupMenuButton<String>(
      tooltip: 'Choose a model to compare with the actual readings',
      initialValue: cur.key,
      onSelected: (k) => setState(() => _model = k),
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      itemBuilder: (_) => [
        for (final k in ForecastComparisons.models)
          if (v.c.models[k] case final m?)
            PopupMenuItem(
              value: k,
              enabled: v.ok(m),
              child: SizedBox(
                width: 260,
                child: Row(children: [
                  _Swatch(kForecastColors[k]!),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(m.name,
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: v.ok(m) ? WebColors.ink : WebColors.muted)),
                  ),
                  Text(
                    v.ok(m) && v.rmse(m) != null
                        ? 'RMSE ${v.rmse(m)!.toStringAsFixed(3)}'
                        : 'Not available',
                    style:
                        const TextStyle(fontSize: 12.5, color: WebColors.muted),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                      width: 58, child: k == v.best ? const _BestChip() : null),
                ]),
              ),
            ),
        PopupMenuItem(
          enabled: false,
          height: 30,
          child: Text(
              v.dayAhead
                  ? 'Best = lowest RMSE on the test days'
                  : 'Best = lowest RMSE on the ${v.days}-day test',
              style: const TextStyle(fontSize: 12, color: WebColors.muted)),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: widget.palette.mid.withAlpha(80)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _Swatch(kForecastColors[cur.key]!),
          const SizedBox(width: 8),
          Flexible(
            child: Text(cur.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: WebColors.ink)),
          ),
          if (cur.key == v.best) ...[
            const SizedBox(width: 6),
            const _BestChip(),
          ],
          const SizedBox(width: 4),
          const Icon(Icons.expand_more_rounded, size: 18, color: WebColors.mid),
        ]),
      ),
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _Swatch(color),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 12.5, color: WebColors.mid)),
    ]);
  }

  /// The model picked in the chart's dropdown: its forecast for tomorrow,
  /// the next 7 days and the next 30 days. The row of the horizon on the
  /// chart is highlighted; tapping a row switches the chart to it.
  Widget _forecastCard(_View v, ModelScore m) {
    final c = v.c;
    final color = kForecastColors[m.key]!;
    Widget row(int days, String label, String dates, double? kwh) {
      final active = v.days == days;
      final canSwitch = days == 1 || c.horizons.containsKey(days);
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: active ? color.withAlpha(22) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
                color: active ? color.withAlpha(150) : WebColors.outline),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: canSwitch ? () => setState(() => _days = days) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: WebColors.ink)),
                        const SizedBox(height: 2),
                        Text(dates,
                            style: const TextStyle(
                                fontSize: 12.5, color: WebColors.muted)),
                        if (kwh != null && days > 1)
                          Text('${(kwh / days).toStringAsFixed(2)} kWh a day',
                              style: const TextStyle(
                                  fontSize: 12.5, color: WebColors.muted)),
                      ]),
                ),
                const SizedBox(width: 12),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(kwh == null ? '—' : '${kwh.toStringAsFixed(2)} kWh',
                      style: const TextStyle(
                          fontFamily: AppFonts.family,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: WebColors.ink)),
                  const SizedBox(height: 2),
                  Text(
                      kwh == null
                          ? (canSwitch
                              ? 'Not available'
                              : 'After the next training run')
                          : '≈ ₱ ${(kwh * widget.rate).toStringAsFixed(2)}',
                      style: const TextStyle(
                          fontSize: 12.5, color: WebColors.mid)),
                ]),
              ]),
            ),
          ),
        ),
      );
    }

    return _card(
      title: '${m.name} forecast',
      subtitle: widget.seriesName,
      trailing: m.key == v.best ? const _BestChip() : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        row(
            1,
            'Tomorrow',
            c.nextDay == null ? 'Next day' : _longDate(c.nextDay!),
            m.ok ? m.nextDay : null),
        for (final h in kForecastHorizons)
          row(
              h,
              'Next $h days',
              c.horizons[h] == null
                  ? '—'
                  : _range(c.horizons[h]!.start, c.horizons[h]!.end),
              m.horizons[h]?.total),
        Text('Cost at ₱${widget.rate.toStringAsFixed(2)}/kWh.',
            style: const TextStyle(fontSize: 12.5, color: WebColors.muted)),
      ]),
    );
  }

  Widget _tableCard(_View v) {
    const head = TextStyle(
        fontSize: 12.5, fontWeight: FontWeight.w600, color: WebColors.muted);
    const cell = TextStyle(
        fontFamily: AppFonts.family,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: WebColors.ink);
    // Actual and predicted kWh summed over the scored days the model has a
    // prediction for, so both totals cover the same days.
    ({double actual, double predicted})? totals(ModelScore m) {
      final actual = v.scoredActual, predicted = v.scoredPredicted(m);
      var a = 0.0, p = 0.0, n = 0;
      for (var i = 0; i < actual.length && i < predicted.length; i++) {
        final av = actual[i], pv = predicted[i];
        if (av == null || pv == null) continue;
        a += av;
        p += pv;
        n++;
      }
      return n == 0 ? null : (actual: a, predicted: p);
    }

    String kwh(double? x) => x == null ? '—' : '${x.toStringAsFixed(2)} kWh';
    Widget num(String s, {TextStyle style = cell}) =>
        Expanded(child: Text(s, textAlign: TextAlign.right, style: style));
    final info = v.info;
    return _card(
      title: 'Model comparison',
      subtitle: v.dayAhead
          ? 'Test period totals · best first · ${widget.seriesName}'
          : '${v.days}-day forecast tested on ${_range(info?.testStart, info?.testEnd)} · '
              'best first · ${widget.seriesName}',
      child: LayoutBuilder(builder: (context, box) {
        // Too narrow for five columns: scroll sideways instead of squeezing.
        const minWidth = 560.0;
        final table = Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              const SizedBox(width: 44, child: Text('Rank', style: head)),
              const Expanded(flex: 3, child: Text('Model', style: head)),
              num('Actual', style: head),
              num('Predicted', style: head),
              num('Accuracy', style: head),
            ]),
          ),
          for (final m in v.rows)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: m.key == v.best ? const Color(0xFFFFF8E6) : null,
                border: const Border(top: BorderSide(color: WebColors.outline)),
              ),
              child: Row(children: [
                SizedBox(
                    width: 44,
                    child: Text(v.rank(m)?.toString() ?? '—', style: cell)),
                Expanded(
                  flex: 3,
                  child: Row(children: [
                    _Swatch(kForecastColors[m.key]!),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m.name, style: cell),
                            Text(
                                m.unavailable ??
                                    (m.order != null
                                        ? 'ARIMA(${m.order!.join(', ')})'
                                        : ForecastComparisons.blurbs[m.key] ??
                                            ''),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12, color: WebColors.muted)),
                          ]),
                    ),
                    if (m.key == v.best) ...[
                      const SizedBox(width: 8),
                      const _BestChip()
                    ],
                  ]),
                ),
                num(kwh(totals(m)?.actual)),
                num(kwh(totals(m)?.predicted)),
                num(v.mape(m) == null
                    ? '—'
                    : '${(100 - v.mape(m)!).clamp(0, 100).toStringAsFixed(1)}%'),
              ]),
            ),
        ]);
        if (box.maxWidth >= minWidth) return table;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: minWidth, child: table),
        );
      }),
    );
  }

  Widget _card({
    required String title,
    required String subtitle,
    Widget? trailing,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: WebColors.outline),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(
                      fontFamily: AppFonts.family,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: WebColors.ink)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: const TextStyle(fontSize: 13, color: WebColors.muted)),
            ]),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            Flexible(child: trailing)
          ],
        ]),
        const SizedBox(height: 16),
        child,
      ]),
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static String _short(DateTime d) => '${_months[d.month - 1]} ${d.day}';
  static String _longDate(DateTime d) =>
      '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}, ${d.year}';
  static String _range(DateTime? a, DateTime? b) =>
      a == null || b == null ? '—' : '${_short(a)} – ${_short(b)}, ${b.year}';

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inHours < 1) return 'less than an hour ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  const _Swatch(this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(3)));
  }
}

class _BestChip extends StatelessWidget {
  const _BestChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3D6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE8B84A)),
      ),
      child: const Text('★ Best',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF8A5A00))),
    );
  }
}
