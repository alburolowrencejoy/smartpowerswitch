import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/screens/web/analytics/analytics_data.dart';
import 'package:smart_power_switch/screens/web/analytics/analytics_filter.dart';
import 'package:smart_power_switch/screens/web/analytics/year_comparison.dart';

UsageRow _row(DateTime d, double kwh,
        {String building = 'IC', String utility = 'Lights'}) =>
    UsageRow(
      date: d,
      deviceId: 'd1',
      building: building,
      utility: utility,
      floor: 1,
      room: 'R1',
      kwh: kwh,
      cost: kwh * 10,
    );

void main() {
  final today = DateTime(2026, 9, 27);
  final rows = [
    _row(DateTime(2025, 3, 5), 10),
    _row(DateTime(2025, 3, 20), 5),
    _row(DateTime(2025, 9, 1), 7),
    _row(DateTime(2026, 3, 2), 20),
    _row(DateTime(2026, 9, 10), 4, building: 'ITED'),
  ];
  const f = AnalyticsFilter();

  test('sums each month of the year in kWh', () {
    final v = monthlyValues(f, rows, 2025, 1, 12, today);
    expect(v, hasLength(12));
    expect(v[2], 15); // March
    expect(v[8], 7); // September
  });

  test('months before the first data and after today are gaps (NaN)', () {
    final v = monthlyValues(f, rows, 2026, 1, 12, today);
    expect(v[2], 20);
    expect(v[9].isNaN, isTrue); // October 2026 hasn't started
    final old = monthlyValues(f, rows, 2025, 1, 12, today);
    expect(old[0].isNaN, isTrue); // January 2025: before the first record
    expect(old[3], 0); // April 2025: recorded period, no usage
  });

  test('respects the month range and the metric', () {
    final v = monthlyValues(
        f.copyWith(metric: ValueMetric.cost), rows, 2025, 3, 4, today);
    expect(v, [150, 0]);
  });

  test('follows the scope filter', () {
    final v = monthlyValues(
        f.copyWith(buildings: ['ITED']), rows, 2026, 9, 9, today);
    expect(v, [4]);
  });
}
