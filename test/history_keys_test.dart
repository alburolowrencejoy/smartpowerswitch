import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/services/history_keys.dart';

// Mirrors the key cases in functions/energy_math.test.js -- keep them in sync,
// the server and the app must build identical keys.
void main() {
  DateTime utc(int y, int mo, int d, [int h = 0, int mi = 0]) =>
      DateTime.utc(y, mo, d, h, mi);

  test('23:59 PH stays on the day, 00:00 PH starts the next', () {
    expect(HistoryKeys.of(utc(2026, 10, 10, 15, 59)).daily, '2026-10-10');
    expect(HistoryKeys.of(utc(2026, 10, 10, 15, 59)).hourly, '2026-10-10-23');
    expect(HistoryKeys.of(utc(2026, 10, 10, 16)).daily, '2026-10-11');
    expect(HistoryKeys.of(utc(2026, 10, 10, 16)).hourly, '2026-10-11-00');
  });

  test('07:59 PH is 23:59 UTC the day before, and belongs to the PH day', () {
    final k = HistoryKeys.of(utc(2026, 10, 10, 23, 59));
    expect(k.daily, '2026-10-11');
    expect(k.hourly, '2026-10-11-07');
  });

  test('PH new year: month, year and ISO week roll over together', () {
    final k = HistoryKeys.of(utc(2026, 12, 31, 16));
    expect(k.hourly, '2027-01-01-00');
    expect(k.daily, '2027-01-01');
    expect(k.weekly, '2026-W53');
    expect(k.monthly, '2027-01');
    expect(k.yearly, '2027');
    expect(HistoryKeys.of(utc(2026, 12, 31, 15, 59)).yearly, '2026');
  });

  test('PH leap day', () {
    expect(HistoryKeys.of(utc(2028, 2, 28, 16)).daily, '2028-02-29');
    expect(HistoryKeys.of(utc(2028, 2, 29, 16)).daily, '2028-03-01');
  });

  test('a local (non-UTC) DateTime gives the same keys as its UTC instant',
      () {
    final instant = utc(2026, 10, 10, 20, 30);
    expect(HistoryKeys.of(instant.toLocal()).hourly,
        HistoryKeys.of(instant).hourly);
    expect(HistoryKeys.of(instant).hourly, '2026-10-11-04');
  });

  test('ISO weeks at year boundaries', () {
    expect(HistoryKeys.isoWeekKey(2026, 1, 1), '2026-W01');
    expect(HistoryKeys.isoWeekKey(2026, 12, 31), '2026-W53');
    expect(HistoryKeys.isoWeekKey(2027, 1, 1), '2026-W53');
    expect(HistoryKeys.isoWeekKey(2027, 1, 3), '2026-W53');
    expect(HistoryKeys.isoWeekKey(2027, 1, 4), '2027-W01');
    expect(HistoryKeys.isoWeekKey(2024, 12, 30), '2025-W01');
    expect(HistoryKeys.isoWeekKey(2021, 1, 3), '2020-W53');
  });

  test('ISO weeks run Monday to Sunday', () {
    expect(HistoryKeys.isoWeekKey(2026, 10, 5), '2026-W41');
    expect(HistoryKeys.isoWeekKey(2026, 10, 11), '2026-W41');
    expect(HistoryKeys.isoWeekKey(2026, 10, 12), '2026-W42');
  });

  test('range lookup by name', () {
    final k = HistoryKeys.of(utc(2026, 10, 10, 2));
    expect(k['daily'], k.daily);
    expect(k['weekly'], '2026-W41');
    expect(() => k['minutely'], throwsArgumentError);
  });
}
