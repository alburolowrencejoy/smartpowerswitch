import 'package:flutter/material.dart';

import '../../../services/rate_timeline.dart';
import 'analytics_filter.dart';
import '../../../utils/last_seen.dart';

/// Live facts about one device from the `devices` node.
@immutable
class DeviceMeta {
  final String id;
  final String building;
  final int floor;
  final String room;
  final String utility;
  final bool online;
  final bool relay;

  const DeviceMeta({
    required this.id,
    required this.building,
    required this.floor,
    required this.room,
    required this.utility,
    required this.online,
    required this.relay,
  });

  static Map<String, DeviceMeta> parseAll(Object? raw) {
    final out = <String, DeviceMeta>{};
    if (raw is! Map) return out;
    raw.forEach((id, val) {
      if (val is! Map) return;
      final online = isDeviceOnline(val);
      out[id.toString()] = DeviceMeta(
        id: id.toString(),
        building: (val['building'] ?? '').toString(),
        floor: int.tryParse('${val['floor'] ?? 1}') ?? 1,
        room: (val['room'] ?? '').toString().trim(),
        utility: (val['utility'] ?? 'Unknown').toString(),
        online: online,
        relay: val['relay'] == true,
      );
    });
    return out;
  }
}

/// One device's total for one day, joined with its metadata. [deviceId] is
/// empty for legacy days that only stored building or campus totals.
@immutable
class UsageRow {
  final DateTime date;
  final String deviceId;
  final String building;
  final String utility;
  final int floor;
  final String room;
  final double kwh;

  /// Cost in ₱ at the rate in force on [date] -- the cost stored with the
  /// reading when there is one, so later rate changes never reprice it.
  final double cost;

  /// 0-23 for a row of `energy_summaries/hourly` ([date] is then still the
  /// day, so the day filters apply unchanged); null for a daily row.
  final int? hour;

  const UsageRow({
    required this.date,
    required this.deviceId,
    required this.building,
    required this.utility,
    required this.floor,
    required this.room,
    required this.kwh,
    required this.cost,
    this.hour,
  });

  /// Rooms are only unique within a building + floor.
  String get roomKey => '$building|$floor|$room';
}

double _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

final _dayKeyPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _hourKeyPattern = RegExp(r'^(\d{4}-\d{2}-\d{2})-(\d{2})$');

/// Flattens an `energy_summaries/hourly` snapshot (`{yyyy-MM-dd-HH: {devices:
/// {id: {kwh, cost, building}}, buildings: {...}, campus: {...}}}`) into
/// per-device rows with [UsageRow.hour] set. Hours without per-device
/// entries fall back to per-building totals, then to the campus total.
List<UsageRow> parseHourly(
  Object? raw,
  Map<String, DeviceMeta> meta, {
  required RateTimeline rates,
}) {
  final rows = <UsageRow>[];
  if (raw is! Map) return rows;
  raw.forEach((key, val) {
    final m = _hourKeyPattern.firstMatch(key.toString());
    if (m == null || val is! Map) return;
    final date = DateTime.tryParse(m[1]!);
    final hour = int.parse(m[2]!);
    if (date == null || hour > 23) return;
    UsageRow row(String id, String building, DeviceMeta? d, Map v) {
      final kwh = _num(v['kwh']);
      return UsageRow(
        date: date,
        deviceId: id,
        building: building,
        utility: d?.utility ?? 'Unknown',
        floor: d?.floor ?? 0,
        room: d?.room ?? '',
        kwh: kwh,
        cost: rates.costOf(v['cost'], kwh, date),
        hour: hour,
      );
    }

    final devices = val['devices'];
    if (devices is Map && devices.isNotEmpty) {
      devices.forEach((id, v) {
        if (v is! Map) return;
        final d = meta[id.toString()];
        final b = (v['building'] ?? '').toString();
        rows.add(row(id.toString(), b.isNotEmpty ? b : (d?.building ?? ''), d, v));
      });
      return;
    }
    final buildings = val['buildings'];
    if (buildings is Map && buildings.isNotEmpty) {
      buildings.forEach((code, v) {
        if (v is Map) rows.add(row('', code.toString(), null, v));
      });
      return;
    }
    if (val['campus'] case final Map v) rows.add(row('', '', null, v));
  });
  return rows;
}

