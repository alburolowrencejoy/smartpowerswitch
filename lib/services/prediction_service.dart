import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

class PredictionService {
  PredictionService._privateConstructor();
  static final PredictionService _instance = PredictionService._privateConstructor();
  factory PredictionService() => _instance;

  Timer? _timer;
  Map<String, dynamic>? latestForecast;

  /// Start periodic forecasting. Default runs every 6 hours.
  Future<void> initialize({int hoursInterval = 6}) async {
    // Run once immediately
    await _computeAndPushForecast();

    // Schedule periodic runs
    _timer?.cancel();
    _timer = Timer.periodic(Duration(hours: hoursInterval), (_) async {
      await _computeAndPushForecast();
    });

    // Listen for externally-provided forecasts (e.g., produced by Python training)
    FirebaseDatabase.instance
        .ref('history/predictions/daily')
        .onValue
        .listen((event) {
      if (event.snapshot.value is Map) {
        latestForecast = Map<String, dynamic>.from(event.snapshot.value as Map);
      }
    });
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
  }

  /// Fetch daily history (or raw) and compute a short linear forecast, then
  /// push it to RTDB under `history/predictions/daily` so the app UI and other
  /// consumers can use it. This is a lightweight fallback when a trained
  /// LSTM model is not available in-app.
  Future<void> _computeAndPushForecast({int horizon = 30}) async {
    try {
      final snapshot = await FirebaseDatabase.instance.ref('history/daily').get();
      List<double> values = [];
      List<String> labels = [];

      if (snapshot.value is Map) {
        final map = Map<String, dynamic>.from(snapshot.value as Map);
        final entries = <Map<String, dynamic>>[];
        map.forEach((k, v) {
          if (v is Map) {
            entries.add({'label': k, 'kwh': (v['kwh'] ?? v['total_kwh'])});
          }
        });
        entries.sort((a, b) => a['label'].toString().compareTo(b['label'].toString()));
        for (final e in entries) {
          final k = e['kwh'];
          final v = k is num ? k.toDouble() : double.tryParse(k?.toString() ?? '') ?? 0.0;
          values.add(v);
          labels.add(e['label'].toString());
        }
      }

      // Fallback to raw history grouping if no daily bucket available
      if (values.isEmpty) {
        final rawSnap = await FirebaseDatabase.instance.ref('history/raw').get();
        if (rawSnap.value is Map) {
          final raw = Map<String, dynamic>.from(rawSnap.value as Map);
          final grouped = <String, double>{};
          raw.forEach((k, v) {
            if (v is Map) {
              final ts = v['ts'] ?? v['timestamp'] ?? v['last_update'];
              DateTime? dt;
              if (ts is num) dt = DateTime.fromMillisecondsSinceEpoch(ts.toInt());
              if (ts is String) dt = DateTime.tryParse(ts);
              if (dt != null) {
                final label = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
                final kwh = v['kwh'];
                final val = kwh is num ? kwh.toDouble() : double.tryParse(kwh?.toString() ?? '') ?? 0.0;
                grouped[label] = (grouped[label] ?? 0.0) + val;
              }
            }
          });
          final ordered = grouped.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
          for (final e in ordered) {
            labels.add(e.key);
            values.add(e.value);
          }
        }
      }

      final forecast = _linearForecast(values, horizon);

      final now = DateTime.now();
      final generated = now.millisecondsSinceEpoch;

      final payload = {
        'generated_at': generated,
        'labels': forecast['labels'],
        'values': forecast['values'],
        'predicted_kwh_total': forecast['predicted_kwh_total'],
      };

      await FirebaseDatabase.instance.ref('history/predictions/daily').set(payload);
      latestForecast = payload;
    } catch (e) {
      // ignore errors silently for now
    }
  }

  Map<String, dynamic> _linearForecast(List<double> history, int horizon) {
    if (history.isEmpty) {
      return {
        'labels': List<String>.generate(horizon, (i) => ''),
        'values': List<double>.filled(horizon, 0.0),
        'predicted_kwh_total': 0.0,
      };
    }

    if (history.length == 1) {
      return {
        'labels': List<String>.generate(horizon, (i) => ''),
        'values': List<double>.filled(horizon, history.first),
        'predicted_kwh_total': history.first * horizon,
      };
    }

    final n = history.length.toDouble();
    final meanX = (n - 1) / 2.0;
    final meanY = history.fold<double>(0.0, (s, v) => s + v) / n;
    double numerator = 0.0;
    double denominator = 0.0;
    for (var i = 0; i < history.length; i++) {
      final dx = i - meanX;
      final dy = history[i] - meanY;
      numerator += dx * dy;
      denominator += dx * dx;
    }
    final slope = denominator == 0 ? 0.0 : numerator / denominator;
    final intercept = meanY - slope * meanX;

    final values = <double>[];
    for (var i = 0; i < horizon; i++) {
      final x = history.length + i;
      final v = intercept + slope * x;
      values.add(v < 0 ? 0.0 : v);
    }

    final predictedTotal = values.fold<double>(0.0, (s, v) => s + v);
    final labels = List<String>.generate(horizon, (i) => 'p${i + 1}');
    return {
      'labels': labels,
      'values': values,
      'predicted_kwh_total': predictedTotal,
    };
  }
}
