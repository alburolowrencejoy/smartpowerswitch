import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/forecast_comparison.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_fonts.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/forecast_comparison_chart.dart';
import 'web_theme.dart';

/// Model colours (the notebook's chart colours; LSTM keeps its old blue).
const kForecastColors = {
  'arima': Color(0xFF55A868),
  'xgboost': Color(0xFFC44E52),
  'gru': Color(0xFF8172B2),
  'lstm': Color(0xFF3B6FD8),
};

/// The forecast section of the web Analytics screen: ARIMA, XGBoost, GRU
/// and LSTM, compared the way the research notebook does it.
///
/// Everything comes from `history/predictions/comparison/{series}`, written
/// daily by `tools/forecast_comparison.py`; nothing is trained here. The
/// chart shows the test days (the last 20 % of the history): what was
/// actually used and what each model predicted for it from the real
/// readings up to the day before. The table ranks the models by RMSE, and
/// "Tomorrow" is each model's forecast for the next day.
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

class _ForecastComparisonState extends State<ForecastComparison> {
  StreamSubscription<Map<String, SeriesComparison>>? _sub;
  Map<String, SeriesComparison> _all = const {};
  bool _loaded = false;
  final Set<String> _hidden = {};

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

    final chart = _card(
      title: 'Actual vs day-ahead forecast',
      subtitle:
          '${widget.seriesName} · test period ${_range(c.testStart, c.testEnd)} '
          '(${c.testDays} days)',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _legend(c),
        const SizedBox(height: 12),
        ForecastComparisonChart(
          labels: c.labels,
          actual: c.actual,
          lines: [
            for (final k in ForecastComparisons.models)
              if (!_hidden.contains(k) && (c.models[k]?.ok ?? false))
                ForecastLine(c.models[k]!.name, kForecastColors[k]!,
                    c.models[k]!.values),
          ],
          actualColor: WebColors.ink,
          axisColor: WebColors.muted,
          tooltipColor: WebColors.ink,
          height: 280,
        ),
      ]),
    );
    final tomorrow = _tomorrowCard(c);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, box) {
        if (box.maxWidth < kWebWideContent) {
          return Column(
              children: [chart, const SizedBox(height: 16), tomorrow]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 2, child: chart),
          const SizedBox(width: 16),
          Expanded(child: tomorrow),
        ]);
      }),
      const SizedBox(height: 16),
      _tableCard(c),
      const SizedBox(height: 8),
      Text(
        'Each model is trained on the first ${c.trainDays} days '
        '(${_range(c.trainStart, c.trainEnd)}) and tested on the last ${c.testDays}: '
        'every test day is predicted from the real readings up to the day before. '
        'Lower MAE, RMSE and MAPE are better; R² closer to 1 is better.'
        '${c.incompleteDays > 0 ? ' ${c.incompleteDays} of ${c.days} days had no readings (meter offline) and were filled in from the days around them.' : ''}'
        '${c.generatedAt != null ? ' Trained ${_ago(c.generatedAt!)}.' : ''}',
        style: const TextStyle(fontSize: 12.5, color: WebColors.muted),
      ),
    ]);
  }

  Widget _legend(SeriesComparison c) {
    return Wrap(spacing: 6, runSpacing: 6, children: [
      _chip(WebColors.ink, 'Actual', true, null),
      for (final k in ForecastComparisons.models)
        if (c.models[k]?.ok ?? false)
          _chip(
              kForecastColors[k]!,
              c.models[k]!.name,
              !_hidden.contains(k),
              () => setState(() =>
                  _hidden.contains(k) ? _hidden.remove(k) : _hidden.add(k))),
    ]);
  }

  Widget _chip(Color color, String label, bool on, VoidCallback? onTap) {
    return Tooltip(
      message: onTap == null ? '' : (on ? 'Hide $label' : 'Show $label'),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: on ? color.withAlpha(140) : WebColors.outline),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                    color: on ? color : WebColors.outline,
                    borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: on ? WebColors.ink : WebColors.muted)),
          ]),
        ),
      ),
    );
  }

  Widget _tomorrowCard(SeriesComparison c) {
    final best = c.bestModel;
    final kwh = best?.nextDay;
    return _card(
      title: 'Tomorrow',
      subtitle: c.nextDay == null ? 'Next day' : _longDate(c.nextDay!),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: WebColors.outline),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('Best model · ${best?.name ?? '—'}',
                  style:
                      const TextStyle(fontSize: 12.5, color: WebColors.muted)),
              const SizedBox(width: 6),
              if (best != null) const _BestChip(),
            ]),
            const SizedBox(height: 6),
            Text(kwh == null ? '—' : '${kwh.toStringAsFixed(2)} kWh',
                style: const TextStyle(
                    fontFamily: AppFonts.family,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: WebColors.ink)),
            const SizedBox(height: 2),
            Text(
                kwh == null
                    ? ''
                    : 'About ₱ ${(kwh * widget.rate).toStringAsFixed(2)} at ₱${widget.rate.toStringAsFixed(2)}/kWh',
                style: const TextStyle(fontSize: 13, color: WebColors.mid)),
          ]),
        ),
        const SizedBox(height: 12),
        for (final k in ForecastComparisons.models)
          if (c.models[k] case final m?)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                        color: kForecastColors[k],
                        borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(m.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: WebColors.ink))),
                Text(
                    m.ok && m.nextDay != null
                        ? '${m.nextDay!.toStringAsFixed(2)} kWh'
                        : 'Not available',
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: m.ok ? FontWeight.w700 : FontWeight.w400,
                        color: m.ok ? WebColors.ink : WebColors.muted)),
              ]),
            ),
      ]),
    );
  }

  Widget _tableCard(SeriesComparison c) {
    const head = TextStyle(
        fontSize: 12.5, fontWeight: FontWeight.w600, color: WebColors.muted);
    const cell = TextStyle(
        fontFamily: AppFonts.family,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: WebColors.ink);
    String f(double? v, int digits) =>
        v == null ? '—' : v.toStringAsFixed(digits);
    final rows = [
      ...c.ranked,
      for (final k in ForecastComparisons.models)
        if (c.models[k] case final m? when !m.ok) m,
    ];
    Widget num(String s, {TextStyle style = cell}) =>
        Expanded(child: Text(s, textAlign: TextAlign.right, style: style));
    return _card(
      title: 'Model comparison',
      subtitle: 'Sorted by lowest RMSE · ${widget.seriesName}',
      child: LayoutBuilder(builder: (context, box) {
        // Too narrow for seven columns: scroll sideways instead of squeezing.
        const minWidth = 680.0;
        final table = Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              const SizedBox(width: 44, child: Text('Rank', style: head)),
              const Expanded(flex: 3, child: Text('Model', style: head)),
              num('MAE (kWh)', style: head),
              num('MSE', style: head),
              num('RMSE (kWh)', style: head),
              num('MAPE', style: head),
              num('R²', style: head),
            ]),
          ),
          for (final m in rows)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: m.key == c.best ? const Color(0xFFFFF8E6) : null,
                border: const Border(top: BorderSide(color: WebColors.outline)),
              ),
              child: Row(children: [
                SizedBox(
                    width: 44,
                    child: Text(m.rank?.toString() ?? '—', style: cell)),
                Expanded(
                  flex: 3,
                  child: Row(children: [
                    Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                            color: kForecastColors[m.key],
                            borderRadius: BorderRadius.circular(3))),
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
                    if (m.key == c.best) ...[
                      const SizedBox(width: 8),
                      const _BestChip()
                    ],
                  ]),
                ),
                num(f(m.mae, 2)),
                num(f(m.mse, 2)),
                num(f(m.rmse, 2)),
                num(m.mape == null ? '—' : '${m.mape!.toStringAsFixed(1)}%'),
                num(f(m.r2, 3)),
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
