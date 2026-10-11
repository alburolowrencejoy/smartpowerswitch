/// Shared helper for the "is this device online?" check used across the
/// mobile screens (`history_screen.dart`, `dashboard_screen.dart`,
/// `device_detail_screen.dart`, `building_floor_screen.dart`).
///
/// Every one of those screens reads a device's `last_seen` millis timestamp
/// straight out of a Firebase Realtime Database snapshot and used to do
/// `lastSeen as int` on it. Firebase Realtime Database is JSON-based and
/// doesn't strictly distinguish `int` from `double` on the wire -- a
/// timestamp that happens to come back from the Dart SDK as a `double`
/// (which does happen in practice, hence the usual
/// `(data['last_seen'] as num?)?.toInt()` guard elsewhere) made `as int`
/// throw a `TypeError` instead of returning a sensible answer. Inside a
/// `setState(() { ... })` closure feeding a `StreamSubscription.listen`
/// callback (not a stream `onError`), that throw is never caught by the
/// subscription's `onError`, which can leave a whole screen permanently
/// stuck showing a loading skeleton. See `history_screen.dart`'s
/// `_listenAll` for the concrete case this was extracted from.
///
/// This always accepts `int`, `double`, `null`, or any other unexpected
/// shape without throwing.
bool isRecentlySeen(Object? lastSeenRaw,
    {Duration within = const Duration(minutes: 2)}) {
  final millis = lastSeenMillis(lastSeenRaw);
  if (millis == null) return false;
  final seenAt = DateTime.fromMillisecondsSinceEpoch(millis);
  return DateTime.now().difference(seenAt) < within;
}

/// Safely extracts a `last_seen` millis-since-epoch value out of a raw
/// Firebase field, accepting `int`, `double`, `null`, or any other
/// unexpected type without throwing. Returns `null` for a missing/zero
/// timestamp (device has never reported in). Use this (instead of a raw
/// `as int` cast) anywhere `last_seen` needs to become a [DateTime], e.g.
/// for a "seen 3m ago" label; use [isRecentlySeen] directly for a plain
/// online/offline check.
int? lastSeenMillis(Object? lastSeenRaw) {
  if (lastSeenRaw is! num) return null;
  final millis = lastSeenRaw.toInt();
  if (millis == 0) return null;
  return millis;
}

/// When a board last checked in: the newer of `last_seen` and
/// `last_updated` (for firmware 2.0 these are `connectivity.lastSeenAt` /
/// `lastUpdatedAt`, merged by `DeviceLive`). Only boards write either field.
///
/// Both firmware versions backdate `last_seen` by five minutes while the
/// PZEM meter isn't answering, but keep stamping `last_updated` on every
/// report. Reading `last_seen` alone made a board with a broken meter look
/// offline, which disabled its ON/OFF switch even though the board was up
/// and polling for commands.
int? deviceSeenMillis(Map<dynamic, dynamic>? data) {
  if (data == null) return null;
  final seen = lastSeenMillis(data['last_seen']);
  final updated = lastSeenMillis(data['last_updated']);
  if (seen == null) return updated;
  if (updated == null) return seen;
  return seen > updated ? seen : updated;
}

/// Whether the board behind [data] (a `devices/{id}` record, merged with
/// `device_live` where present) has checked in within [within]. Use this
/// for every online/offline decision, not `last_seen` alone.
bool isDeviceOnline(Map<dynamic, dynamic>? data,
        {Duration within = const Duration(minutes: 2)}) =>
    isRecentlySeen(deviceSeenMillis(data), within: within);
