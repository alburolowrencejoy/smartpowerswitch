import 'package:firebase_database/firebase_database.dart';

/// Reads the forecast comparison that `tools/forecast_comparison.py` (run
/// daily by `.github/workflows/train.yml`) writes to
/// `history/predictions/comparison/{series}`: one entry for the campus total
/// and one per institute code.
///
/// Every model is scored the way the research notebook does it: a
/// chronological 80/20 split of the daily history, then a day-ahead
/// ("rolling") forecast of each test day from the real readings up to the
/// day before. Nothing is computed in the app.
class ForecastComparisons {
  ForecastComparisons._();

  static const path = 'history/predictions/comparison';

  /// Display order.
  static const models = ['arima', 'xgboost', 'gru', 'lstm'];
  static const names = {
    'arima': 'ARIMA',
    'xgboost': 'XGBoost',
    'gru': 'GRU',
    'lstm': 'LSTM',
  };
  static const blurbs = {
    'arima': 'Auto-selected ARIMA(p,d,q)',
    'xgboost': 'Gradient-boosted trees on lags and calendar',
    'gru': 'Gated recurrent neural network',
    'lstm': 'Long short-term memory network',
  };

  /// All series, keyed 'campus' or an institute code.
  static Stream<Map<String, SeriesComparison>> watch() =>
      FirebaseDatabase.instance
          .ref(path)
          .onValue
          .map((e) => parseAll(e.snapshot.value));

  static Map<String, SeriesComparison> parseAll(Object? raw) {
    if (raw is! Map) return const {};
    return {
      for (final e in raw.entries)
        if (SeriesComparison.fromMap(e.key.toString(), e.value) case final s?)
          e.key.toString(): s,
    };
  }

  /// Which series answers the Analytics filter: the campus with no scope,
  /// one institute when exactly that institute is picked, or null when the
  /// filter is narrower (floor, room, device, or only some utilities) and
  /// no comparison exists for it.
  static String? seriesFor({
    required List<String> buildings,
    int floor = 0,
    String room = '',
    String device = '',
    List<String> utilities = const [],
    int allUtilities = 3,
  }) {
    if (utilities.isNotEmpty && utilities.length < allUtilities) return null;
    if (floor != 0 || room.isNotEmpty || device.isNotEmpty) return null;
    if (buildings.isEmpty) return 'campus';
    if (buildings.length == 1) return buildings.first;
    return null;
  }
}

/// One model's day-ahead test result.
class ModelScore {
  final String key;
  final double? mae, mse, rmse, mape, r2;

  /// 1 = lowest RMSE.
  final int? rank;

  /// Predictions for the test days, aligned with [SeriesComparison.labels].
  final List<double?> values;

  /// Forecast for [SeriesComparison.nextDay].
  final double? nextDay;

  /// ARIMA only: the (p, d, q) the search picked.
  final List<int>? order;

  /// Set when the model failed to train.
  final String? unavailable;

  const ModelScore({
    required this.key,
    this.mae,
    this.mse,
    this.rmse,
    this.mape,
    this.r2,
    this.rank,
    this.values = const [],
    this.nextDay,
    this.order,
    this.unavailable,
  });

  String get name => ForecastComparisons.names[key] ?? key;
  bool get ok => unavailable == null && rmse != null;

  factory ModelScore.fromMap(String key, Object? raw) {
    if (raw is! Map) {
      return ModelScore(key: key, unavailable: 'Not trained yet.');
    }
    final order = raw['order'];
    return ModelScore(
      key: key,
      mae: _d(raw['mae']),
      mse: _d(raw['mse']),
      rmse: _d(raw['rmse']),
      mape: _d(raw['mape']),
      r2: _d(raw['r2']),
      rank: _d(raw['rank'])?.toInt(),
      values: _list(raw['values']),
      nextDay: _d(raw['next_day']),
      order:
          order is List ? [for (final v in order) _d(v)?.toInt() ?? 0] : null,
      unavailable: raw['unavailable']?.toString(),
    );
  }
}

