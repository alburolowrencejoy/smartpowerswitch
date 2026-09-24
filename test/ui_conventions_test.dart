import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/theme/app_fonts.dart';
import 'package:smart_power_switch/widgets/app_text_field.dart';

/// App-wide UI rules that are easy to break by accident in new code:
///  * every text input shakes on error, so inputs must go through
///    AppTextField / AppTextFormField (lib/widgets/app_text_field.dart);
///  * one typeface everywhere, so fonts must come from AppFonts.family.
void main() {
  final sources = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  String rel(File f) => f.path.replaceAll('\\', '/');

  List<String> offenders(RegExp pattern, {Set<String> allow = const {}}) => [
        for (final f in sources)
          if (!allow.contains(rel(f)))
            for (final (i, line) in f.readAsLinesSync().indexed)
              if (pattern.hasMatch(line)) '${rel(f)}:${i + 1}: ${line.trim()}',
      ];

  test('text inputs use AppTextField / AppTextFormField', () {
    final found = offenders(
      RegExp(r'(^|[^A-Za-z_])(TextField|TextFormField)\('),
      allow: {'lib/widgets/app_text_field.dart'},
    );
    expect(found, isEmpty,
        reason: 'Use AppTextField / AppTextFormField so the field shakes on '
            'error:\n${found.join('\n')}');
  });

  test('fonts come from AppFonts.family only', () {
    final literal = offenders(RegExp(r'''fontFamily:\s*['"]'''));
    final googleFonts = offenders(RegExp(r'google_fonts|GoogleFonts\.'),
        allow: {'lib/theme/app_fonts.dart'});
    expect([...literal, ...googleFonts], isEmpty,
        reason: 'Use fontFamily: AppFonts.family:\n'
            '${[...literal, ...googleFonts].join('\n')}');
  });

  testWidgets('AppTextField shakes when its error appears', (tester) async {
    Widget field(String? error, {int trigger = 0}) => MaterialApp(
          theme: ThemeData(fontFamily: AppFonts.family),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: AppTextField(
                  shakeTrigger: trigger,
                  decoration: InputDecoration(errorText: error),
                ),
              ),
            ),
          ),
        );

    double dx() => tester
        .widget<Transform>(find
            .ancestor(
                of: find.byType(TextField), matching: find.byType(Transform))
            .first)
        .transform
        .getTranslation()
        .x;

    await tester.pumpWidget(field(null));
    expect(dx(), 0);

    await tester.pumpWidget(field('Required'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(dx(), isNot(0), reason: 'error appeared -> shake');
    await tester.pumpAndSettle();
    expect(dx(), closeTo(0, 0.01));

    // Same error again after a failed submit -> shake again.
    await tester.pumpWidget(field('Required', trigger: 1));
    await tester.pump(const Duration(milliseconds: 30));
    expect(dx(), isNot(0));
    await tester.pumpAndSettle();
  });

  testWidgets('AppTextFormField shakes when validation fails', (tester) async {
    final formKey = GlobalKey<FormState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Form(
          key: formKey,
          child: AppTextFormField(
            validator: (v) => (v ?? '').isEmpty ? 'Required' : null,
          ),
        ),
      ),
    ));

    double dx() => tester
        .widget<Transform>(find
            .ancestor(
                of: find.byType(TextFormField),
                matching: find.byType(Transform))
            .first)
        .transform
        .getTranslation()
        .x;

    expect(formKey.currentState!.validate(), isFalse);
    await tester.pump(); // runs the post-frame callback that starts the shake
    await tester.pump(); // first animation tick (elapsed 0)
    await tester.pump(const Duration(milliseconds: 30));
    expect(dx(), isNot(0));
    await tester.pumpAndSettle();
  });
}
