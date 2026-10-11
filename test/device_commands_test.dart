import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/services/device_commands.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 11, 1);
  final ms = t0.millisecondsSinceEpoch;

  test('relay command writes device_commands and the old field together', () {
    final u = DeviceCommands.relayUpdate('X', true,
        issuedBy: 'uid-1', issuedAt: ms, commandId: 'c1');
    expect(u, {
      'device_commands/X/desiredRelay': true,
      'device_commands/X/commandId': 'c1',
      'device_commands/X/issuedAt': ms,
      'device_commands/X/issuedBy': 'uid-1',
      'devices/X/relay': true,
    });
  });

  test('command IDs are unique', () {
    final ids = {for (var i = 0; i < 200; i++) DeviceCommands.newCommandId(t0)};
    expect(ids, hasLength(200));
  });

  test('wifi reset and its cancel', () {
    expect(DeviceCommands.wifiResetUpdate('X', true), {
      'device_commands/X/wifiReset': true,
      'devices/X/wifiReset': true,
    });
    expect(DeviceCommands.wifiResetUpdate('X', false), {
      'device_commands/X/wifiReset': null,
      'devices/X/wifiReset': null,
    });
  });

  group('statusOf', () {
    final cmd = {'commandId': 'c1', 'desiredRelay': true, 'issuedAt': ms};
    CommandStatus at(Object? command, Object? state, int seconds) =>
        DeviceCommands.statusOf(command, state,
            now: t0.add(Duration(seconds: seconds)));

    test('no command', () => expect(at(null, null, 0), CommandStatus.none));

    test('old firmware (no device_live) is unconfirmed, never failed', () {
      expect(at(cmd, null, 300), CommandStatus.unconfirmed);
    });

    test('pending until acknowledged, failed after the timeout', () {
      final state = {'lastCommandId': 'c0', 'reportedRelay': false};
      expect(at(cmd, state, 5), CommandStatus.pending);
      expect(at(cmd, state, 31), CommandStatus.failed);
    });

    test('acknowledged when the board confirms and its relay matches', () {
      expect(at(cmd, {'lastCommandId': 'c1', 'reportedRelay': true}, 2),
          CommandStatus.acknowledged);
    });

    test('confirmed but relay did not follow is failed', () {
      expect(at(cmd, {'lastCommandId': 'c1', 'reportedRelay': false}, 2),
          CommandStatus.failed);
    });
  });
}
