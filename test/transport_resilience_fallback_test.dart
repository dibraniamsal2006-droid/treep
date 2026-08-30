import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:treep/models/trip_candidate.dart';
import 'package:treep/services/ojp_public_direction_service.dart';
import 'package:treep/services/transport_service.dart';

void main() {
  group('transient stationboard fallback', () {
    test('stationboard success does not call OJP', () async {
      final ojp = _FakeOjpClient(records: [_arrivalRecord()]);
      final service = _service(
        ojp: ojp,
        stationboardResponse: _stationboardResponse(),
      );

      final candidates = await _arrivals(service);

      expect(candidates, hasLength(1));
      expect(candidates.single.directionSource, DirectionSource.stationboard);
      expect(ojp.stopEventCalls, 0);
    });

    test('stationboard timeout uses one OJP arrival request', () async {
      final ojp = _FakeOjpClient(records: [_arrivalRecord()]);
      final service = _service(
        ojp: ojp,
        stationboardError: TimeoutException('upstream timeout'),
      );

      final candidates = await _arrivals(service);

      expect(candidates, hasLength(1));
      expect(candidates.single.displayTrain, 'S22');
      expect(candidates.single.stopId, '8500212');
      expect(candidates.single.directionSource, DirectionSource.ojpStopEvent);
      expect(ojp.stopEventCalls, 1);
      expect(ojp.lastEventType, OjpStopEventType.arrival);
    });

    test('stationboard HTTP 500 uses OJP fallback', () async {
      final ojp = _FakeOjpClient(records: [_arrivalRecord()]);
      final service = _service(
        ojp: ojp,
        stationboardResponse: http.Response('', 500),
      );

      expect(await _arrivals(service), hasLength(1));
      expect(ojp.stopEventCalls, 1);
    });

    test('clean empty stationboard does not use OJP', () async {
      final ojp = _FakeOjpClient(records: [_arrivalRecord()]);
      final service = _service(
        ojp: ojp,
        stationboardResponse: _jsonResponse({'stationboard': const []}),
      );

      expect(await _arrivals(service), isEmpty);
      expect(ojp.stopEventCalls, 0);
      expect(service.lastArrivalFallbackFailure, isNull);
    });

    test('stationboard and OJP failure return cleanly', () async {
      final ojp = _FakeOjpClient(stopEventError: TimeoutException('ojp'));
      final service = _service(
        ojp: ojp,
        stationboardError: TimeoutException('stationboard'),
      );

      expect(await _arrivals(service), isEmpty);
      expect(ojp.stopEventCalls, 1);
      expect(
        service.lastArrivalFallbackFailure,
        ArrivalFallbackFailure.temporaryUnavailable,
      );
    });

    test('origin event without a prior serviced call is rejected', () async {
      final ojp = _FakeOjpClient(
        records: [_arrivalRecord(hasPreviousServicedCall: false)],
      );
      final service = _service(
        ojp: ojp,
        stationboardError: TimeoutException('stationboard'),
      );

      expect(await _arrivals(service), isEmpty);
    });

    test('wrong authoritative public line is rejected', () async {
      final ojp = _FakeOjpClient(
        records: [_arrivalRecord(publicLineName: 'S20')],
      );
      final service = _service(
        ojp: ojp,
        stationboardError: TimeoutException('stationboard'),
      );

      expect(await _arrivals(service), isEmpty);
    });

    test('mismatched destination SLOID is rejected', () async {
      final ojp = _FakeOjpClient(
        records: [_arrivalRecord(stopPointRef: 'ch:1:sloid:207')],
      );
      final service = _service(
        ojp: ojp,
        stationboardError: TimeoutException('stationboard'),
      );

      expect(await _arrivals(service), isEmpty);
    });

    test('outside picker horizon and missing schedule are rejected', () async {
      final ojp = _FakeOjpClient(
        records: [
          _arrivalRecord(
            scheduledArrival: DateTime.now().add(const Duration(hours: 7)),
          ),
          const OjpStopEventRecord(
            journeyRef: 'ch:1:sjyid:missing-time',
            operatingDayRef: '2026-08-29',
            destinationText: 'Oensingen',
            hasPreviousServicedCall: true,
            stopPointRef: 'ch:1:sloid:212',
            publicLineName: 'S22',
          ),
        ],
      );
      final service = _service(
        ojp: ojp,
        stationboardError: TimeoutException('stationboard'),
      );

      expect(await _arrivals(service), isEmpty);
    });

    test('arrival estimate produces delay against its schedule', () async {
      final scheduled = DateTime.now().add(const Duration(hours: 1));
      final ojp = _FakeOjpClient(
        records: [
          _arrivalRecord(
            scheduledArrival: scheduled,
            estimatedArrival: scheduled.add(const Duration(minutes: 4)),
          ),
        ],
      );
      final service = _service(
        ojp: ojp,
        stationboardError: TimeoutException('stationboard'),
      );

      final candidate = (await _arrivals(service)).single;
      expect(candidate.delaySeconds, 240);
      expect(
        candidate.etaLocal
            .difference(scheduled.add(const Duration(minutes: 4)).toLocal())
            .inSeconds
            .abs(),
        lessThanOrEqualTo(1),
      );
    });

    test('numeric destination bypasses name query resolution', () async {
      var nameQueryCalls = 0;
      final ojp = _FakeOjpClient(records: [_arrivalRecord()]);
      final service = TransportService(
        ojpClient: ojp,
        ojpApiKeyProvider: () => 'test-key',
        httpGet: (uri, {headers}) async {
          if (uri.path.endsWith('/locations')) {
            if (uri.queryParameters.containsKey('query')) nameQueryCalls++;
            return _locationResponse();
          }
          throw TimeoutException('stationboard');
        },
      );

      await service.fallbackArrivalsAtDestination(
        trainQuery: 'S22',
        destStopIdCanons: const ['8500212'],
        resolveDestinationName: false,
      );

      expect(nameQueryCalls, 0);
    });
  });

  group('OJP location fallback', () {
    test('primary timeout resolves exact Oensingen through OJP', () async {
      final ojp = _FakeOjpClient(
        locations: const [
          OjpLocationRecord(name: 'Oensingen', stopPlaceRef: 'ch:1:sloid:212'),
        ],
      );
      final service = TransportService(
        httpGet: (uri, {headers}) async => throw TimeoutException('primary'),
        ojpLocationClient: ojp,
        ojpApiKeyProvider: () => 'test-key',
      );

      expect(await service.resolveStopIdsFromName('oensingen'), ['8500212']);
      expect(service.lastStopResolutionFailure, isNull);
      expect(ojp.locationCalls, 1);
    });

    test('diacritics-normalized exact Zürich HB resolves safely', () async {
      final ojp = _FakeOjpClient(
        locations: const [
          OjpLocationRecord(name: 'Zürich HB', stopPlaceRef: 'ch:1:sloid:3000'),
        ],
      );
      final service = TransportService(
        httpGet: (uri, {headers}) async => throw TimeoutException('primary'),
        ojpLocationClient: ojp,
        ojpApiKeyProvider: () => 'test-key',
      );

      expect(await service.resolveStopIdsFromName('zurich hb'), ['8503000']);
    });

    test('clean not-found remains distinct and does not call OJP', () async {
      final ojp = _FakeOjpClient(
        locations: const [
          OjpLocationRecord(name: 'Oensingen', stopPlaceRef: 'ch:1:sloid:212'),
        ],
      );
      final service = TransportService(
        httpGet: (uri, {headers}) async =>
            _jsonResponse({'stations': const []}),
        ojpLocationClient: ojp,
        ojpApiKeyProvider: () => 'test-key',
      );

      expect(await service.resolveStopIdsFromName('Missing'), isEmpty);
      expect(service.lastStopResolutionFailure, StopResolutionFailure.notFound);
      expect(ojp.locationCalls, 0);
    });

    test('ambiguous exact OJP names are not guessed', () async {
      final ojp = _FakeOjpClient(
        locations: const [
          OjpLocationRecord(name: 'Example', stopPlaceRef: 'ch:1:sloid:212'),
          OjpLocationRecord(name: 'Example', stopPlaceRef: 'ch:1:sloid:207'),
        ],
      );
      final service = TransportService(
        httpGet: (uri, {headers}) async => throw TimeoutException('primary'),
        ojpLocationClient: ojp,
        ojpApiKeyProvider: () => 'test-key',
      );

      expect(await service.resolveStopIdsFromName('Example'), isEmpty);
      expect(service.lastStopResolutionFailure, StopResolutionFailure.notFound);
    });
  });

  group('bus candidate discovery', () {
    Future<List<TripCandidate>> runBus(List<OjpStopEventRecord> records) {
      final ojp = _FakeOjpClient(records: records);
      final service = TransportService(
        ojpClient: ojp,
        ojpApiKeyProvider: () => 'test-key',
        httpGet: (uri, {headers}) async => _busOriginStationboardResponse(),
      );
      return service.fallbackArrivalsAtDestination(
        trainQuery: '129',
        destStopIdCanons: const ['8572372'],
        resolveDestinationName: false,
      );
    }

    test('authoritative downstream OJP bus arrival is accepted', () async {
      final candidates = await runBus([_busArrivalRecord()]);

      expect(candidates, hasLength(1));
      expect(candidates.single.displayTrain, 'B129');
      expect(candidates.single.vehicleLabel, 'Bus');
      expect(candidates.single.stopId, '8572372');
      expect(candidates.single.destinationMatched, isTrue);
    });

    test('authoritative bus mode accepts a B-prefixed query', () async {
      final ojp = _FakeOjpClient(
        records: [_busArrivalRecord(publicLineName: '129')],
      );
      final service = TransportService(
        ojpClient: ojp,
        ojpApiKeyProvider: () => 'test-key',
        httpGet: (uri, {headers}) async => _busOriginStationboardResponse(),
      );

      final candidates = await service.fallbackArrivalsAtDestination(
        trainQuery: 'B129',
        destStopIdCanons: const ['8572372'],
        resolveDestinationName: false,
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.displayTrain, '129');
      expect(candidates.single.vehicleLabel, 'Bus');
    });

    test('wrong public bus line is rejected', () async {
      expect(
        await runBus([_busArrivalRecord(publicLineName: 'B127')]),
        isEmpty,
      );
    });

    test('bus destination-as-origin is rejected', () async {
      expect(
        await runBus([_busArrivalRecord(hasPreviousServicedCall: false)]),
        isEmpty,
      );
    });

    test('stationboard departure-only bus origin is never exposed', () async {
      expect(await runBus(const []), isEmpty);
    });
  });

  test('Swiss SLOID conversion uses the semantic base, not digit joining', () {
    expect(
      swissStopPointRefFromGtfsStopId('ch:1:sloid:212:0:880532'),
      'ch:1:sloid:212',
    );
    expect(
      swissGtfsStopIdFromStopPointRef('ch:1:sloid:212:0:880532'),
      '8500212',
    );
    expect(swissGtfsStopIdFromStopPointRef('ch:1:sloid:212:0:880532x'), isNull);
  });
}

