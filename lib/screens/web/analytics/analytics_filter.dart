import 'package:flutter/material.dart';
import '../../../services/history_clock.dart';

/// Time-range presets of the Analytics filter bar.
enum RangePreset {
  today('Today'),
  last7('Last 7 days'),
  last30('Last 30 days'),
  last90('Last 90 days'),
  thisMonth('This month'),
  lastMonth('Last month'),
  thisYear('This year'),
  custom('Custom range');

  final String label;
  const RangePreset(this.label);
}

enum GroupBy {
  hourly('Hourly'),
  daily('Daily'),
  weekly('Weekly'),
  monthly('Monthly');

  final String label;
  const GroupBy(this.label);
}

enum DayType {
  all('All days'),
  weekday('Weekdays'),
  weekend('Weekends');

  final String label;
  const DayType(this.label);
}

enum TimeOfDayFilter {
  all('All day'),
  classHours('Class hours'),
  afterHours('After hours');

  final String label;
  const TimeOfDayFilter(this.label);
}

enum CompareMode {
  off('Off'),
  previous('Previous period'),
  lastYear('Last year');

  final String label;
  const CompareMode(this.label);
}

enum ValueMetric {
  kwh('kWh'),
  cost('Cost (₱)');

  final String label;
  const ValueMetric(this.label);
}

/// The utilities a device can control.
const kUtilities = ['Lights', 'Outlets', 'AC'];

/// Buildings always offered in the Scope panel, even before any device in
/// them reports (codes from the `buildings` node are appended after these).
const kDefaultBuildings = ['IC', 'ILEGG', 'ITED', 'IAAS', 'ADMIN'];

/// Hourly grouping and the time-of-day filter need hourly readings, but
/// `history/daily` only stores per-device daily totals.
// TODO(analytics): enable Hourly grouping and the Time-of-day filter once an
// hourly history node exists (e.g. history/hourly/{yyyy-MM-ddTHH}/devices).
const bool kHasHourlyData = false;

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String _pad(int n) => n.toString().padLeft(2, '0');

/// `yyyy-MM-dd`, the key format of `history/daily`.
String dayKey(DateTime d) => '${d.year}-${_pad(d.month)}-${_pad(d.day)}';

const kMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];
const kWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String fmtDate(DateTime d, {bool year = false}) =>
    '${kMonths[d.month - 1]} ${d.day}${year ? ', ${d.year}' : ''}';

String spanText(DateTimeRange r) {
  if (r.start == r.end) return fmtDate(r.start, year: true);
  if (r.start.year == r.end.year) {
    return '${fmtDate(r.start)} – ${fmtDate(r.end, year: true)}';
  }
  return '${fmtDate(r.start, year: true)} – ${fmtDate(r.end, year: true)}';
}

int spanDays(DateTimeRange r) => r.end.difference(r.start).inDays + 1;

bool isWeekend(DateTime d) =>
    d.weekday == DateTime.saturday || d.weekday == DateTime.sunday;

/// Dates of a preset, both ends inclusive, relative to [today].
DateTimeRange presetSpan(RangePreset p, DateTime today,
    {DateTime? from, DateTime? to}) {
  final t = dateOnly(today);
  DateTimeRange r(DateTime a, DateTime b) => DateTimeRange(start: a, end: b);
  switch (p) {
    case RangePreset.today:
      return r(t, t);
    case RangePreset.last7:
      return r(DateTime(t.year, t.month, t.day - 6), t);
    case RangePreset.last90:
      return r(DateTime(t.year, t.month, t.day - 89), t);
    case RangePreset.thisMonth:
      return r(DateTime(t.year, t.month, 1), t);
    case RangePreset.lastMonth:
      return r(DateTime(t.year, t.month - 1, 1), DateTime(t.year, t.month, 0));
    case RangePreset.thisYear:
      return r(DateTime(t.year, 1, 1), t);
    case RangePreset.custom:
      if (from != null) return r(dateOnly(from), dateOnly(to ?? from));
      return r(DateTime(t.year, t.month, t.day - 29), t);
    case RangePreset.last30:
      return r(DateTime(t.year, t.month, t.day - 29), t);
  }
}

/// Grouping suggested for a range of [days] days.
GroupBy suggestedGroup(int days) {
  if (days <= 2 && kHasHourlyData) return GroupBy.hourly;
  if (days <= 62) return GroupBy.daily;
  if (days <= 180) return GroupBy.weekly;
  return GroupBy.monthly;
}

/// Whether [g] makes sense for a range of [days] days.
bool groupAllowed(GroupBy g, int days) {
  switch (g) {
    case GroupBy.hourly:
      return kHasHourlyData && days <= 7;
    case GroupBy.daily:
      return days <= 366;
    case GroupBy.weekly:
      return days >= 14;
    case GroupBy.monthly:
      return days >= 60;
  }
}

/// Why [g] is greyed out.
String groupDisabledReason(GroupBy g) {
  switch (g) {
    case GroupBy.hourly:
      return kHasHourlyData
          ? 'Only for ranges up to 7 days'
          : 'Needs hourly readings (daily totals only for now)';
    case GroupBy.daily:
      return 'Only for ranges up to 1 year';
    case GroupBy.weekly:
      return 'Only for ranges of 14 days or more';
    case GroupBy.monthly:
      return 'Only for ranges of 60 days or more';
  }
}

/// Every Analytics filter, as one immutable value.
@immutable
class AnalyticsFilter {
  final RangePreset range;

  /// Only used when [range] is [RangePreset.custom].
  final DateTime? from;
  final DateTime? to;
  final GroupBy group;

