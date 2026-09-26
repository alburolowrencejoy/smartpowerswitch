// Tests for [ScreenSkeleton], the shared shimmer wrapper introduced to fix
// the "blank dashboard flash" bug (see lib/widgets/screen_skeleton.dart).
//
// Contract under test:
//   * isLoading: false  -> zero visual/behavioral side effects vs rendering
//     `child` directly (same finders, taps still reach the child).
//   * isLoading: true   -> the skeletonizer shimmer is actually enabled, and
//     it uses AppColors.skeleton (+ a lighter tint) as configured.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skeletonizer/skeletonizer.dart';

import 'package:smart_power_switch/theme/app_colors.dart';
import 'package:smart_power_switch/widgets/screen_skeleton.dart';

void main() {
  group('ScreenSkeleton(isLoading: false)', () {
    testWidgets('renders the child text exactly like pumping it directly',
        (tester) async {
      const child = Text('Hello world');

      await tester.pumpWidget(const MaterialApp(home: child));
      expect(find.text('Hello world'), findsOneWidget);

      await tester.pumpWidget(
        const MaterialApp(
          home: ScreenSkeleton(isLoading: false, child: child),
        ),
      );
      expect(find.text('Hello world'), findsOneWidget);
    });

    testWidgets('reports the skeletonizer scope as disabled', (tester) async {
      late BuildContext capturedContext;

      await tester.pumpWidget(
        MaterialApp(
          home: ScreenSkeleton(
            isLoading: false,
            child: Builder(builder: (context) {
              capturedContext = context;
              return const Text('content');
            }),
          ),
        ),
      );

      expect(Skeletonizer.of(capturedContext).enabled, isFalse);
    });

    testWidgets('does not block pointer events reaching the child',
        (tester) async {
      var tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: ScreenSkeleton(
            isLoading: false,
            child: ElevatedButton(
              onPressed: () => tapped = true,
              child: const Text('Tap me'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Tap me'));
      await tester.pump();

      expect(tapped, isTrue);
    });
  });

  group('ScreenSkeleton(isLoading: true)', () {
    testWidgets('reports the skeletonizer scope as enabled', (tester) async {
      late BuildContext capturedContext;

      await tester.pumpWidget(
        MaterialApp(
          home: ScreenSkeleton(
            isLoading: true,
            child: Builder(builder: (context) {
              capturedContext = context;
              return const Text('content');
            }),
          ),
        ),
      );

      expect(Skeletonizer.of(capturedContext).enabled, isTrue);
    });

    testWidgets('still mounts the child widget tree underneath the shimmer',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ScreenSkeleton(isLoading: true, child: Text('content')),
        ),
      );

      // Skeletonizer paints bones *over* the real render objects rather than
      // replacing the widget tree, so the real widget must still be present
      // (this is what lets it show "realistic" shapes from placeholder data).
      expect(find.text('content'), findsOneWidget);
    });

    testWidgets('uses AppColors.skeleton (and a lighter tint) as the shimmer colors',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ScreenSkeleton(isLoading: true, child: Text('content')),
        ),
      );

      final skeletonizer = tester.widget<Skeletonizer>(
        find.byWidgetPredicate((w) => w is Skeletonizer),
      );
      final effect = skeletonizer.effect;

      expect(effect, isA<ShimmerEffect>());
      final shimmer = effect as ShimmerEffect;
      final expectedHighlight =
          Color.lerp(AppColors.skeleton, Colors.white, 0.6);
      // `baseColor`/`highlightColor` are only exposed on the private
      // `_ShimmerEffect` impl, so assert via the public `colors` gradient
      // stops instead: [base, highlight, base].
      expect(shimmer.colors, [
        AppColors.skeleton,
        expectedHighlight,
        AppColors.skeleton,
      ]);
    });

    testWidgets('blocks pointer events by default while loading (package default)',
        (tester) async {
      var tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: ScreenSkeleton(
            isLoading: true,
            child: ElevatedButton(
              onPressed: () => tapped = true,
              child: const Text('Tap me'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Tap me'), warnIfMissed: false);
      await tester.pump();

      // Skeletonizer's `ignorePointers` defaults to true, so interactive
      // controls under the shimmer must not be tappable while isLoading is
      // true. If this starts failing, ScreenSkeleton's default changed.
      expect(tapped, isFalse);
    });
  });
}
