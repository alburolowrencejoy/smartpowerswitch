import 'dart:async';
import 'dart:math';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../config/app_mode.dart';
import 'history_service.dart';

class MockLiveFeedService {
  static Timer? _timer;
  static final Random _random = Random();

  static Future<void> startIfNeeded() async {
    await start();
  }

  static Future<void> start({bool force = false}) async {
    if (!force && !kEnableMockLiveFeed) return;
    if (_timer != null) return;

    _timer = Timer.periodic(
      const Duration(seconds: kMockLiveFeedIntervalSec),
      (_) => _tick(),
    );
  }

  static Future<void> _tick() async {
    try {
      final ref = FirebaseDatabase.instance.ref('devices');
      final snap = await ref.get();
      final raw = snap.value;
      if (raw is! Map) return;

      final devices = Map<String, dynamic>.from(raw);
      if (devices.isEmpty) return;

      final updates = <String, dynamic>{};
      final historyWrites = <Future<void>>[];
      final now = DateTime.now().millisecondsSinceEpoch;
      const dtHours = kMockLiveFeedIntervalSec / 3600.0;

      devices.forEach((id, value) {
        if (value is! Map) return;
        final device = Map<String, dynamic>.from(value);

        final relay = (device['relay'] ?? true) == true;
        final status = _random.nextDouble() < 0.06 ? 'offline' : 'online';
        final building = (device['building'] ?? '').toString();

        final baseVoltage = ((device['voltage'] ?? 220.0) as num).toDouble();
        final voltage = _clamp(baseVoltage + _jitter(1.8), 210.0, 235.0);

        final baseCurrent = ((device['current'] ?? 1.0) as num).toDouble();
        final currentTarget = relay ? max(0.2, baseCurrent) : 0.03;
        final current =
            _clamp(currentTarget + _jitter(relay ? 0.18 : 0.02), 0.0, 15.0);

        final basePf = ((device['powerFactor'] ?? 0.95) as num).toDouble();
        final powerFactor = _clamp(basePf + _jitter(0.02), 0.80, 0.99);

        final power = voltage * current * powerFactor;
        final baseKwh = ((device['kwh'] ?? 0.0) as num).toDouble();
        final addKwh = (power / 1000.0) * dtHours;
        final kwh = relay ? (baseKwh + addKwh) : baseKwh;

        updates['$id/voltage'] = _round(voltage, 1);
        updates['$id/current'] = _round(current, 2);
        updates['$id/powerFactor'] = _round(powerFactor, 2);
        updates['$id/power'] = _round(power, 1);
        updates['$id/kwh'] = _round(kwh, 4);
        updates['$id/status'] = status;
        updates['$id/last_seen'] =
            status == 'online' ? now : now - 1000 * 60 * 5;

        // Keep history/monthly totals in sync with mock updates using incremental kWh.
        if (status == 'online' && relay && building.isNotEmpty && addKwh > 0) {
          historyWrites.add(
            HistoryService.writeHistory(
              deviceId: id,
              building: building,
              kwh: addKwh,
            ),
          );
        }
      });

      if (updates.isNotEmpty) {
        await ref.update(updates);
      }
      if (historyWrites.isNotEmpty) {
        await Future.wait(historyWrites);
      }
    } catch (e) {
      final text = e.toString().toLowerCase();
      if (text.contains('permission-denied') ||
          text.contains('permission_denied')) {
        debugPrint(
          'MockLiveFeedService: stopped due to Firebase rules (permission-denied).',
        );
        stop();
        return;
      }
      debugPrint('MockLiveFeedService error: $e');
    }
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static double _jitter(double amount) =>
      (_random.nextDouble() * 2 - 1) * amount;

  static double _clamp(double value, double min, double max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  static double _round(double value, int places) {
    final p = pow(10, places).toDouble();
    return (value * p).roundToDouble() / p;
  }
}
