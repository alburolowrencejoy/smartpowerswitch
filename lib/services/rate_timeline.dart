import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

/// One entry of the `rate_changes/{timestamp}` audit log: from [at] on, the
/// electricity rate was [rate] (₱/kWh). [previous] is the rate it replaced.
@immutable
class RateChange {
  final DateTime at;
  final double rate;
  final double? previous;
  const RateChange(this.at, this.rate, [this.previous]);
}

/// Which electricity rate applied at a given moment.
///
/// History records store the cost at the rate in force when each reading
/// was written (`history_writer.js` / `HistoryService`), so saved costs never
/// change when the rate does. This is the fallback for records that have no
/// stored cost: they are priced at the rate of *their own* date, taken from
/// the `rate_changes` log, never at today's rate -- so a new rate only ever
/// affects usage recorded after it was set.
class RateTimeline {
  /// Changes sorted oldest first.
  final List<RateChange> changes;

  /// `settings/electricityRate` -- used when the log is empty or unreadable.
  final double current;

  RateTimeline(this.current, [List<RateChange> changes = const []])
      : changes = [...changes]..sort((a, b) => a.at.compareTo(b.at));

  /// Parses a `rate_changes` snapshot value (`{ts: {timestamp, newRate,
  /// oldRate}}`). Entries without a usable timestamp or rate are skipped.
  factory RateTimeline.parse(Object? raw, double current) {
    final out = <RateChange>[];
    if (raw is Map) {
      raw.forEach((key, val) {
        if (val is! Map) return;
        final ts = val['timestamp'] ?? int.tryParse(key.toString());
        final rate = val['newRate'];
        if (ts is! num || rate is! num || rate <= 0) return;
        final prev = val['oldRate'];
        out.add(RateChange(
          DateTime.fromMillisecondsSinceEpoch(ts.toInt()),
          rate.toDouble(),
          prev is num && prev > 0 ? prev.toDouble() : null,
        ));
      });
    }
    return RateTimeline(current, out);
  }

  /// The rate in force at [t]: the latest change made on or before [t]. For
  /// dates before the first logged change, the rate that change replaced.
  double rateAt(DateTime t) {
    if (changes.isEmpty) return current;
    RateChange? last;
    for (final c in changes) {
      if (c.at.isAfter(t)) break;
      last = c;
    }
    if (last != null) return last.rate;
    return changes.first.previous ?? changes.first.rate;
  }

  /// The rate for a whole day [day]: the one in force at the end of it, so
  /// a change made during the day already counts for that day.
  double rateForDay(DateTime day) =>
      rateAt(DateTime(day.year, day.month, day.day, 23, 59, 59));
}

/// App-wide live copy of the `rate_changes` log. Read access is limited to
/// admin/faculty roles, so for everyone else (or offline) the log just stays
/// empty and [RateTimeline] falls back to the current rate.
class RateHistory {
  RateHistory._();
  static final instance = RateHistory._();

  final ValueNotifier<Object?> _raw = ValueNotifier<Object?>(null);
  StreamSubscription<DatabaseEvent>? _sub;

  /// Notifies whenever the log changes. Starts listening on first use.
  ValueListenable<Object?> get log {
    _sub ??= FirebaseDatabase.instance.ref('rate_changes').onValue.listen(
          (e) => _raw.value = e.snapshot.value,
          onError: (Object _) => _raw.value = null,
        );
    return _raw;
  }

  RateTimeline timeline(double current) =>
      RateTimeline.parse(log.value, current);
}
