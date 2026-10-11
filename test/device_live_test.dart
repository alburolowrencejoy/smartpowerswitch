import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/services/device_live.dart';

void main() {
  final legacy = {
    'building': 'TEST',
    'room': 'test',
    'utility': 'Lights',
    'relay': true, // the app's command (old shared field)
    'kwh': 0.5, // stale once the board runs v2
    'power': 99.0,
    'last_seen': 1,
    'wifiReset': true,
  };
  final live = {
    'telemetry': {'voltage': 230.1, 'power': 60.5, 'cumulativeKwh': 12.3456},
    'connectivity': {
      'status': 'online',
      'lastSeenAt': 1791700000000,
      'wifiSsid': 'DNSC',
      'wifiRssi': -60,
    },
    'state': {'reportedRelay': false, 'lastCommandId': 'c1'},
  };

  test('old board: the old record as is', () {
    expect(DeviceLive.mergeOne(legacy, null), legacy);
  });

  test('v2 board: live fields from device_live, registry copy from devices', () {
    final m = DeviceLive.mergeOne(legacy, live)!;
    expect(m['kwh'], 12.3456);
    expect(m['power'], 60.5);
    expect(m['voltage'], 230.1);
    expect(m['last_seen'], 1791700000000);
    expect(m['status'], 'online');
    expect(m['wifi_ssid'], 'DNSC');
    expect(m['relay'], false, reason: 'what the board reports, not the command');
    expect(m['building'], 'TEST');
    expect(m['utility'], 'Lights');
    expect(m['wifiReset'], true);
  });

  test('v2 board without meter data: stale old readings are not shown', () {
    final m = DeviceLive.mergeOne(legacy, {
      'telemetry': {'voltageWarning': ''},
      'state': {'reportedRelay': true},
    })!;
    expect(m.containsKey('power'), isFalse);
    expect(m['relay'], true);
  });

  test('merge covers devices in either node; nothing for neither', () {
    final all = DeviceLive.merge({'A': legacy}, {'B': live});
    expect(all.keys.toSet(), {'A', 'B'});
    expect(all['B']['kwh'], 12.3456);
    expect(DeviceLive.mergeOne(null, null), isNull);
    expect(DeviceLive.merge(null, null), isEmpty);
  });

  test('isV2', () {
    expect(DeviceLive.isV2(live), isTrue);
    expect(DeviceLive.isV2(null), isFalse);
  });
}
