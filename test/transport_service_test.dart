import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:http/http.dart' as http;
import 'package:treep/services/transport_service.dart';

void main() {
  group('fallback arrival timing', () {
    const destinationId = '8500207';

    Future<List<dynamic>> runFallback(List<Map<String, dynamic>> items) async {
      final service = TransportService(
        httpGet: (uri, {headers}) async {
          if (uri.path.endsWith('/locations')) {
            return _jsonResponse({
              'stations': [
                {'id': destinationId, 'name': 'Solothurn'},
              ],
            });
          }
          if (uri.path.endsWith('/stationboard')) {
            return _jsonResponse({'stationboard': items});
          }
          return http.Response('not found', 404);
        },
      );

      return service.fallbackArrivalsAtDestination(
        trainQuery: 'IR55',
        destStopIdCanons: const [destinationId],
        limit: 100,
      );
    }

    test('arrival prognosis wins over a closer departure prognosis', () async {
      final scheduled = DateTime.now().add(const Duration(hours: 2));
      final arrivals = await runFallback([
        _stationboardItem(
          scheduled: scheduled,
          prognosisArrival: scheduled.add(const Duration(minutes: 5)),
          prognosisDeparture: scheduled.add(const Duration(minutes: 1)),
        ),
      ]);

      expect(arrivals, hasLength(1));
      expect(arrivals.single.delaySeconds, 5 * 60);
      expect(
        arrivals.single.etaLocal
            .difference(scheduled.add(const Duration(minutes: 5)))
            .inSeconds
            .abs(),
        lessThanOrEqualTo(1),
      );
    });

    test(
      'departure prognosis is a fallback when arrival prognosis is absent',
      () async {
        final scheduled = DateTime.now().add(const Duration(hours: 2));
        final arrivals = await runFallback([
          _stationboardItem(
            scheduled: scheduled,
            prognosisDeparture: scheduled.add(const Duration(minutes: 4)),
          ),
        ]);

        expect(arrivals.single.delaySeconds, 4 * 60);
      },
    );

    test('absurd early prognosis falls back to the schedule', () async {
      final scheduled = DateTime.now().add(const Duration(hours: 2));
      final arrivals = await runFallback([
        _stationboardItem(
          scheduled: scheduled,
          prognosisArrival: scheduled.subtract(const Duration(minutes: 306)),
        ),
      ]);

      expect(arrivals.single.delaySeconds, 0);
      expect(
        arrivals.single.etaLocal.difference(scheduled).inSeconds.abs(),
        lessThanOrEqualTo(1),
      );
    });

    test('valid positive arrival delay remains accepted', () async {
      final scheduled = DateTime.now().add(const Duration(hours: 2));
      final arrivals = await runFallback([
        _stationboardItem(
          scheduled: scheduled,
          prognosisArrival: scheduled.add(const Duration(hours: 2)),
        ),
      ]);

      expect(arrivals, hasLength(1));
      expect(arrivals.single.delaySeconds, 2 * 60 * 60);
    });

    test('valid delayed duplicate beats rejected extreme data', () async {
      final scheduled = DateTime.now().add(const Duration(hours: 2));
      final arrivals = await runFallback([
        _stationboardItem(
          scheduled: scheduled,
          prognosisArrival: scheduled.subtract(const Duration(minutes: 306)),
        ),
        _stationboardItem(
          scheduled: scheduled,
          prognosisArrival: scheduled.add(const Duration(minutes: 2)),
        ),
      ]);

      expect(arrivals, hasLength(1));
      expect(arrivals.single.delaySeconds, 2 * 60);
    });

    test('separate scheduled IR55 services remain separate', () async {
      final first = DateTime.now().add(const Duration(hours: 1));
      final second = first.add(const Duration(hours: 1));
      final arrivals = await runFallback([
        _stationboardItem(scheduled: first),
        _stationboardItem(scheduled: second),
      ]);

      expect(arrivals, hasLength(2));
      expect(arrivals[0].tripId, isNot(arrivals[1].tripId));
    });
  });

  test(
    'destination-name rescue examines candidates after the old first eight',
    () async {
      const targetStopId = '8501999';
      final service = TransportService(
        httpGet: (uri, {headers}) async {
          final id = uri.queryParameters['id'] ?? uri.queryParameters['query'];
          final name = id == targetStopId ? 'Oensingen' : 'Other station';
          return _jsonResponse({
            'stations': [
              {'id': id, 'name': name},
            ],
          });
        },
      );
      final baseTime = DateTime.now().add(const Duration(hours: 1));
      final entities = <FeedEntity>[];
      for (var index = 0; index < 9; index++) {
        final stopId = index == 8
            ? targetStopId
            : '85010${index.toString().padLeft(2, '0')}';
        final etaSeconds =
            baseTime
                .add(Duration(minutes: index))
                .toUtc()
                .millisecondsSinceEpoch ~/
            1000;
        entities.add(
          FeedEntity(
            id: 'entity-$index',
            tripUpdate: TripUpdate(
              trip: TripDescriptor(
                tripId: 'trip-$index',
                routeId: 'S20',
                startDate: '20260827',
                startTime: '12:00:00',
              ),
              stopTimeUpdate: [
                TripUpdate_StopTimeUpdate(
                  stopId: stopId,
                  arrival: TripUpdate_StopTimeEvent.fromJson(
                    '{"2":"$etaSeconds"}',
                  ),
                ),
              ],
            ),
          ),
        );
      }

      final candidates = await service.findCandidatesByTrainAndDestinationName(
        FeedMessage(entity: entities),
        'S20',
        'Oensingen',
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.tripId, 'trip-8');
      expect(candidates.single.displayTrain, 'S20');
      expect(candidates.single.stopId, targetStopId);
    },
  );

  test(
    'filtered fallback can recover from a failed primary strong stop',
    () async {
      const primaryId = '8500207';
      const alternateId = '8500208';
      final fetchedStationboards = <String>[];
      final scheduled = DateTime.now().add(const Duration(hours: 1));
      final service = TransportService(
        httpGet: (uri, {headers}) async {
          if (uri.path.endsWith('/locations') &&
              uri.queryParameters['query'] == 'Solothurn') {
            return _jsonResponse({
              'stations': const [
                {'id': primaryId, 'name': 'Solothurn'},
                {'id': alternateId, 'name': 'Solothurn Bahnhof'},
              ],
            });
          }
          if (uri.path.endsWith('/locations')) {
            final id =
                uri.queryParameters['id'] ?? uri.queryParameters['query'];
            return _jsonResponse({
              'stations': [
                {
                  'id': id,
                  'name': id == primaryId ? 'Solothurn' : 'Solothurn Bahnhof',
                },
              ],
            });
          }
          if (uri.path.endsWith('/stationboard')) {
            final id = uri.queryParameters['id']!;
            fetchedStationboards.add(id);
            return _jsonResponse({
              'stationboard': id == alternateId
                  ? [_stationboardItem(scheduled: scheduled)]
                  : const <Object>[],
            });
          }
          return http.Response('not found', 404);
        },
      );

      final candidates = await service.fallbackArrivalsAtDestination(
        trainQuery: 'IR55',
        destStopIdCanons: const [primaryId],
        destNameQuery: 'Solothurn',
      );

      expect(fetchedStationboards, [primaryId, alternateId]);
      expect(candidates, hasLength(1));
      expect(candidates.single.stopId, alternateId);
    },
  );
}

http.Response _jsonResponse(Object body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json'},
  );
}

Map<String, dynamic> _stationboardItem({
  required DateTime scheduled,
  DateTime? prognosisArrival,
  DateTime? prognosisDeparture,
}) {
  return {
    'name': 'IR 55',
    'category': 'IR',
    'number': '55',
    'to': 'Zürich HB',
    'stop': {
      'arrivalTimestamp': scheduled.toUtc().millisecondsSinceEpoch ~/ 1000,
      'station': {'id': '8500207', 'name': 'Solothurn'},
      'prognosis': {
        if (prognosisArrival != null)
          'arrival': prognosisArrival.toUtc().toIso8601String(),
        if (prognosisDeparture != null)
          'departure': prognosisDeparture.toUtc().toIso8601String(),
        'platform': '1',
      },
    },
  };
}
