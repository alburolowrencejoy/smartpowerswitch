import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/screens/web/web_forecast_cards.dart';
import 'package:smart_power_switch/services/forecast_comparison.dart';
import 'package:smart_power_switch/theme/app_fonts.dart';
import 'package:smart_power_switch/theme/institute_colors.dart';

/// What tools/forecast_comparison.py writes for one series.
Map<String, Object?> payload({String best = 'gru'}) => {
      'series': 'campus',
      'generated_at': 1793000000000,
      'mode': 'rolling',
      'days': 10,
      'incomplete_days': 1,
      'train': {'start': '2026-01-01', 'end': '2026-01-08', 'days': 8},
      'test': {'start': '2026-01-09', 'end': '2026-01-10', 'days': 2},
      'actual': {
        'labels': ['2026-01-09', '2026-01-10'],
        'values': [10.0, 12.0],
      },
      'next_day_label': '2026-01-11',
      'best': best,
      'models': {
        'arima': {
          'mae': 2.0,
          'mse': 4.0,
          'rmse': 2.0,
          'mape': 18.0,
          'r2': 0.4,
          'rank': 3,
          'values': [12.0, 14.0],
          'next_day': 13.0,
          'order': [7, 1, 3],
        },
        'xgboost': {
          'mae': 1.0,
          'mse': 1.0,
          'rmse': 1.0,
          'mape': 9.0,
          'r2': 0.8,
          'rank': 2,
          'values': [11.0, 13.0],
          'next_day': 12.5,
        },
        'gru': {
          'mae': 0.5, 'mse': 0.25, 'rmse': 0.5, 'mape': 4.5, 'r2': 0.95,
          'rank': 1,
          // RTDB drops a null entry, so a hole can come back as a map.
          'values': {'1': 12.5}, 'next_day': 12.2,
        },
        'lstm': {'unavailable': 'Training failed: boom'},
      },
    };

/// [payload] plus a 7-day horizon for ARIMA and XGBoost (GRU has none).
Map<String, Object?> payloadWithHorizons() {
  final p = payload();
  final models = p['models'] as Map<String, Object?>;
  (models['arima'] as Map<String, Object?>)['horizons'] = {
    'd7': {
      'backtest': [11.0, 13.0],
      'values': List.filled(7, 1.0),
      'total': 7.0,
      'mae': 1.0,
      'rmse': 1.0,
      'mape': 9.0,
      'rank': 2,
    },
  };
  (models['xgboost'] as Map<String, Object?>)['horizons'] = {
    'd7': {
      'backtest': [10.0, 12.5],
      'values': List.filled(7, 2.0),
      'total': 14.0,
      'mae': 0.25,
      'rmse': 0.35,
      'mape': 2.0,
      'rank': 1,
    },
  };
  return {
    ...p,
    'horizons': {
      'd7': {
        'days': 7,
        'start': '2026-01-11',
        'end': '2026-01-17',
        'test': {'start': '2026-01-09', 'end': '2026-01-10', 'days': 2},
        'best': 'xgboost',
      },
    },
  };
}

