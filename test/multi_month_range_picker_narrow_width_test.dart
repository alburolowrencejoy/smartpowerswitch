import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/widgets/multi_month_range_picker.dart';

void main() {
  testWidgets('narrow available width scrolls horizontally instead of overflowing',
      (tester) async {
    final latest = DateTime(2026, 9, 1);
    final earliest = DateTime(2025, 10, 1);

    // Deliberately narrower than the natural 2-column width (~380px).
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            width: 260,
            child: MultiMonthRangePicker(
              earliestMonth: earliest,
              latestMonth: latest,
              onPendingChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No overflow errors should have been recorded.
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsWidgets);

    final horizontalScrollables = find
        .byWidgetPredicate((w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal)
        .evaluate();
    expect(horizontalScrollables, isNotEmpty);
  });

  testWidgets('wide available width does not add a horizontal scroll wrapper',
      (tester) async {
    final latest = DateTime(2026, 9, 1);
    final earliest = DateTime(2025, 10, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            width: 800,
            child: MultiMonthRangePicker(
              earliestMonth: earliest,
              latestMonth: latest,
              onPendingChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final horizontalScrollables = find
        .byWidgetPredicate((w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal)
        .evaluate();
    expect(horizontalScrollables, isEmpty);
  });
}
