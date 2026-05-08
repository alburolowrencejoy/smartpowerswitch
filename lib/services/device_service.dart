import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

class DeviceService {
  static final DeviceService _instance = DeviceService._internal();

  factory DeviceService() {
    return _instance;
  }

  DeviceService._internal();

  final Map<String, Map<String, dynamic>> _deviceCache = {};
  final Map<String, int> _lastRecordedSeen = {}; // Track readings per device
  final Map<String, double> _lastValidEnergy = {}; // Track energy per device
  StreamSubscription? _devicesSub;
  final List<VoidCallback> _listeners = [];
  bool _initialized = false;

  /// Initialize background listening on all devices and collect readings
  void initialize() {
    if (_initialized) return;
    _initialized = true;

    _devicesSub = FirebaseDatabase.instance
        .ref('devices')
        .onValue
        .listen((event) {
      if (event.snapshot.value is! Map) {
        _deviceCache.clear();
      } else {
        final raw = Map<String, dynamic>.from(event.snapshot.value as Map);
        raw.forEach((deviceId, value) {
          if (value is Map) {
            final deviceData = Map<String, dynamic>.from(value);
            _deviceCache[deviceId] = deviceData;
            // Collect readings for this device in background
            _processReadings(deviceId, deviceData);
          }
        });
      }
      // Notify all listeners of updates
      _notifyListeners();
    }, onError: (e) {
      debugPrint('[DeviceService] Error listening to devices: $e');
    });
  }

  /// Process and collect readings for a device (runs in background)
  Future<void> _processReadings(String deviceId, Map<String, dynamic> data) async {
    try {
      final lastSeen = (data['last_seen'] as num?)?.toInt();
      final lastRecordedForDevice = _lastRecordedSeen[deviceId];

      // Skip if no new update
      if (lastSeen != null && lastSeen == lastRecordedForDevice) {
        return;
      }

      // Calculate energy for this 3-second interval
      final power = (data['power'] as num?)?.toDouble() ?? 0.0;
      const intervalHours = 3.0 / 3600.0;
      final kwhThisInterval = (power / 1000.0) * intervalHours;

      if (kwhThisInterval > 0.000001) {
        // Accumulate energy
        _lastValidEnergy[deviceId] = (_lastValidEnergy[deviceId] ?? 0) + kwhThisInterval;
        final relay = (data['relay'] as bool?) ?? false;

        // Push to database
        final building = (data['building'] as String?) ?? 'Unknown';
        final room = (data['room'] as String?) ?? 'Unknown';

        // Record reading
        await FirebaseDatabase.instance
            .ref('readings/$building/$room/$deviceId')
            .set({
          'cumulative_kwh': double.parse(
              (_lastValidEnergy[deviceId] ?? 0).toStringAsFixed(6)),
          'last_update': DateTime.now().millisecondsSinceEpoch,
          'last_iso_timestamp': DateTime.now().toIso8601String(),
          'relay_status': relay,
          'building': building,
          'room': room,
          'device_id': deviceId,
        });

        // Record history
        await FirebaseDatabase.instance
            .ref('history/daily/${_dateKey()}/totals/$deviceId')
            .update({
          'kwh': kwhThisInterval,
        }).catchError((_) {
          // Ignore errors, history is secondary
        });
      }

      if (lastSeen != null) {
        _lastRecordedSeen[deviceId] = lastSeen;
      }
    } catch (e) {
      debugPrint('[DeviceService] Error processing readings for $deviceId: $e');
    }
  }

  String _dateKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  /// Stop background listening
  void dispose() {
    _devicesSub?.cancel();
    _initialized = false;
    _deviceCache.clear();
    _listeners.clear();
  }

  /// Get device data by ID
  Map<String, dynamic>? getDevice(String deviceId) {
    final device = _deviceCache[deviceId];
    if (device is! Map) return null;
    return device;
  }

  /// Get all devices
  Map<String, Map<String, dynamic>> getAllDevices() {
    return Map.from(_deviceCache);
  }

  /// Subscribe to device updates (call returns unsubscribe function)
  VoidCallback subscribe(VoidCallback listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }
}

