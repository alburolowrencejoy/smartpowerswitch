import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/services/device_registry.dart';

void main() {
  group('parseAssignedTo', () {
    test('building, floor and room', () {
      final a = DeviceRegistry.parseAssignedTo('ic/2/Room 201');
      expect(a.building, 'IC');
      expect(a.floor, 2);
      expect(a.room, 'Room 201');
    });

    test('room names may contain slashes', () {
      expect(DeviceRegistry.parseAssignedTo('ITED/1/Lab A/B').room, 'Lab A/B');
    });

    test('unassigned and malformed values are unassigned', () {
      for (final v in [null, '', 'IC', 'IC/1']) {
        expect(DeviceRegistry.parseAssignedTo(v).building, '', reason: '$v');
      }
    });
  });

  group('parse', () {
    final master = {
      'ESP32-B': {
        'assignedTo': 'TEST/1/test',
        'source': 'real_iot',
        'utility': 'Unassigned',
      },
      'ESP32-A': {
        'assignedTo': '',
        'source': 'real_iot',
        'name': 'Lab lights',
        'utility': 'Lights',
      },
    };
    final live = {
      'ESP32-B': {'utility': 'Lights', 'power': 12.5, 'kwh': 3.2},
      'DVC-IC-001': {'utility': 'Lights'}, // only in devices: not a device
    };

    test('lists registry entries only, sorted, joined with live readings', () {
      final all = DeviceRegistry.parse(master, live);
      expect(all.map((d) => d.id), ['ESP32-A', 'ESP32-B']);
      final b = all[1];
      expect(b.live['power'], 12.5);
      expect(b.building, 'TEST');
      expect(b.floor, 1);
      expect(b.room, 'test');
      expect(b.assignedTo, 'TEST/1/test');
      expect(all[0].isAssigned, isFalse);
      expect(all[0].live, isEmpty);
    });

    test('name and utility come from the registry, else the live copy', () {
      final all = DeviceRegistry.parse(master, live);
      expect(all[0].name, 'Lab lights');
      expect(all[0].displayName, 'Lab lights');
      expect(all[1].utility, 'Lights'); // registry says 'Unassigned'
      expect(all[1].displayName, 'ESP32-B');
    });

    test('inPlace filters by building, floor and room', () {
      final all = DeviceRegistry.parse(master, live);
      expect(DeviceRegistry.inPlace(all, building: 'test').map((d) => d.id),
          ['ESP32-B']);
      expect(DeviceRegistry.inPlace(all, building: 'TEST', floor: 2), isEmpty);
      expect(DeviceRegistry.inPlace(all, building: 'TEST', floor: 1, room: 'test'),
          hasLength(1));
    });

    test('no registry means no devices', () {
      expect(DeviceRegistry.parse(null, live), isEmpty);
    });
  });

  group('writes', () {
    test('assignment writes registry + transition copy, never live readings',
        () {
      final u = DeviceRegistry.assignmentUpdate(
          id: 'X', building: 'ic', floor: 1, room: 'Room 101 ', utility: 'AC',
          name: ' Aircon 1 ');
      expect(u['master_devices/X/assignedTo'], 'IC/1/Room 101');
      expect(u['master_devices/X/utility'], 'AC');
      expect(u['master_devices/X/name'], 'Aircon 1');
      expect(u['devices/X/building'], 'IC');
      expect(u['devices/X/floor'], '1');
      for (final field in ['kwh', 'power', 'voltage', 'current', 'relay',
          'status', 'last_seen', 'last_updated']) {
        expect(u.containsKey('devices/X/$field'), isFalse, reason: field);
      }
      expect(u.keys.any((k) => k.startsWith('buildings/')), isFalse);
    });

    test('unassignment clears the room but keeps the device registered', () {
      final u = DeviceRegistry.unassignmentUpdate('X');
      expect(u['master_devices/X/assignedTo'], '');
      expect(u.containsKey('master_devices/X'), isFalse);
      expect(u['devices/X/building'], '');
    });

    test('rename', () {
      expect(DeviceRegistry.renameUpdate('X', ' Desk fan '),
          {'master_devices/X/name': 'Desk fan'});
    });
  });
}
