import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/services/meter_review.dart';

void main() {
  group('MeterReview.parse', () {
    test('a paused (frozen) meter needs a review', () {
      final r = MeterReview.parse({
        'lastAcceptedKwh': 1.0,
        'flag': {'reason': 'spike', 'observedKwh': 9.5, 'at': 1000, 'frozen': true},
      });
      expect(r, isNotNull);
      expect(r!.isSpike, isTrue);
      expect(r.observedKwh, 9.5);
      expect(r.at, 1000);
      expect(r.answered, isFalse);
    });

    test('an answer waiting for the next reading is marked answered', () {
      final r = MeterReview.parse({
        'flag': {'reason': 'decrease', 'at': 1, 'frozen': true},
        'resolve': 'accept',
      });
      expect(r!.answered, isTrue);
      expect(r.isSpike, isFalse);
    });

    test('nothing to review: normal, invalid-only flag, or no data', () {
      expect(MeterReview.parse({'lastAcceptedKwh': 1.0}), isNull);
      expect(
          MeterReview.parse({
            'flag': {'reason': 'invalid', 'frozen': false}
          }),
          isNull);
      expect(MeterReview.parse(null), isNull);
      expect(MeterReview.parse('x'), isNull);
    });
  });
}
