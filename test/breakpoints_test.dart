import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/theme/breakpoints.dart';

/// Boundary coverage for the four responsive bands (handoff §10.1):
/// < 360 compact, 360-599 standard, 600-899 tablet, >= 900 web.
void main() {
  test('359 is compact, 360 is not', () {
    expect(Breakpoints.isCompact(359), isTrue);
    expect(Breakpoints.isCompact(360), isFalse);
  });

  test('360 and 599 are standard; 359 and 600 are not', () {
    expect(Breakpoints.isStandard(360), isTrue);
    expect(Breakpoints.isStandard(599), isTrue);
    expect(Breakpoints.isStandard(359), isFalse);
    expect(Breakpoints.isStandard(600), isFalse);
  });

  test('600 and 899 are tablet; 599 and 900 are not', () {
    expect(Breakpoints.isTablet(600), isTrue);
    expect(Breakpoints.isTablet(899), isTrue);
    expect(Breakpoints.isTablet(599), isFalse);
    expect(Breakpoints.isTablet(900), isFalse);
  });

  test('900 is web; 899 is not', () {
    expect(Breakpoints.isWeb(900), isTrue);
    expect(Breakpoints.isWeb(899), isFalse);
  });

  test('every width matches exactly one band (no gap, no overlap)', () {
    const widths = [0.0, 1, 100, 359, 360, 361, 599, 600, 601, 899, 900, 901, 5000];
    for (final w in widths) {
      final matches = [
        Breakpoints.isCompact(w.toDouble()),
        Breakpoints.isStandard(w.toDouble()),
        Breakpoints.isTablet(w.toDouble()),
        Breakpoints.isWeb(w.toDouble()),
      ].where((matched) => matched).length;
      expect(matches, 1, reason: 'width $w should match exactly one band, matched $matches');
    }
  });

  test('a negative width still classifies as compact rather than throwing', () {
    expect(Breakpoints.isCompact(-10), isTrue);
    expect(Breakpoints.isStandard(-10), isFalse);
  });
}
