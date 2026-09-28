/// Filters for the automation schedule lists (mobile and web).
///
/// Three questions a user asks when scanning schedules:
///  * **status** -- is it running? (all / active / paused)
///  * **where** -- does it affect this building?
///  * **which** -- does it control this utility (Lights / Outlets / AC)?
///
/// "Does it affect" is answered the way the scheduler applies a schedule
/// (see automation_scheduler_service.dart `_resolveTargets`), so filtering
/// by a building also lists the campus-wide (global and utility-wide)
/// schedules that switch devices in that building.
library;

enum ScheduleStatus { all, active, paused }

/// The utilities a schedule can target.
const kScheduleUtilities = ['Lights', 'Outlets', 'AC'];

class ScheduleFilter {
  final ScheduleStatus status;

  /// Building code, or null for every building.
  final String? building;

  /// One of [kScheduleUtilities], or null for every utility.
  final String? utility;

  const ScheduleFilter({
    this.status = ScheduleStatus.all,
    this.building,
    this.utility,
  });

  /// True when a building or utility is picked (status has its own
  /// always-visible control, so it isn't counted here).
  bool get narrowsPlace => building != null || utility != null;

  ScheduleFilter withStatus(ScheduleStatus s) =>
      ScheduleFilter(status: s, building: building, utility: utility);

  ScheduleFilter withBuilding(String? b) =>
      ScheduleFilter(status: status, building: b, utility: utility);

  ScheduleFilter withUtility(String? u) =>
      ScheduleFilter(status: status, building: building, utility: u);

  ScheduleFilter clearPlace() => ScheduleFilter(status: status);

  /// Whether a schedule passes this filter. [deviceBuilding] and
  /// [deviceUtility] describe the target device of a `device`-scoped
  /// schedule (null when unknown or for other scopes).
  bool matches({
    required String scope,
    required String target,
    required String utility,
    required bool enabled,
    String? deviceBuilding,
    String? deviceUtility,
  }) {
    if (status == ScheduleStatus.active && !enabled) return false;
    if (status == ScheduleStatus.paused && enabled) return false;

    final b = building;
    if (b != null) {
      final where = switch (scope) {
        // Campus-wide schedules run in every building.
        'global' || 'utility' => true,
        'building' => _same(target, b),
        'device' => _same(deviceBuilding ?? '', b),
        _ => false,
      };
      if (!where) return false;
    }

    final u = this.utility;
    if (u != null) {
      final which = switch (scope) {
        'utility' => target,
        'device' => deviceUtility ?? utility,
        _ => utility,
      };
      // 'All' (or blank) means the schedule switches every utility.
      final all = which.trim().isEmpty || _same(which, 'all');
      if (!all && !_same(which, u)) return false;
    }
    return true;
  }

  static bool _same(String a, String b) =>
      a.trim().toUpperCase() == b.trim().toUpperCase();
}