/// Flattens a daily snapshot in the legacy `history/daily` shape (see
/// `EnergyHistory.legacyRange`: `{yyyy-MM-dd: {devices: {id: {kwh, cost,
/// building}}, buildings: {...}, total_kwh}}`) into per-device rows.
/// Days without per-device entries fall back to per-building totals, then
/// to the day total.
List<UsageRow> parseDaily(
  Object? raw,
  Map<String, DeviceMeta> meta, {
  required RateTimeline rates,
  DateTime? until,
}) {
  final rows = <UsageRow>[];
  // Stored cost when the record has one; otherwise kWh at that day's rate.
  double costOf(Object? stored, double kwh, DateTime date) =>
      rates.costOf(stored, kwh, date);
  if (raw is! Map) return rows;
  raw.forEach((key, val) {
    final k = key.toString();
    if (!_dayKeyPattern.hasMatch(k) || val is! Map) {
      return;
    }
    final date = DateTime.tryParse(k);
    if (date == null || (until != null && date.isAfter(until))) return;

    final devices = val['devices'];
    if (devices is Map && devices.isNotEmpty) {
      devices.forEach((id, d) {
        if (d is! Map) return;
        final m = meta[id.toString()];
        final kwh = _num(d['kwh'] ?? d['total_kwh']);
        final histBuilding = (d['building'] ?? '').toString();
        rows.add(UsageRow(
          date: date,
          deviceId: id.toString(),
          building: histBuilding.isNotEmpty ? histBuilding : (m?.building ?? ''),
          utility: m?.utility ?? 'Unknown',
          floor: m?.floor ?? 0,
          room: m?.room ?? '',
          kwh: kwh,
          cost: costOf(d['cost'] ?? d['total_cost'], kwh, date),
        ));
      });
      return;
    }
    final buildings = val['buildings'];
    if (buildings is Map && buildings.isNotEmpty) {
      buildings.forEach((code, b) {
        if (b is! Map) return;
        final kwh = _num(b['kwh']);
        rows.add(UsageRow(
          date: date,
          deviceId: '',
          building: code.toString(),
          utility: 'Unknown',
          floor: 0,
          room: '',
          kwh: kwh,
          cost: costOf(b['cost'], kwh, date),
        ));
      });
      return;
    }
    final total = _num(val['total_kwh'] ?? val['kwh']);
    if (total > 0) {
      rows.add(UsageRow(
        date: date,
        deviceId: '',
        building: '',
        utility: 'Unknown',
        floor: 0,
        room: '',
        kwh: total,
        cost: costOf(val['total_cost'], total, date),
      ));
    }
  });
  return rows;
}

/// Rows inside [f]'s scope + utility filters (not its dates or day type).
bool inScope(AnalyticsFilter f, UsageRow r) {
  if (f.buildings.isNotEmpty && !f.buildings.contains(r.building)) {
    return false;
  }
  // Floor / room / device / utility need per-device rows.
  final needsDevice = f.floor > 0 ||
      f.room.isNotEmpty ||
      f.device.isNotEmpty ||
      f.utilities.isNotEmpty;
  if (needsDevice && r.deviceId.isEmpty) return false;
  if (f.floor > 0 && r.floor != f.floor) return false;
  if (f.room.isNotEmpty && r.room != f.room) return false;
  if (f.device.isNotEmpty && r.deviceId != f.device) return false;
  if (f.utilities.isNotEmpty && !f.utilities.contains(r.utility)) return false;
  return true;
}

/// Rows matching every filter of [f] for the dates in [span].
List<UsageRow> applyFilter(
    AnalyticsFilter f, List<UsageRow> rows, DateTimeRange span) {
  return [
    for (final r in rows)
      if (!r.date.isBefore(span.start) &&
          !r.date.isAfter(span.end) &&
          f.dayAllowed(r.date) &&
          inScope(f, r))
        r
  ];
}

double sumKwh(Iterable<UsageRow> rows) =>
    rows.fold<double>(0, (a, r) => a + r.kwh);

double sumCost(Iterable<UsageRow> rows) =>
    rows.fold<double>(0, (a, r) => a + r.cost);

