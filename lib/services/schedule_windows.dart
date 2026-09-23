/// Time windows for automation schedules.
///
/// A schedule may carry several "ON from [on] until [until]" windows under
/// `automations/{id}/windows` (a list of `{on: 'HH:mm', until: 'HH:mm'}`).
/// Devices turn ON at [on] and OFF one minute after [until], so a window
/// "08:00 to 11:59" is ON for the whole of 11:59 and OFF at 12:00. A window
/// whose [until] is earlier than [on] runs overnight into the next day.
///
/// Schedules without `windows` keep the original single `onTime`/`offTime`
/// pair. Writers that save `windows` also save the first window as
/// `onTime`/`offTime` (with `offTime` = until + 1 minute) so older app
/// versions and the mobile screen keep showing and running that window.
library;

const int _day = 24 * 60;

int? parseHm(String value) {
  final parts = value.trim().split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
    return null;
  }
  return h * 60 + m;
}

String formatHm(int minutes) {
  final m = ((minutes % _day) + _day) % _day;
  return '${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}

class ScheduleWindow {
  /// Minutes after midnight the devices turn ON.
  final int on;

  /// Last minute (after midnight) the devices stay ON.
  final int until;

  const ScheduleWindow(this.on, this.until);

  static ScheduleWindow? parse(String on, String until) {
    final a = parseHm(on);
    final b = parseHm(until);
    if (a == null || b == null) return null;
    return ScheduleWindow(a, b);
  }

  /// Parses `windows` from a schedule map; empty when absent or invalid.
  static List<ScheduleWindow> listFrom(Object? raw) {
    final items = raw is List
        ? raw
        : raw is Map
            ? (raw.entries.toList()
                  ..sort((a, b) => a.key.toString().compareTo(b.key.toString())))
                .map((e) => e.value)
                .toList()
            : const [];
    final out = <ScheduleWindow>[];
    for (final item in items) {
      if (item is! Map) continue;
      final w = parse('${item['on'] ?? ''}', '${item['until'] ?? ''}');
      if (w != null) out.add(w);
    }
    return out;
  }

  /// Runs past midnight into the next day.
  bool get overnight => until < on;

  /// Minute of day the devices turn OFF (one minute after [until]).
  int get offMinute => (until + 1) % _day;

  /// Days after the start day that the OFF happens: 1 for overnight
  /// windows and for windows ending at 23:59, otherwise 0.
  int get offDayOffset => (until + 1 >= _day || overnight) ? 1 : 0;

  /// Length in minutes the devices stay ON.
  int get duration => (overnight ? until + _day : until) - on + 1;

  String get onLabel => formatHm(on);
  String get untilLabel => formatHm(until);
  String get offLabel => formatHm(offMinute);

  Map<String, String> toMap() => {'on': onLabel, 'until': untilLabel};

  /// [start, end) in minutes, where end may exceed one day.
  (int, int) get _span => (on, on + duration);

  bool overlaps(ScheduleWindow other) {
    final (a0, a1) = _span;
    for (final shift in const [-_day, 0, _day]) {
      final (b0, b1) = other._span;
      if (a0 < b1 + shift && b0 + shift < a1) return true;
    }
    return false;
  }

  @override
  bool operator ==(Object other) =>
      other is ScheduleWindow && other.on == on && other.until == until;

  @override
  int get hashCode => Object.hash(on, until);
}

/// Validates a set of windows. Returns a message per invalid window index
/// (key -1 for a problem with the set as a whole), empty when valid.
Map<int, String> validateWindows(List<ScheduleWindow?> windows) {
  final errors = <int, String>{};
  if (windows.isEmpty) {
    errors[-1] = 'Add at least one time window.';
    return errors;
  }
  for (var i = 0; i < windows.length; i++) {
    final w = windows[i];
    if (w == null) {
      errors[i] = 'Pick both times.';
    } else if (w.duration >= _day) {
      errors[i] = 'The end time must differ from the start time.';
    }
  }
  for (var i = 0; i < windows.length; i++) {
    for (var j = i + 1; j < windows.length; j++) {
      final a = windows[i];
      final b = windows[j];
      if (a == null || b == null || errors.containsKey(j)) continue;
      if (a.overlaps(b)) {
        errors[j] = 'Overlaps with window ${i + 1}.';
      }
    }
  }
  return errors;
}

/// The relay action ('on' / 'off') a set of windows asks for at [now], or
/// null. [runsOn] says whether the schedule is active on a given calendar
/// day (weekday chips or a date range). ON wins when an OFF and an ON land
/// on the same minute (back-to-back windows).
String? windowsActionAt(
  List<ScheduleWindow> windows,
  DateTime now,
  bool Function(DateTime day) runsOn,
) {
  final minute = now.hour * 60 + now.minute;
  final today = DateTime(now.year, now.month, now.day);
  String? action;
  for (final w in windows) {
    if (w.on == minute && runsOn(today)) return 'on';
    if (w.offMinute == minute &&
        runsOn(DateTime(today.year, today.month, today.day - w.offDayOffset))) {
      action = 'off';
    }
  }
  return action;
}
