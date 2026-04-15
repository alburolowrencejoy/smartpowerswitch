import 'dart:math';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../config/app_mode.dart';

class MockSeedService {
  static const String _seedVersion = 'mock-v4-live-only';
  static const double _rate = 11.5;

  static Future<void> seedIfNeeded({
    bool force = false,
    bool reseed = false,
  }) async {
    if (!force && !kSeedMockData) {
      return;
    }

    try {
      final db = FirebaseDatabase.instance.ref();
      final markerRef = db.child('meta/mockSeedVersion');

      if (!reseed && !kForceReseedMock) {
        final marker = await markerRef.get();
        if (marker.value == _seedVersion) return;
      }

      final random = Random(20260415);
      final now = DateTime.now().millisecondsSinceEpoch;

      final buildingDefs = <Map<String, String>>[
        {'code': 'IC', 'name': 'Institute of Computing'},
        {'code': 'ITE', 'name': 'Institute of Teacher Education'},
        {
          'code': 'IAAS',
          'name': 'Institute of Agriculture and Applied Sciences'
        },
        {
          'code': 'ILEGG',
          'name': 'Institute of Leadership and Good Governance'
        },
        {'code': 'ADMIN', 'name': 'Administration Building'},
      ];

      final roomNames = <String>['Room 101', 'Room 102', 'Room 103'];
      final utilityPool = <String>['Lights', 'Outlets', 'AC'];

      final buildings = <String, dynamic>{};
      final devices = <String, dynamic>{};
      final masterDevices = <String, dynamic>{};

      int deviceCounter = 1;

      for (final b in buildingDefs) {
        final code = b['code']!;
        final buildingDevices = <String, dynamic>{};

        for (final room in roomNames) {
          final deviceCount = 1 + random.nextInt(4); // 1..4 randomized

          for (int i = 0; i < deviceCount; i++) {
            final deviceId =
                'DVC-$code-${deviceCounter.toString().padLeft(3, '0')}';
            deviceCounter++;

            final utility = utilityPool[random.nextInt(utilityPool.length)];
            final relay = random.nextBool();
            final voltage = 218 + random.nextDouble() * 8;
            final current = relay ? (0.3 + random.nextDouble() * 3.8) : 0.02;
            final pf = 0.88 + random.nextDouble() * 0.1;
            final power = voltage * current * pf;
            // Start from zero so history and totals are built only by live feed.
            const kwh = 0.0;
            final online = random.nextDouble() > 0.08;

            buildingDevices[deviceId] = {
              'room': room,
              'utility': utility,
              'relay': relay,
            };

            devices[deviceId] = {
              'building': code,
              'floor': '1',
              'room': room,
              'utility': utility,
              'voltage': _round(voltage, 1),
              'current': _round(current, 2),
              'power': _round(power, 1),
              'powerFactor': _round(pf, 2),
              'kwh': _round(kwh, 3),
              'relay': relay,
              'status': online ? 'online' : 'offline',
              'last_seen':
                  online ? now : now - 1000 * 60 * (6 + random.nextInt(8)),
            };

            masterDevices[deviceId] = {
              'assignedTo': '$code/1/$room',
              'utility': utility,
            };
          }
        }

        buildings[code] = {
          'name': b['name'],
          'floors': 1,
          'floorData': {
            '1': {
              'rooms': {
                '1': roomNames[0],
                '2': roomNames[1],
                '3': roomNames[2],
              },
              'devices': buildingDevices,
            },
          },
        };
      }

      // Add some unassigned inventory devices.
      for (int i = 0; i < 3; i++) {
        final id = 'DVC-UNASSIGNED-${(i + 1).toString().padLeft(3, '0')}';
        final utility = utilityPool[random.nextInt(utilityPool.length)];
        masterDevices[id] = {'assignedTo': '', 'utility': utility};
      }

      final hotspots = <String, dynamic>{
        'IC': {'x': 0.30, 'y': 0.36, 'w': 0.16, 'h': 0.09},
        'ITE': {'x': 0.62, 'y': 0.38, 'w': 0.16, 'h': 0.09},
        'IAAS': {'x': 0.46, 'y': 0.56, 'w': 0.17, 'h': 0.10},
        'ILEGG': {'x': 0.22, 'y': 0.60, 'w': 0.17, 'h': 0.10},
        'ADMIN': {'x': 0.70, 'y': 0.58, 'w': 0.17, 'h': 0.10},
      };

      final users = <String, dynamic>{
        'mock-admin': {
          'email': 'admin@dnsc.edu.ph',
          'name': 'Mock Admin',
          'role': 'admin',
        },
        'mock-faculty': {
          'email': 'faculty@dnsc.edu.ph',
          'name': 'Mock Faculty',
          'role': 'faculty',
        },
      };

      final notifications = <String, dynamic>{
        'n1': {
          'title': 'High Consumption Detected',
          'message': 'One room exceeded normal usage in IC.',
          'type': 'warning',
          'timestamp': now - 1000 * 60 * 40,
        },
        'n2': {
          'title': 'Device Offline',
          'message': 'A mock device went offline for monitoring test.',
          'type': 'alert',
          'timestamp': now - 1000 * 60 * 9,
        },
      };

      await db.child('settings').set({'electricityRate': _rate});
      await db.child('users').set(users);
      await db.child('buildings').set(buildings);
      await db.child('devices').set(devices);
      await db.child('master_devices').set(masterDevices);
      await db.child('hotspots').set(hotspots);
      await db.child('history').set({
        // Keep empty until live feed writes incremental values.
        'daily': <String, dynamic>{},
        'weekly': <String, dynamic>{},
        'monthly': <String, dynamic>{},
        'yearly': <String, dynamic>{},
      });
      await db.child('notifications').set(notifications);
      await markerRef.set(_seedVersion);
    } catch (e) {
      final text = e.toString().toLowerCase();
      if (text.contains('permission-denied') ||
          text.contains('permission_denied')) {
        debugPrint(
          'MockSeedService: skipped seeding due to Firebase rules (permission-denied).',
        );
        return;
      }
      rethrow;
    }
  }

  static Future<void> clearRuntimeDemoData() async {
    final db = FirebaseDatabase.instance.ref();

    await db.child('history').set({
      'daily': <String, dynamic>{},
      'weekly': <String, dynamic>{},
      'monthly': <String, dynamic>{},
      'yearly': <String, dynamic>{},
    });

    final devicesSnap = await db.child('devices').get();
    if (devicesSnap.value is Map) {
      final devices = Map<String, dynamic>.from(devicesSnap.value as Map);
      final updates = <String, dynamic>{};

      devices.forEach((id, _) {
        updates['devices/$id/kwh'] = 0;
        updates['devices/$id/voltage'] = 0;
        updates['devices/$id/current'] = 0;
        updates['devices/$id/power'] = 0;
        updates['devices/$id/powerFactor'] = 0;
        updates['devices/$id/status'] = 'offline';
        updates['devices/$id/last_seen'] = 0;
      });

      if (updates.isNotEmpty) {
        await db.update(updates);
      }
    }

    await db.child('meta/mockSeedVersion').remove();
  }

  static double _round(double value, int places) {
    final p = pow(10, places).toDouble();
    return (value * p).roundToDouble() / p;
  }
}