Future<List<TripCandidate>> _arrivals(TransportService service) {
  return service.fallbackArrivalsAtDestination(
    trainQuery: 'S22',
    destStopIdCanons: const ['8500212'],
    resolveDestinationName: false,
  );
}

TransportService _service({
  required _FakeOjpClient ojp,
  http.Response? stationboardResponse,
  Object? stationboardError,
}) {
  return TransportService(
    ojpClient: ojp,
    ojpApiKeyProvider: () => 'test-key',
    httpGet: (uri, {headers}) async {
      if (uri.path.endsWith('/locations')) return _locationResponse();
      if (stationboardError != null) throw stationboardError;
      return stationboardResponse ?? http.Response('', 500);
    },
  );
}

OjpStopEventRecord _arrivalRecord({
  bool hasPreviousServicedCall = true,
  String stopPointRef = 'ch:1:sloid:212:0:880532',
  String publicLineName = 'S22',
  DateTime? scheduledArrival,
  DateTime? estimatedArrival,
}) {
  return OjpStopEventRecord(
    journeyRef: 'ch:1:sjyid:test-s22',
    operatingDayRef: '2026-08-29',
    destinationText: 'Oensingen',
    hasPreviousServicedCall: hasPreviousServicedCall,
    stopPointRef: stopPointRef,
    publicLineName: publicLineName,
    scheduledArrival:
        scheduledArrival ?? DateTime.now().add(const Duration(hours: 1)),
    estimatedArrival: estimatedArrival,
  );
}