  /// Empty = all buildings.
  final List<String> buildings;

  /// 0 = all floors. Only meaningful with exactly one building.
  final int floor;

  /// '' = all rooms.
  final String room;

  /// '' = all devices.
  final String device;

  /// Empty = all utilities.
  final List<String> utilities;
  final DayType dayType;
  final TimeOfDayFilter timeOfDay;
  final CompareMode compare;
  final ValueMetric metric;

  const AnalyticsFilter({
    this.range = RangePreset.last30,
    this.from,
    this.to,
    this.group = GroupBy.daily,
    this.buildings = const [],
    this.floor = 0,
    this.room = '',
    this.device = '',
    this.utilities = const [],
    this.dayType = DayType.all,
    this.timeOfDay = TimeOfDayFilter.all,
    this.compare = CompareMode.off,
    this.metric = ValueMetric.kwh,
  });

  static const defaults = AnalyticsFilter();

  AnalyticsFilter copyWith({
    RangePreset? range,
    DateTime? from,
    DateTime? to,
    bool clearCustomDates = false,
    GroupBy? group,
    List<String>? buildings,
    int? floor,
    String? room,
    String? device,
    List<String>? utilities,
    DayType? dayType,
    TimeOfDayFilter? timeOfDay,
    CompareMode? compare,
    ValueMetric? metric,
  }) {
    return AnalyticsFilter(
      range: range ?? this.range,
      from: clearCustomDates ? null : (from ?? this.from),
      to: clearCustomDates ? null : (to ?? this.to),
      group: group ?? this.group,
      buildings: List.unmodifiable(buildings ?? this.buildings),
      floor: floor ?? this.floor,
      room: room ?? this.room,
      device: device ?? this.device,
      utilities: List.unmodifiable(utilities ?? this.utilities),
      dayType: dayType ?? this.dayType,
      timeOfDay: timeOfDay ?? this.timeOfDay,
      compare: compare ?? this.compare,
      metric: metric ?? this.metric,
    );
  }

  DateTimeRange span([DateTime? today]) =>
      presetSpan(range, today ?? HistoryClock.instance.now(), from: from, to: to);

  int get days => spanDays(span());

  /// The earlier period that [compare] measures against, or null when off.
  DateTimeRange? compareSpan([DateTime? today]) {
    final s = span(today);
    switch (compare) {
      case CompareMode.off:
        return null;
      case CompareMode.previous:
        final n = spanDays(s);
        return DateTimeRange(
          start: DateTime(s.start.year, s.start.month, s.start.day - n),
          end: DateTime(s.start.year, s.start.month, s.start.day - 1),
        );
      case CompareMode.lastYear:
        return DateTimeRange(
          start: DateTime(s.start.year - 1, s.start.month, s.start.day),
          end: DateTime(s.end.year - 1, s.end.month, s.end.day),
        );
    }
  }

  /// Keeps [group] valid for the current range.
  AnalyticsFilter withValidGroup() {
    final n = days;
    return groupAllowed(group, n) ? this : copyWith(group: suggestedGroup(n));
  }

  /// A new range, with the grouping it suggests.
  AnalyticsFilter withRange(RangePreset p, {DateTime? from, DateTime? to}) {
    final next = p == RangePreset.custom
        ? copyWith(range: p, from: from, to: to ?? from)
        : copyWith(range: p, clearCustomDates: true);
    return next.copyWith(group: suggestedGroup(next.days));
  }

  AnalyticsFilter clearedScope() =>
      copyWith(buildings: const [], floor: 0, room: '', device: '');

  bool get hasScope => buildings.isNotEmpty;
  bool get hasUtility => utilities.isNotEmpty;
  bool get isDefaultGroup => group == suggestedGroup(days);

  int get moreCount => [
        dayType != DayType.all,
        timeOfDay != TimeOfDayFilter.all,
        compare != CompareMode.off,
        metric != ValueMetric.kwh,
      ].where((x) => x).length;

  bool get isDefault =>
      range == RangePreset.last30 &&
      isDefaultGroup &&
      !hasScope &&
      !hasUtility &&
      moreCount == 0;

  String get rangeName =>
      range == RangePreset.custom ? spanText(span()) : range.label;

  String get scopeName {
    if (buildings.isEmpty) return 'All buildings';
    if (buildings.length > 1) return buildings.join(', ');
    var s = buildings.first;
    if (floor > 0) s += ' · Floor $floor';
    if (room.isNotEmpty) s += ' · $room';
    if (device.isNotEmpty) s += ' · $device';
    return s;
  }

  String get utilityName =>
      utilities.isEmpty ? 'All utilities' : utilities.join(', ');

  bool dayAllowed(DateTime d) => switch (dayType) {
        DayType.all => true,
        DayType.weekday => !isWeekend(d),
        DayType.weekend => isWeekend(d),
      };

  @override
  bool operator ==(Object other) =>
      other is AnalyticsFilter &&
      other.range == range &&
      other.from == from &&
      other.to == to &&
      other.group == group &&
      _listEq(other.buildings, buildings) &&
      other.floor == floor &&
      other.room == room &&
      other.device == device &&
      _listEq(other.utilities, utilities) &&
      other.dayType == dayType &&
      other.timeOfDay == timeOfDay &&
      other.compare == compare &&
      other.metric == metric;

  @override
  int get hashCode => Object.hash(
        range,
        from,
        to,
        group,
        Object.hashAll(buildings),
        floor,
        room,
        device,
        Object.hashAll(utilities),
        dayType,
        timeOfDay,
        compare,
        metric,
      );
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
