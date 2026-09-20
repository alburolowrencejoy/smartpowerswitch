// Unit tests for lib/utils/placeholder_data.dart -- the plain-map fake data
// fed to ScreenSkeleton/Skeletonizer while a screen's real Firebase data is
// still loading. Skeletonizer needs realistic-looking, non-empty content to
// draw bones over, so every field is checked for a plausible non-empty/
// non-zero value, and every *List helper is checked for both the right
// length and genuinely varying content (not `count` identical copies, which
// would mask a bug where the loop index isn't threaded through).
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_power_switch/utils/placeholder_data.dart';

void main() {
  group('placeholderBuilding', () {
    test('has the expected keys, types, and non-empty values', () {
      final building = placeholderBuilding();

      expect(building['code'], isA<String>());
      expect((building['code'] as String).isNotEmpty, isTrue);
      expect(building['name'], isA<String>());
      expect((building['name'] as String).isNotEmpty, isTrue);
      expect(building['floors'], isA<int>());
      expect(building['floors'] as int, greaterThan(0));
    });

    test('honors the code override', () {
      final building = placeholderBuilding(code: 'CCS');
      expect(building['code'], 'CCS');
    });
  });

  group('placeholderBuildingList', () {
    test('defaults to 4 items', () {
      expect(placeholderBuildingList().length, 4);
    });

    test('returns exactly `count` items with distinct codes', () {
      final list = placeholderBuildingList(6);
      expect(list, hasLength(6));

      final codes = list.map((b) => b['code']).toSet();
      expect(codes, hasLength(6),
          reason: 'each building should have a distinct code, otherwise the '
              'loop index is not being used');
    });

    test('count of 0 returns an empty list', () {
      expect(placeholderBuildingList(0), isEmpty);
    });
  });

  group('placeholderDevice', () {
    test('has the expected keys, types, and plausible non-zero values', () {
      final device = placeholderDevice();

      expect(device['device_id'], isA<String>());
      expect((device['device_id'] as String).isNotEmpty, isTrue);
      expect(device['utility'], isA<String>());
      expect((device['utility'] as String).isNotEmpty, isTrue);
      expect(device['building'], isA<String>());
      expect(device['room'], isA<String>());
      expect((device['room'] as String).isNotEmpty, isTrue);
      expect(device['floor'], isA<int>());
      expect(device['relay'], isA<bool>());
      expect(device['power'], isA<num>());
      expect(device['power'] as num, greaterThan(0));
      expect(device['kwh'], isA<num>());
      expect(device['kwh'] as num, greaterThan(0));
      expect(device['assignedTo'], isA<String>());
      expect((device['assignedTo'] as String).isNotEmpty, isTrue);
      expect(device['last_seen'], isA<int>());
      expect(device['last_seen'] as int, greaterThan(0));
    });
  });

  group('placeholderDeviceList', () {
    test('defaults to 6 items', () {
      expect(placeholderDeviceList().length, 6);
    });

    test('returns exactly `count` items with distinct device ids', () {
      final list = placeholderDeviceList(5);
      expect(list, hasLength(5));

      final ids = list.map((d) => d['device_id']).toSet();
      expect(ids, hasLength(5));
    });
  });

  group('placeholderHistoryEntry', () {
    test('has the expected keys, types, and positive kwh/cost', () {
      final entry = placeholderHistoryEntry();

      expect(entry['label'], isA<String>());
      expect((entry['label'] as String).isNotEmpty, isTrue);
      expect(entry['kwh'], isA<num>());
      expect(entry['kwh'] as num, greaterThan(0));
      expect(entry['cost'], isA<num>());
      expect(entry['cost'] as num, greaterThan(0));
    });
  });

  group('placeholderHistoryList', () {
    test('defaults to 7 items', () {
      expect(placeholderHistoryList().length, 7);
    });

    test('returns exactly `count` items with distinct labels', () {
      final list = placeholderHistoryList(3);
      expect(list, hasLength(3));

      final labels = list.map((h) => h['label']).toSet();
      expect(labels, hasLength(3));
    });
  });

  group('placeholderNotification', () {
    test('has the expected keys, types, and non-empty message', () {
      final notif = placeholderNotification();

      expect(notif['id'], isA<String>());
      expect((notif['id'] as String).isNotEmpty, isTrue);
      expect(notif['type'], isA<String>());
      expect((notif['type'] as String).isNotEmpty, isTrue);
      expect(notif['message'], isA<String>());
      expect((notif['message'] as String).isNotEmpty, isTrue);
      expect(notif['building'], isA<String>());
      expect(notif['deviceId'], isA<String>());
      expect(notif['timestamp'], isA<int>());
      expect(notif['timestamp'] as int, greaterThan(0));
    });
  });

  group('placeholderNotificationList', () {
    test('defaults to 5 items', () {
      expect(placeholderNotificationList().length, 5);
    });

    test('returns exactly `count` items with distinct ids', () {
      final list = placeholderNotificationList(4);
      expect(list, hasLength(4));

      final ids = list.map((n) => n['id']).toSet();
      expect(ids, hasLength(4));
    });
  });

  group('placeholderUser', () {
    test('has the expected keys, types, and a plausible email', () {
      final user = placeholderUser();

      expect(user['uid'], isA<String>());
      expect((user['uid'] as String).isNotEmpty, isTrue);
      expect(user['name'], isA<String>());
      expect((user['name'] as String).isNotEmpty, isTrue);
      expect(user['email'], isA<String>());
      expect(user['email'] as String, contains('@'));
      expect(user['role'], isA<String>());
      expect((user['role'] as String).isNotEmpty, isTrue);
      expect(user['institute'], isA<String>());
      expect((user['institute'] as String).isNotEmpty, isTrue);
    });
  });

  group('placeholderUserList', () {
    test('defaults to 5 items', () {
      expect(placeholderUserList().length, 5);
    });

    test('returns exactly `count` items with distinct uids', () {
      final list = placeholderUserList(3);
      expect(list, hasLength(3));

      final uids = list.map((u) => u['uid']).toSet();
      expect(uids, hasLength(3));
    });
  });
}
