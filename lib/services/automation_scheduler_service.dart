import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

String _dayLabel(DateTime now) {
  switch (now.weekday) {
    case DateTime.monday:
      return 'Mon';
    case DateTime.tuesday:
      return 'Tue';
    case DateTime.wednesday:
      return 'Wed';
    case DateTime.thursday:
      return 'Thu';
    case DateTime.friday:
      return 'Fri';
    case DateTime.saturday:
      return 'Sat';
    case DateTime.sunday:
      return 'Sun';
    default:
      return 'Mon';
  }
}

String _previousDayLabel(DateTime now) {
  final previous = now.subtract(const Duration(days: 1));
  return _dayLabel(previous);
}

bool _parseBool(Object? raw) {
  if (raw is bool) return raw;
  return raw?.toString().toLowerCase().trim() == 'true';
}

class AutomationSchedulerService {
  static final DatabaseReference _root = FirebaseDatabase.instance.ref();

  static StreamSubscription<DatabaseEvent>? _automationSub;
  static StreamSubscription<DatabaseEvent>? _deviceSub;
  static Timer? _timer;
  static bool _started = false;

  static List<_AutomationRecord> _schedules = const [];
  static Map<String, Map<String, dynamic>> _devices = const {};
  static DateTime? _lastTickTime; // Debounce rapid ticks

  static Future<void> startIfNeeded() async {
    if (_started) return;
    _started = true;

    await _refreshSnapshots();

    _automationSub = _root.child('automations').onValue.listen(
      _handleAutomationEvent,
      onError: (Object error) {
        debugPrint('[AutomationScheduler] schedule listen failed: $error');
      },
    );

    _deviceSub = _root.child('devices').onValue.listen(
      _handleDeviceEvent,
      onError: (Object error) {
        debugPrint('[AutomationScheduler] device listen failed: $error');
      },
    );

    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_tick());
    });

    unawaited(_tick());
  }

  static Future<void> stop() async {
    await _automationSub?.cancel();
    await _deviceSub?.cancel();
    _automationSub = null;
    _deviceSub = null;
    _timer?.cancel();
    _timer = null;
    _schedules = const [];
    _devices = const {};
    _started = false;
  }

  static Future<void> _refreshSnapshots() async {
    try {
      final scheduleSnapshot = await _root.child('automations').get();
      _handleAutomationSnapshot(scheduleSnapshot.value);
    } catch (error) {
      debugPrint('[AutomationScheduler] initial schedule load failed: $error');
    }

    try {
      final deviceSnapshot = await _root.child('devices').get();
      _handleDeviceSnapshot(deviceSnapshot.value);
    } catch (error) {
      debugPrint('[AutomationScheduler] initial device load failed: $error');
    }
  }

  static void _handleAutomationEvent(DatabaseEvent event) {
    _handleAutomationSnapshot(event.snapshot.value);
  }

  static void _handleDeviceEvent(DatabaseEvent event) {
    _handleDeviceSnapshot(event.snapshot.value);
  }

  static void _handleAutomationSnapshot(Object? raw) {
    final schedules = <_AutomationRecord>[];
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      map.forEach((id, value) {
        if (value is Map) {
          schedules.add(_AutomationRecord.fromMap(
            id.toString(),
            Map<String, dynamic>.from(value),
          ));
        }
      });
    }
    _schedules = schedules;
  }

  static void _handleDeviceSnapshot(Object? raw) {
    final devices = <String, Map<String, dynamic>>{};
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      map.forEach((id, value) {
        if (value is Map) {
          devices[id.toString()] = Map<String, dynamic>.from(value);
        }
      });
    }
    _devices = devices;
  }

  static Future<void> _tick() async {
    if (_schedules.isEmpty || _devices.isEmpty) return;

    final now = DateTime.now();
    // Debounce: skip if last tick was less than 2 seconds ago
    if (_lastTickTime != null && now.difference(_lastTickTime!).inMilliseconds < 2000) {
      return;
    }
    _lastTickTime = now;

    for (final schedule in _schedules) {
      if (!schedule.enabled) continue;

      final action = schedule.actionFor(now);
      if (action == null) continue;

      final desiredRelay = action == 'on';
      final targets = _resolveTargets(schedule);
      if (targets.isEmpty) continue;

      for (final device in targets) {
        final currentRelay = _parseBool(device.value['relay']);
        if (currentRelay == desiredRelay) continue;
        await _applyRelay(device, desiredRelay);
      }
    }
  }

  static List<MapEntry<String, Map<String, dynamic>>> _resolveTargets(
    _AutomationRecord schedule,
  ) {
    final entries = _devices.entries.where((entry) {
      final device = entry.value;
      switch (schedule.scope) {
        case 'global':
          return _utilityMatches(schedule.utility, device['utility']);
        case 'building':
          return _buildingMatches(schedule.target, device['building']) &&
              _utilityMatches(schedule.utility, device['utility']);
        case 'utility':
          return _utilityMatches(schedule.target, device['utility']);
        case 'device':
          return entry.key.trim() == schedule.target.trim();
        default:
          return false;
      }
    }).toList();

    return entries;
  }

  static Future<void> _applyRelay(
    MapEntry<String, Map<String, dynamic>> device,
    bool desiredRelay,
  ) async {
    final deviceId = device.key;
    final deviceData = device.value;

    try {
      await _root.child('devices/$deviceId/relay').set(desiredRelay);

      final building = (deviceData['building'] ?? '').toString().trim();
      final floor = (deviceData['floor'] ?? '').toString().trim();
      if (building.isNotEmpty && floor.isNotEmpty) {
        unawaited(
          _root
              .child('buildings/$building/floorData/$floor/devices/$deviceId/relay')
              .set(desiredRelay),
        );
      }

      debugPrint(
        '[AutomationScheduler] $deviceId -> ${desiredRelay ? 'ON' : 'OFF'}',
      );
    } catch (error) {
      debugPrint(
        '[AutomationScheduler] failed to update $deviceId -> ${desiredRelay ? 'ON' : 'OFF'}: $error',
      );
    }
  }

  static bool _buildingMatches(String expected, Object? actual) {
    return _normalizeBuilding(expected) == _normalizeBuilding(actual);
  }

  static bool _utilityMatches(String expected, Object? actual) {
    final normalizedExpected = _canonicalUtility(expected);
    if (normalizedExpected == 'all') return true;
    return normalizedExpected == _canonicalUtility(actual?.toString());
  }

  static String _canonicalUtility(String? raw) {
    final value = (raw ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '');

    switch (value) {
      case 'light':
      case 'lights':
        return 'lights';
      case 'outlet':
      case 'outlets':
        return 'outlets';
      case 'ac':
      case 'aircon':
      case 'airconditioner':
      case 'airconditioners':
      case 'airconditioning':
        return 'ac';
      case 'all':
      case '':
        return 'all';
      default:
        return value;
    }
  }

  static String _normalizeBuilding(Object? raw) {
    return (raw ?? '').toString().trim().toUpperCase();
  }

  static bool _parseBool(Object? raw) {
    if (raw is bool) return raw;
    return raw?.toString().toLowerCase().trim() == 'true';
  }
}

