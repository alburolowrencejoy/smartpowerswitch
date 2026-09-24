import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

/// The date the app treats as "now" when *reading* energy history.
///
/// Normally this is the real date. When nothing has been recorded for the
/// current month yet (e.g. the meters haven't reported in a while, so the
/// newest data is from months ago), screens would all ask for an empty
/// month and show zeros. Instead [now] falls back to the newest day that
/// has data, so "this month / this week / today" show the latest recorded
/// period. As soon as data for the current month arrives it goes back to
/// the real date on its own.
///
/// Only use this for choosing which history to *show*. Writes, "online in
/// the last 2 minutes" checks and "x min ago" labels must keep using
/// `DateTime.now()`.
class HistoryClock extends ChangeNotifier {
  HistoryClock._();

  static final HistoryClock instance = HistoryClock._();

  /// Newest day present under `history/daily`, or null if unknown/none.
  DateTime? _latest;
  Future<void>? _ready;
  StreamSubscription<DatabaseEvent>? _sub;

  /// Newest day that has recorded history, if known.
  DateTime? get latestRecorded => _latest;

  /// "Now" for reading history: the real date/time, or -- when the current
  /// month has no data -- the newest recorded day at the current time of
  /// day.
  DateTime now() {
    final real = DateTime.now();
    final latest = _latest;
    if (!_isFallback(real, latest)) return real;
    return DateTime(latest!.year, latest.month, latest.day, real.hour,
        real.minute, real.second);
  }

  /// True while [now] is showing an older period than the real one.
  bool get isFallback => _isFallback(DateTime.now(), _latest);

  static bool _isFallback(DateTime real, DateTime? latest) {
    if (latest == null) return false;
    final sameMonth = latest.year == real.year && latest.month == real.month;
    return !sameMonth && latest.isBefore(real);
  }

  /// Resolves the newest recorded day (once per sign-in). Screens that pick
  /// their history keys at start-up should await this first. Never throws;
  /// on failure [now] simply stays the real date.
  Future<void> ensureReady() => _ready ??= _start();

  Future<void> _start() async {
    final first = Completer<void>();
    // Only the newest key of history/daily is downloaded. Kept live so new
    // data flips the clock back to the real date.
    _sub = FirebaseDatabase.instance
        .ref('history/daily')
        .orderByKey()
        .limitToLast(1)
        .onValue
        .listen((event) {
      final key = event.snapshot.children.isEmpty
          ? null
          : event.snapshot.children.last.key;
      final parsed = key == null ? null : DateTime.tryParse(key);
      if (parsed != _latest) {
        _latest = parsed;
        notifyListeners();
      }
      if (!first.isCompleted) first.complete();
    }, onError: (Object e) {
      debugPrint('[HistoryClock] could not read latest history day: $e');
      if (!first.isCompleted) first.complete();
      // Allow a retry on the next ensureReady() (e.g. after signing in).
      _sub?.cancel();
      _sub = null;
      _ready = null;
    });
    await first.future.timeout(const Duration(seconds: 8), onTimeout: () {});
  }

  @visibleForTesting
  void debugSetLatest(DateTime? latest) {
    _latest = latest;
    notifyListeners();
  }

  /// Forget the resolved date (call on sign-out).
  void reset() {
    _sub?.cancel();
    _sub = null;
    _ready = null;
    if (_latest != null) {
      _latest = null;
      notifyListeners();
    }
  }
}
