// Unit tests for AutomationSchedule's additive `.placeholder()` /
// `.placeholderList()` factories (lib/screens/mobile/automation_screen.dart),
// added to feed the mobile Automation screen's ScreenSkeleton while its
// real schedules are still loading.
//
// These check two things:
//   1. The new factories produce valid, displayable instances.
//   2. The pre-existing `.fromMap()`/`.toMap()` round trip still works,
//      i.e. the additive change didn't disturb the existing model.
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_power_switch/screens/mobile/automation_screen.dart';

final _timeFormat = RegExp(r'^\d{2}:\d{2}$');

void main() {
  group('AutomationSchedule.placeholder', () {
    test('produces a valid, displayable schedule', () {
      final schedule = AutomationSchedule.placeholder();

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
  });

  group('AutomationSchedule.placeholderList', () {
    test('defaults to 4 items', () {
      expect(AutomationSchedule.placeholderList().length, 4);
    });

    test('returns exactly `count` valid schedules', () {
      final list = AutomationSchedule.placeholderList(6);
      expect(list, hasLength(6));
      for (final schedule in list) {
        expect(schedule.name.isNotEmpty, isTrue);
        expect(schedule.onTime, matches(_timeFormat));
        expect(schedule.offTime, matches(_timeFormat));
        expect(schedule.days, isNotEmpty);
      }
    });

    // Fixed: AutomationSchedule.placeholder() now accepts an id and
    // placeholderList() threads the loop index through it, matching
    // WebAutomationSchedule.
    test(
      'items have distinct ids (parity with WebAutomationSchedule)',
      () {
        final ids = AutomationSchedule.placeholderList(4)
            .map((s) => s.id)
            .toSet();
        expect(ids, hasLength(4));
      },
    );
  });

  group('AutomationSchedule.fromMap/.toMap round trip (regression guard)', () {
    test('placeholder survives a toMap -> fromMap round trip', () {
      final original = AutomationSchedule.placeholder();
      final restored = AutomationSchedule.fromMap('some-id', original.toMap());

      expect(restored.id, 'some-id');
      expect(restored.name, original.name);
      expect(restored.scope, original.scope);
      expect(restored.target, original.target);
      expect(restored.utility, original.utility);
      expect(restored.onTime, original.onTime);
      expect(restored.offTime, original.offTime);
      expect(restored.days, original.days);
      expect(restored.enabled, original.enabled);
    });

    test('fromMap still defaults missing onTime/offTime to 08:00/18:00', () {
      final schedule = AutomationSchedule.fromMap('x', const {});
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