OjpStopEventRecord _busArrivalRecord({
  String publicLineName = 'B129',
  bool hasPreviousServicedCall = true,
}) {
  return OjpStopEventRecord(
    journeyRef: 'ch:1:sjyid:test-bus-129',
    operatingDayRef: '2026-08-29',
    destinationText: 'Oensingen, Bahnhof',
    hasPreviousServicedCall: hasPreviousServicedCall,
    stopPointRef: 'ch:1:sloid:72372',
    stopPointName: 'Oensingen, Bahnhof',
    publicLineName: publicLineName,
    transportMode: 'bus',
    scheduledArrival: DateTime.now().add(const Duration(hours: 1)),
  );
}

http.Response _stationboardResponse() {
  final scheduled = DateTime.now().add(const Duration(hours: 1));
  final timestamp = scheduled.toUtc().millisecondsSinceEpoch ~/ 1000;
  return _jsonResponse({
    'stationboard': [
      {
        'name': 'S22',
        'category': 'S',
        'number': '22',
        'to': 'Oensingen',
        'stop': {
          'arrivalTimestamp': timestamp,
          'station': {'id': '8500212', 'name': 'Oensingen'},
          'prognosis': const <String, Object?>{},
        },
      },
    ],
  });
}

http.Response _busOriginStationboardResponse() {
  final departure = DateTime.now().add(const Duration(hours: 1));
  final timestamp = departure.toUtc().millisecondsSinceEpoch ~/ 1000;
  return _jsonResponse({
    'stationboard': [
      {
        'name': '013020',
        'category': 'B',
        'number': '129',
        'to': 'Balsthal, Bahnhof',
        'stop': {
          'station': {'id': '8572372', 'name': 'Oensingen, Bahnhof'},
          'departureTimestamp': timestamp,
          'location': {'id': '8500674'},
          'prognosis': const <String, Object?>{},
        },
        'passList': [
          {
            'station': {'id': '8500674', 'name': null},
            'location': {'id': '8500674'},
            'departureTimestamp': timestamp,
          },
        ],
      },
    ],
  });
}

http.Response _locationResponse() => _jsonResponse({
  'stations': const [
    {'id': '8500212', 'name': 'Oensingen'},
  ],
});

http.Response _jsonResponse(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json'},
);

class _FakeOjpClient implements OjpPublicDirectionClient, OjpLocationClient {
  _FakeOjpClient({
    this.records = const [],
    this.locations = const [],
    this.stopEventError,
  });

  final List<OjpStopEventRecord> records;
  final List<OjpLocationRecord> locations;
  final Object? stopEventError;
  int stopEventCalls = 0;
  int locationCalls = 0;
  OjpStopEventType? lastEventType;

  @override
  Future<List<OjpStopEventRecord>> fetchStopEvents({
    required String apiKey,
    required String stopPointRef,
    required DateTime from,
    required int numberOfResults,
    OjpStopEventType eventType = OjpStopEventType.both,
  }) async {
    stopEventCalls++;
    lastEventType = eventType;
    if (stopEventError != null) throw stopEventError!;
    return records;
  }

  @override
  Future<List<OjpLocationRecord>> fetchLocations({
    required String apiKey,
    required String name,
    required int numberOfResults,
  }) async {
    locationCalls++;
    return locations;
  }
}