/// Sums [rows] by [key], largest first -- kWh, or ₱ when [cost] is set.
List<MapEntry<String, double>> groupSum(
    Iterable<UsageRow> rows, String Function(UsageRow) key,
    {bool cost = false}) {
  final m = <String, double>{};
  for (final r in rows) {
    final k = key(r);
    m[k] = (m[k] ?? 0) + (cost ? r.cost : r.kwh);
  }
  return m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
}

/// One bucket of the trend chart.
@immutable
class Bucket {
  final DateTime start;
  final String label;
  final String tooltipLabel;
  final double kwh;
  final double cost;
  const Bucket(this.start, this.label, this.tooltipLabel, this.kwh, this.cost);
}

/// Buckets every allowed day of [span] by [group]; empty days count as 0 so
/// the axis stays evenly spaced.
List<Bucket> bucketize(AnalyticsFilter f, List<UsageRow> rows,
    DateTimeRange span, GroupBy group) {
  if (group == GroupBy.hourly) return _bucketizeHourly(f, rows, span);
  final byDay = <DateTime, double>{};
  final costByDay = <DateTime, double>{};
  for (final r in rows) {
    byDay[r.date] = (byDay[r.date] ?? 0) + r.kwh;
    costByDay[r.date] = (costByDay[r.date] ?? 0) + r.cost;
  }
  final out = <Bucket>[];
  final buckets = <DateTime, double>{};
  final costs = <DateTime, double>{};
  final order = <DateTime>[];
  for (var d = span.start;
      !d.isAfter(span.end);
      d = DateTime(d.year, d.month, d.day + 1)) {
    if (!f.dayAllowed(d)) continue;
    final DateTime b;
    switch (group) {
      case GroupBy.weekly:
        b = DateTime(d.year, d.month, d.day - (d.weekday - 1));
      case GroupBy.monthly:
        b = DateTime(d.year, d.month, 1);
      case GroupBy.hourly:
      case GroupBy.daily:
        b = d;
    }
    if (!buckets.containsKey(b)) order.add(b);
    buckets[b] = (buckets[b] ?? 0) + (byDay[d] ?? 0);
    costs[b] = (costs[b] ?? 0) + (costByDay[d] ?? 0);
  }
  for (final b in order) {
    final v = buckets[b]!;
    final c = costs[b]!;
    switch (group) {
      case GroupBy.weekly:
        out.add(Bucket(b, fmtDate(b), 'Week of ${fmtDate(b)}', v, c));
      case GroupBy.monthly:
        out.add(Bucket(b, kMonths[b.month - 1],
            '${kMonths[b.month - 1]} ${b.year}', v, c));
      case GroupBy.hourly:
      case GroupBy.daily:
        out.add(Bucket(b, fmtDate(b),
            '${fmtDate(b)} · ${kWeekdays[b.weekday - 1]}', v, c));
    }
  }
  return out;
}

/// One bucket per hour of every allowed day of [span], from hourly rows
/// ([UsageRow.hour] set; daily rows are ignored). Hours with no reading
/// count as 0, like empty days.
List<Bucket> _bucketizeHourly(
    AnalyticsFilter f, List<UsageRow> rows, DateTimeRange span) {
  final kwh = <DateTime, double>{};
  final cost = <DateTime, double>{};
  for (final r in rows) {
    final h = r.hour;
    if (h == null) continue;
    final t = DateTime(r.date.year, r.date.month, r.date.day, h);
    kwh[t] = (kwh[t] ?? 0) + r.kwh;
    cost[t] = (cost[t] ?? 0) + r.cost;
  }
  final oneDay = span.start == span.end;
  final out = <Bucket>[];
  for (var d = span.start;
      !d.isAfter(span.end);
      d = DateTime(d.year, d.month, d.day + 1)) {
    if (!f.dayAllowed(d)) continue;
    for (var h = 0; h < 24; h++) {
      final t = DateTime(d.year, d.month, d.day, h);
      final hh = '${h.toString().padLeft(2, '0')}:00';
      out.add(Bucket(
        t,
        oneDay ? hh : '${fmtDate(d)} $hh',
        '${fmtDate(d)} · ${kWeekdays[d.weekday - 1]} · '
            '$hh–${((h + 1) % 24).toString().padLeft(2, '0')}:00',
        kwh[t] ?? 0,
        cost[t] ?? 0,
      ));
    }
  }
  return out;
}
