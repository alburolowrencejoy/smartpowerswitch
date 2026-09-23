import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../../services/forecast_models.dart';
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import 'web_theme.dart';

/// Two half-width forecast cards for the web Analytics screen.
///
/// Left: ARIMA, computed here from the daily history. Right: a picker to
/// compare against XGBoost or LSTM, which the Python job
/// (tools/train_and_push.py) trains daily and writes to
/// `history/predictions/models/{xgboost,lstm}`, or ARIMA itself.
///
/// Every model is scored by the same backtest (trained without the last 14
/// days, then compared with them); the lowest MAPE gets a ★ Best badge.
/// Both charts show only the next 30 days, on the same scale.
class ForecastComparison extends StatefulWidget {
  final InstitutePalette palette;

  /// Daily kWh, oldest first.
  final List<double> daily;

  /// Date of the last value in [daily], used to label the forecast days.
  final DateTime? lastDate;
  final double rate;

  const ForecastComparison({
    super.key,
    required this.palette,
    required this.daily,
    required this.lastDate,
    required this.rate,
  });

  @override
  State<ForecastComparison> createState() => _ForecastComparisonState();
}

class _Model {
  final String key;
  final String name;
  final String blurb;
  final Color color;
  final List<double>? values;
  final ForecastError? error;
  final DateTime? trainedAt;

  /// Why [values] is missing, if it is.
  final String? unavailable;

  const _Model({
    required this.key,
    required this.name,
    required this.blurb,
    required this.color,
    this.values,
    this.error,
    this.trainedAt,
    this.unavailable,
  });
}

const _arimaColor = Color(0xFF2E9E52);
const _xgbColor = Color(0xFFE8922A);
const _lstmColor = Color(0xFF3B6FD8);

class _ForecastComparisonState extends State<ForecastComparison> {
  StreamSubscription<DatabaseEvent>? _sub;
  Map<String, dynamic> _remote = {};
  bool _remoteLoaded = false;
  String _compare = 'xgboost';

