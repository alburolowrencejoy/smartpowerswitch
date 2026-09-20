import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/theme/app_colors.dart';
import 'package:smart_power_switch/widgets/multi_month_range_picker.dart';

Color? bgColorFor(WidgetTester tester, Finder textFinder) {
  final container = tester.widget<Container>(
    find.ancestor(of: textFinder, matching: find.byType(Container)).first,
  );
  final decoration = container.decoration as BoxDecoration?;
  return decoration?.color;
}

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
      return find.descendant(of: blockFinder, matching: find.text(dayText));
    }
  }
  throw StateError('month block for $monthLabel not found');
}

void main() {
  // Regression test for the range-highlight-never-appears bug: relying on
  // GestureDetector's built-in onTap/onDoubleTap disambiguation broke down
  // for double-clicks slower than Flutter's hardcoded kDoubleTapTimeout
  // (300ms), which is quite plausible for a real user. The widget now does
  // its own double-click detection with a more generous window instead.
  testWidgets(
      'double click with a 350ms gap (slower than kDoubleTapTimeout, '
      'within the widget\'s own window) still starts a range',
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

    // First click on Aug 28: should NOT immediately commit a single-day
    // selection while it's still possibly the first half of a double-click.
    await tester.tap(dayInMonth(tester, 'August 2026', '28'));
    await tester.pump(const Duration(milliseconds: 350)); // > kDoubleTapTimeout (300ms)
    expect(pending, isNull);
    expect(bgColorFor(tester, dayInMonth(tester, 'August 2026', '28')), isNull);

    // Second click on Aug 28, slow enough that Flutter's own onDoubleTap
    // would have missed it -- but still within our widget's window, so it
    // must be recognized as the double-click that arms a range start.
    await tester.tap(dayInMonth(tester, 'August 2026', '28'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(pending, isNull); // range not complete yet -- only a start picked
    expect(bgColorFor(tester, dayInMonth(tester, 'August 2026', '28')),
        AppColors.greenDark);

    // Double-click a different day (Sep 3) to complete the range.
    await tester.tap(dayInMonth(tester, 'September 2026', '3'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(dayInMonth(tester, 'September 2026', '3'));
    await tester.pump(const Duration(milliseconds: 350));

    expect(pending, isNotNull);
    expect(pending!.start, DateTime(2026, 8, 28));
    expect(pending!.end, DateTime(2026, 9, 3));
    expect(bgColorFor(tester, dayInMonth(tester, 'August 2026', '28')),
        AppColors.greenDark);
    expect(bgColorFor(tester, dayInMonth(tester, 'September 2026', '3')),
        AppColors.greenDark);
    expect(bgColorFor(tester, dayInMonth(tester, 'August 2026', '30')),
        AppColors.greenPale);
  });
}
