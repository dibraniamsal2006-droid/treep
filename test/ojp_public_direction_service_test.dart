import 'dart:async';
import 'dart:convert';

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
    expect(records.single.hasPreviousServicedCall, isFalse);
  });

  test('StopEvent parser exposes an exact serviced PreviousCall as proof', () {
    const xml = '''
<OJP xmlns="http://www.vdv.de/ojp" xmlns:siri="http://www.siri.org.uk/siri">
  <StopEventResult>
    <StopEvent>
      <PreviousCall>
        <CallAtStop>
          <siri:StopPointRef>ch:1:sloid:8500207</siri:StopPointRef>
          <NotServicedStop>false</NotServicedStop>
        </CallAtStop>
      </PreviousCall>
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
    expect(records.single.hasPreviousServicedCall, isTrue);
  });

  test('a skipped OJP PreviousCall is not prior-call proof', () {
    const xml = '''
<OJP xmlns="http://www.vdv.de/ojp" xmlns:siri="http://www.siri.org.uk/siri">
  <StopEventResult>
    <StopEvent>
      <PreviousCall>
        <CallAtStop><NotServicedStop>true</NotServicedStop></CallAtStop>
      </PreviousCall>
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

    expect(records.single.hasPreviousServicedCall, isFalse);
  });

  test('StopEvent request enables PreviousCall in the same request', () async {
    Object? sentBody;
    var calls = 0;
    final client = OjpStopEventClient(
      httpPost: (uri, {headers, body}) async {
        calls++;
        sentBody = body;
        return http.Response('<OJP/>', 200);
      },
    );

    await client.fetchStopEvents(
      apiKey: 'test-key',
      stopPointRef: 'ch:1:sloid:8500212',
      from: DateTime.utc(2026, 8, 28, 10),
      numberOfResults: 20,
    );

    expect(calls, 1);
    expect(
      sentBody.toString(),
      contains('<IncludePreviousCalls>true</IncludePreviousCalls>'),
    );
  });

  test('StopEvent parser exposes authoritative arrival candidate fields', () {
    const xml = '''
<OJP xmlns="http://www.vdv.de/ojp" xmlns:siri="http://www.siri.org.uk/siri">
  <StopEventResult><StopEvent>
    <PreviousCall><CallAtStop><NotServicedStop>false</NotServicedStop></CallAtStop></PreviousCall>
    <ThisCall><CallAtStop>
      <siri:StopPointRef>ch:1:sloid:212:0:880532</siri:StopPointRef>
      <StopPointName><Text>Oensingen</Text></StopPointName>
      <ServiceArrival>
        <TimetabledTime>2026-08-29T16:40:00Z</TimetabledTime>
        <EstimatedTime>2026-08-29T16:44:00Z</EstimatedTime>
      </ServiceArrival>
    </CallAtStop></ThisCall>
    <Service>
      <OperatingDayRef>2026-08-29</OperatingDayRef>
      <JourneyRef>ch:1:sjyid:test</JourneyRef>
      <PublishedServiceName><Text>S22</Text></PublishedServiceName>
      <Mode><PtMode>rail</PtMode></Mode>
      <DestinationText><Text>Oensingen</Text></DestinationText>
    </Service>
  </StopEvent></StopEventResult>
</OJP>
''';

    final record = OjpStopEventClient.parseStopEventRecords(xml).single;

    expect(record.stopPointRef, 'ch:1:sloid:212:0:880532');
    expect(record.stopPointName, 'Oensingen');
    expect(record.publicLineName, 'S22');
    expect(record.transportMode, 'rail');
    expect(record.scheduledArrival, DateTime.utc(2026, 8, 29, 16, 40));
    expect(record.estimatedArrival, DateTime.utc(2026, 8, 29, 16, 44));
    expect(record.hasPreviousServicedCall, isTrue);
    expect(record.isDestinationServiced, isTrue);
  });

  test('Location parser scopes stop name and SLOID', () {
    const xml = '''
<OJP xmlns="http://www.vdv.de/ojp">
  <PlaceResult><Place><StopPlace>
    <StopPlaceRef>ch:1:sloid:212</StopPlaceRef>
    <StopPlaceName><Text>Oensingen</Text></StopPlaceName>
  </StopPlace></Place></PlaceResult>
</OJP>
''';

    final record = OjpStopEventClient.parseLocationRecords(xml).single;

    expect(record.name, 'Oensingen');
    expect(record.stopPlaceRef, 'ch:1:sloid:212');
  });

  test('OJP HTTP boundary decodes UTF-8 station names exactly once', () async {
    const xml = '''
<OJP xmlns="http://www.vdv.de/ojp" xmlns:siri="http://www.siri.org.uk/siri">
  <StopEventResult><StopEvent>
    <ThisCall><CallAtStop>
      <siri:StopPointRef>ch:1:sloid:212</siri:StopPointRef>
      <StopPointName><Text>Oensingen, Bahnhof Süd</Text></StopPointName>
    </CallAtStop></ThisCall>
    <Service>
      <JourneyRef>ch:1:sjyid:test</JourneyRef>
      <OperatingDayRef>2026-08-29</OperatingDayRef>
      <PublishedServiceName><Text>S20</Text></PublishedServiceName>
      <DestinationText><Text>Zürich HB</Text></DestinationText>
    </Service>
  </StopEvent></StopEventResult>
</OJP>
''';
    final client = OjpStopEventClient(
      httpPost: (uri, {headers, body}) async => http.Response.bytes(
        utf8.encode(xml),
        200,
        headers: const {'content-type': 'application/xml'},
      ),
    );

    final record = (await client.fetchStopEvents(
      apiKey: 'test-key',
      stopPointRef: 'ch:1:sloid:212',
      from: DateTime.utc(2026, 8, 29),
      numberOfResults: 1,
    )).single;

    expect(record.stopPointName, 'Oensingen, Bahnhof Süd');
    expect(record.destinationText, 'Zürich HB');
    expect(record.stopPointName, isNot(contains('Ã')));
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
    OjpStopEventType eventType = OjpStopEventType.both,
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
    OjpStopEventType eventType = OjpStopEventType.both,
  }) async {
    throw error;
  }
}