  @override
  void initState() {
    super.initState();
    _sub = FirebaseDatabase.instance
        .ref('history/predictions/models')
        .onValue
        .listen((e) {
      if (!mounted) return;
      setState(() {
        final v = e.snapshot.value;
        _remote = v is Map ? Map<String, dynamic>.from(v) : {};
        _remoteLoaded = true;
      });
    }, onError: (_) {
      if (mounted) setState(() => _remoteLoaded = true);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  List<double> get _window => widget.daily.length > 90
      ? widget.daily.sublist(widget.daily.length - 90)
      : widget.daily;

  _Model _arima() {
    final w = _window;
    if (w.length < 2) {
      return const _Model(
        key: 'arima',
        name: 'ARIMA',
        blurb: 'Seasonal time-series model',
        color: _arimaColor,
        unavailable: 'Needs at least 2 days of daily history.',
      );
    }
    return _Model(
      key: 'arima',
      name: 'ARIMA',
      blurb: 'Seasonal time-series model',
      color: _arimaColor,
      values: arimaForecast(w, 30),
      error: backtest(w, (y, h) => arimaForecast(y, h)),
    );
  }

  _Model _remoteModel(String key, String name, String blurb, Color color) {
    final raw = _remote[key];
    if (!_remoteLoaded) {
      return _Model(
          key: key, name: name, blurb: blurb, color: color,
          unavailable: 'Loading…');
    }
    if (raw is! Map || raw['values'] is! List) {
      return _Model(
        key: key,
        name: name,
        blurb: blurb,
        color: color,
        unavailable: 'Not trained yet. The daily training job '
            '(Train LSTM and Publish Forecast) publishes it once there are '
            'at least 35 days of history.',
      );
    }
    final values = [
      for (final v in raw['values'] as List) v is num ? v.toDouble() : 0.0
    ];
    final gen = raw['generated_at'];
    return _Model(
      key: key,
      name: name,
      blurb: blurb,
      color: color,
      values: values.take(30).toList(),
      error: ForecastError.fromMap(raw['backtest']),
      trainedAt:
          gen is num ? DateTime.fromMillisecondsSinceEpoch(gen.toInt()) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final models = {
      'arima': _arima(),
      'xgboost': _remoteModel(
          'xgboost', 'XGBoost', 'Gradient-boosted trees', _xgbColor),
      'lstm': _remoteModel('lstm', 'LSTM', 'Recurrent neural network', _lstmColor),
    };
    String? best;
    for (final m in models.values) {
      final e = m.error;
      if (e == null || m.values == null) continue;
      if (best == null || e.mape < models[best]!.error!.mape) best = m.key;
    }
    final left = models['arima']!;
    final right = models[_compare]!;

    final all = [...?left.values, ...?right.values];
    final maxV = _niceMax(all.isEmpty ? 0 : all.reduce(math.max));
    final labels = List.generate(30, (i) {
      final d = widget.lastDate?.add(Duration(days: i + 1));
      return d;
    });

    final leftCard = _card(
      title: 'ARIMA Forecast',
      subtitle: '${left.blurb} · next 30 days',
      trailing: best == 'arima' ? const _BestChip(big: true) : null,
      model: left,
      labels: labels,
      maxV: maxV,
    );
    final rightCard = _card(
      title: 'Compare with',
      subtitle: '${right.blurb} · next 30 days',
      trailing: _picker(models, best),
      model: right,
      labels: labels,
      maxV: maxV,
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, c) {
        if (c.maxWidth < 900) {
          return Column(children: [leftCard, const SizedBox(height: 16), rightCard]);
        }
        // No IntrinsicHeight: the charts use LayoutBuilder, which it can't
        // measure. Both cards have the same fixed-height sections anyway.
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: leftCard),
          const SizedBox(width: 16),
          Expanded(child: rightCard),
        ]);
      }),
      const SizedBox(height: 8),
      const Text(
        'Both charts show the next 30 days on the same scale. Error is a '
        'backtest: each model is trained without the last 14 days and its '
        'predictions are compared with what actually happened. Lower is better.',
        style: TextStyle(fontSize: 12.5, color: WebColors.muted),
      ),
    ]);
  }

  Widget _picker(Map<String, _Model> models, String? best) {
    final p = widget.palette;
    final cur = models[_compare]!;
    return PopupMenuButton<String>(
      tooltip: 'Choose a model to compare',
      initialValue: _compare,
      onSelected: (v) => setState(() => _compare = v),
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      itemBuilder: (_) => [
        for (final m in models.values)
          PopupMenuItem(
            value: m.key,
            child: SizedBox(
              width: 260,
              child: Row(children: [
                _Swatch(m.color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(m.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, color: WebColors.ink)),
                ),
                Text(
                  m.error != null
                      ? '${m.error!.mape.toStringAsFixed(1)}% error'
                      : m.values != null
                          ? 'No backtest'
                          : 'Not available',
                  style: const TextStyle(fontSize: 12.5, color: WebColors.muted),
                ),
                const SizedBox(width: 8),
                SizedBox(
                    width: 58,
                    child: best == m.key ? const _BestChip() : null),
              ]),
            ),
          ),
        const PopupMenuItem(
          enabled: false,
          height: 30,
          child: Text('Best = lowest error on the last 14 days',
              style: TextStyle(fontSize: 12, color: WebColors.muted)),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.mid.withAlpha(80)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _Swatch(cur.color),
          const SizedBox(width: 8),
          Text(cur.name,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, color: WebColors.ink)),
          if (best == cur.key) ...[
            const SizedBox(width: 6),
            const _BestChip(),
          ],
          const SizedBox(width: 4),
          const Icon(Icons.expand_more_rounded, size: 18, color: WebColors.mid),
        ]),
      ),
    );
  }

  Widget _card({
    required String title,
    required String subtitle,
    required Widget? trailing,
    required _Model model,
    required List<DateTime?> labels,
    required double maxV,
  }) {
    final p = widget.palette;
    final values = model.values;
    final total = values?.fold<double>(0, (a, b) => a + b) ?? 0;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.mid.withAlpha(26)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: WebColors.ink)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: const TextStyle(fontSize: 13, color: WebColors.muted)),
            ]),
          ),
          if (trailing != null) trailing,
        ]),
        const SizedBox(height: 16),
        if (values == null)
          Container(
            height: 230,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: p.mid.withAlpha(60)),
            ),
            child: Text(model.unavailable ?? 'Not available.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: WebColors.mid)),
          )
        else ...[
          SizedBox(
            height: 230,
            child: _ForecastChart(
                values: values, labels: labels, color: model.color, maxV: maxV),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
                child: _Box('Projected 30-day kWh', total.toStringAsFixed(2))),
            const SizedBox(width: 10),
            Expanded(
                child: _Box('Estimated bill',
                    '₱ ${(total * widget.rate).toStringAsFixed(2)}')),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: _Box(
                  'Avg error (MAE)',
                  model.error == null
                      ? '—'
                      : '${model.error!.mae.toStringAsFixed(2)} kWh/day'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Box(
                  'Error % (MAPE)',
                  model.error == null
                      ? 'Needs 22+ days'
                      : '${model.error!.mape.toStringAsFixed(1)}%'),
            ),
          ]),
          if (model.trainedAt != null) ...[
            const SizedBox(height: 8),
            Text('Trained ${_ago(model.trainedAt!)}',
                style: const TextStyle(fontSize: 12, color: WebColors.muted)),
          ],
        ],
      ]),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inHours < 1) return 'less than an hour ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
  }
}

double _niceMax(double v) {
  if (v <= 0) return 10;
  final e = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
  final f = v / e;
  final n = f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10;
  return n * e;
}

class _Swatch extends StatelessWidget {
  final Color color;
  const _Swatch(this.color);

  @override
  Widget build(BuildContext context) => Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)));
}

class _BestChip extends StatelessWidget {
  final bool big;
  const _BestChip({this.big = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: big ? 10 : 7, vertical: big ? 5 : 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3D6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE8B84A)),
      ),
      child: Text('★ Best',
          style: TextStyle(
              fontSize: big ? 12.5 : 11,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF8A5A00))),
    );
  }
}

