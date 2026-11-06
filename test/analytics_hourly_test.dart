import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/screens/web/analytics/analytics_data.dart';
import 'package:smart_power_switch/screens/web/analytics/analytics_filter.dart';
import 'package:smart_power_switch/services/rate_timeline.dart';

void main() {
  final rates = RateTimeline(10);
  const meta = {
    'd1': DeviceMeta(
        id: 'd1',
        building: 'IC',
        floor: 2,
        room: 'R1',
        utility: 'Lights',
        online: true,
        relay: true),
  };

  group('parseHourly', () {
    test('reads per-device hours with their hour and metadata', () {
      final rows = parseHourly({
        '2026-11-05-18': {
          'campus': {'kwh': 0.014, 'cost': 0.19},
          'devices': {
            'd1': {'building': 'TEST', 'kwh': 0.014, 'cost': 0.19},
          },
        },
        '2026-11-05': {'devices': {}}, // a day key, not an hour: ignored
      }, meta, rates: rates);
      expect(rows, hasLength(1));
      final r = rows.single;
      expect([r.date, r.hour], [DateTime(2026, 11, 5), 18]);
      // The building stored with the hour wins over the device's current one.
      expect([r.deviceId, r.building, r.utility, r.floor, r.room],
          ['d1', 'TEST', 'Lights', 2, 'R1']);
      expect([r.kwh, r.cost], [0.014, 0.19]);
    });

    test('falls back to building totals, then the campus total', () {
      final rows = parseHourly({
        '2026-11-05-01': {
          'buildings': {'IC': {'kwh': 2.0}},
        },
        '2026-11-05-02': {
          'campus': {'kwh': 3.0},
        },
      }, meta, rates: rates);
      rows.sort((a, b) => a.hour!.compareTo(b.hour!));
      expect([rows[0].building, rows[0].kwh, rows[0].cost], ['IC', 2.0, 20.0]);
      expect([rows[1].building, rows[1].kwh, rows[1].hour], ['', 3.0, 2]);
    });
  });

  group('hourly buckets', () {
    UsageRow at(DateTime day, int hour, double kwh) => UsageRow(
        date: day,
        deviceId: 'd1',
        building: 'IC',
        utility: 'Lights',
        floor: 2,
        room: 'R1',
        kwh: kwh,
        cost: kwh * 10,
        hour: hour);

    test('one day gives 24 hours labelled HH:00, empty hours at 0', () {
      final day = DateTime(2026, 11, 5);
      final b = bucketize(
          AnalyticsFilter.defaults,
          [at(day, 18, 0.014), at(day, 18, 0.001), at(day, 5, 0.013)],
          DateTimeRange(start: day, end: day),
          GroupBy.hourly);
      expect(b, hasLength(24));
      expect(b.first.label, '00:00');
      expect(b[18].label, '18:00');
      expect(b[18].kwh, closeTo(0.015, 1e-9));
      expect(b[18].tooltipLabel, 'Nov 5 · Thu · 18:00–19:00');
      expect(b[5].kwh, 0.013);
      expect(b[12].kwh, 0);
    });

    test('several days carry the date in the label; daily rows are ignored',
        () {
      final d1 = DateTime(2026, 11, 5), d2 = DateTime(2026, 11, 6);
      final daily = UsageRow(
          date: d1,
          deviceId: 'd1',
          building: 'IC',
          utility: 'Lights',
          floor: 2,
          room: 'R1',
          kwh: 99,
          cost: 990);
      final b = bucketize(AnalyticsFilter.defaults, [daily, at(d2, 23, 0.02)],
          DateTimeRange(start: d1, end: d2), GroupBy.hourly);
      expect(b, hasLength(48));
      expect(b.last.label, 'Nov 6 23:00');
      expect(b.last.kwh, 0.02);
      expect(b.fold<double>(0, (a, x) => a + x.kwh), 0.02);
    });
  });

  test('hourly grouping is offered for ranges up to 7 days', () {
    expect(groupAllowed(GroupBy.hourly, 1), isTrue);
    expect(groupAllowed(GroupBy.hourly, 7), isTrue);
    expect(groupAllowed(GroupBy.hourly, 8), isFalse);
    expect(suggestedGroup(1), GroupBy.hourly);
    expect(suggestedGroup(7), GroupBy.daily);
    expect(groupDisabledReason(GroupBy.hourly), 'Only for ranges up to 7 days');
  });
}
