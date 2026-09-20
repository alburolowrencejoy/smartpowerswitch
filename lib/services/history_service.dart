import 'dart:async';
import 'package:firebase_database/firebase_database.dart';

class HistoryService {
  static final _db = FirebaseDatabase.instance.ref();

  static double? _cachedRate;
  static StreamSubscription<DatabaseEvent>? _rateSub;

  /// Call this whenever a device sends new PZEM data.
  /// Writes kwh + cost to all 4 ranges: daily, weekly, monthly, yearly.
  static Future<void> writeHistory({
    required String deviceId,
    required String building,
    required double kwh,
  }) async {
    final rate = await _getRate();
    final cost = kwh * rate;
    final now = DateTime.now();

    final periods = {
      'daily': _dailyKey(now),
      'weekly': _weeklyKey(now),
      'monthly': _monthlyKey(now),
      'yearly': _yearlyKey(now),
    };

    // The 4 ranges are independent of each other, and within a range the
    // per-device entry, the two period totals, and the two per-building
    // totals are independent writes too -- run everything concurrently
    // instead of awaiting ~25 round-trips one at a time.
    await Future.wait(periods.entries.map((entry) => _writePeriod(
          range: entry.key,
          period: entry.value,
          deviceId: deviceId,
          building: building,
          kwh: kwh,
          cost: cost,
        )));
  }

  static Future<void> _writePeriod({
    required String range,
    required String period,
    required String deviceId,
    required String building,
    required double kwh,
    required double cost,
  }) async {
    final base = 'history/$range/$period';

    if (await _isDeleted(range, period)) {
      return;
    }

    await Future.wait([
      // Write per-device entry
      _db.child('$base/devices/$deviceId').update({
        'kwh': kwh,
        'cost': cost,
        'building': building,
      }),

      // Update period totals using transactions (safe for concurrent writes)
      _db.child('$base/total_kwh').runTransaction((current) {
        final prev = (current as num?)?.toDouble() ?? 0.0;
        return Transaction.success(
            double.parse((prev + kwh).toStringAsFixed(6)));
      }),

      _db.child('$base/total_cost').runTransaction((current) {
        final prev = (current as num?)?.toDouble() ?? 0.0;
        return Transaction.success(
            double.parse((prev + cost).toStringAsFixed(6)));
      }),

      // Update per-building totals
      _db.child('$base/buildings/$building/kwh').runTransaction((current) {
        final prev = (current as num?)?.toDouble() ?? 0.0;
        return Transaction.success(
            double.parse((prev + kwh).toStringAsFixed(6)));
      }),

      _db.child('$base/buildings/$building/cost').runTransaction((current) {
        final prev = (current as num?)?.toDouble() ?? 0.0;
        return Transaction.success(
            double.parse((prev + cost).toStringAsFixed(6)));
      }),
    ]);
  }

  /// Current electricity rate, kept warm by a persistent listener so most
  /// calls avoid a network round-trip entirely. Falls back to a one-shot
  /// read the very first time, before the listener has delivered a value.
  static Future<double> _getRate() async {
    _rateSub ??= _db.child('settings/electricityRate').onValue.listen((event) {
      final v = (event.snapshot.value as num?)?.toDouble();
      if (v != null) _cachedRate = v;
    });

    final cached = _cachedRate;
    if (cached != null) return cached;

    final snap = await _db.child('settings/electricityRate').get();
    final v = (snap.value as num?)?.toDouble() ?? 11.5;
    _cachedRate = v;
    return v;
  }

  static Future<bool> _isDeleted(String range, String period) async {
    final snap = await _db.child('history/deleted/$range/$period').get();
    return snap.value == true;
  }

  /// e.g. "2024-06-01"
  static String _dailyKey(DateTime d) =>
      '${d.year}-${_pad(d.month)}-${_pad(d.day)}';

  /// e.g. "2024-W22"
  static String _weeklyKey(DateTime d) => '${d.year}-W${_pad(_isoWeek(d))}';

  /// e.g. "2024-06"
  static String _monthlyKey(DateTime d) => '${d.year}-${_pad(d.month)}';

  /// e.g. "2024"
  static String _yearlyKey(DateTime d) => '${d.year}';

  static String _pad(int n) => n.toString().padLeft(2, '0');

  /// ISO week number
  static int _isoWeek(DateTime date) {
    final startOfYear = DateTime(date.year, 1, 1);
    final firstMonday = startOfYear.weekday;
    final dayOfYear = date.difference(startOfYear).inDays + 1;
    final weekNumber = ((dayOfYear + firstMonday - 2) / 7).ceil();
    return weekNumber < 1 ? 1 : weekNumber;
  }
}
