import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../../../services/energy_history.dart';
import 'analytics_filter.dart';

/// Keeps `energy_summaries/hourly` subscribed for one range of days, for the
/// trend's Hourly grouping (ranges of at most 7 days, so at most 168 keys).
/// Used by the web Analytics screen and the mobile History screen.
///
/// Call [watch] with the range on every build-relevant change (null when
/// the trend isn't grouped by hour); it only re-subscribes when the dates
/// change. [onChange] runs whenever new data (or an error) arrives.
class HourlyRange {
  HourlyRange(this.onChange);

  final VoidCallback onChange;

  StreamSubscription<DatabaseEvent>? _sub;
  String? _key;

  /// The raw snapshot for the watched range, or null.
  Object? raw;

  /// False while the first snapshot for the watched range is on its way.
  bool loaded = true;

  void watch(DateTimeRange? span) {
    final key =
        span == null ? null : '${dayKey(span.start)}..${dayKey(span.end)}';
    if (key == _key) return;
    _key = key;
    _sub?.cancel();
    _sub = null;
    raw = null;
    loaded = span == null;
    if (span == null) return;
    // Hour keys are "yyyy-MM-dd-HH", so the whole range is one key range.
    _sub = FirebaseDatabase.instance
        .ref(EnergyHistory.path('hourly'))
        .orderByKey()
        .startAt('${dayKey(span.start)}-00')
        .endAt('${dayKey(span.end)}-23')
        .onValue
        .listen((e) {
      raw = e.snapshot.value;
      loaded = true;
      onChange();
    }, onError: (_) {
      loaded = true;
      onChange();
    });
  }

  void dispose() => _sub?.cancel();
}
