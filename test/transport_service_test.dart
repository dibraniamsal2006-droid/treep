import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:http/http.dart' as http;
import 'package:treep/models/trip_candidate.dart';
import 'package:treep/services/transport_service.dart';

void main() {
  group('fallback arrival timing', () {
    const destinationId = '8500207';

    Future<List<dynamic>> runFallback(
      List<Map<String, dynamic>> items, {
      String trainQuery = 'IR55',
    }) async {
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
        trainQuery: trainQuery,
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
      'departure prognosis is not substituted for missing arrival prognosis',
      () async {
        final scheduled = DateTime.now().add(const Duration(hours: 2));
        final arrivals = await runFallback([
          _stationboardItem(
            scheduled: scheduled,
            prognosisDeparture: scheduled.add(const Duration(minutes: 4)),
          ),
        ]);

        expect(arrivals.single.delaySeconds, 0);
        expect(
          arrivals.single.etaLocal.difference(scheduled).inSeconds.abs(),
          lessThanOrEqualTo(1),
        );
      },
    );

    test(
      '05:40-style journey keeps schedule without matching realtime',
      () async {
        final sharedMalformedRealtime = DateTime.now();
        final scheduled = sharedMalformedRealtime.add(
          const Duration(minutes: 15),
        );
        final arrivals = await runFallback([
          _stationboardItem(
            scheduled: scheduled,
            scheduledInDepartureField: true,
            prognosisArrival: sharedMalformedRealtime,
            category: 'S',
            number: '22',
          ),
        ], trainQuery: 'S22');

        expect(arrivals, hasLength(1));
        expect(
          arrivals.single.etaLocal.difference(scheduled).inSeconds.abs(),
          lessThanOrEqualTo(1),
        );
        expect(arrivals.single.delaySeconds, 0);
      },
    );

    test(
      '06:10-style journey keeps schedule without matching realtime',
      () async {
        final sharedMalformedRealtime = DateTime.now();
        final scheduled = sharedMalformedRealtime.add(
          const Duration(minutes: 45),
        );
        final arrivals = await runFallback([
          _stationboardItem(
            scheduled: scheduled,
            scheduledInDepartureField: true,
            prognosisArrival: sharedMalformedRealtime,
            category: 'S',
            number: '22',
          ),
        ], trainQuery: 'S22');

        expect(arrivals, hasLength(1));
        expect(
          arrivals.single.etaLocal.difference(scheduled).inSeconds.abs(),
          lessThanOrEqualTo(1),
        );
        expect(arrivals.single.delaySeconds, 0);
      },
    );

    test('two S22 schedules do not collapse to one shared prognosis', () async {
      final sharedMalformedRealtime = DateTime.now();
      final first = sharedMalformedRealtime.add(const Duration(minutes: 15));
      final second = sharedMalformedRealtime.add(const Duration(minutes: 45));
      final arrivals = await runFallback([
        _stationboardItem(
          scheduled: first,
          scheduledInDepartureField: true,
          prognosisArrival: sharedMalformedRealtime,
          category: 'S',
          number: '22',
        ),
        _stationboardItem(
          scheduled: second,
          scheduledInDepartureField: true,
          prognosisArrival: sharedMalformedRealtime,
          category: 'S',
          number: '22',
        ),
      ], trainQuery: 'S22');

      expect(arrivals, hasLength(2));
      expect(
        arrivals[0].etaLocal.difference(first).inSeconds.abs(),
        lessThanOrEqualTo(1),
      );
      expect(
        arrivals[1].etaLocal.difference(second).inSeconds.abs(),
        lessThanOrEqualTo(1),
      );
      expect(arrivals[0].etaLocal, isNot(arrivals[1].etaLocal));
    });

    test(
      'matching departure prognosis remains a valid realtime update',
      () async {
        final scheduled = DateTime.now().add(const Duration(hours: 1));
        final realtime = scheduled.add(const Duration(minutes: 4));
        final arrivals = await runFallback([
          _stationboardItem(
            scheduled: scheduled,
            scheduledInDepartureField: true,
            prognosisDeparture: realtime,
          ),
        ]);

        expect(arrivals.single.delaySeconds, 4 * 60);
        expect(
          arrivals.single.etaLocal.difference(realtime).inSeconds.abs(),
          lessThanOrEqualTo(1),
        );
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

    test('valid matching early arrival remains a negative delay', () async {
      final scheduled = DateTime.now().add(const Duration(hours: 2));
      final realtime = scheduled.subtract(const Duration(minutes: 3));
      final arrivals = await runFallback([
        _stationboardItem(scheduled: scheduled, prognosisArrival: realtime),
      ]);

      expect(arrivals, hasLength(1));
      expect(
        (arrivals.single.delaySeconds + 3 * 60).abs(),
        lessThanOrEqualTo(1),
      );
      expect(
        arrivals.single.etaLocal.difference(realtime).inSeconds.abs(),
        lessThanOrEqualTo(1),
      );
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

    test(
      'delayed synthetic journey keeps its original scheduled identity',
      () async {
        final firstSchedule = DateTime.now().add(const Duration(hours: 1));
        final secondSchedule = firstSchedule.add(const Duration(minutes: 30));
        var items = <Map<String, dynamic>>[
          _stationboardItem(scheduled: firstSchedule),
          _stationboardItem(scheduled: secondSchedule),
        ];
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
        final initial = await service.fallbackArrivalsAtDestination(
          trainQuery: 'IR55',
          destStopIdCanons: const [destinationId],
          limit: 100,
        );
        final selected = initial.first;
        items = [
          _stationboardItem(
            scheduled: firstSchedule,
            prognosisArrival: firstSchedule.add(const Duration(minutes: 31)),
          ),
          _stationboardItem(
            scheduled: secondSchedule,
            prognosisArrival: secondSchedule.add(const Duration(minutes: 1)),
          ),
        ];

        final refreshed = await service.refreshCandidateEta(selected);

        expect(refreshed, isNotNull);
        expect(refreshed!.tripId, selected.tripId);
        expect(refreshed.tripId, isNot(initial.last.tripId));
        expect(
          refreshed.etaLocal
              .difference(firstSchedule.add(const Duration(minutes: 31)))
              .inSeconds
              .abs(),
          lessThanOrEqualTo(1),
        );
      },
    );

    test(
      'arrival pass list uses downstream terminal instead of S22 origin-side to',
      () async {
        final scheduled = DateTime.now().add(const Duration(hours: 2));
        final candidate = await _runDirectionFallback(
          trainQuery: 'S22',
          destinationId: '8500212',
          destinationName: 'Oensingen',
          item: _arrivalDirectionItem(
            scheduled: scheduled,
            category: 'S',
            number: '22',
            originName: 'Balsthal',
            destinationId: '8500212',
            destinationName: 'Oensingen',
            destinationLocationId: '8500294',
          ),
        );

        expect(candidate.terminalStopId, 'Oensingen');
        expect(candidate.directionSource, DirectionSource.stationboard);
      },
    );

    test(
      'arrival pass list uses downstream terminal instead of S20 origin-side to',
      () async {
        final scheduled = DateTime.now().add(const Duration(hours: 2));
        final candidate = await _runDirectionFallback(
          trainQuery: 'S20',
          destinationId: '8500218',
          destinationName: 'Olten',
          item: _arrivalDirectionItem(
            scheduled: scheduled,
            category: 'S',
            number: '20',
            originName: 'Langendorf',
            destinationId: '8500218',
            destinationName: 'Olten',
            destinationLocationId: '8500295',
          ),
        );

        expect(candidate.terminalStopId, 'Olten');
        expect(candidate.directionSource, DirectionSource.stationboard);
      },
    );

    test('arrival pass list chooses its final serviced stop', () async {
      final scheduled = DateTime.now().add(const Duration(hours: 2));
      final candidate = await _runDirectionFallback(
        trainQuery: 'S20',
        destinationId: '8500218',
        destinationName: 'Olten',
        item: _arrivalDirectionItem(
          scheduled: scheduled,
          category: 'S',
          number: '20',
          originName: 'Langendorf',
          destinationId: '8500218',
          destinationName: 'Olten',
          destinationLocationId: '8500295',
          terminalName: 'Zürich HB',
        ),
      );

      expect(candidate.terminalStopId, 'Zürich HB');
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
                  stopSequence: 1,
                  stopId: '8500001',
                  departure: TripUpdate_StopTimeEvent.fromJson(
                    '{"2":"${baseTime.subtract(const Duration(minutes: 10)).toUtc().millisecondsSinceEpoch ~/ 1000}"}',
                  ),
                ),
                TripUpdate_StopTimeUpdate(
                  stopSequence: 2,
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

  test('stationboard fallback explicitly requests arrivals', () async {
    Uri? stationboardRequest;
    final service = TransportService(
      httpGet: (uri, {headers}) async {
        if (uri.path.endsWith('/locations')) {
          return _jsonResponse({
            'stations': const [
              {'id': '8500207', 'name': 'Solothurn'},
            ],
          });
        }
        if (uri.path.endsWith('/stationboard')) {
          stationboardRequest = uri;
          return _jsonResponse({'stationboard': const <Object>[]});
        }
        return http.Response('not found', 404);
      },
    );

    await service.fallbackArrivalsAtDestination(
      trainQuery: 'IR55',
      destStopIdCanons: const ['8500207'],
      resolveDestinationName: false,
    );

    expect(stationboardRequest, isNotNull);
    expect(stationboardRequest!.queryParameters['type'], 'arrival');
  });

  group('destination stationboard stop recovery', () {
    const primaryId = '8501001';
    const firstAlternateId = '8501002';
    const secondAlternateId = '8501003';
    const stopNames = <String, String>{
      primaryId: 'Oensingen',
      firstAlternateId: 'Oensingen, Bahnhof',
      secondAlternateId: 'Oensingen, Bahnhof Süd',
    };

    TransportService serviceFor({
      required Map<String, List<Map<String, dynamic>>> stationboards,
      required List<String> fetchedStationboards,
    }) {
      return TransportService(
        httpGet: (uri, {headers}) async {
          if (uri.path.endsWith('/locations')) {
            final id = uri.queryParameters['id'];
            if (id != null) {
              return _jsonResponse({
                'stations': [
                  {'id': id, 'name': stopNames[id] ?? id},
                ],
              });
            }
            return _jsonResponse({
              'stations': stopNames.entries
                  .map((entry) => {'id': entry.key, 'name': entry.value})
                  .toList(),
            });
          }
          if (uri.path.endsWith('/stationboard')) {
            final id = uri.queryParameters['id']!;
            fetchedStationboards.add(id);
            return _jsonResponse({
              'stationboard': stationboards[id] ?? const <Object>[],
            });
          }
          return http.Response('not found', 404);
        },
      );
    }

    test('normal query stops after usable primary station', () async {
      final fetched = <String>[];
      final scheduled = DateTime.now().add(const Duration(hours: 1));
      final service = serviceFor(
        fetchedStationboards: fetched,
        stationboards: {
          primaryId: [_stationboardItem(scheduled: scheduled)],
          firstAlternateId: [
            _stationboardItem(
              scheduled: scheduled.add(const Duration(minutes: 5)),
            ),
          ],
        },
      );

      final candidates = await service.fallbackArrivalsAtDestination(
        trainQuery: '',
        destStopIdCanons: const [
          primaryId,
          firstAlternateId,
          secondAlternateId,
        ],
        destNameQuery: 'Oensingen Bahnhof',
        resolveDestinationName: false,
      );

      expect(fetched, [primaryId]);
      expect(candidates, hasLength(1));
      expect(candidates.single.stopId, primaryId);
    });

    test('empty primary falls through to the first usable alternate', () async {
      final fetched = <String>[];
      final scheduled = DateTime.now().add(const Duration(hours: 1));
      final service = serviceFor(
        fetchedStationboards: fetched,
        stationboards: {
          primaryId: const [],
          firstAlternateId: [_stationboardItem(scheduled: scheduled)],
        },
      );

      final candidates = await service.fallbackArrivalsAtDestination(
        trainQuery: '',
        destStopIdCanons: const [primaryId, firstAlternateId],
        destNameQuery: 'Oensingen Bahnhof',
        resolveDestinationName: false,
      );

      expect(fetched, [primaryId, firstAlternateId]);
      expect(candidates.single.stopId, firstAlternateId);
    });

    test(
      'successful recovery prevents later alternatives from merging',
      () async {
        final fetched = <String>[];
        final scheduled = DateTime.now().add(const Duration(hours: 1));
        final service = serviceFor(
          fetchedStationboards: fetched,
          stationboards: {
            primaryId: const [],
            firstAlternateId: [_stationboardItem(scheduled: scheduled)],
            secondAlternateId: [
              _stationboardItem(
                scheduled: scheduled.add(const Duration(minutes: 5)),
              ),
            ],
          },
        );

        final candidates = await service.fallbackArrivalsAtDestination(
          trainQuery: '',
          destStopIdCanons: const [
            primaryId,
            firstAlternateId,
            secondAlternateId,
          ],
          destNameQuery: 'Oensingen Bahnhof',
          resolveDestinationName: false,
        );

        expect(fetched, [primaryId, firstAlternateId]);
        expect(candidates, hasLength(1));
        expect(candidates.single.stopId, firstAlternateId);
      },
    );

    test(
      'explicit local qualifier preserves bounded multi-stop fetch',
      () async {
        final fetched = <String>[];
        final scheduled = DateTime.now().add(const Duration(hours: 1));
        final service = serviceFor(
          fetchedStationboards: fetched,
          stationboards: {
            primaryId: [_stationboardItem(scheduled: scheduled)],
            firstAlternateId: [
              _stationboardItem(
                scheduled: scheduled.add(const Duration(minutes: 5)),
              ),
            ],
            secondAlternateId: [
              _stationboardItem(
                scheduled: scheduled.add(const Duration(minutes: 10)),
              ),
            ],
          },
        );

        final candidates = await service.fallbackArrivalsAtDestination(
          trainQuery: '',
          destStopIdCanons: const [
            primaryId,
            firstAlternateId,
            secondAlternateId,
          ],
          destNameQuery: 'Oensingen Bahnhof Süd',
          resolveDestinationName: false,
        );

        expect(fetched, [primaryId, firstAlternateId, secondAlternateId]);
        expect(candidates, hasLength(3));
      },
    );

    test('train filter recovers when primary has only another line', () async {
      final fetched = <String>[];
      final scheduled = DateTime.now().add(const Duration(hours: 1));
      final service = serviceFor(
        fetchedStationboards: fetched,
        stationboards: {
          primaryId: [
            _stationboardItem(
              scheduled: scheduled,
              category: 'IC',
              number: '5',
            ),
          ],
          firstAlternateId: [
            _stationboardItem(
              scheduled: scheduled.add(const Duration(minutes: 5)),
            ),
          ],
          secondAlternateId: [
            _stationboardItem(
              scheduled: scheduled.add(const Duration(minutes: 10)),
            ),
          ],
        },
      );

      final candidates = await service.fallbackArrivalsAtDestination(
        trainQuery: 'IR55',
        destStopIdCanons: const [
          primaryId,
          firstAlternateId,
          secondAlternateId,
        ],
        destNameQuery: 'Oensingen Bahnhof',
        resolveDestinationName: false,
      );

      expect(fetched, [primaryId, firstAlternateId]);
      expect(candidates, hasLength(1));
      expect(candidates.single.displayTrain, 'IR55');
      expect(candidates.single.stopId, firstAlternateId);
    });
  });

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

Future<TripCandidate> _runDirectionFallback({
  required String trainQuery,
  required String destinationId,
  required String destinationName,
  required Map<String, dynamic> item,
}) async {
  final service = TransportService(
    httpGet: (uri, {headers}) async {
      if (uri.path.endsWith('/locations')) {
        return _jsonResponse({
          'stations': [
            {'id': destinationId, 'name': destinationName},
          ],
        });
      }
      if (uri.path.endsWith('/stationboard')) {
        return _jsonResponse({
          'stationboard': [item],
        });
      }
      return http.Response('not found', 404);
    },
  );

  final candidates = await service.fallbackArrivalsAtDestination(
    trainQuery: trainQuery,
    destStopIdCanons: [destinationId],
    resolveDestinationName: false,
  );
  expect(candidates, hasLength(1));
  return candidates.single;
}

Map<String, dynamic> _arrivalDirectionItem({
  required DateTime scheduled,
  required String category,
  required String number,
  required String originName,
  required String destinationId,
  required String destinationName,
  required String destinationLocationId,
  String? terminalName,
}) {
  final timestamp = scheduled.toUtc().millisecondsSinceEpoch ~/ 1000;
  return {
    'name': '$category $number',
    'category': category,
    'number': number,
    // Arrival stationboards can expose the origin side here.
    'to': originName,
    'stop': {
      'arrivalTimestamp': timestamp,
      'station': {'id': destinationId, 'name': destinationName},
      'location': {'id': destinationLocationId},
      'prognosis': const <String, Object?>{},
    },
    'passList': [
      {
        'station': {'id': '8500998', 'name': originName},
      },
      {
        'station': {'id': destinationLocationId, 'name': null},
        'location': {'id': destinationLocationId},
      },
      if (terminalName != null)
        {
          'station': {'id': '8500999', 'name': terminalName},
        },
    ],
  };
}

Map<String, dynamic> _stationboardItem({
  required DateTime scheduled,
  DateTime? prognosisArrival,
  DateTime? prognosisDeparture,
  bool scheduledInDepartureField = false,
  String category = 'IR',
  String number = '55',
}) {
  return {
    'name': '$category $number',
    'category': category,
    'number': number,
    'to': 'Zürich HB',
    'stop': {
      if (scheduledInDepartureField)
        'departureTimestamp': scheduled.toUtc().millisecondsSinceEpoch ~/ 1000
      else
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
