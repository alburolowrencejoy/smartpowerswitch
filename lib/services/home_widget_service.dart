import 'package:flutter/foundation.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service to manage home screen widget updates
class HomeWidgetService {
  /// Initialize home widget updates
  /// Call this once when app starts
  static Future<void> initialize() async {
    try {
      await updateWidget();
    } catch (e) {
      debugPrint('[HomeWidget] Init error: $e');
    }
  }

  /// Update home widget with latest device data
  /// Call this whenever device data changes in Firebase
  static Future<void> updateWidget() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Get saved device ID and building from last viewed device
      final deviceId = prefs.getString('last_device_id') ?? '';
      final building = prefs.getString('last_device_building') ?? '';
      final room = prefs.getString('last_device_room') ?? '';

      if (deviceId.isEmpty) {
        await _updateWidgetOffline('No Device Selected');
        return;
      }

      // Fetch device data from Firebase
      final ref = FirebaseDatabase.instance.ref('devices/$deviceId');
      final snapshot = await ref.get();

      if (!snapshot.exists) {
        await _updateWidgetOffline('Device Not Found');
        return;
      }

      final data = Map<String, dynamic>.from(snapshot.value as Map);

      // Extract metrics
      final kwh = (data['kwh'] as num?)?.toDouble() ?? 0.0;
      final voltage = (data['voltage'] as num?)?.toDouble() ?? 0.0;
      final power = (data['power'] as num?)?.toDouble() ?? 0.0;
      final status = (data['status'] as String?) ?? 'offline';
      const rate = 11.5; // PHP per kWh
      final cost = (kwh * rate).toStringAsFixed(2);

      // Determine voltage status
      final voltageStatus = _getVoltageStatus(voltage);

      // Save widget data to SharedPreferences (accessible by widget)
      await prefs.setString('widget_device_id', deviceId);
      await prefs.setString('widget_building', building);
      await prefs.setString('widget_room', room);
      await prefs.setString('widget_kwh', kwh.toStringAsFixed(3));
      await prefs.setString('widget_cost', cost);
      await prefs.setString('widget_voltage', voltage.toStringAsFixed(1));
      await prefs.setString('widget_power', power.toStringAsFixed(1));
      await prefs.setString('widget_status', status);
      await prefs.setString('widget_voltage_status', voltageStatus);
      await prefs.setString('widget_timestamp', DateTime.now().toString());

      debugPrint('[HomeWidget] Updated: $deviceId - ${kwh.toStringAsFixed(3)}kWh');
    } catch (e) {
      debugPrint('[HomeWidget] Update error: $e');
      await _updateWidgetOffline('Update Failed');
    }
  }

  /// Save device selection for widget display
  static Future<void> saveDeviceSelection({
    required String deviceId,
    required String building,
    required String room,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_device_id', deviceId);
    await prefs.setString('last_device_building', building);
    await prefs.setString('last_device_room', room);

    // Immediately update widget
    await updateWidget();
  }

  /// Update widget to offline state
  static Future<void> _updateWidgetOffline(String reason) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('widget_device_id', 'N/A');
      await prefs.setString('widget_building', 'N/A');
      await prefs.setString('widget_room', 'N/A');
      await prefs.setString('widget_kwh', '0.000');
      await prefs.setString('widget_cost', '0.00');
      await prefs.setString('widget_voltage', '0.0');
      await prefs.setString('widget_power', '0.0');
      await prefs.setString('widget_status', 'offline');
      await prefs.setString('widget_voltage_status', 'unknown');
      await prefs.setString('widget_timestamp', DateTime.now().toString());

      debugPrint('[HomeWidget] Offline: $reason');
    } catch (e) {
      debugPrint('[HomeWidget] Offline update error: $e');
    }
  }

  /// Determine voltage status (normal, low, high)
  static String _getVoltageStatus(double voltage) {
    if (voltage < 207.0) {
      return 'low'; // Brownout
    } else if (voltage > 253.0) {
      return 'high'; // Surge
    }
    return 'normal';
  }
}

