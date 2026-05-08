import 'package:firebase_database/firebase_database.dart';

class HistoryService {
  static final _db = FirebaseDatabase.instance.ref();

  /// Call this whenever a device sends new PZEM data.
  /// Writes kwh + cost to all 4 ranges: daily, weekly, monthly, yearly.
  static Future<void> writeHistory({
    required String deviceId,
    required String building,
    required double kwh,
  }) async {
    final rate = await _getRate();
    final cost = kwh * rate;
    final now  = DateTime.now();

    final periods = {
      'daily':   _dailyKey(now),
      'weekly':  _weeklyKey(now),
      'monthly': _monthlyKey(now),
      'yearly':  _yearlyKey(now),
    };

    for (final entry in periods.entries) {
      final range  = entry.key;
      final period = entry.value;
      final base   = 'history/$range/$period';

      if (await _isDeleted(range, period)) {
        continue;
      }

      // Write per-device entry
      await _db.child('$base/devices/$deviceId').update({
        'kwh':      kwh,
        'cost':     cost,
        'building': building,
      });

      // Update period totals using transactions (safe for concurrent writes)
      await _db.child('$base/total_kwh').runTransaction((current) {
        final prev = (current as num?)?.toDouble() ?? 0.0;
        return Transaction.success(double.parse((prev + kwh).toStringAsFixed(6)));
      });

      await _db.child('$base/total_cost').runTransaction((current) {
        final prev = (current as num?)?.toDouble() ?? 0.0;
        return Transaction.success(double.parse((prev + cost).toStringAsFixed(6)));
      });

      // Update per-building totals
      await _db.child('$base/buildings/$building/kwh').runTransaction((current) {
        final prev = (current as num?)?.toDouble() ?? 0.0;
        return Transaction.success(double.parse((prev + kwh).toStringAsFixed(6)));
      });
    }
  }

  /// Fetch the current electricity rate from Firebase settings
  static Future<double> _getRate() async {
    final snap = await _db.child('settings/electricityRate').get();
    return (snap.value as num?)?.toDouble() ?? 11.5;
  }

  static Future<bool> _isDeleted(String range, String period) async {
    final snap = await _db.child('history/deleted/$range/$period').get();
    return snap.value == true;
  }

  /// e.g. "2024-06-01"
  static String _dailyKey(DateTime d) =>
      '${d.year}-${_pad(d.month)}-${_pad(d.day)}';

  /// e.g. "2024-W22"
  static String _weeklyKey(DateTime d) =>
      '${d.year}-W${_pad(_isoWeek(d))}';

  /// e.g. "2024-06"
  static String _monthlyKey(DateTime d) =>
      '${d.year}-${_pad(d.month)}';

  /// e.g. "2024"
  static String _yearlyKey(DateTime d) =>
      '${d.year}';

  static String _pad(int n) => n.toString().padLeft(2, '0');

  /// ISO week number
  static int _isoWeek(DateTime date) {
    final startOfYear   = DateTime(date.year, 1, 1);
    final firstMonday   = startOfYear.weekday;
    final dayOfYear     = date.difference(startOfYear).inDays + 1;
    final weekNumber    = ((dayOfYear + firstMonday - 2) / 7).ceil();
    return weekNumber < 1 ? 1 : weekNumber;
  }
}
