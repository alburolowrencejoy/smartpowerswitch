import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/screens/web/analytics/analytics_data.dart';
import 'package:smart_power_switch/services/rate_timeline.dart';

int _ms(DateTime d) => d.millisecondsSinceEpoch;

void main() {
  // Rate went 11.50 -> 12.00 on Oct 1, then 12.00 -> 13.00 on Nov 1.
  final log = {
    '1': {
      'timestamp': _ms(DateTime(2026, 10, 1, 9)),
      'oldRate': 11.5,
      'newRate': 12.0,
    },
    '2': {
      'timestamp': _ms(DateTime(2026, 11, 1, 9)),
      'oldRate': 12.0,
      'newRate': 13.0,
    },
  };
  final rates = RateTimeline.parse(log, 13.0);

  group('RateTimeline.rateAt', () {
    test('before the first change uses the rate it replaced', () {
      expect(rates.rateAt(DateTime(2026, 9, 15)), 11.5);
    });

    test('between changes uses the earlier change', () {
      expect(rates.rateAt(DateTime(2026, 10, 20)), 12.0);
    });

    test('after the last change uses the latest rate', () {
      expect(rates.rateAt(DateTime(2026, 11, 5)), 13.0);
    });

    test('a change during a day counts for that whole day', () {
      expect(rates.rateForDay(DateTime(2026, 11, 1)), 13.0);
    });

    test('with no log it falls back to the current rate', () {
      expect(RateTimeline.parse(null, 11.5).rateAt(DateTime(2020)), 11.5);
    });
  });

  group('parseDaily cost', () {
    test('keeps the stored cost even after the rate changed', () {
      final rows = parseDaily({
        '2026-09-10': {
          'devices': {
            'd1': {'kwh': 10.0, 'cost': 115.0, 'building': 'IC'},
          },
        },
      }, const {}, rates: rates);
      expect(rows.single.cost, 115.0);
    });

    test('prices records without a stored cost at their own day\'s rate', () {
      final rows = parseDaily({
        '2026-09-10': {
          'devices': {
            'd1': {'kwh': 10.0, 'building': 'IC'},
          },
        },
        '2026-10-10': {
          'devices': {
            'd1': {'kwh': 10.0, 'building': 'IC'},
          },
        },
      }, const {}, rates: rates);
      final byMonth = {for (final r in rows) r.date.month: r.cost};
      expect(byMonth[9], closeTo(115.0, 1e-9));
      expect(byMonth[10], closeTo(120.0, 1e-9));
    });
  });
}
