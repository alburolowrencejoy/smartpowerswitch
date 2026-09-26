import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/utils/last_seen.dart';

/// Regression test for the Analytics "Usage" tab permanently-stuck-loading
/// bug: `history_screen.dart`'s `_listenAll` (and the same online-status
/// pattern in `dashboard_screen.dart`, `device_detail_screen.dart`, and
/// `building_floor_screen.dart`) used to do `lastSeen as int` on a raw
/// Firebase `last_seen` value. Firebase Realtime Database doesn't strictly
/// distinguish `int` from `double` on the wire, so a timestamp that comes
/// back as a `double` made that cast throw a `TypeError` -- and because it
/// threw from inside a `setState` callback body (not a stream error), it
/// was never caught by the listener's `onError`, permanently freezing the
/// screen on its loading skeleton (which also blocks all pointer events,
/// per `screen_skeleton_test.dart`).
///
/// [isRecentlySeen]/[lastSeenMillis] must accept every shape a real
/// `last_seen` field could plausibly have and never throw.
void main() {
  group('isRecentlySeen', () {
    test('true for an int timestamp from just now', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(isRecentlySeen(now), isTrue);
    });

    test('true for a double timestamp from just now (the historical bug)', () {
      final now = DateTime.now().millisecondsSinceEpoch.toDouble();
      expect(() => isRecentlySeen(now), returnsNormally);
      expect(isRecentlySeen(now), isTrue);
    });

    test('false for a stale double timestamp', () {
      final stale = DateTime.now()
          .subtract(const Duration(minutes: 10))
          .millisecondsSinceEpoch
          .toDouble();
      expect(isRecentlySeen(stale), isFalse);
    });

    test('false for null', () {
      expect(isRecentlySeen(null), isFalse);
    });

    test('false for zero (never reported in)', () {
      expect(isRecentlySeen(0), isFalse);
      expect(isRecentlySeen(0.0), isFalse);
    });

    test('false, not throwing, for a completely unexpected type', () {
      expect(() => isRecentlySeen('not a timestamp'), returnsNormally);
      expect(isRecentlySeen('not a timestamp'), isFalse);
      expect(() => isRecentlySeen(<String, dynamic>{'x': 1}), returnsNormally);
      expect(isRecentlySeen(<String, dynamic>{'x': 1}), isFalse);
    });

    test('respects a custom `within` window', () {
      final fiveMinAgo = DateTime.now()
          .subtract(const Duration(minutes: 5))
          .millisecondsSinceEpoch;
      expect(isRecentlySeen(fiveMinAgo), isFalse);
      expect(isRecentlySeen(fiveMinAgo, within: const Duration(minutes: 10)),
          isTrue);
    });
  });

  group('lastSeenMillis', () {
    test('returns the millis for an int', () {
      expect(lastSeenMillis(1700000000000), 1700000000000);
    });

    test('returns the millis (truncated) for a double, without throwing', () {
      expect(() => lastSeenMillis(1700000000000.0), returnsNormally);
      expect(lastSeenMillis(1700000000000.0), 1700000000000);
    });

    test('returns null for null, zero, or an unexpected type', () {
      expect(lastSeenMillis(null), isNull);
      expect(lastSeenMillis(0), isNull);
      expect(lastSeenMillis(0.0), isNull);
      expect(() => lastSeenMillis('nope'), returnsNormally);
      expect(lastSeenMillis('nope'), isNull);
    });
  });
}