/// The comparison for one series (campus or an institute).
class SeriesComparison {
  final String series;
  final DateTime? generatedAt;

  /// Days of history used, and how many of them the cleaning step had to
  /// reconstruct (fewer than 20 hours of readings).
  final int days;
  final int incompleteDays;

  final DateTime? trainStart, trainEnd, testStart, testEnd;
  final int trainDays, testDays;

  /// The test days and what was actually used on them.
  final List<DateTime> labels;
  final List<double?> actual;

  /// The day after the last full day of history: the day-ahead forecast.
  final DateTime? nextDay;

  /// Key of the model with the lowest RMSE.
  final String? best;
  final Map<String, ModelScore> models;

  /// Set when the series has too little history to compare.
  final String? unavailable;

  const SeriesComparison({
    required this.series,
    this.generatedAt,
    this.days = 0,
    this.incompleteDays = 0,
    this.trainStart,
    this.trainEnd,
    this.testStart,
    this.testEnd,
    this.trainDays = 0,
    this.testDays = 0,
    this.labels = const [],
    this.actual = const [],
    this.nextDay,
    this.best,
    this.models = const {},
    this.unavailable,
  });

  ModelScore? get bestModel => best == null ? null : models[best];

  /// Models that trained, lowest RMSE first.
  List<ModelScore> get ranked {
    final out = [
      for (final m in models.values)
        if (m.ok) m
    ];
    out.sort((a, b) => a.rmse!.compareTo(b.rmse!));
    return out;
  }

  static SeriesComparison? fromMap(String series, Object? raw) {
    if (raw is! Map) return null;
    final gen = _d(raw['generated_at']);
    final train = raw['train'] is Map ? raw['train'] as Map : const {};
    final test = raw['test'] is Map ? raw['test'] as Map : const {};
    final actual = raw['actual'] is Map ? raw['actual'] as Map : const {};
    final labels = actual['labels'] is List
        ? [for (final l in actual['labels'] as List) _date(l)]
            .whereType<DateTime>()
            .toList()
        : <DateTime>[];
    final modelsRaw = raw['models'] is Map ? raw['models'] as Map : const {};
    return SeriesComparison(
      series: series,
      generatedAt:
          gen == null ? null : DateTime.fromMillisecondsSinceEpoch(gen.toInt()),
      days: _d(raw['days'])?.toInt() ?? 0,
      incompleteDays: _d(raw['incomplete_days'])?.toInt() ?? 0,
      trainStart: _date(train['start']),
      trainEnd: _date(train['end']),
      trainDays: _d(train['days'])?.toInt() ?? 0,
      testStart: _date(test['start']),
      testEnd: _date(test['end']),
      testDays: _d(test['days'])?.toInt() ?? 0,
      labels: labels,
      actual: _list(actual['values']),
      nextDay: _date(raw['next_day_label']),
      best: raw['best']?.toString(),
      models: {
        for (final k in ForecastComparisons.models)
          if (modelsRaw.containsKey(k)) k: ModelScore.fromMap(k, modelsRaw[k]),
      },
      unavailable: raw['unavailable']?.toString(),
    );
  }
}

double? _d(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

/// RTDB returns a list with holes (null) where a value was missing, or a
/// map keyed by index when the first entries are missing.
List<double?> _list(Object? v) {
  if (v is List) return [for (final x in v) _d(x)];
  if (v is Map) {
    final n = v.keys
            .map((k) => int.tryParse('$k') ?? -1)
            .fold<int>(-1, (a, b) => b > a ? b : a) +
        1;
    return [for (var i = 0; i < n; i++) _d(v['$i'] ?? v[i])];
  }
  return const [];
}

DateTime? _date(Object? v) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch('${v ?? ''}');
  if (m == null) return null;
  return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}
