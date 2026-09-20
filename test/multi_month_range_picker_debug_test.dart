import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/theme/app_colors.dart';
import 'package:smart_power_switch/widgets/multi_month_range_picker.dart';

Future<void> doubleClick(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 100));
}

Color? bgColorFor(WidgetTester tester, Finder textFinder) {
  final container = tester.widget<Container>(
    find.ancestor(of: textFinder, matching: find.byType(Container)).first,
  );
  final decoration = container.decoration as BoxDecoration?;
  return decoration?.color;
}

/// Finds the outer month-block Container (identified by its
/// AppColors.surface background) that contains [monthLabel], then finds
/// [dayText] within that specific block only -- so day "3" in September
/// isn't confused with day "3" in August.
Finder dayInMonth(WidgetTester tester, String monthLabel, String dayText) {
  final blocks = find.byWidgetPredicate((w) =>
      w is Container &&
      (w.decoration as BoxDecoration?)?.color == AppColors.surface);
  for (final blockElement in blocks.evaluate()) {
    final blockFinder = find.byWidget(blockElement.widget);
    if (find
        .descendant(of: blockFinder, matching: find.text(monthLabel))
        .evaluate()
        .isNotEmpty) {
      return find.descendant(
          of: blockFinder, matching: find.text(dayText));
    }
  }
  throw StateError('month block for $monthLabel not found');
}

void main() {
  testWidgets('range spanning two different month blocks (Aug 28 -> Sep 3)',
      (tester) async {
    final latest = DateTime(2026, 9, 1);
    final earliest = DateTime(2025, 10, 1);
    DateTimeRange? pending;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            width: 800,
            child: MultiMonthRangePicker(
              earliestMonth: earliest,
              latestMonth: latest,
              onPendingChanged: (range) => pending = range,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(dayInMonth(tester, 'September 2026', '3'), findsOneWidget);
    expect(dayInMonth(tester, 'August 2026', '28'), findsOneWidget);

    await doubleClick(tester, dayInMonth(tester, 'August 2026', '28'));
    await tester.pump();
    await tester.pump();
    print('after first double-click (Aug 28) pending=$pending '
        'aug28 color=${bgColorFor(tester, dayInMonth(tester, 'August 2026', '28'))}');

    await doubleClick(tester, dayInMonth(tester, 'September 2026', '3'));
    await tester.pump();
    await tester.pump();
    print('after second double-click (Sep 3) pending=$pending');
    print('aug28 color=${bgColorFor(tester, dayInMonth(tester, 'August 2026', '28'))} '
        'sep3 color=${bgColorFor(tester, dayInMonth(tester, 'September 2026', '3'))}');
    print('aug30 (in-range) color=${bgColorFor(tester, dayInMonth(tester, 'August 2026', '30'))} '
        'sep1 (in-range) color=${bgColorFor(tester, dayInMonth(tester, 'September 2026', '1'))}');
  });
}
