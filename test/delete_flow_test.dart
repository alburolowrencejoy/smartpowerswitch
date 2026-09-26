import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/widgets/delete_flow.dart';

/// Records every call the flow makes so tests can assert both "was it
/// called" and "in what order" without depending on internal timing.
class _Recorder {
  final calls = <String>[];
  String? committedReason;
  String? committedOtherText;
  bool? flowResult;

  DeleteCommit get onCommit => (reason, otherText) async {
        calls.add('commit');
        committedReason = reason;
        committedOtherText = otherText;
      };

  VoidCallback get onOptimisticRemove => () => calls.add('optimisticRemove');
  VoidCallback get onRestore => () => calls.add('restore');
}

/// Pumps a screen with a single button that opens [showDeleteFlow] with the
/// given parameters, recording the returned bool onto [recorder.flowResult].
Future<void> pumpFlow(
  WidgetTester tester, {
  required DeleteType type,
  required _Recorder recorder,
  String itemName = 'Test item',
  List<String>? impact,
  List<String>? reasons,
  Duration undoWindow = const Duration(milliseconds: 200),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              recorder.flowResult = await showDeleteFlow(
                context,
                type: type,
                itemName: itemName,
                impact: impact,
                reasons: reasons,
                onCommit: recorder.onCommit,
                onOptimisticRemove: recorder.onOptimisticRemove,
                onRestore: recorder.onRestore,
                undoWindow: undoWindow,
              );
            },
            child: const Text('Open delete flow'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open delete flow'));
  await tester.pumpAndSettle();
}

/// Scrolls [finder] into view inside the dialog before tapping it -- the
/// dialog is capped at 440px wide, so long reason lists can push the
/// buttons below the fold, exactly as a user would have to scroll to them.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

Future<void> tapContinue(WidgetTester tester) async {
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
}

/// The Delete button in step 2 is an [AppDangerButton] wrapping an
/// [ElevatedButton]; `onPressed == null` is how "disabled" is expressed.
ElevatedButton deleteButtonWidget(WidgetTester tester) => tester.widget<ElevatedButton>(
      find.ancestor(of: find.text('Delete'), matching: find.byType(ElevatedButton)).first,
    );

void main() {
  group('step 1 (confirm)', () {
    testWidgets('shows title, item name, impact list, Cancel/Continue', (tester) async {
      final recorder = _Recorder();
      await pumpFlow(tester, type: DeleteType.building, recorder: recorder, itemName: 'IC Building');

      expect(find.text('Delete building?'), findsOneWidget);
      expect(find.text('IC Building'), findsOneWidget);
      expect(find.text('This will:'), findsOneWidget);
      for (final line in DeleteFlowDefaults.sampleImpactFor(DeleteType.building)) {
        expect(find.text(line), findsOneWidget, reason: 'expected impact bullet "$line"');
      }
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      // Step 2 content must not be visible yet.
      expect(find.text('Why are you deleting it?'), findsNothing);
    });

    testWidgets('Cancel dismisses without calling onCommit/onOptimisticRemove', (tester) async {
      final recorder = _Recorder();
      await pumpFlow(tester, type: DeleteType.device, recorder: recorder);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(recorder.calls, isEmpty);
      expect(recorder.flowResult, isFalse);
      expect(find.text('Delete device?'), findsNothing);
    });

    testWidgets('Continue advances to step 2 with the full reason list', (tester) async {
      final recorder = _Recorder();
      await pumpFlow(tester, type: DeleteType.device, recorder: recorder);
      await tapContinue(tester);

      expect(find.text('Why are you deleting it?'), findsOneWidget);
      for (final reason in DeleteFlowDefaults.reasonsFor(DeleteType.device)) {
        expect(find.text(reason), findsOneWidget, reason: 'expected reason "$reason"');
      }
      expect(find.text('Back'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });
  });

  group('step 2 (reason)', () {
    testWidgets('Delete stays disabled until a reason is tapped', (tester) async {
      final recorder = _Recorder();
      await pumpFlow(tester, type: DeleteType.device, recorder: recorder);
      await tapContinue(tester);

      expect(deleteButtonWidget(tester).onPressed, isNull,
          reason: 'Delete must be disabled before any reason is picked');

      final firstReason = DeleteFlowDefaults.reasonsFor(DeleteType.device).first;
      await tapVisible(tester, find.text(firstReason));
      await tester.pump();

      expect(deleteButtonWidget(tester).onPressed, isNotNull,
          reason: 'Delete must enable once a reason is picked');
    });

    testWidgets('Back returns to step 1', (tester) async {
      final recorder = _Recorder();
      await pumpFlow(tester, type: DeleteType.room, recorder: recorder);
      await tapContinue(tester);

      await tapVisible(tester, find.text('Back'));
      await tester.pumpAndSettle();

      expect(find.text('This will:'), findsOneWidget);
      expect(find.text('Why are you deleting it?'), findsNothing);
    });

    testWidgets('picking "Other" reveals a text field', (tester) async {
      final recorder = _Recorder();
      await pumpFlow(tester, type: DeleteType.schedule, recorder: recorder);
      await tapContinue(tester);

      expect(find.text('Tell us briefly why'), findsNothing);

      await tapVisible(tester, find.text('Other'));
      await tester.pumpAndSettle();

      expect(find.text('Tell us briefly why'), findsOneWidget);
    });

    testWidgets('submitting "Other" with empty text is blocked, onCommit never called', (tester) async {
      final recorder = _Recorder();
      await pumpFlow(tester, type: DeleteType.schedule, recorder: recorder);
      await tapContinue(tester);

      await tapVisible(tester, find.text('Other'));
      await tester.pumpAndSettle();

      // Delete is enabled (a reason -- "Other" -- is picked) but the empty
      // text must still block the submit rather than closing the dialog.
      expect(deleteButtonWidget(tester).onPressed, isNotNull);

      await tapVisible(tester, find.text('Delete'));
      await tester.pumpAndSettle();

      expect(recorder.calls, isEmpty, reason: 'empty "Other" text must not commit');
      expect(find.text('Why are you deleting it?'), findsOneWidget,
          reason: 'dialog must stay open (blocked submit), not close');
    });

    testWidgets('submitting "Other" with text fills otherText through to onCommit', (tester) async {
      final recorder = _Recorder();
      await pumpFlow(
        tester,
        type: DeleteType.schedule,
        recorder: recorder,
        undoWindow: const Duration(milliseconds: 50),
      );
      await tapContinue(tester);

      await tapVisible(tester, find.text('Other'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Testing the flow');
      await tester.pump();

      await tapVisible(tester, find.text('Delete'));
      await tester.pump(); // process pop
      await tester.pump(); // run post-await continuation (onOptimisticRemove, show undo bar)

      expect(recorder.calls, ['optimisticRemove']);

      // Let the (short, test-only) undo window elapse.
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump();
      await tester.pump();

      expect(recorder.calls, ['optimisticRemove', 'commit']);
      expect(recorder.committedReason, 'Other');
      expect(recorder.committedOtherText, 'Testing the flow');
    });
  });

  group('optimistic remove + undo bar', () {
    testWidgets('valid submit fires onOptimisticRemove immediately and shows the Undo bar',
        (tester) async {
      final recorder = _Recorder();
      await pumpFlow(tester, type: DeleteType.account, recorder: recorder);
      await tapContinue(tester);

      final reason = DeleteFlowDefaults.reasonsFor(DeleteType.account).first;
      await tapVisible(tester, find.text(reason));
      await tester.pump();
      await tapVisible(tester, find.text('Delete'));
      await tester.pump(); // process pop
      await tester.pump(); // run post-await continuation

      expect(recorder.calls, ['optimisticRemove']);
      expect(find.text('Undo'), findsOneWidget);
      expect(find.text(DeleteFlowDefaults.successMessageFor(DeleteType.account)), findsOneWidget);
    });

    testWidgets('tapping Undo within the window calls onRestore and never onCommit', (tester) async {
      final recorder = _Recorder();
      await pumpFlow(
        tester,
        type: DeleteType.notifications,
        recorder: recorder,
        undoWindow: const Duration(milliseconds: 200),
      );
      await tapContinue(tester);

      final reason = DeleteFlowDefaults.reasonsFor(DeleteType.notifications).first;
      await tapVisible(tester, find.text(reason));
      await tester.pump();
      await tapVisible(tester, find.text('Delete'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Undo'), findsOneWidget);

      // Well within the 200ms window.
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump();

      expect(recorder.calls, ['optimisticRemove', 'restore']);
      expect(recorder.flowResult, isFalse);

      // Advance well past where the window would have originally elapsed --
      // onCommit must never fire once Undo has already resolved the flow.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(recorder.calls, ['optimisticRemove', 'restore']);
      expect(find.text('Restored'), findsOneWidget);

      // The "Restored" success toast (TopToast.success) schedules its own
      // real dart:async Timers (2s visible + 240ms fade) independent of the
      // delete flow. Drain them before the test ends -- otherwise the
      // framework's `!timersPending` invariant fails even though the delete
      // flow itself behaved correctly.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('letting the window elapse calls onCommit with the right reason and not onRestore',
        (tester) async {
      final recorder = _Recorder();
      await pumpFlow(
        tester,
        type: DeleteType.building,
        recorder: recorder,
        undoWindow: const Duration(milliseconds: 50),
      );
      await tapContinue(tester);

      final reason = DeleteFlowDefaults.reasonsFor(DeleteType.building)[2]; // not "Other"
      await tapVisible(tester, find.text(reason));
      await tester.pump();
      await tapVisible(tester, find.text('Delete'));
      await tester.pump();
      await tester.pump();

      expect(recorder.calls, ['optimisticRemove']);

      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump();
      await tester.pump();

      expect(recorder.calls, ['optimisticRemove', 'commit']);
      expect(recorder.committedReason, reason);
      expect(recorder.committedOtherText, isNull);
      expect(recorder.flowResult, isTrue);
    });
  });

  group('DeleteFlowDefaults.reasonsFor', () {
    test('every DeleteType reason list ends with "Other"', () {
      for (final type in DeleteType.values) {
        final reasons = DeleteFlowDefaults.reasonsFor(type);
        expect(reasons.last, 'Other', reason: '$type must end with "Other"');
        expect(reasons.length, inInclusiveRange(5, 7));
      }
    });

    // Exact wording regression guard (handoff §7.2) -- catches silent copy
    // drift even though the list still technically "ends with Other".
    test('building: exact 7 reasons match handoff §7.2', () {
      expect(DeleteFlowDefaults.reasonsFor(DeleteType.building), [
        'Building is no longer in use',
        'Merged with another building',
        'Added by mistake or a duplicate',
        'Will be re-added with a new code or name',
        'Devices moved to another building',
        'Energy monitoring no longer needed',
        'Other',
      ]);
    });

    test('room: exact 6 reasons match handoff §7.2', () {
      expect(DeleteFlowDefaults.reasonsFor(DeleteType.room), [
        'Room was converted or closed',
        'Merged with another room',
        'Added by mistake or a duplicate',
        'Devices moved to another room',
        'Room is under renovation',
        'Other',
      ]);
    });
  });
}
