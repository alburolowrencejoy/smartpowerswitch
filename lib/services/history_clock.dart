import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import 'energy_history.dart';
import 'history_keys.dart';

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

  /// Newest day present under `energy_summaries/daily`, or null if
  /// unknown/none.
  DateTime? _latest;
  Future<void>? _ready;
  StreamSubscription<DatabaseEvent>? _sub;

  /// Oldest day present under `energy_summaries/daily`. History restarted
  /// clean on 2026-10-10 (old demo history archived), so earlier dates have
  /// no data; screens say so instead of showing them as 0 kWh.
  DateTime? _earliest;
  bool _earliestKnown = false;
  StreamSubscription<DatabaseEvent>? _firstSub;

  /// Newest day that has recorded history, if known.
  DateTime? get latestRecorded => _latest;

  /// Oldest day that has recorded history, if known.
  DateTime? get earliestRecorded => _earliest;

  /// True once the oldest day has been looked up; then a null
  /// [earliestRecorded] means nothing has been recorded yet.
  bool get earliestKnown => _earliestKnown;

  /// The real current time as Philippine wall-clock time (a local
  /// [DateTime] whose fields read as the time in the Philippines). History
  /// keys are in Philippine time on the server, so "today" must be too,
  /// whatever time zone the phone or browser is set to.
  static DateTime realNow() {
    final ph = HistoryKeys.phNow();
    return DateTime(ph.year, ph.month, ph.day, ph.hour, ph.minute, ph.second);
  }

  /// "Now" for reading history: the real date/time, or -- when the current
  /// month has no data -- the newest recorded day at the current time of
  /// day.
  DateTime now() {
    final real = realNow();
    final latest = _latest;
    if (!_isFallback(real, latest)) return real;
    return DateTime(latest!.year, latest.month, latest.day, real.hour,
        real.minute, real.second);
  }

  /// True while [now] is showing an older period than the real one.
  bool get isFallback => _isFallback(realNow(), _latest);

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
    // Only the newest key of the daily summaries is downloaded. Kept live so
    // new data flips the clock back to the real date.
    _sub = FirebaseDatabase.instance
        .ref(EnergyHistory.path('daily'))
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
      _firstSub?.cancel();
      _firstSub = null;
      _ready = null;
    });
    // And the oldest key, for the "history starts on" notice.
    _firstSub = FirebaseDatabase.instance
        .ref(EnergyHistory.path('daily'))
        .orderByKey()
        .limitToFirst(1)
        .onValue
        .listen((event) {
      final key = event.snapshot.children.isEmpty
          ? null
          : event.snapshot.children.first.key;
      final parsed = key == null ? null : DateTime.tryParse(key);
      if (parsed != _earliest || !_earliestKnown) {
        _earliest = parsed;
        _earliestKnown = true;
        notifyListeners();
      }
    }, onError: (Object e) {
      debugPrint('[HistoryClock] could not read first history day: $e');
    });
    await first.future.timeout(const Duration(seconds: 8), onTimeout: () {});
  }

  @visibleForTesting
  void debugSetLatest(DateTime? latest) {
    _latest = latest;
    notifyListeners();
  }

  @visibleForTesting
  void debugSetEarliest(DateTime? earliest, {bool known = true}) {
    _earliest = earliest;
    _earliestKnown = known;
    notifyListeners();
  }

  /// Forget the resolved dates (call on sign-out).
  void reset() {
    _sub?.cancel();
    _sub = null;
    _firstSub?.cancel();
    _firstSub = null;
    _ready = null;
    final hadData = _latest != null || _earliest != null || _earliestKnown;
    _latest = null;
    _earliest = null;
    _earliestKnown = false;
    if (hadData) {
      notifyListeners();
    }
  }
}
