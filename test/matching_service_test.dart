import 'package:flutter_test/flutter_test.dart';
import 'package:treep/services/matching_service.dart';

void main() {
  group('train query matching', () {
    bool matches(String query, String label) {
      return MatchingService.matchesTrainQuery(
        MatchingService.normalizeTrainToken(query),
        MatchingService.normalizeTrainToken(label),
      );
    }

    test('matches exact public line identities', () {
      expect(matches('S20', 'S20'), isTrue);
      expect(matches('S3', 'S3'), isTrue);
      expect(matches('IR55', 'IR55'), isTrue);
      expect(matches('IR55', 'IR 55'), isTrue);
      expect(matches('IC5', 'IC5'), isTrue);
      expect(matches('IC5', 'IC 5'), isTrue);
    });

    test('matches a public line followed by a separate train number', () {
      expect(matches('IR55', 'IR55 2317'), isTrue);
      expect(
        MatchingService.matchesTrainQueryTokenAware('IR55', ['IR55 2317']),
        isTrue,
      );
    });

    test('preserves letters-only category matching', () {
      expect(matches('EC', 'EC'), isTrue);
      expect(matches('EC', 'EC7'), isTrue);
    });

    test('does not match colliding public line prefixes', () {
      expect(matches('S3', 'S33'), isFalse);
      expect(matches('S33', 'S3'), isFalse);
      expect(matches('S2', 'S20'), isFalse);
      expect(matches('IR55', 'IR15'), isFalse);
      expect(matches('IC5', 'IC51'), isFalse);
      expect(matches('IR5', 'IR55 2317'), isFalse);
      expect(matches('S3', 'S33 2317'), isFalse);
    });
  });
}
