import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:http/http.dart' as http;
import 'package:treep/models/trip_candidate.dart';
import 'package:treep/services/ojp_public_direction_service.dart';
import 'package:treep/services/transport_service.dart';

void main() {
  const destination = '8500212';
  const origin = destination;
  const prior = '8500207';
  const intermediate = '8500208';

  group('GTFS downstream destination qualification', () {
    test('first destination occurrence with departure only is rejected', () {
      final candidates = _find(
        _feed([
          _stop(1, origin, departureMinutes: 10),
          _stop(2, intermediate, arrivalMinutes: 20),
        ]),
        destination,
      );

      expect(candidates, isEmpty);
    });

    test(
      'first supplied destination arrival without prior proof remains unproven',
      () {
        final candidates = _find(
          _feed([
            _stop(4, destination, arrivalMinutes: 10),
            _stop(5, intermediate, arrivalMinutes: 20),
          ]),
          destination,
        );

        expect(candidates, isEmpty);
      },
    );

    test('earlier serviced update plus destination arrival is accepted', () {
      final candidates = _find(
        _feed([
          _stop(1, prior, departureMinutes: 5),
          _stop(2, destination, arrivalMinutes: 15),
        ]),
        destination,
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.destinationMatched, isTrue);
      expect(candidates.single.stopId, destination);
      expect(candidates.single.terminalStopId, destination);
    });

    test('a skipped prior update is not prior-call proof', () {
      final candidates = _find(
        _feed([
          _stop(
            1,
            prior,
            departureMinutes: 5,
            relationship:
                TripUpdate_StopTimeUpdate_ScheduleRelationship.SKIPPED,
          ),
          _stop(2, destination, arrivalMinutes: 15),
        ]),
        destination,
      );

      expect(candidates, isEmpty);
    });

    test('a skipped destination occurrence is rejected', () {
      final candidates = _find(
        _feed([
          _stop(1, prior, departureMinutes: 5),
          _stop(
            2,
            destination,
            arrivalMinutes: 15,
            relationship:
                TripUpdate_StopTimeUpdate_ScheduleRelationship.SKIPPED,
          ),
        ]),
        destination,
      );

      expect(candidates, isEmpty);
    });

    test('missing realtime arrival time never defaults to now', () {
      final candidates = _find(
        _feed([
          _stop(1, prior, departureMinutes: 5),
          TripUpdate_StopTimeUpdate(
            stopSequence: 2,
            stopId: destination,
            arrival: TripUpdate_StopTimeEvent(delay: -14 * 60),
          ),
        ]),
        destination,
      );

      expect(candidates, isEmpty);
    });

    test('terminating destination arrival without departure is accepted', () {
      final candidates = _find(
        _feed([
          _stop(1, prior, departureMinutes: 5),
          _stop(2, destination, arrivalMinutes: 15),
        ]),
        destination,
      );

      expect(candidates, hasLength(1));
      expect(
        candidates.single.etaLocal.difference(_time(15)).inSeconds.abs(),
        lessThanOrEqualTo(1),
      );
    });

    test('a downstream departure-only occurrence is rejected', () {
      final candidates = _find(
        _feed([
          _stop(1, prior, departureMinutes: 5),
          _stop(2, destination, departureMinutes: 15),
          _stop(3, intermediate, arrivalMinutes: 25),
        ]),
        destination,
      );

      expect(candidates, isEmpty);
    });

    test(
      'later repeated stop qualifies while its origin occurrence does not',
      () {
        final candidates = _find(
          _feed([
            _stop(1, destination, departureMinutes: 5),
            _stop(2, intermediate, arrivalMinutes: 15),
            _stop(3, destination, arrivalMinutes: 25),
          ]),
          destination,
        );

        expect(candidates, hasLength(1));
        expect(
          candidates.single.etaLocal.difference(_time(25)).inSeconds.abs(),
          lessThanOrEqualTo(1),
        );
        expect(
          candidates.single.upcomingStops.map((stop) => stop.stopIdCanon),
          [intermediate, destination],
        );
      },
    );

    test('train-only picker exposure excludes an unproven origin', () {
      final service = TransportService();
      final candidates = service.findCandidates(
        _feed([
          _stop(1, destination, departureMinutes: 5),
          _stop(2, intermediate, arrivalMinutes: 15),
        ]),
        'S22',
        destination,
        requireDestinationMatch: false,
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.destinationMatched, isFalse);
      expect(candidates.single.upcomingStops.map((stop) => stop.stopIdCanon), [
        intermediate,
      ]);
    });

    test(
      'terminal follows final serviced stop sequence rather than ETA sort',
      () {
        final candidates = _find(
          _feed([
            _stop(1, prior, departureMinutes: 5),
            _stop(2, destination, arrivalMinutes: 25),
            _stop(3, intermediate, arrivalMinutes: 20),
          ]),
          destination,
        );

        expect(candidates, hasLength(1));
        expect(candidates.single.stopId, destination);
        expect(candidates.single.terminalStopId, intermediate);
        expect(candidates.single.terminalStopIdCanon, intermediate);
      },
    );
  });

  test('destination-name rescue cannot reintroduce an origin', () async {
    final service = TransportService(
      httpGet: (uri, {headers}) async {
        final id = uri.queryParameters['id'] ?? uri.queryParameters['query'];
        return _jsonResponse({
          'stations': [
            {
              'id': id,
              'name': id == destination ? 'Oensingen' : 'Other station',
            },
          ],
        });
      },
    );

    final candidates = await service.findCandidatesByTrainAndDestinationName(
      _feed([
        _stop(1, destination, departureMinutes: 5),
        _stop(2, intermediate, arrivalMinutes: 15),
      ]),
      'S22',
      'Oensingen',
    );

    expect(candidates, isEmpty);
  });

  test('refresh cannot promote an origin departure to destination', () async {
    final service = _FeedTransportService(
      _feed([
        _stop(1, destination, departureMinutes: 5),
        _stop(2, intermediate, arrivalMinutes: 15),
      ]),
      httpGet: (uri, {headers}) async {
        if (uri.path.endsWith('/locations')) {
          return _jsonResponse({
            'stations': const [
              {'id': destination, 'name': 'Oensingen'},
            ],
          });
        }
        if (uri.path.endsWith('/stationboard')) {
          return _jsonResponse({'stationboard': const <Object>[]});
        }
        return http.Response('not found', 404);
      },
    );

    final refreshed = await service.refreshCandidateEta(_candidate());

    expect(refreshed, isNull);
  });

  test('OJP unavailability does not loosen GTFS qualification', () async {
    final service = TransportService(
      ojpClient: _ThrowingOjpClient(),
      ojpApiKeyProvider: () => 'test-key',
    );
    final originCandidates = _findWithService(
      service,
      _feed([
        _stop(1, destination, departureMinutes: 5),
        _stop(2, intermediate, arrivalMinutes: 15),
      ]),
      destination,
    );

    final enriched = await service.enrichPublicDirections(originCandidates);

    expect(originCandidates, isEmpty);
    expect(enriched, isEmpty);
  });
}

