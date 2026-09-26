import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/widgets/app_segmented_control.dart';

/// Smoke coverage for [AppSegmentedControl]. Segments are found by their
/// label text (no [Key] on `_Segment`) -- flagged in the QA report.
void main() {
  testWidgets('renders every segment label', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppSegmentedControl(
            segments: const [
              AppSegment(label: 'Weekly'),
              AppSegment(label: 'Calendar'),
            ],
            selectedIndex: 0,
            onChanged: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('Weekly'), findsOneWidget);
    expect(find.text('Calendar'), findsOneWidget);
  });

  testWidgets('tapping an unselected segment calls onChanged with its index', (tester) async {
    int? changedTo;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppSegmentedControl(
            segments: const [
              AppSegment(label: 'Weekly'),
              AppSegment(label: 'Calendar'),
            ],
            selectedIndex: 0,
            onChanged: (i) => changedTo = i,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Calendar'));
    await tester.pump();

    expect(changedTo, 1);
  });

  testWidgets('enabled: false ignores taps (edge case: disabled control must not fire onChanged)',
      (tester) async {
    int? changedTo;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppSegmentedControl(
            segments: const [
              AppSegment(label: 'A'),
              AppSegment(label: 'B'),
            ],
            selectedIndex: 0,
            onChanged: (i) => changedTo = i,
            enabled: false,
          ),
        ),
      ),
    );

    // warnIfMissed: false -- IgnorePointer deliberately removes this widget
    // from hit-testing while disabled, so the tap genuinely not landing on
    // it *is* the behavior under test, not a broken finder.
    await tester.tap(find.text('B'), warnIfMissed: false);
    await tester.pump();

    expect(changedTo, isNull, reason: 'IgnorePointer should block the tap while disabled');
  });

  testWidgets('a single segment renders and can still report its own tap', (tester) async {
    int? changedTo;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppSegmentedControl(
            segments: const [AppSegment(label: 'Only')],
            selectedIndex: 0,
            onChanged: (i) => changedTo = i,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Only'));
    await tester.pump();
    expect(changedTo, 0);
  });
}
