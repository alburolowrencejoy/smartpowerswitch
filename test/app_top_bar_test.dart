import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/widgets/app_top_bar.dart';

/// KNOWN DEFECT (reported separately, not fixed here -- see the QA handback
/// for this session): every [AppTopBar] configuration -- even the minimal
/// `AppTopBar(title: 'x')` with no actions/back/avatar/subtitle -- throws a
/// "RenderFlex overflowed by 1.00 pixels on the bottom" during layout of the
/// title/subtitle `Column` (lib/widgets/app_top_bar.dart:120). Root cause:
/// `_contentHeight`/`preferredSize` (same file, ~180-194) budgets the bar's
/// height from title/subtitle line heights + vertical padding only, but the
/// outer `Container`'s `decoration` carries a bottom `Border` (1px normal,
/// 3px when `showInstituteLine: true`) -- Flutter's `Container.build()`
/// automatically folds a `BoxDecoration`'s border width into the effective
/// padding, silently consuming that many pixels from the height budget
/// `_contentHeight` promised. The Column is then laid out exactly
/// `borderWidth` pixels short, hence the universal 1px overflow.
///
/// This isn't purely cosmetic: in at least one observed run it also
/// corrupted the actions row's hit-test geometry (a tap aimed at the
/// notification-bell icon's computed center missed it -- see
/// `flutter test test/app_top_bar_test.dart` output), so tap-based
/// interaction assertions on `AppTopBar` are NOT reliable until this is
/// fixed. This file only asserts things `find.text`/`find.byIcon` can see
/// without depending on tap hit-testing, and consumes the known,
/// always-present overflow via [_expectKnownOverflowOnly] so those
/// assertions can still run. AppBottomNav/AppSegmentedControl/AppSwitch
/// (see their own test files) do not have this problem and are the
/// reliable "3 shared components" smoke coverage for this session; this
/// file is extra, regression-documenting coverage for AppTopBar specifically.
void _expectKnownOverflowOnly(WidgetTester tester) {
  final err = tester.takeException();
  if (err == null) return; // Already fixed -- nothing to swallow.
  expect(err, isA<FlutterError>());
  expect(err.toString(), contains('overflowed'),
      reason: 'expected only the known app_top_bar.dart border/height-budget '
          'overflow, got a different error: $err');
}

void main() {
  testWidgets('renders title and subtitle', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          appBar: AppTopBar(title: 'Home', subtitle: 'Overview'),
        ),
      ),
    );
    _expectKnownOverflowOnly(tester);

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Overview'), findsOneWidget);
  });

  testWidgets('no back button by default; showBackButton renders one', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(appBar: AppTopBar(title: 'Home')),
      ),
    );
    _expectKnownOverflowOnly(tester);
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppTopBar(title: 'Device', showBackButton: true, onBack: () {}),
        ),
      ),
    );
    _expectKnownOverflowOnly(tester);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
  });

  testWidgets('action with a badge count renders the count as text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppTopBar(
            title: 'Notifications',
            actions: [
              AppTopBarAction(icon: Icons.notifications, onTap: () {}, badgeCount: 3),
            ],
          ),
        ),
      ),
    );
    _expectKnownOverflowOnly(tester);

    expect(find.byIcon(Icons.notifications), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('badge count above 99 renders as "99+"', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppTopBar(
            title: 'Notifications',
            actions: [
              AppTopBarAction(icon: Icons.notifications, onTap: () {}, badgeCount: 150),
            ],
          ),
        ),
      ),
    );
    _expectKnownOverflowOnly(tester);

    expect(find.text('99+'), findsOneWidget);
    expect(find.text('150'), findsNothing);
  });

  testWidgets('a zero badge count renders no badge', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppTopBar(
            title: 'Notifications',
            actions: [
              AppTopBarAction(icon: Icons.notifications, onTap: () {}, badgeCount: 0),
            ],
          ),
        ),
      ),
    );
    _expectKnownOverflowOnly(tester);

    expect(find.text('0'), findsNothing);
  });

  testWidgets('avatar renders its initials', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppTopBar(title: 'Home', showAvatar: true, avatarInitials: 'LJ'),
        ),
      ),
    );
    _expectKnownOverflowOnly(tester);

    expect(find.text('LJ'), findsOneWidget);
  });

  testWidgets(
      'regression guard: title-only bar should not overflow',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(appBar: AppTopBar(title: 'Home'))),
    );

    expect(tester.takeException(), isNull,
        reason: 'AppTopBar should not overflow for a plain title -- if this '
            'now passes, the border/height-budget bug documented at the top '
            'of this file has been fixed and _expectKnownOverflowOnly above '
            'can be deleted.');
  });
}
