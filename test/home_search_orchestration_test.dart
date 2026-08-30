import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:treep/models/trip_candidate.dart';
import 'package:treep/screens/home_screen.dart';
import 'package:treep/services/transport_service.dart';

void main() {
  group('local-line direction enrichment', () {
    test('confident correspondence enriches only direction metadata', () {
      final eta = DateTime(2026, 8, 27, 12);
      final upcoming = <StopEta>[
        StopEta(
          stopIdRaw: '8500207',
          stopIdCanon: '8500207',
          etaLocal: eta,
          delaySeconds: 90,
        ),
      ];
      final gtfs = _candidate(
        tripId: 'gtfs-trip',
        line: 'S11',
        eta: eta,
        delaySeconds: 90,
        direction: 'Oensingen',
        upcomingStops: upcoming,
      );
      final stationboard = _candidate(
        tripId: 'fallback-trip',
        line: 'S11',
        eta: eta.add(const Duration(seconds: 30)),
        delaySeconds: 0,
        direction: 'Solothurn',
      );

      final result = _enrich([gtfs], [stationboard], 'S11');
      final enriched = result.candidates.single;

      expect(result.enrichedCount, 1);
      expect(enriched.terminalStopId, 'Solothurn');
      expect(enriched.tripId, gtfs.tripId);
      expect(enriched.routeId, gtfs.routeId);
      expect(enriched.startDate, gtfs.startDate);
      expect(enriched.startTime, gtfs.startTime);
      expect(enriched.stopId, gtfs.stopId);
      expect(enriched.etaLocal, gtfs.etaLocal);
      expect(enriched.delaySeconds, gtfs.delaySeconds);
      expect(enriched.displayTrain, gtfs.displayTrain);
      expect(enriched.upcomingStops, same(upcoming));
      expect(enriched.directionSource, DirectionSource.stationboard);
    });

    test('ambiguous stationboard correspondence preserves GTFS direction', () {
      final eta = DateTime(2026, 8, 27, 12);
      final gtfs = _candidate(
        tripId: 'gtfs-trip',
        line: 'S11',
        eta: eta,
        direction: 'Oensingen',
      );
      final first = _candidate(
        tripId: 'fallback-1',
        line: 'S11',
        eta: eta.add(const Duration(seconds: 20)),
        direction: 'Solothurn',
      );
      final second = _candidate(
        tripId: 'fallback-2',
        line: 'S11',
        eta: eta.add(const Duration(seconds: 50)),
        direction: 'Langenthal',
      );

      final result = _enrich([gtfs], [first, second], 'S11');

      expect(result.enrichedCount, 0);
      expect(result.candidates.single, same(gtfs));
      expect(
        result.decisions.single.reason,
        'ambiguous-stationboard-counterpart',
      );
    });

    test('already-correct S20 direction is not rewritten', () {
      final eta = DateTime(2026, 8, 27, 12);
      final gtfs = _candidate(
        tripId: 's20-gtfs',
        line: 'S20',
        eta: eta,
        direction: 'Oensingen',
      );
      final stationboard = _candidate(
        tripId: 's20-fallback',
        line: 'S20',
        eta: eta.add(const Duration(seconds: 15)),
        direction: 'Oensingen',
      );

      final result = _enrich([gtfs], [stationboard], 'S20');

      expect(result.enrichedCount, 0);
      expect(result.candidates.single.publicDirection, 'Oensingen');
      expect(result.decisions.single.reason, 'direction-already-correct');
      expect(
        result.candidates.single.directionSource,
        DirectionSource.stationboard,
      );
    });

    test('stationboard cannot downgrade an OJP public direction', () {
      final eta = DateTime(2026, 8, 27, 12);
      final ojp = _candidate(
        tripId: 'ojp-enriched',
        line: 'S11',
        eta: eta,
        direction: 'Solothurn',
        directionSource: DirectionSource.ojpStopEvent,
      );
      final stationboard = _candidate(
        tripId: 'fallback-trip',
        line: 'S11',
        eta: eta.add(const Duration(seconds: 20)),
        direction: 'Oensingen',
      );

      final result = _enrich([ojp], [stationboard], 'S11');

      expect(result.candidates.single.publicDirection, 'Solothurn');
      expect(
        result.candidates.single.directionSource,
        DirectionSource.ojpStopEvent,
      );
    });
  });

  test('destination validation depends on the selected candidate', () {
    final unverified = _candidate(
      tripId: 'unverified',
      line: 'S20',
      eta: DateTime(2026, 8, 27, 12),
      direction: 'Oensingen',
      destinationMatched: false,
    );
    final verified = _candidate(
      tripId: 'verified',
      line: 'S20',
      eta: DateTime(2026, 8, 27, 12),
      direction: 'Oensingen',
    );

    expect(candidateNeedsDestinationConfirmation(unverified), isTrue);
    expect(candidateNeedsDestinationConfirmation(verified), isFalse);
  });

  testWidgets('destination-name rescue runs before broad train-only fallback', (
    tester,
  ) async {
    final eta = DateTime.now().add(const Duration(minutes: 30));
    final service = _FakeSearchTransportService(
      strictCandidates: const [],
      nameRescueCandidates: [
        _candidate(
          tripId: 'name-1',
          line: 'IR55',
          eta: eta,
          direction: 'Zürich HB',
        ),
        _candidate(
          tripId: 'name-2',
          line: 'IR55',
          eta: eta.add(const Duration(minutes: 10)),
          direction: 'Biel/Bienne',
        ),
      ],
    );

    await _startSearch(
      tester,
      service,
      train: 'IR55',
      destination: 'Solothurn',
    );

    expect(service.resolveCalls, 1);
    expect(service.calls, containsAllInOrder(['strict-gtfs', 'name-rescue']));
    expect(service.calls, isNot(contains('stationboard')));
    expect(service.calls, isNot(contains('broad-gtfs')));
    expect(find.text('Direction Zürich HB'), findsOneWidget);
    expect(find.text('Direction Biel/Bienne'), findsOneWidget);

    await _dismissBottomSheet(tester);
    _expectCancelledWithoutAlarm(tester);
  });

  testWidgets(
    'local-line name rescue preserves candidate-specific opposite directions',
    (tester) async {
      final firstEta = DateTime.now().add(const Duration(minutes: 30));
      final secondEta = firstEta.add(const Duration(minutes: 12));
      final service = _FakeSearchTransportService(
        strictCandidates: const [],
        nameRescueCandidates: [
          _candidate(
            tripId: 'gtfs-towards-first-terminal',
            line: 'S11',
            eta: firstEta,
            direction: 'Oensingen',
          ),
          _candidate(
            tripId: 'gtfs-towards-second-terminal',
            line: 'S11',
            eta: secondEta,
            direction: 'Oensingen',
          ),
        ],
        stationboardCandidates: [
          _candidate(
            tripId: 'public-towards-first-terminal',
            line: 'S11',
            eta: firstEta.add(const Duration(seconds: 20)),
            direction: 'Solothurn',
          ),
          _candidate(
            tripId: 'public-towards-second-terminal',
            line: 'S11',
            eta: secondEta.add(const Duration(seconds: 25)),
            direction: 'Oensingen',
          ),
        ],
      );

      await _startSearch(
        tester,
        service,
        train: 'S11',
        destination: 'Oberbipp',
      );

      expect(
        service.calls,
        containsAllInOrder(['strict-gtfs', 'name-rescue', 'stationboard']),
      );
      expect(service.stationboardTrainQueries, contains('S11'));
      expect(find.text('Direction Solothurn'), findsOneWidget);
      expect(find.text('Direction Oensingen'), findsOneWidget);

      await _dismissBottomSheet(tester);
      _expectCancelledWithoutAlarm(tester);
    },
  );

  testWidgets('dismissing direction picker cancels tracking', (tester) async {
    final eta = DateTime.now().add(const Duration(minutes: 30));
    final service = _FakeSearchTransportService(
      strictCandidates: [
        _candidate(
          tripId: 'strict-1',
          line: 'IR55',
          eta: eta,
          direction: 'Zürich HB',
        ),
        _candidate(
          tripId: 'strict-2',
          line: 'IR55',
          eta: eta.add(const Duration(minutes: 10)),
          direction: 'Biel/Bienne',
        ),
      ],
    );

    await _startSearch(
      tester,
      service,
      train: 'IR55',
      destination: 'Solothurn',
    );
    await _dismissBottomSheet(tester);

    _expectCancelledWithoutAlarm(tester);
  });

  testWidgets('dismissing trip picker cancels tracking', (tester) async {
    final eta = DateTime.now().add(const Duration(minutes: 30));
    final service = _FakeSearchTransportService(
      strictCandidates: [
        _candidate(
          tripId: 'strict-1',
          line: 'IR55',
          eta: eta,
          direction: 'Zürich HB',
        ),
        _candidate(
          tripId: 'strict-2',
          line: 'IR55',
          eta: eta.add(const Duration(minutes: 10)),
          direction: 'Zürich HB',
        ),
      ],
    );

    await _startSearch(
      tester,
      service,
      train: 'IR55',
      destination: 'Solothurn',
    );
    await _dismissBottomSheet(tester);

    _expectCancelledWithoutAlarm(tester);
  });
}

