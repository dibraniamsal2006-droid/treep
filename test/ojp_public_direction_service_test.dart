import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:treep/models/trip_candidate.dart';
import 'package:treep/services/ojp_public_direction_service.dart';
import 'package:treep/services/transport_service.dart';

void main() {
  group('OJP public-direction exact join', () {
    test('exact unique identity replaces weak GTFS direction', () async {
      final client = _FakeOjpClient([
        const OjpStopEventRecord(
          journeyRef: 'ch:1:sjyid:100060:SKI-429',
          operatingDayRef: '2026-08-28',
          destinationText: 'Solothurn',
        ),
      ]);
      final service = _service(client);

      final result = await service.enrichPublicDirections([_candidate()]);

      expect(client.calls, 1);
      expect(result.single.publicDirection, 'Solothurn');
      expect(result.single.directionSource, DirectionSource.ojpStopEvent);
    });

    test('one request enriches several exact candidates', () async {
      final client = _FakeOjpClient([
        const OjpStopEventRecord(
          journeyRef: 'ch:1:sjyid:100060:SKI-429',
          operatingDayRef: '2026-08-28',
          destinationText: 'Solothurn',
        ),
        const OjpStopEventRecord(
          journeyRef: 'ch:1:sjyid:100060:SKI-430',
          operatingDayRef: '2026-08-28',
          destinationText: 'Langenthal',
        ),
      ]);
      final service = _service(client);

      final result = await service.enrichPublicDirections([
        _candidate(),
        _candidate(originalTripId: 'ch:1:sjyid:100060:SKI-430'),
      ]);

      expect(client.calls, 1);
      expect(result.map((candidate) => candidate.publicDirection), [
        'Solothurn',
        'Langenthal',
      ]);
    });

    test('wrong SJYID does not enrich', () async {
      final result = await _service(
        _FakeOjpClient([
          const OjpStopEventRecord(
            journeyRef: 'ch:1:sjyid:100060:OTHER',
            operatingDayRef: '2026-08-28',
            destinationText: 'Solothurn',
          ),
        ]),
      ).enrichPublicDirections([_candidate()]);

      _expectWeakFallback(result.single);
    });

    test('wrong operating day does not enrich', () async {
      final result = await _service(
        _FakeOjpClient([
          const OjpStopEventRecord(
            journeyRef: 'ch:1:sjyid:100060:SKI-429',
            operatingDayRef: '2026-08-29',
            destinationText: 'Solothurn',
          ),
        ]),
      ).enrichPublicDirections([_candidate()]);

      _expectWeakFallback(result.single);
    });

    test('blank DestinationText does not enrich', () async {
      final result = await _service(
        _FakeOjpClient([
          const OjpStopEventRecord(
            journeyRef: 'ch:1:sjyid:100060:SKI-429',
            operatingDayRef: '2026-08-28',
            destinationText: '   ',
          ),
        ]),
      ).enrichPublicDirections([_candidate()]);

      _expectWeakFallback(result.single);
    });

    test('conflicting duplicate exact records are rejected', () async {
      final result = await _service(
        _FakeOjpClient([
          const OjpStopEventRecord(
            journeyRef: 'ch:1:sjyid:100060:SKI-429',
            operatingDayRef: '2026-08-28',
            destinationText: 'Solothurn',
          ),
          const OjpStopEventRecord(
            journeyRef: 'ch:1:sjyid:100060:SKI-429',
            operatingDayRef: '2026-08-28',
            destinationText: 'Oensingen',
          ),
        ]),
      ).enrichPublicDirections([_candidate()]);

      _expectWeakFallback(result.single);
    });

    test('timeout leaves candidates usable', () async {
      final result = await _service(
        _ThrowingOjpClient(TimeoutException('test timeout')),
      ).enrichPublicDirections([_candidate()]);

      _expectWeakFallback(result.single);
    });

    test('HTTP error leaves candidates usable', () async {
      final client = OjpStopEventClient(
        httpPost: (uri, {headers, body}) async => http.Response('', 429),
      );
      final result = await _service(
        client,
      ).enrichPublicDirections([_candidate()]);

      _expectWeakFallback(result.single);
    });

    test('malformed XML leaves candidates usable', () async {
      final client = OjpStopEventClient(
        httpPost: (uri, {headers, body}) async => http.Response('<broken', 200),
      );
      final result = await _service(
        client,
      ).enrichPublicDirections([_candidate()]);

      _expectWeakFallback(result.single);
    });

    test(
      'missing OJP_API_KEY leaves candidates usable without a call',
      () async {
        final client = _FakeOjpClient(const []);
        final service = TransportService(
          ojpClient: client,
          ojpApiKeyProvider: () => '',
        );

        final result = await service.enrichPublicDirections([_candidate()]);

        expect(client.calls, 0);
        _expectWeakFallback(result.single);
      },
    );
  });

  test('StopEvent parser scopes direction to each service', () {
    const xml = '''
<OJP xmlns="http://www.vdv.de/ojp" xmlns:siri="http://www.siri.org.uk/siri">
  <StopEventResult>
    <StopEvent>
      <Service>
        <siri:JourneyRef>journey-a</siri:JourneyRef>
        <OperatingDayRef>2026-08-28</OperatingDayRef>
        <DestinationText><Text>Solothurn</Text></DestinationText>
      </Service>
    </StopEvent>
  </StopEventResult>
</OJP>
''';

    final records = OjpStopEventClient.parseStopEventRecords(xml);

    expect(records, hasLength(1));
    expect(records.single.journeyRef, 'journey-a');
    expect(records.single.operatingDayRef, '2026-08-28');
    expect(records.single.destinationText, 'Solothurn');
  });
}

TransportService _service(OjpPublicDirectionClient client) {
  return TransportService(
    ojpClient: client,
    ojpApiKeyProvider: () => 'test-key',
  );
}

TripCandidate _candidate({
  String originalTripId = 'ch:1:sjyid:100060:SKI-429',
}) {
  return TripCandidate(
    tripId: '.ojp-test',
    originalTripId: originalTripId,
    routeId: 'S11',
    startDate: '20260828',
    startTime: '10:00:00',
    stopId: '8500212',
    etaLocal: DateTime(2026, 8, 28, 10),
    delaySeconds: 0,
    displayTrain: 'S11',
    vehicleLabel: 'Train',
    destinationMatched: true,
    upcomingStops: const [],
    terminalStopId: 'Oensingen',
    terminalStopIdCanon: '',
  );
}

void _expectWeakFallback(TripCandidate candidate) {
  expect(candidate.publicDirection, 'Oensingen');
  expect(candidate.directionSource, DirectionSource.gtfsRealtimeLastStop);
}

class _FakeOjpClient implements OjpPublicDirectionClient {
  _FakeOjpClient(this.records);

  final List<OjpStopEventRecord> records;
  int calls = 0;

  @override
  Future<List<OjpStopEventRecord>> fetchStopEvents({
    required String apiKey,
    required String stopPointRef,
    required DateTime from,
    required int numberOfResults,
  }) async {
    calls++;
    return records;
  }
}

class _ThrowingOjpClient implements OjpPublicDirectionClient {
  _ThrowingOjpClient(this.error);

  final Object error;

  @override
  Future<List<OjpStopEventRecord>> fetchStopEvents({
    required String apiKey,
    required String stopPointRef,
    required DateTime from,
    required int numberOfResults,
  }) async {
    throw error;
  }
}