class _AutomationRecord {
  final String id;
  final String scope;
  final String target;
  final String utility;
  final String onTime;
  final String offTime;
  final List<String> days;
  final bool enabled;

  _AutomationRecord({
    required this.id,
    required this.scope,
    required this.target,
    required this.utility,
    required this.onTime,
    required this.offTime,
    required this.days,
    required this.enabled,
  });

  factory _AutomationRecord.fromMap(String id, Map<String, dynamic> data) {
    final rawDays = data['days'];
    final days = <String>[];
    if (rawDays is List) {
      days.addAll(rawDays.map((d) => d.toString()));
    } else if (rawDays is Map) {
      days.addAll(rawDays.values.map((d) => d.toString()));
    }

    final legacyAction = (data['action'] ?? '').toString().toLowerCase();
    final legacyTime = (data['time'] ?? '').toString();

    var onTime = (data['onTime'] ?? '').toString();
    var offTime = (data['offTime'] ?? '').toString();

    if (onTime.isEmpty && legacyAction == 'on' && legacyTime.isNotEmpty) {
      onTime = legacyTime;
    }
    if (offTime.isEmpty && legacyAction == 'off' && legacyTime.isNotEmpty) {
      offTime = legacyTime;
    }
    if (onTime.isEmpty) onTime = '08:00';
    if (offTime.isEmpty) offTime = '18:00';

    return _AutomationRecord(
      id: id,
      scope: (data['scope'] ?? 'global').toString(),
      target: (data['target'] ?? 'all').toString(),
      utility: (data['utility'] ?? 'All').toString(),
      onTime: onTime,
      offTime: offTime,
      days: days,
      enabled: _parseBool(data['enabled'] ?? true),
    );
  }

  bool _matchesDay(DateTime now) {
    return days.contains(_dayLabel(now));
  }

  bool _matchesPreviousDay(DateTime now) {
    return days.contains(_previousDayLabel(now));
  }

  int? _parseMinutes(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return hour * 60 + minute;
  }

  String? actionFor(DateTime now) {
    final current = now.hour * 60 + now.minute;
    final onMinutes = _parseMinutes(onTime);
    final offMinutes = _parseMinutes(offTime);
    if (onMinutes == null || offMinutes == null) return null;

    if (_matchesDay(now) && current == onMinutes) {
      return 'on';
    }

    final overnight = onMinutes > offMinutes;
    if (current != offMinutes) return null;

    if (!overnight) {
      return _matchesDay(now) ? 'off' : null;
    }

    return _matchesPreviousDay(now) ? 'off' : null;
  }
}