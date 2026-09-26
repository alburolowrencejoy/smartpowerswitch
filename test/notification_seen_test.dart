import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_power_switch/services/notification_seen.dart';
import 'package:smart_power_switch/widgets/ringing_bell.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final notifs = [
    {'timestamp': 100, 'building': ''},
    {'timestamp': 300, 'building': 'IC'},
    {'timestamp': 200, 'building': 'ITED'},
  ];

  test('counts unread, and marking the newest clears every badge', () async {
    SharedPreferences.setMockInitialValues({});
    final seen = NotificationSeen.instance;
    await seen.reset();
    expect(seen.unreadCount(notifs), 3);

    var notified = 0;
    void listener() => notified++;
    seen.lastSeen.addListener(listener);
    await seen.markSeen(NotificationSeen.newestOf(notifs));
    seen.lastSeen.removeListener(listener);

    expect(notified, 1); // other screens hear about it right away
    expect(seen.unreadCount(notifs), 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('notifications_last_seen_timestamp'), 300);
  });

  test('never moves backwards (e.g. a list sorted oldest-first)', () async {
    SharedPreferences.setMockInitialValues({});
    final seen = NotificationSeen.instance;
    await seen.reset();
    await seen.markSeen(300);
    await seen.markSeen(100);
    expect(seen.lastSeen.value, 300);
  });

  test('institute admins only count what they can see', () async {
    SharedPreferences.setMockInitialValues({});
    final seen = NotificationSeen.instance;
    await seen.reset();
    // Campus-wide (no building) + their own institute; not ITED's.
    expect(seen.unreadCount(notifs, instituteCode: 'ic'), 2);
    await seen.markSeen(150);
    expect(seen.unreadCount(notifs, instituteCode: 'IC'), 1);
  });

  testWidgets('bell swings only while ringing', (tester) async {
    Widget bell(bool ringing) => MaterialApp(
          home: Center(
            child: RingingBell(
                ringing: ringing,
                child: const Icon(Icons.notifications_outlined)),
          ),
        );
    Transform? swing() {
      final t = find.descendant(
          of: find.byType(RingingBell), matching: find.byType(Transform));
      return t.evaluate().isEmpty ? null : tester.widget<Transform>(t.first);
    }

    await tester.pumpWidget(bell(true));
    await tester.pump(const Duration(milliseconds: 120));
    expect(swing(), isNotNull);
    expect(swing()!.transform.isIdentity(), isFalse);

    await tester.pumpWidget(bell(false));
    expect(swing(), isNull);
  });
}
