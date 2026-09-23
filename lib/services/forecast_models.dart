/// Daily-kWh forecasters used by the web Analytics screen, plus a backtest
/// that scores them the same way the Python job scores LSTM / XGBoost:
/// train without the last [kBacktestDays] days, predict those days, and
/// compare with what actually happened (MAE in kWh/day and MAPE in %).
library;

import 'dart:math' as math;

const int kBacktestDays = 14;

typedef Forecaster = List<double> Function(List<double> history, int horizon);

class ForecastError {
  final double mae;
  final double mape;
  const ForecastError(this.mae, this.mape);

  static ForecastError? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final mae = raw['mae'];
    final mape = raw['mape'];
    if (mae is! num || mape is! num) return null;
    return ForecastError(mae.toDouble(), mape.toDouble());
  }
}

/// Straight-line trend, used when there is too little history for a model.
List<double> linearForecast(List<double> y, int h) {
  if (y.isEmpty) return List.filled(h, 0);
  if (y.length == 1) return List.filled(h, math.max(0, y.first));
  final n = y.length;
  final mx = (n - 1) / 2;
  final my = y.reduce((a, b) => a + b) / n;
  var num = 0.0, den = 0.0;
  for (var i = 0; i < n; i++) {
    num += (i - mx) * (y[i] - my);
    den += (i - mx) * (i - mx);
  }
  final slope = den == 0 ? 0.0 : num / den;
  final ic = my - slope * mx;
  return List.generate(h, (i) => math.max(0.0, ic + slope * (n + i)));
}

/// Solves A·x = b by Gaussian elimination with partial pivoting; singular
/// columns resolve to 0.
List<double> _solve(List<List<double>> a, List<double> b) {
  final n = b.length;
  final m = [
    for (var i = 0; i < n; i++) [...a[i], b[i]]
  ];
  for (var c = 0; c < n; c++) {
    var p = c;
    for (var r = c + 1; r < n; r++) {
      if (m[r][c].abs() > m[p][c].abs()) p = r;
    }
    final tmp = m[c];
    m[c] = m[p];
    m[p] = tmp;
    if (m[c][c].abs() < 1e-12) continue;
    for (var r = 0; r < n; r++) {
      if (r == c) continue;
      final f = m[r][c] / m[c][c];
      for (var k = c; k <= n; k++) {
        m[r][k] -= f * m[c][k];
      }
    }
  }
  return [for (var i = 0; i < n; i++) m[i][i].abs() < 1e-12 ? 0.0 : m[i][n] / m[i][i]];
}

/// Seasonal ARIMA(p,0,0)(0,1,0)[m]: differences each day against the same
/// weekday last week, fits AR(p) with an intercept on those differences by
/// least squares, then rebuilds the forecast one day at a time.
List<double> arimaForecast(List<double> y, int h, {int p = 2, int m = 7}) {
  if (y.length < m + p + 6) return linearForecast(y, h);
  final d = [for (var i = m; i < y.length; i++) y[i] - y[i - m]];
  final k = p + 1;
  final ata = List.generate(k, (_) => List<double>.filled(k, 0));
  final atb = List<double>.filled(k, 0);
  for (var t = p; t < d.length; t++) {
    final row = [1.0, for (var j = 0; j < p; j++) d[t - 1 - j]];
    for (var a = 0; a < k; a++) {
      atb[a] += row[a] * d[t];
      for (var c = 0; c < k; c++) {
        ata[a][c] += row[a] * row[c];
      }
    }
  }
  final coef = _solve(ata, atb);
  final yy = [...y];
  final dd = [...d];
  for (var s = 0; s < h; s++) {
    var nd = coef[0];
    for (var j = 0; j < p; j++) {
      nd += coef[1 + j] * dd[dd.length - 1 - j];
    }
    dd.add(nd);
    yy.add(yy[yy.length - m] + nd);
  }
  return [for (final v in yy.sublist(y.length)) math.max(0.0, v)];
}

/// Scores [fn] on the last [hold] days of [y]; null when there is too
/// little history to hold that many days back.
ForecastError? backtest(List<double> y, Forecaster fn,
    {int hold = kBacktestDays}) {
  if (y.length < hold + 8) return null;
  final train = y.sublist(0, y.length - hold);
  final test = y.sublist(y.length - hold);
  final pred = fn(train, hold);
  var ae = 0.0, ape = 0.0;
  var apeCount = 0;
  for (var i = 0; i < hold; i++) {
    final err = (test[i] - pred[i]).abs();
    ae += err;
    // Skip near-zero days (e.g. a building closed all day), where a
    // percentage error is meaningless.
    if (test[i] > 0.05) {
      ape += err / test[i];
      apeCount++;
    }
  }
  return ForecastError(
      ae / hold, apeCount == 0 ? 0 : ape / apeCount * 100);
}
