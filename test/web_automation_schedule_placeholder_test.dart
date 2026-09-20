// Unit tests for WebAutomationSchedule's additive `.placeholder()` /
// `.placeholderList()` factories (lib/screens/web/automation_screen_web.dart),
// added to feed the desktop/web Automation screen's ScreenSkeleton while its
// real schedules are still loading.
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_power_switch/screens/web/automation_screen_web.dart';

final _timeFormat = RegExp(r'^\d{2}:\d{2}$');

void main() {
  group('WebAutomationSchedule.placeholder', () {
    test('produces a valid, displayable schedule with the default id', () {
      final schedule = WebAutomationSchedule.placeholder();

      expect(schedule.id, 'schedule-0');
      expect(schedule.name.isNotEmpty, isTrue);
      expect(schedule.scope.isNotEmpty, isTrue);
      expect(schedule.target.isNotEmpty, isTrue);
      expect(schedule.utility.isNotEmpty, isTrue);
      expect(schedule.onTime, matches(_timeFormat));
      expect(schedule.offTime, matches(_timeFormat));
      expect(schedule.days, isNotEmpty);
      expect(schedule.scheduleMode, 'weekly');
      expect(schedule.isCalendarMode, isFalse);
    });

    test('honors the id override', () {
      final schedule = WebAutomationSchedule.placeholder(id: 'custom-id');
      expect(schedule.id, 'custom-id');
    });
  });

  group('WebAutomationSchedule.placeholderList', () {
    test('defaults to 4 items', () {
      expect(WebAutomationSchedule.placeholderList().length, 4);
    });

    test('returns exactly `count` items with distinct ids', () {
      final list = WebAutomationSchedule.placeholderList(6);
      expect(list, hasLength(6));

      final ids = list.map((s) => s.id).toSet();
      expect(ids, hasLength(6),
          reason: 'each schedule should have a distinct id, otherwise the '
              'loop index is not being used');

      for (final schedule in list) {
        expect(schedule.name.isNotEmpty, isTrue);
        expect(schedule.onTime, matches(_timeFormat));
        expect(schedule.offTime, matches(_timeFormat));
        expect(schedule.days, isNotEmpty);
      }
    });
  });

  group('WebAutomationSchedule.fromMap/.toMap round trip (regression guard)', () {
    test('placeholder survives a toMap -> fromMap round trip', () {
      final original = WebAutomationSchedule.placeholder(id: 'schedule-2');
      final restored =
          WebAutomationSchedule.fromMap('some-id', original.toMap());

      expect(restored.id, 'some-id');
      expect(restored.name, original.name);
      expect(restored.scope, original.scope);
      expect(restored.target, original.target);
      expect(restored.utility, original.utility);
      expect(restored.onTime, original.onTime);
      expect(restored.offTime, original.offTime);
      expect(restored.days, original.days);
      expect(restored.enabled, original.enabled);
      expect(restored.scheduleMode, original.scheduleMode);
    });

    test('fromMap still defaults missing onTime/offTime to 08:00/18:00', () {
      final schedule = WebAutomationSchedule.fromMap('x', const {});
      expect(schedule.onTime, '08:00');
      expect(schedule.offTime, '18:00');
      expect(schedule.scope, 'global');
      expect(schedule.target, 'all');
      expect(schedule.enabled, isTrue);
      expect(schedule.scheduleMode, 'weekly');
      expect(schedule.isCalendarMode, isFalse);
    });
  });
}