LocalDirectionEnrichmentResult _enrich(
  List<TripCandidate> gtfs,
  List<TripCandidate> stationboard,
  String query,
) {
  return enrichLocalLineDirections(
    gtfsCandidates: gtfs,
    stationboardCandidates: stationboard,
    trainQuery: query,
    stopIdsMatch: (a, b) => a == b,
    directionLabel: (candidate) => candidate.terminalStopId,
  );
}

TripCandidate _candidate({
  required String tripId,
  required String line,
  required DateTime eta,
  required String direction,
  int delaySeconds = 0,
  bool destinationMatched = true,
  List<StopEta> upcomingStops = const [],
  DirectionSource directionSource = DirectionSource.gtfsRealtimeLastStop,
}) {
  return TripCandidate(
    tripId: tripId,
    routeId: line,
    startDate: '20260827',
    startTime: '12:00:00',
    stopId: '8500207',
    etaLocal: eta,
    delaySeconds: delaySeconds,
    displayTrain: line,
    vehicleLabel: 'Train',
    destinationMatched: destinationMatched,
    upcomingStops: upcomingStops,
    terminalStopId: direction,
    terminalStopIdCanon: '',
    directionSource: directionSource,
  );
}

Future<void> _startSearch(
  WidgetTester tester,
  TransportService service, {
  required String train,
  required String destination,
}) async {
  await tester.pumpWidget(
    MaterialApp(home: TreepHome(transportService: service)),
  );
  await tester.enterText(find.byType(TextField).at(0), train);
  await tester.enterText(find.byType(TextField).at(1), destination);
  await tester.ensureVisible(find.byKey(const Key('choose-journey-button')));
  await tester.tap(find.byKey(const Key('choose-journey-button')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void _expectCancelledWithoutAlarm(WidgetTester tester) {
  expect(
    find.text('Selection cancelled. No tracking was started.'),
    findsOneWidget,
  );
  expect(find.text('Active journey'), findsNothing);
  expect(find.byKey(const Key('alarm-confirmation')), findsNothing);
}

Future<void> _dismissBottomSheet(WidgetTester tester) async {
  final sheet = find.byType(BottomSheet);
  expect(sheet, findsOneWidget);
  Navigator.of(tester.element(sheet)).pop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

class _FakeSearchTransportService extends TransportService {
  _FakeSearchTransportService({
    required this.strictCandidates,
    this.nameRescueCandidates = const [],
    this.stationboardCandidates = const [],
  });

  final List<TripCandidate> strictCandidates;
  final List<TripCandidate> nameRescueCandidates;
  final List<TripCandidate> stationboardCandidates;
  final List<String> calls = [];
  final List<String> stationboardTrainQueries = [];
  int resolveCalls = 0;

  @override
  Future<List<String>> resolveStopIdsFromName(String query) async {
    resolveCalls++;
    return const ['8500207'];
  }

  @override
  Future<FeedMessage> fetchGtfsRtFeed() async => FeedMessage();

  @override
  List<TripCandidate> findCandidates(
    FeedMessage feed,
    String trainQuery,
    String destQuery, {
    required bool requireDestinationMatch,
  }) {
    if (requireDestinationMatch) {
      calls.add('strict-gtfs');
      return strictCandidates;
    }
    calls.add('broad-gtfs');
    return const [];
  }

  @override
  Future<List<TripCandidate>> findCandidatesByTrainAndDestinationName(
    FeedMessage feed,
    String trainQuery,
    String destName,
  ) async {
    calls.add('name-rescue');
    return nameRescueCandidates;
  }

  @override
  Future<List<TripCandidate>> fallbackArrivalsAtDestination({
    required String trainQuery,
    required List<String> destStopIdCanons,
    String? destNameQuery,
    int limit = 100,
    bool resolveDestinationName = true,
  }) async {
    calls.add('stationboard');
    stationboardTrainQueries.add(trainQuery);
    return stationboardCandidates;
  }

  @override
  Future<void> ensureStopName(String canonStopId) async {}

  @override
  Future<void> warmStopNamesForCandidates(
    List<TripCandidate> candidates,
  ) async {}

  @override
  String stopLabel(String rawStopId) => rawStopId;

  @override
  bool stopIdMatches(String stopCanon, String destCanon) {
    return stopCanon == destCanon;
  }
}
