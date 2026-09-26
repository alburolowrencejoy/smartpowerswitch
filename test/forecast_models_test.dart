import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/services/forecast_models.dart';

void main() {
  // Eight weeks of a clean weekday pattern: 10 kWh on weekdays, 3 on the
  // weekend, plus a gentle upward trend.
  final weekly = [
    for (var i = 0; i < 56; i++) (i % 7 < 5 ? 10.0 : 3.0) + i * 0.05,
  ];

  group('arimaForecast', () {
    test('keeps the weekly pattern and never goes negative', () {
      final f = arimaForecast(weekly, 14);
      expect(f, hasLength(14));
      expect(f.every((v) => v >= 0), isTrue);
      // Day 56 is a weekday (56 % 7 == 0), day 61 a weekend day.
      expect(f[0], greaterThan(f[5] + 4));
      expect(f[0], closeTo(10 + 56 * 0.05, 0.6));
    });

    test('stays finite and bounded over a 90-day horizon', () {
      // Explosive history (grows 30% a day) and irregular on/off usage:
      // both used to make the 90-day forecast a year range asks for run
      // away, which blanked the forecast chart.
      final explosive = [for (var i = 0; i < 40; i++) math.pow(1.3, i) / 1e3];
      final rnd = math.Random(7);
      final irregular = [
        for (var i = 0; i < 60; i++)
          rnd.nextDouble() < 0.4 ? 0.0 : rnd.nextDouble() * 50,
      ];
      for (final y in [explosive, irregular, weekly]) {
        final peak = y.reduce(math.max);
        final f = arimaForecast(y, 90);
        expect(f, hasLength(90));
        expect(f.every((v) => v.isFinite && v >= 0 && v <= peak * 3 + 1),
            isTrue);
      }
    });

    test('seasonal naive repeats the weekly pattern', () {
      final f = seasonalNaiveForecast(weekly, 14);
      expect(f, hasLength(14));
      expect(f[0], greaterThan(f[5] + 4)); // weekday vs weekend
      expect(f[0], closeTo(f[7], 1e-9));
    });

    test('falls back to a straight line for short history', () {
      expect(arimaForecast([1, 2, 3], 3), [
        closeTo(4, 1e-9),
        closeTo(5, 1e-9),
        closeTo(6, 1e-9),
      ]);
      expect(arimaForecast([], 2), [0, 0]);
      expect(arimaForecast([5], 2), [5, 5]);
    });
  });

  group('backtest', () {
    test('scores a near-perfect model close to zero error', () {
      final err = backtest(weekly, (y, h) => arimaForecast(y, h))!;
      expect(err.mae, lessThan(0.5));
      expect(err.mape, lessThan(8));
    });

    test('ignores near-zero days in MAPE and needs enough history', () {
      final y = [for (var i = 0; i < 30; i++) i.isEven ? 0.0 : 4.0];
      final err = backtest(y, (h, n) => List.filled(n, 4.0))!;
      expect(err.mape, 0); // every non-zero day was predicted exactly
      expect(err.mae, closeTo(2, 1e-9));
      expect(backtest([1, 2, 3], (y, h) => List.filled(h, 0)), isNull);
    });
  });

  test('ForecastError.fromMap reads the Python job output', () {
    final e = ForecastError.fromMap({'mae': 1.25, 'mape': 9, 'days': 14})!;
    expect(e.mae, 1.25);
    expect(e.mape, 9);
    expect(ForecastError.fromMap({'mae': 'x'}), isNull);
    expect(ForecastError.fromMap(null), isNull);
  });
}
