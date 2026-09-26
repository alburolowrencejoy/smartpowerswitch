import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The one "last seen notification" time shared by every bell, badge and
/// notifications screen (web and mobile).
///
/// Each screen used to read and write the saved value on its own and keep a
/// private copy, so reading notifications on one screen left another
/// screen's bell showing "new" until the app restarted. Now every screen
/// listens to [lastSeen] and marks through [markSeen], so reading anywhere
/// clears every badge at once.
class NotificationSeen {
  NotificationSeen._();
  static final instance = NotificationSeen._();

  static const _key = 'notifications_last_seen_timestamp';

  /// Newest notification timestamp (ms) the user has seen; 0 = none yet.
  final ValueNotifier<int> lastSeen = ValueNotifier<int>(0);

  Future<void>? _loading;

  /// Loads the saved value once; safe to call from every screen.
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(_key) ?? 0;
      if (saved > lastSeen.value) lastSeen.value = saved;
    } catch (_) {
      // No saved state: every notification simply counts as unread.
    }
  }

  /// Marks everything up to [timestamp] as seen. Never moves backwards, so
  /// seeing an older list (e.g. sorted oldest-first) can't un-read newer
  /// notifications.
  Future<void> markSeen(int timestamp) async {
    if (timestamp <= lastSeen.value) return;
    lastSeen.value = timestamp;
    await _save(timestamp);
  }

  /// After "Clear all": start over, so every future notification is new.
  Future<void> reset() async {
    lastSeen.value = 0;
    await _save(0);
  }

  Future<void> _save(int value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_key, value);
    } catch (_) {}
  }

  /// Newest timestamp in a `notifications` list or snapshot map.
  static int newestOf(Iterable<Object?> notifications) {
    var newest = 0;
    for (final n in notifications) {
      if (n is! Map) continue;
      final t = timestampOf(n['timestamp']);
      if (t > newest) newest = t;
    }
    return newest;
  }

  static int timestampOf(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  /// Whether a notification is shown to this viewer. Institute admins only
  /// see campus-wide notifications (no building) and their own institute's;
  /// everyone else sees all.
  static bool visibleTo(Map n, {String? instituteCode}) {
    final code = (instituteCode ?? '').trim().toUpperCase();
    if (code.isEmpty) return true;
    final building = (n['building'] ?? '').toString().trim().toUpperCase();
    return building.isEmpty || building == code;
  }

  /// How many of [notifications] this viewer hasn't seen yet.
  int unreadCount(Iterable<Object?> notifications, {String? instituteCode}) {
    var count = 0;
    for (final n in notifications) {
      if (n is! Map || !visibleTo(n, instituteCode: instituteCode)) continue;
      if (timestampOf(n['timestamp']) > lastSeen.value) count++;
    }
    return count;
  }
}
