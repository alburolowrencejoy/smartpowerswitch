import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';

class ReadingsService {
  static final _db = FirebaseDatabase.instance.ref();

  /// Records accumulated energy reading.
  /// Stores the cumulative kWh total calculated from watt readings over time.
  /// Only records when value actually changes (delta detection at caller level).
  static Future<bool> recordReading({
    required String deviceId,
    required String building,
    required String room,
    required double kwh,
    required bool relay,
  }) async {
    try {
      final now = DateTime.now();
      final timestamp = now.millisecondsSinceEpoch;

      // Store the accumulated energy total calculated by the caller.
      await _db.child('readings/$building/$room/$deviceId').set({
        'cumulative_kwh': double.parse(kwh.toStringAsFixed(6)),
        'last_update': timestamp,
        'last_iso_timestamp': now.toIso8601String(),
        'relay_status': relay,
        'building': building,
        'room': room,
        'device_id': deviceId,
      });

      return true;
    } catch (e) {
      debugPrint('ReadingsService: Error recording reading: $e');
      return false;
    }
  }

  /// Fetches all readings from the database
  static Future<List<Map<String, dynamic>>> getAllReadings() async {
    try {
      final snap = await _db.child('readings').get();
      if (!snap.exists) return [];

      final List<Map<String, dynamic>> readings = [];
      final data = Map<String, dynamic>.from(snap.value as Map);

      data.forEach((building, buildingData) {
        final bData = Map<String, dynamic>.from(buildingData as Map);
        bData.forEach((room, roomData) {
          final rData = Map<String, dynamic>.from(roomData as Map);
          rData.forEach((deviceId, readingData) {
            final rMap = Map<String, dynamic>.from(readingData as Map);
            readings.add({
              'building': building,
              'room': room,
              'device_id': deviceId,
              ...rMap,
            });
          });
        });
      });

      // Sort by timestamp descending
      readings.sort((a, b) {
        final tsA = (a['last_update'] as num?) ?? 0;
        final tsB = (b['last_update'] as num?) ?? 0;
        return tsB.compareTo(tsA);
      });

      return readings;
    } catch (e) {
      debugPrint('ReadingsService: Error fetching readings: $e');
      return [];
    }
  }

  /// Export all readings as JSON string
  static Future<String> exportAsJson() async {
    final readings = await getAllReadings();
    return jsonEncode({
      'export_timestamp': DateTime.now().toIso8601String(),
      'total_devices': readings.length,
      'readings': readings,
    });
  }

  /// Export all readings as CSV string
  static Future<String> exportAsCsv() async {
    final readings = await getAllReadings();
    if (readings.isEmpty) return 'Building,Room,Device ID,Cumulative kWh,Last Update,Relay Status\n';

    final StringBuffer csv = StringBuffer();
    csv.writeln('Building,Room,Device ID,Cumulative kWh,ISO Timestamp,Relay Status');

    for (final reading in readings) {
      final building = reading['building'] ?? '';
      final room = reading['room'] ?? '';
      final deviceId = reading['device_id'] ?? '';
      final cumulativeKwh = reading['cumulative_kwh'] ?? 0.0;
      final ts = reading['last_iso_timestamp'] ?? '';
      final relay = reading['relay_status'] ?? false;

      csv.writeln('$building,$room,$deviceId,$cumulativeKwh,$ts,$relay');
    }

    return csv.toString();
  }

  /// Clear all readings (use with caution)
  static Future<void> clearAllReadings() async {
    try {
      await _db.child('readings').remove();
    } catch (e) {
      debugPrint('ReadingsService: Error clearing readings: $e');
    }
  }
}
