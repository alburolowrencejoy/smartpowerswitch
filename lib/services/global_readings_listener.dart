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

  StreamSubscription? _devicesSub;
  StreamSubscription? _masterDevicesSub;
  final Map<String, dynamic> _cachedDeviceData = {};
  final Map<String, double> _lastReportedMeterKwh = {};
  final Map<String, Map<String, dynamic>> _deviceMetadata = {};
  Set<String> _realIotDeviceIds = {};

  /// Initialize and start listening to all real devices
  Future<void> initialize() async {
    try {
      final db = FirebaseDatabase.instance;

      // Get the initial list of real devices
      final snapshot = await db.ref('master_devices').get();
      if (snapshot.exists) {
        _applyMasterDevices(Map<String, dynamic>.from(snapshot.value as Map));
      }

      // Keep the real-IoT device set current, so a device registered after
      // startup is picked up without needing an app restart.
      _masterDevicesSub = db.ref('master_devices').onValue.listen((event) {
        final raw = event.snapshot.value;
        if (raw is! Map) return;
        _applyMasterDevices(Map<String, dynamic>.from(raw));
      }, onError: (error) {
        debugPrint('[GlobalReadingsListener] master_devices error: $error');
      });

      _startListening();

      debugPrint(
          '[GlobalReadingsListener] Initialized for ${_realIotDeviceIds.length} devices');
    } catch (e) {
      debugPrint('[GlobalReadingsListener] Initialize error: $e');
    }
  }

  void _applyMasterDevices(Map<String, dynamic> devices) {
    final ids = <String>{};
    for (final entry in devices.entries) {
      final deviceId = entry.key;
      if (entry.value is! Map) continue;
      final data = Map<String, dynamic>.from(entry.value as Map);
      if (data['source'] == 'real_iot') {
        _deviceMetadata[deviceId] = data;
        ids.add(deviceId);
      }
    }
    _realIotDeviceIds = ids;
  }

  /// Single persistent listener on the whole `devices` node -- covers every
  /// real-IoT device with one subscription instead of one listener per
  /// device (which also never noticed devices registered after startup).
  void _startListening() {
    if (_devicesSub != null) return;

    _devicesSub =
        FirebaseDatabase.instance.ref('devices').onValue.listen((event) {
      final raw = event.snapshot.value;
      if (raw is! Map) return;
      final devices = Map<String, dynamic>.from(raw);

      for (final deviceId in _realIotDeviceIds) {
        final val = devices[deviceId];
        if (val is! Map) continue;
        final data = Map<String, dynamic>.from(val);
        _cachedDeviceData[deviceId] = data;
        _processReading(deviceId, data);
      }
    }, onError: (error) {
      debugPrint('[GlobalReadingsListener] Error listening to devices: $error');
    });
  }

  /// Process a device reading: calculate kWh delta, write to history, update widget
  Future<void> _processReading(
      String deviceId, Map<String, dynamic> data) async {
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

  /// Stop tracking a single device (it stays covered by the shared `devices`
  /// listener until removed from `master_devices`; this just clears its
  /// locally cached state).
  void stopListening(String deviceId) {
    _realIotDeviceIds.remove(deviceId);
    _cachedDeviceData.remove(deviceId);
    _lastReportedMeterKwh.remove(deviceId);
    _deviceMetadata.remove(deviceId);
    debugPrint('[GlobalReadingsListener] Stopped tracking $deviceId');
  }

  /// Stop all listeners
  void stopAllListeners() {
    _devicesSub?.cancel();
    _devicesSub = null;
    _masterDevicesSub?.cancel();
    _masterDevicesSub = null;
    _realIotDeviceIds.clear();
    _cachedDeviceData.clear();
    _lastReportedMeterKwh.clear();
    _deviceMetadata.clear();
    debugPrint('[GlobalReadingsListener] Stopped all listeners');
  }
}
