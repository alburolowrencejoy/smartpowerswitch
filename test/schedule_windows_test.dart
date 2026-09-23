import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/services/schedule_windows.dart';

ScheduleWindow w(String on, String until) => ScheduleWindow.parse(on, until)!;

void main() {
  group('ScheduleWindow', () {
    test('turns OFF one minute after the end time', () {
      final win = w('08:00', '11:59');
      expect(win.offLabel, '12:00');
      expect(win.offDayOffset, 0);
      expect(win.overnight, isFalse);
    });

    test('overnight window turns OFF the next day', () {
      final win = w('22:00', '05:59');
      expect(win.overnight, isTrue);
      expect(win.offLabel, '06:00');
      expect(win.offDayOffset, 1);
    });

    test('ending at 23:59 turns OFF at midnight the next day', () {
      final win = w('18:00', '23:59');
      expect(win.overnight, isFalse);
      expect(win.offLabel, '00:00');
      expect(win.offDayOffset, 1);
    });

    test('listFrom reads lists and index-keyed maps, skips bad entries', () {
      expect(
        ScheduleWindow.listFrom([
          {'on': '08:00', 'until': '09:59'},
          {'on': 'bad', 'until': '10:00'},
        ]),
        [w('08:00', '09:59')],
      );
      expect(
        ScheduleWindow.listFrom({
          '1': {'on': '13:00', 'until': '14:00'},
          '0': {'on': '08:00', 'until': '09:00'},
        }),
        [w('08:00', '09:00'), w('13:00', '14:00')],
      );
      expect(ScheduleWindow.listFrom(null), isEmpty);
    });
  });

  group('validateWindows', () {
    test('accepts back-to-back windows', () {
      expect(validateWindows([w('08:00', '11:59'), w('12:00', '17:00')]),
          isEmpty);
    });

    test('rejects overlapping windows', () {
      expect(validateWindows([w('08:00', '12:00'), w('12:00', '17:00')]),
          {1: 'Overlaps with window 1.'});
    });

    test('rejects an overnight window overlapping an early one', () {
      expect(validateWindows([w('22:00', '06:00'), w('05:00', '07:00')]),
          {1: 'Overlaps with window 1.'});
    });

    test('rejects equal start and end, missing times and an empty set', () {
      expect(validateWindows([w('08:00', '07:59')]).keys, [0]);
      expect(validateWindows([null]).keys, [0]);
      expect(validateWindows([]).keys, [-1]);
    });
  });

  group('windowsActionAt', () {
    bool weekdays(DateTime d) => d.weekday <= DateTime.friday;
    // 2026-09-21 is a Monday.
    DateTime at(int day, int h, int m) => DateTime(2026, 9, day, h, m);

    test('fires ON and OFF for each window on a matching day', () {
      final ws = [w('08:00', '11:59'), w('13:00', '16:59')];
      expect(windowsActionAt(ws, at(21, 8, 0), weekdays), 'on');
      expect(windowsActionAt(ws, at(21, 12, 0), weekdays), 'off');
      expect(windowsActionAt(ws, at(21, 13, 0), weekdays), 'on');
      expect(windowsActionAt(ws, at(21, 17, 0), weekdays), 'off');
      expect(windowsActionAt(ws, at(21, 10, 0), weekdays), isNull);
    });

    test('does nothing on a non-matching day', () {
      expect(windowsActionAt([w('08:00', '11:59')], at(26, 8, 0), weekdays),
          isNull);
    });

    test('ON wins when back-to-back windows meet', () {
      final ws = [w('08:00', '11:59'), w('12:00', '13:00')];
      expect(windowsActionAt(ws, at(21, 12, 0), weekdays), 'on');
    });

    test('overnight OFF belongs to the day the window started', () {
      final ws = [w('22:00', '05:59')];
      // Friday night -> Saturday 06:00 OFF still fires.
      expect(windowsActionAt(ws, at(26, 6, 0), weekdays), 'off');
      // Sunday night did not start a window -> no OFF Monday morning.
      expect(windowsActionAt(ws, at(21, 6, 0), weekdays), isNull);
    });
  });
}
