/// Energy-history period keys, always in Philippine time (UTC+8, no
/// daylight saving), whatever time zone the phone or browser is in.
///
/// This is the Dart twin of `functions/energy_math.js` (`periodKeys`,
/// `isoWeekKey`): the server writes `energy_summaries/{range}/{key}` with
/// those keys, so screens must build exactly the same ones. The test cases
/// in `test/history_keys_test.dart` mirror `functions/energy_math.test.js`;
/// keep them in sync.
class PeriodKeys {
  final String hourly;
  final String daily;
  final String weekly;
  final String monthly;
  final String yearly;

  const PeriodKeys({
    required this.hourly,
    required this.daily,
    required this.weekly,
    required this.monthly,
    required this.yearly,
  });

  /// The key for a range name used in the database path
  /// (`hourly`, `daily`, `weekly`, `monthly`, `yearly`).
  String operator [](String range) => switch (range) {
        'hourly' => hourly,
        'daily' => daily,
        'weekly' => weekly,
        'monthly' => monthly,
        'yearly' => yearly,
        _ => throw ArgumentError.value(range, 'range'),
      };

  @override
  String toString() =>
      'PeriodKeys($hourly, $daily, $weekly, $monthly, $yearly)';
}

class HistoryKeys {
  HistoryKeys._();

  static const Duration phOffset = Duration(hours: 8);

  /// [instant] as Philippine wall-clock time. The result is a UTC
  /// [DateTime] whose year/month/day/hour fields read as the time in the
  /// Philippines; use it only for its fields, not as an instant.
  static DateTime phWallClock(DateTime instant) =>
      instant.toUtc().add(phOffset);

  /// Current Philippine wall-clock time (see [phWallClock]).
  static DateTime phNow() => phWallClock(DateTime.now());

  /// Every history key that [instant] falls into.
  static PeriodKeys of(DateTime instant) {
    final ph = phWallClock(instant);
    final daily = dailyKey(ph.year, ph.month, ph.day);
    return PeriodKeys(
      hourly: '$daily-${_pad(ph.hour)}',
      daily: daily,
      weekly: isoWeekKey(ph.year, ph.month, ph.day),
      monthly: '${ph.year}-${_pad(ph.month)}',
      yearly: '${ph.year}',
    );
  }

  /// Keys for right now.
  static PeriodKeys now() => of(DateTime.now());

  /// "YYYY-MM-DD" for a calendar date.
  static String dailyKey(int year, int month, int day) =>
      '$year-${_pad(month)}-${_pad(day)}';

  /// ISO 8601 week key (Monday start, ISO week-year), e.g. "2026-W53".
  static String isoWeekKey(int year, int month, int day) {
    final date = DateTime.utc(year, month, day);
    final weekdayFromMonday = date.weekday - DateTime.monday; // Monday = 0
    // The ISO week belongs to the year that contains its Thursday.
    final thursday = date.add(Duration(days: 3 - weekdayFromMonday));
    final ordinal =
        thursday.difference(DateTime.utc(thursday.year, 1, 1)).inDays + 1;
    return '${thursday.year}-W${_pad((ordinal - 1) ~/ 7 + 1)}';
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');
}