class _Box extends StatelessWidget {
  final String label;
  final String value;
  const _Box(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final p = context.institutePalette;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.pale.withAlpha(65),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.mid.withAlpha(28)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 12.5, color: WebColors.muted)),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(
                fontFamily: 'Outfit',
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: WebColors.ink)),
      ]),
    );
  }
}

/// Area chart of the forecast only, with a hover crosshair and tooltip.
class _ForecastChart extends StatefulWidget {
  final List<double> values;
  final List<DateTime?> labels;
  final Color color;
  final double maxV;

  const _ForecastChart({
    required this.values,
    required this.labels,
    required this.color,
    required this.maxV,
  });

  @override
  State<_ForecastChart> createState() => _ForecastChartState();
}

class _ForecastChartState extends State<_ForecastChart> {
  int? _hover;

  static const _left = 44.0, _right = 12.0, _top = 12.0, _bottom = 26.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final n = widget.values.length;
      final pw = c.maxWidth - _left - _right;
      double xOf(int i) => _left + (n < 2 ? pw / 2 : pw * i / (n - 1));
      return MouseRegion(
        onHover: (e) {
          if (n == 0) return;
          final i = n < 2
              ? 0
              : ((e.localPosition.dx - _left) / (pw / (n - 1))).round().clamp(0, n - 1);
          if (i != _hover) setState(() => _hover = i);
        },
        onExit: (_) => setState(() => _hover = null),
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _ForecastPainter(
                values: widget.values,
                labels: widget.labels,
                color: widget.color,
                maxV: widget.maxV,
                hover: _hover,
              ),
            ),
          ),
          if (_hover != null)
            Positioned(
              left: (xOf(_hover!) - 80).clamp(0.0, math.max(0.0, c.maxWidth - 160)),
              top: 0,
              child: IgnorePointer(
                child: Container(
                  width: 160,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: WebColors.ink,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${_fmtDate(widget.labels[_hover!])} · '
                    '${widget.values[_hover!].toStringAsFixed(1)} kWh',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white),
                  ),
                ),
              ),
            ),
        ]),
      );
    });
  }
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

String _fmtDate(DateTime? d) => d == null ? '' : '${_months[d.month - 1]} ${d.day}';

class _ForecastPainter extends CustomPainter {
  final List<double> values;
  final List<DateTime?> labels;
  final Color color;
  final double maxV;
  final int? hover;

  _ForecastPainter({
    required this.values,
    required this.labels,
    required this.color,
    required this.maxV,
    required this.hover,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const l = _ForecastChartState._left, r = _ForecastChartState._right;
    const t = _ForecastChartState._top, b = _ForecastChartState._bottom;
    final pw = size.width - l - r, ph = size.height - t - b, base = t + ph;
    final n = values.length;
    double x(int i) => l + (n < 2 ? pw / 2 : pw * i / (n - 1));
    double y(double v) => t + ph * (1 - (v / maxV).clamp(0.0, 1.0));

    final grid = Paint()..color = const Color(0x244F6A58);
    for (var g = 0; g <= 4; g++) {
      final gy = t + ph * g / 4;
      canvas.drawLine(Offset(l, gy), Offset(size.width - r, gy), grid);
      final v = maxV * (4 - g) / 4;
      _text(canvas, v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1),
          Offset(l - 6, gy), align: 1);
    }
    if (n == 0) return;

    final line = Path()..moveTo(x(0), y(values[0]));
    for (var i = 1; i < n; i++) {
      line.lineTo(x(i), y(values[i]));
    }
    final area = Path.from(line)
      ..lineTo(x(n - 1), base)
      ..lineTo(x(0), base)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withAlpha(72), color.withAlpha(5)],
        ).createShader(Rect.fromLTWH(0, t, size.width, ph)),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round,
    );

    for (final i in {0, 7, 14, 21, n - 1}) {
      if (i < 0 || i >= n) continue;
      _text(canvas, _fmtDate(labels.length > i ? labels[i] : null),
          Offset(x(i), base + 14),
          align: i == 0 ? -1 : (i == n - 1 ? 1 : 0));
    }

    if (hover != null && hover! < n) {
      final hx = x(hover!);
      canvas.drawLine(Offset(hx, t), Offset(hx, base),
          Paint()..color = const Color(0x590E2E1A));
      canvas.drawCircle(Offset(hx, y(values[hover!])), 5, Paint()..color = Colors.white);
      canvas.drawCircle(Offset(hx, y(values[hover!])), 3.5, Paint()..color = color);
    }
  }

  /// [align]: -1 left, 0 centre, 1 right of [at]; vertically centred.
  void _text(Canvas canvas, String s, Offset at, {int align = 0}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s, style: const TextStyle(fontSize: 12, color: WebColors.muted)),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = align < 0 ? at.dx : (align > 0 ? at.dx - tp.width : at.dx - tp.width / 2);
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _ForecastPainter old) =>
      old.values != values || old.hover != hover || old.maxV != maxV || old.color != color;
}
