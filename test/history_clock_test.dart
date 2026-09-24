import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/services/history_clock.dart';
import 'package:smart_power_switch/widgets/history_fallback_notice.dart';

void main() {
  final clock = HistoryClock.instance;
  tearDown(() => clock.debugSetLatest(null));

  test('uses the real date when nothing is known', () {
    clock.debugSetLatest(null);
    expect(clock.isFallback, isFalse);
    expect(clock.now().difference(DateTime.now()).inSeconds.abs(), lessThan(2));
  });

  test('uses the real date when the current month has data', () {
    final today = DateTime.now();
    clock.debugSetLatest(DateTime(today.year, today.month, 1));
    expect(clock.isFallback, isFalse);
    expect(clock.now().month, today.month);
    expect(clock.now().day, today.day);
  });

  test('falls back to the newest recorded day when this month is empty', () {
    final old = DateTime.now().subtract(const Duration(days: 120));
    final latest = DateTime(old.year, old.month, old.day);
    clock.debugSetLatest(latest);
    expect(clock.isFallback, isTrue);
    final now = clock.now();
    expect(DateTime(now.year, now.month, now.day), latest);
  });

  testWidgets('notice shows only while falling back', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: HistoryFallbackNotice()),
    ));
    expect(find.textContaining('Showing latest recorded data'), findsNothing);

    clock.debugSetLatest(DateTime(2026, 6, 1));
    await tester.pump();
    final expectFallback = clock.isFallback; // depends on today's date
    expect(find.text('Showing latest recorded data · Jun 1, 2026'),
        expectFallback ? findsOneWidget : findsNothing);
  });
}
