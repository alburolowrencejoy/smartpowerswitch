/// Where energy history lives and how screens read it.
///
/// The server's `rollupEnergy` Cloud Function (functions/energy_rollup.js) is
/// the only writer. Once a minute it adds each real board's new energy to
///
///   energy_summaries/{range}/{key}/
///       campus/{kwh,cost}
///       buildings/{CODE}/{kwh,cost}      CODE = building, or UNASSIGNED
///       devices/{id}/{kwh,cost,building}
///
/// for range = hourly | daily | weekly | monthly | yearly, with keys from
/// [HistoryKeys] (Philippine time, ISO weeks). Costs are stored at the rate in
/// force when the energy was counted.
///
/// Screens were written against the old `history/{range}/{key}` node, which
/// stored the campus total as `total_kwh`/`total_cost`. The `legacy*`
/// converters return that shape (buildings and devices are unchanged), so a
/// screen only has to change the path it listens to.
class EnergyHistory {
  EnergyHistory._();

  static const String root = 'energy_summaries';

  /// Ranges the screens list and chart. `hourly` is left out of [legacyRoot]
  /// readers on purpose: only the Home sparkline/peak hour needs it.
  static const List<String> ranges = ['daily', 'weekly', 'monthly', 'yearly'];

  /// `energy_summaries/{range}` or `energy_summaries/{range}/{key}`.
  static String path(String range, [String? key]) =>
      key == null ? '$root/$range' : '$root/$range/$key';

  /// `{range: {key: period}}` in the old `history` shape.
  static Map<String, dynamic> legacyRoot(Object? raw) {
    if (raw is! Map) return {};
    return {
      for (final e in raw.entries)
        e.key.toString(): legacyRange(e.value),
    };
  }

  /// `{key: period}` in the old `history/{range}` shape.
  static Map<String, dynamic> legacyRange(Object? raw) {
    if (raw is! Map) return {};
    return {
      for (final e in raw.entries)
        if (e.value is Map) e.key.toString(): legacyPeriod(e.value),
    };
  }

  /// One period with `total_kwh`/`total_cost` taken from its `campus` node.
  static Map<String, dynamic> legacyPeriod(Object? raw) {
    if (raw is! Map) return {};
    final period = Map<String, dynamic>.from(raw);
    final campus = period.remove('campus');
    if (campus is Map) {
      if (campus['kwh'] is num) period['total_kwh'] = campus['kwh'];
      if (campus['cost'] is num) period['total_cost'] = campus['cost'];
    }
    return period;
  }
}
