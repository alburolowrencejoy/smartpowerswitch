import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'history_service.dart';
import 'home_widget_service.dart';

/// Global service that maintains a persistent Firebase listener
/// for all devices. Keeps readings updated everywhere in the app.
class GlobalReadingsListener {
  static final GlobalReadingsListener _instance =
      GlobalReadingsListener._internal();

  factory GlobalReadingsListener() {
    return _instance;
  }

  GlobalReadingsListener._internal();

  final Map<String, StreamSubscription> _listeners = {};
  final Map<String, dynamic> _cachedDeviceData = {};
  final Map<String, double> _lastReportedMeterKwh = {};
  final Map<String, Map<String, dynamic>> _deviceMetadata = {};

  /// Initialize and start listening to all real devices
  Future<void> initialize() async {
    try {
      final db = FirebaseDatabase.instance;
      final ref = db.ref('master_devices');

      // Get list of all real devices
      final snapshot = await ref.get();
      if (snapshot.exists) {
        final devices = Map<String, dynamic>.from(snapshot.value as Map);

        for (final entry in devices.entries) {
          final deviceId = entry.key;
          final data = Map<String, dynamic>.from(entry.value as Map);

          // Only listen to real IoT devices
          if (data['source'] == 'real_iot') {
            // Cache device metadata (building, room, etc.)
            _deviceMetadata[deviceId] = data;
            _startListeningToDevice(deviceId);
          }
        }
      }

      debugPrint('[GlobalReadingsListener] Initialized for ${_listeners.length} devices');
    } catch (e) {
      debugPrint('[GlobalReadingsListener] Initialize error: $e');
    }
  }

  /// Start persistent listener for a specific device
  void _startListeningToDevice(String deviceId) {
    if (_listeners.containsKey(deviceId)) {
      return; // Already listening
    }

    final ref = FirebaseDatabase.instance.ref('devices/$deviceId');

    final subscription = ref.onValue.listen((event) {
      if (event.snapshot.exists) {
        final data =
            Map<String, dynamic>.from(event.snapshot.value as Map);
        _cachedDeviceData[deviceId] = data;
        
        // Process reading: calculate kWh delta, write history, update widget
        _processReading(deviceId, data);
      }
    }, onError: (error) {
      debugPrint('[GlobalReadingsListener] Error listening to $deviceId: $error');
    });

    _listeners[deviceId] = subscription;
  }

  /// Process a device reading: calculate kWh delta, write to history, update widget
  Future<void> _processReading(String deviceId, Map<String, dynamic> data) async {
    try {
      final meterKwh = (data['kwh'] as num?)?.toDouble() ?? 0.0;
      double kwhDelta = 0.0;

      // Calculate kWh delta
      final lastReportedKwh = _lastReportedMeterKwh[deviceId] ?? 0.0;
      if (lastReportedKwh > 0.0) {
        kwhDelta = meterKwh - lastReportedKwh;
        if (kwhDelta < 0.0) kwhDelta = meterKwh; // Meter reset
      }

      // Only write if significant enough
      if (kwhDelta >= 0.000001) {
        // Get building from cached metadata
        final metadata = _deviceMetadata[deviceId];
        final building = (metadata?['building'] as String?) ?? 'Unknown';

        await HistoryService.writeHistory(
          deviceId: deviceId,
          building: building,
          kwh: kwhDelta,
        );
        _lastReportedMeterKwh[deviceId] = meterKwh;

        // Update home widget with latest data
        await HomeWidgetService.updateWidget();

        debugPrint(
            '[GlobalReadingsListener] Processed $deviceId: kwhDelta=$kwhDelta');
      }
    } catch (e) {
      debugPrint('[GlobalReadingsListener] Error processing $deviceId: $e');
    }
  }

  /// Get cached data for a device
  Map<String, dynamic>? getDeviceData(String deviceId) {
    return _cachedDeviceData[deviceId];
  }

  /// Get all cached devices
  Map<String, dynamic> getAllDeviceData() {
    return Map.from(_cachedDeviceData);
  }

  /// Stop listening to a device
  void stopListening(String deviceId) {
    _listeners[deviceId]?.cancel();
    _listeners.remove(deviceId);
    _cachedDeviceData.remove(deviceId);
    _lastReportedMeterKwh.remove(deviceId);
    _deviceMetadata.remove(deviceId);
    debugPrint('[GlobalReadingsListener] Stopped listening to $deviceId');
  }

  /// Stop all listeners
  void stopAllListeners() {
    for (final subscription in _listeners.values) {
      subscription.cancel();
    }
    _listeners.clear();
    _cachedDeviceData.clear();
    _lastReportedMeterKwh.clear();
    _deviceMetadata.clear();
    debugPrint('[GlobalReadingsListener] Stopped all listeners');
  }
}
  