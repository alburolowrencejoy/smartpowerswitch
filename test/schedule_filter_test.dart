import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/services/schedule_filter.dart';

void main() {
  bool m(
    ScheduleFilter f, {
    String scope = 'building',
    String target = 'IC',
    String utility = 'All',
    bool enabled = true,
    String? deviceBuilding,
    String? deviceUtility,
  }) =>
      f.matches(
        scope: scope,
        target: target,
        utility: utility,
        enabled: enabled,
        deviceBuilding: deviceBuilding,
        deviceUtility: deviceUtility,
      );

  test('default filter matches everything', () {
    const f = ScheduleFilter();
    expect(m(f), isTrue);
    expect(m(f, enabled: false), isTrue);
    expect(m(f, scope: 'device', target: 'X'), isTrue);
  });

  test('status filter', () {
    const active = ScheduleFilter(status: ScheduleStatus.active);
    const paused = ScheduleFilter(status: ScheduleStatus.paused);
    expect(m(active), isTrue);
    expect(m(active, enabled: false), isFalse);
    expect(m(paused), isFalse);
    expect(m(paused, enabled: false), isTrue);
  });

  test('building filter: own building, its devices, and campus-wide', () {
    const f = ScheduleFilter(building: 'IC');
    expect(m(f, target: 'ic'), isTrue, reason: 'case-insensitive');
    expect(m(f, target: 'ITED'), isFalse);
    expect(m(f, scope: 'device', target: 'D1', deviceBuilding: 'IC'), isTrue);
    expect(
        m(f, scope: 'device', target: 'D1', deviceBuilding: 'ITED'), isFalse);
    expect(m(f, scope: 'device', target: 'D1'), isFalse,
        reason: 'unknown device location');
    expect(m(f, scope: 'global', target: 'all'), isTrue);
    expect(m(f, scope: 'utility', target: 'Lights'), isTrue);
  });

  test('utility filter', () {
    const f = ScheduleFilter(utility: 'Lights');
    expect(m(f, utility: 'All'), isTrue, reason: '"All" covers Lights');
    expect(m(f, utility: 'Lights'), isTrue);
    expect(m(f, utility: 'AC'), isFalse);
    expect(m(f, scope: 'utility', target: 'lights'), isTrue);
    expect(m(f, scope: 'utility', target: 'Outlets'), isFalse);
    expect(
        m(f,
            scope: 'device', target: 'D1', utility: 'All', deviceUtility: 'AC'),
        isFalse,
        reason: "a device schedule controls that device's utility");
  });

  test('filters combine', () {
    const f = ScheduleFilter(
        status: ScheduleStatus.active, building: 'IC', utility: 'AC');
    expect(m(f, utility: 'AC'), isTrue);
    expect(m(f, utility: 'AC', enabled: false), isFalse);
    expect(m(f, utility: 'AC', target: 'IAAS'), isFalse);
    expect(f.clearPlace().narrowsPlace, isFalse);
    expect(f.clearPlace().status, ScheduleStatus.active);
  });
}
