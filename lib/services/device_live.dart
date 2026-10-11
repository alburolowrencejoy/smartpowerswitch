/// Live readings for screens (master plan Phase 5b).
///
/// Boards on firmware 2.0+ report to `device_live/{id}`:
///   telemetry   { voltage, current, power, cumulativeKwh, powerFactor,
///                 frequency, voltageWarning }
///   connectivity{ status, lastSeenAt, lastUpdatedAt, wifiSsid, wifiRssi }
///   state       { reportedRelay, lastCommandId, lastCommandAt }
/// Boards on the old firmware still report to `devices/{id}` (flat keys).
///
/// [merge] / [mergeOne] give every screen one flat record per device in the
/// old key names (`kwh`, `last_seen`, `relay`, `wifi_ssid`, ...), taking each
/// live field from `device_live` when the board has one and keeping the old
/// record otherwise. `relay` is then what the board REPORTS (for old boards
/// it is the old shared field). The registry copy (`building`, `floor`,
/// `room`, `utility`) and `wifiReset` always come from the old record.
class DeviceLive {
  DeviceLive._();

  /// `device_live` key paths -> old flat key.
  static const Map<String, List<String>> _fields = {
    'voltage': ['telemetry', 'voltage'],
    'current': ['telemetry', 'current'],
    'power': ['telemetry', 'power'],
    'kwh': ['telemetry', 'cumulativeKwh'],
    'powerFactor': ['telemetry', 'powerFactor'],
    'frequency': ['telemetry', 'frequency'],
    'voltage_warning': ['telemetry', 'voltageWarning'],
    'status': ['connectivity', 'status'],
    'last_seen': ['connectivity', 'lastSeenAt'],
    'last_updated': ['connectivity', 'lastUpdatedAt'],
    'wifi_ssid': ['connectivity', 'wifiSsid'],
    'wifi_rssi': ['connectivity', 'wifiRssi'],
    'relay': ['state', 'reportedRelay'],
  };

  /// Telemetry readings, cleared together when a v2 board reports no meter
  /// data (the board then omits them).
  static const Set<String> _telemetry = {
    'voltage', 'current', 'power', 'powerFactor', 'frequency', //
  };

  /// One device: [legacy] = `devices/{id}`, [live] = `device_live/{id}`.
  /// Null when neither exists.
  static Map<String, dynamic>? mergeOne(Object? legacy, Object? live) {
    if (legacy is! Map && live is! Map) return null;
    final out = <String, dynamic>{
      if (legacy is Map)
        for (final e in legacy.entries) e.key.toString(): e.value,
    };
    if (live is! Map) return out;
    // A v2 board owns its live fields: drop the stale old ones first.
    for (final key in _telemetry) {
      out.remove(key);
    }
    for (final entry in _fields.entries) {
      final group = live[entry.value[0]];
      if (group is! Map) continue;
      final value = group[entry.value[1]];
      if (value != null) out[entry.key] = value;
    }
    return out;
  }

  /// Every device in either node: `{id: flat record}`.
  static Map<String, dynamic> merge(Object? legacyAll, Object? liveAll) {
    final ids = <String>{
      if (legacyAll is Map) ...legacyAll.keys.map((k) => '$k'),
      if (liveAll is Map) ...liveAll.keys.map((k) => '$k'),
    };
    final out = <String, dynamic>{};
    for (final id in ids) {
      final record = mergeOne(
        legacyAll is Map ? legacyAll[id] : null,
        liveAll is Map ? liveAll[id] : null,
      );
      if (record != null) out[id] = record;
    }
    return out;
  }

  /// Whether the board runs firmware 2.0+ (has a `device_live` record).
  static bool isV2(Object? live) => live is Map;
}
