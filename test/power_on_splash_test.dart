import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_power_switch/screens/shared/login_screen.dart';
import 'package:smart_power_switch/widgets/login_intro_scope.dart';
import 'package:smart_power_switch/widgets/power_emblem.dart';

void main() {
  testWidgets('emblem renders mid-intro poses (overshoot, waves, blur)',
      (tester) async {
    for (final pose in const [
      EmblemPose(
          track: 0,
          arc: 0,
          bar: 0,
          spark: 0,
          nodes: [0, 0, 0],
          letters: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
      EmblemPose(
        track: .5,
        arc: .7,
        arcCharge: 1,
        bar: .4,
        shake: Offset(-6, 3),
        wave1: .3,
        wave2: .05,
        letters: [1.1, 1, .8, .5, .2, 0, 0, 0, 0, 0, 0],
        switchGlow: .4,
        nodes: [1.2, .5, 0],
        ripples: [.5, -1, -1],
        spark: .5,
        sparkTurn: .3,
      ),
      EmblemPose(),
    ]) {
      await tester.pumpWidget(MaterialApp(
        home: Center(child: PowerEmblemView(size: 260, pose: pose)),
      ));
      expect(tester.takeException(), isNull);
    }
    expect(find.text('S'), findsNWidgets(2)); // "Smart" + "Switch"
  });

  testWidgets('login card and emblem follow the splash hand-off',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final settle = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: LoginIntroScope.settleMs));
    final orbit = AnimationController(
        vsync: const TestVSync(), duration: const Duration(seconds: 9));
    final hidden = ValueNotifier(true);
    final slot = GlobalKey();
    addTearDown(() {
      settle.dispose();
      orbit.dispose();
      hidden.dispose();
    });

    await tester.pumpWidget(MaterialApp(
      home: LoginIntroScope(
        settle: settle,
        emblemSlotKey: slot,
        emblemHidden: hidden,
        orbit: orbit,
        child: const LoginScreen(),
      ),
    ));
    await tester.pump();

    double opacityAbove(Finder f) => tester
        .widget<Opacity>(
            find.ancestor(of: f, matching: find.byType(Opacity)).last)
        .opacity;

    // Start of the settle: card and form hidden, login emblem stood in for.
    expect(slot.currentContext, isNotNull, reason: 'slot is measurable');
    expect(opacityAbove(find.text('Sign in').first), 0);
    expect(
        tester
            .widget<Opacity>(find
                .descendant(
                    of: find.byKey(slot), matching: find.byType(Opacity))
                .first)
            .opacity,
        0);

    // End of the settle: everything visible.
    settle.value = 1;
    hidden.value = false;
    await tester.pump();
    expect(opacityAbove(find.text('Sign in').first), 1);
    expect(
        tester
            .widget<Opacity>(find
                .descendant(
                    of: find.byKey(slot), matching: find.byType(Opacity))
                .first)
            .opacity,
        1);
    expect(tester.takeException(), isNull);
  });
}
