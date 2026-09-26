import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/widgets/app_switch.dart';

/// Smoke coverage for [AppSwitch]. No [Key] on the widget itself; found by
/// [GestureDetector]/[AppSwitch] type since it renders no text.
void main() {
  testWidgets('tapping toggles value through onChanged', (tester) async {
    bool? newValue;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppSwitch(value: false, onChanged: (v) => newValue = v),
        ),
      ),
    );

    await tester.tap(find.byType(AppSwitch));
    await tester.pump();

    expect(newValue, isTrue);
  });

  testWidgets('tapping when on calls onChanged(false)', (tester) async {
    bool? newValue;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppSwitch(value: true, onChanged: (v) => newValue = v),
        ),
      ),
    );

    await tester.tap(find.byType(AppSwitch));
    await tester.pump();

    expect(newValue, isFalse);
  });

  testWidgets('onChanged: null (disabled) ignores taps and does not throw', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AppSwitch(value: false, onChanged: null)),
      ),
    );

    await tester.tap(find.byType(AppSwitch));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('renders at the spec 52x32 size', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: AppSwitch(value: false, onChanged: (_) {})),
        ),
      ),
    );

    final size = tester.getSize(find.byType(AppSwitch));
    expect(size, const Size(52, 32));
  });
}