List<TripCandidate> _find(FeedMessage feed, String destination) {
  return _findWithService(TransportService(), feed, destination);
}

List<TripCandidate> _findWithService(
  TransportService service,
  FeedMessage feed,
  String destination,
) {
  return service.findCandidates(
    feed,
    'S22',
    destination,
    requireDestinationMatch: true,
  );
}

FeedMessage _feed(List<TripUpdate_StopTimeUpdate> stops) {
  return FeedMessage(
    entity: [
      FeedEntity(
        id: 'entity-s22',
        tripUpdate: TripUpdate(
          trip: TripDescriptor(
            tripId: 'trip-s22',
            routeId: 'S22',
            startDate: '20260829',
            startTime: '08:00:00',
          ),
          stopTimeUpdate: stops,
        ),
      ),
    ],
  );
}

TripUpdate_StopTimeUpdate _stop(
  int sequence,
  String stopId, {
  int? arrivalMinutes,
  int? departureMinutes,
  TripUpdate_StopTimeUpdate_ScheduleRelationship? relationship,
}) {
  TripUpdate_StopTimeEvent event(int minutes) {
    final seconds = _time(minutes).toUtc().millisecondsSinceEpoch ~/ 1000;
    return TripUpdate_StopTimeEvent.fromJson('{"2":"$seconds"}');
  }

  return TripUpdate_StopTimeUpdate(
    stopSequence: sequence,
    stopId: stopId,
    arrival: arrivalMinutes == null ? null : event(arrivalMinutes),
    departure: departureMinutes == null ? null : event(departureMinutes),
    scheduleRelationship: relationship,
  );
}

final DateTime _baseTime = DateTime.now().add(const Duration(hours: 1));

DateTime _time(int minutes) => _baseTime.add(Duration(minutes: minutes));

TripCandidate _candidate() {
  return TripCandidate(
    tripId: 'trip-s22',
    routeId: 'S22',
    startDate: '20260829',
    startTime: '08:00:00',
    stopId: '8500212',
    etaLocal: _time(10),
    delaySeconds: 0,
    displayTrain: 'S22',
    vehicleLabel: 'Train',
    destinationMatched: true,
    upcomingStops: const [],
    terminalStopId: 'Balsthal',
    terminalStopIdCanon: '',
  );
}

http.Response _jsonResponse(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json'},
);

class _FeedTransportService extends TransportService {
  _FeedTransportService(this.feed, {super.httpGet});

  final FeedMessage feed;

  @override
  Future<FeedMessage> fetchGtfsRtFeed() async => feed;
}

class _ThrowingOjpClient implements OjpPublicDirectionClient {
  @override
  Future<List<OjpStopEventRecord>> fetchStopEvents({
    required String apiKey,
    required String stopPointRef,
    required DateTime from,
    required int numberOfResults,
    OjpStopEventType eventType = OjpStopEventType.both,
  }) {
    throw TimeoutException('OJP unavailable');
  }
}
