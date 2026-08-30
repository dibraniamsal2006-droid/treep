import 'package:flutter_test/flutter_test.dart';
import 'package:treep/models/trip_candidate.dart';
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

  group('public service presentation labels', () {
    test('keeps validated public line labels', () {
      expect(
        MatchingService.publicServicePresentationLabel(
          publicLine: 'S20',
          modeLabel: 'Train',
        ),
        'S20',
      );
      expect(
        MatchingService.publicServicePresentationLabel(
          publicLine: '129',
          modeLabel: 'Bus',
        ),
        '129',
      );
      expect(
        MatchingService.publicServicePresentationLabel(
          publicLine: 'IC 5',
          modeLabel: 'Train',
        ),
        'IC 5',
      );
    });

    test('replaces technical identifiers with an authoritative mode label', () {
      expect(
        MatchingService.publicServicePresentationLabel(
          publicLine: 'ojp:96260:0:H:j26',
          modeLabel: 'Bus',
        ),
        'Bus',
      );
      expect(
        MatchingService.publicServicePresentationLabel(
          publicLine: '.ojp-91-11-M.1.TA.477.j26',
          modeLabel: 'Train',
        ),
        'Train',
      );
    });

    test('omits an invalid identifier when no trusted mode exists', () {
      expect(
        MatchingService.publicServicePresentationLabel(
          publicLine: 'ch:1:sjyid:100060:SKI-429',
          modeLabel: 'unknown',
        ),
        isEmpty,
      );
    });

    test('recognizes internal OJP and Swiss identity namespaces', () {
      expect(
        MatchingService.looksTechnicalIdentifier('ojp:96260:0:H:j26'),
        isTrue,
      );
      expect(
        MatchingService.looksTechnicalIdentifier('ch:1:sjyid:100060:SKI-429'),
        isTrue,
      );
      expect(MatchingService.looksTechnicalIdentifier('S20'), isFalse);
      expect(
        MatchingService.looksTechnicalIdentifier('Oensingen, Bahnhof Süd'),
        isFalse,
      );
    });
  });

  test('terminal label and direction key consume corrected terminal data', () {
    final candidate = TripCandidate(
      tripId: 's22-inbound',
      routeId: 'S22',
      startDate: '20260829',
      startTime: '08:02:00',
      stopId: '8500212',
      etaLocal: DateTime(2026, 8, 29, 8, 10),
      delaySeconds: 0,
      displayTrain: 'S22',
      vehicleLabel: 'Train',
      destinationMatched: true,
      upcomingStops: const [],
      terminalStopId: '8500212',
      terminalStopIdCanon: '8500212',
    );

    expect(
      MatchingService.terminalLabelFor(
        candidate,
        stopLabel: (id) => id == '8500212' ? 'Oensingen' : id,
        normalizeStopId: (raw) => RegExp(r'^\d{7}$').hasMatch(raw) ? raw : null,
      ),
      'Oensingen',
    );
    expect(
      MatchingService.directionKeyFor(
        candidate,
        normalizeStopId: (raw) => RegExp(r'^\d{7}$').hasMatch(raw) ? raw : null,
      ),
      '8500212',
    );
  });
}
