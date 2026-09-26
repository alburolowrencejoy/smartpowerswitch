import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/widgets/app_bottom_nav.dart';

/// Smoke coverage for [AppBottomNav]. Tabs are found by their label text
/// (no [Key] on [_NavItem]/tab icons) -- flagged in the QA report; labels
/// are static enum-driven strings so this isn't expected to be brittle, but
/// a `Key` per tab (e.g. `ValueKey(tab)`) would be more robust than text.
void main() {
  testWidgets('renders all 5 tabs by default', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: AppBottomNav(
            selected: AppNavTab.home,
            onSelect: (_) {},
          ),
        ),
      ),
    );

    for (final label in ['Home', 'Devices', 'Analytics', 'Automation', 'More']) {
      expect(find.text(label), findsOneWidget, reason: 'expected tab "$label"');
    }
  });

  testWidgets('tapping a tab calls onSelect with that tab', (tester) async {
    AppNavTab? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: AppBottomNav(
            selected: AppNavTab.home,
            onSelect: (t) => selected = t,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Devices'));
    await tester.pump();

    expect(selected, AppNavTab.devices);
  });

  testWidgets('active tab uses the filled icon, inactive tabs use outlined icons', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: AppBottomNav(
            selected: AppNavTab.home,
            onSelect: (_) {},
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.home), findsOneWidget, reason: 'selected Home should be filled');
    expect(find.byIcon(Icons.home_outlined), findsNothing);
    expect(find.byIcon(Icons.devices_other_outlined), findsOneWidget,
        reason: 'unselected Devices should be outlined');
    expect(find.byIcon(Icons.devices_other), findsNothing);
  });

  testWidgets('hiddenTabs omits a tab entirely, not just disables it', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: AppBottomNav(
            selected: AppNavTab.home,
            onSelect: (_) {},
            hiddenTabs: const {AppNavTab.analytics},
          ),
        ),
      ),
    );

    expect(find.text('Analytics'), findsNothing);
    for (final label in ['Home', 'Devices', 'Automation', 'More']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('hiding every tab renders an empty nav without throwing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: AppBottomNav(
            selected: AppNavTab.home,
            onSelect: (_) {},
            hiddenTabs: Set.of(AppNavTab.values),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    for (final label in ['Home', 'Devices', 'Analytics', 'Automation', 'More']) {
      expect(find.text(label), findsNothing);
    }
  });
}