void main() {
  group('SeriesComparison.fromMap', () {
    test('reads every field the job writes', () {
      final s = SeriesComparison.fromMap('campus', payload())!;
      expect(s.generatedAt, DateTime.fromMillisecondsSinceEpoch(1793000000000));
      expect(s.days, 10);
      expect(s.incompleteDays, 1);
      expect(s.trainDays, 8);
      expect(s.testStart, DateTime(2026, 1, 9));
      expect(s.testEnd, DateTime(2026, 1, 10));
      expect(s.labels, [DateTime(2026, 1, 9), DateTime(2026, 1, 10)]);
      expect(s.actual, [10.0, 12.0]);
      expect(s.nextDay, DateTime(2026, 1, 11));
      expect(s.best, 'gru');
      expect(s.bestModel!.nextDay, 12.2);

      final arima = s.models['arima']!;
      expect(arima.order, [7, 1, 3]);
      expect([arima.mae, arima.mse, arima.rmse, arima.mape, arima.r2],
          [2, 4, 2, 18, 0.4]);
      expect(s.models['gru']!.values, [null, 12.5]);
      expect(s.models['lstm']!.ok, isFalse);
      expect(s.models['lstm']!.unavailable, contains('boom'));
    });

    test('reads the 7-day horizon', () {
      final s = SeriesComparison.fromMap('campus', payloadWithHorizons())!;
      final h = s.horizons[7]!;
      expect([h.start, h.end], [DateTime(2026, 1, 11), DateTime(2026, 1, 17)]);
      expect([h.testStart, h.testEnd, h.testDays],
          [DateTime(2026, 1, 9), DateTime(2026, 1, 10), 2]);
      expect(h.best, 'xgboost');
      expect(s.horizons.containsKey(30), isFalse);
      final x = s.models['xgboost']!.horizons[7]!;
      expect([x.total, x.rmse, x.mape, x.rank], [14.0, 0.35, 2.0, 1]);
      expect(x.backtest, [10.0, 12.5]);
      expect(x.values, hasLength(7));
      expect(s.models['gru']!.horizons, isEmpty);
      expect(SeriesComparison.fromMap('campus', payload())!.horizons, isEmpty);
    });

    test('ranked lists trained models by RMSE', () {
      final s = SeriesComparison.fromMap('campus', payload())!;
      expect(s.ranked.map((m) => m.key), ['gru', 'xgboost', 'arima']);
    });

    test('an unavailable series keeps its reason', () {
      final s = SeriesComparison.fromMap('IC', {
        'series': 'IC',
        'unavailable': 'Needs at least 60 days of history (has 12).'
      })!;
      expect(s.models, isEmpty);
      expect(s.unavailable, contains('60 days'));
    });

    test('parseAll skips junk', () {
      final all = ForecastComparisons.parseAll({'campus': payload(), 'bad': 5});
      expect(all.keys, ['campus']);
      expect(ForecastComparisons.parseAll(null), isEmpty);
    });
  });

  group('ForecastComparisons.seriesFor', () {
    test('campus with no scope, one institute when exactly one is picked', () {
      expect(ForecastComparisons.seriesFor(buildings: const []), 'campus');
      expect(ForecastComparisons.seriesFor(buildings: const ['IC']), 'IC');
      expect(
          ForecastComparisons.seriesFor(
              buildings: const [],
              utilities: const ['Lights', 'Outlets', 'AC']),
          'campus');
    });

    test('nothing for a narrower filter', () {
      expect(ForecastComparisons.seriesFor(buildings: const ['IC', 'ITED']),
          isNull);
      expect(ForecastComparisons.seriesFor(buildings: const ['IC'], floor: 2),
          isNull);
      expect(ForecastComparisons.seriesFor(buildings: const ['IC'], room: 'R1'),
          isNull);
      expect(ForecastComparisons.seriesFor(buildings: const [], device: 'd1'),
          isNull);
      expect(
          ForecastComparisons.seriesFor(
              buildings: const [], utilities: const ['AC']),
          isNull);
    });
  });

  group('web ForecastComparison', () {
    Future<StreamController<Map<String, SeriesComparison>>> pump(
        WidgetTester tester,
        {String? series = 'campus',
        Object? data}) async {
      tester.view.physicalSize = const Size(1400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final source = StreamController<Map<String, SeriesComparison>>();
      addTearDown(source.close);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: AppFonts.family),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ForecastComparison(
              palette: InstituteColors.ic,
              rate: 10,
              series: series,
              seriesName: 'Whole campus',
              source: source.stream,
            ),
          ),
        ),
      ));
      if (data != null) {
        source.add(ForecastComparisons.parseAll(data));
        await tester.pump();
      }
      return source;
    }

    testWidgets('shows the table, the best model and tomorrow', (tester) async {
      await pump(tester, data: {'campus': payload()});
      expect(find.text('Model comparison'), findsOneWidget);
      expect(find.text('ARIMA(7, 1, 3)'), findsOneWidget);
      expect(find.text('Training failed: boom'), findsOneWidget);
      // The forecast card shows the picked model (GRU, the best) only.
      expect(find.text('GRU forecast'), findsOneWidget);
      expect(find.text('12.20 kWh'), findsOneWidget); // GRU, tomorrow
      expect(find.text('≈ ₱ 122.00'), findsOneWidget);
      expect(find.text('13.00 kWh'), findsNothing); // ARIMA's tomorrow
      expect(find.text('Sun, Jan 11, 2026'), findsOneWidget);
      // No horizons published yet: the 7- and 30-day rows wait for them,
      // and there is no Tomorrow / Next 7 days switch (one 'Tomorrow').
      expect(find.text('After the next training run'), findsNWidgets(2));
      expect(find.text('Tomorrow'), findsOneWidget);
      expect(find.text('95.5%'), findsOneWidget); // GRU: 100 - MAPE 4.5
      // GRU predicted only the second test day: both totals cover that day.
      expect(find.text('12.50 kWh'), findsOneWidget);
      expect(find.text('22.00 kWh'), findsNWidgets(2)); // ARIMA, XGBoost actual
    });

    testWidgets('the forecast card follows the model dropdown', (tester) async {
      await pump(tester, data: {'campus': payloadWithHorizons()});
      await tester.tap(
          find.byTooltip('Choose a model to compare with the actual readings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ARIMA').last);
      await tester.pumpAndSettle();
      expect(find.text('ARIMA forecast'), findsOneWidget);
      expect(find.text('13.00 kWh'), findsOneWidget); // tomorrow
      expect(find.text('7.00 kWh'), findsOneWidget); // next 7 days
      expect(find.text('≈ ₱ 70.00'), findsOneWidget);
      expect(find.text('1.00 kWh a day'), findsOneWidget);
      // Tapping the 7-day row switches the chart.
      await tester.tap(find.text('7.00 kWh'));
      await tester.pump();
      expect(find.text('Actual vs 7-day forecast'), findsOneWidget);
    });

    testWidgets('the 7-day switch changes the chart title, card and table',
        (tester) async {
      await pump(tester, data: {'campus': payloadWithHorizons()});
      expect(find.text('Actual vs day-ahead forecast'), findsOneWidget);

      await tester.tap(find.text('Next 7 days').first); // the switch
      await tester.pump();
      expect(find.text('Actual vs 7-day forecast'), findsOneWidget);
      expect(find.textContaining('tested on Jan 9 – Jan 10, 2026'),
          findsNWidgets(2)); // chart and table subtitles
      // XGBoost is best on this horizon, so the dropdown and card follow it.
      expect(find.text('XGBoost forecast'), findsOneWidget);
      expect(find.text('14.00 kWh'), findsOneWidget);
      expect(find.text('≈ ₱ 140.00'), findsOneWidget);
      expect(find.text('2.00 kWh a day'), findsOneWidget);
      expect(find.text('After the next training run'), findsOneWidget); // 30
      // Table: totals over the 2 scored days, accuracy = 100 - MAPE.
      expect(find.text('98.0%'), findsOneWidget); // XGBoost
      expect(find.text('91.0%'), findsOneWidget); // ARIMA
      expect(find.text('22.50 kWh'), findsOneWidget); // XGBoost predicted
      expect(find.text('24.00 kWh'), findsOneWidget); // ARIMA predicted
    });

    testWidgets('explains a filter with no comparison', (tester) async {
      await pump(tester, series: null);
      expect(find.textContaining('whole campus and for each institute'),
          findsOneWidget);
    });

    testWidgets('waits for the data, then says when a series is missing',
        (tester) async {
      final source = await pump(tester);
      expect(find.text('Loading…'), findsOneWidget);
      source.add(ForecastComparisons.parseAll({'IC': payload()}));
      await tester.pump();
      expect(find.textContaining('Not trained yet'), findsOneWidget);
    });
  });
}
