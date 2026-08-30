import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:treep/models/trip_candidate.dart';
import 'package:treep/services/transport_service.dart';

void main() {
  test('Swiss protobuf field 8 extracts original_trip_id', () {
    const originalTripId = 'ch:1:sjyid:100060:SKI-429';
    final bytes = utf8.encode(originalTripId);
    final trip = TripDescriptor.fromBuffer(<int>[0x42, bytes.length, ...bytes]);

    expect(extractSwissOriginalTripId(trip), originalTripId);
  });

  test('missing Swiss protobuf field 8 is safe', () {
    expect(extractSwissOriginalTripId(TripDescriptor()), isEmpty);
  });

  test('CANCELED GTFS trip is not emitted as a normal candidate', () {
    final service = TransportService();
    final feed = _feed(
      relationship: TripDescriptor_ScheduleRelationship.CANCELED,
    );

    final candidates = service.findCandidates(
      feed,
      'S20',
      '8500207',
      requireDestinationMatch: true,
    );

    expect(candidates, isEmpty);
  });

  test('scheduled S20 matching remains unchanged', () {
    final service = TransportService();

    final candidates = service.findCandidates(
      _feed(originalTripId: 'ch:1:sjyid:100060:S20-CONTROL'),
      'S20',
      '8500207',
      requireDestinationMatch: true,
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.displayTrain, 'S20');
    expect(candidates.single.originalTripId, 'ch:1:sjyid:100060:S20-CONTROL');
    expect(
      candidates.single.directionSource,
      DirectionSource.gtfsRealtimeLastStop,
    );
  });

  test('ADDED and UNSCHEDULED journeys are not assigned OJP identity', () {
    final service = TransportService();

    for (final relationship in <TripDescriptor_ScheduleRelationship>[
      TripDescriptor_ScheduleRelationship.ADDED,
      TripDescriptor_ScheduleRelationship.UNSCHEDULED,
    ]) {
      final candidates = service.findCandidates(
        _feed(
          relationship: relationship,
          originalTripId: 'ch:1:sjyid:100060:SHOULD-NOT-JOIN',
        ),
        'S20',
        '8500207',
        requireDestinationMatch: true,
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.originalTripId, isEmpty);
    }
  });

  test(
    'refresh preserves trusted OJP direction against GTFS last stop',
    () async {
      final service = _FeedTransportService(_feed());
      final refreshed = await service.refreshCandidateEta(
        _candidate(
          direction: 'Solothurn',
          source: DirectionSource.ojpStopEvent,
        ),
      );

      expect(refreshed, isNotNull);
      expect(refreshed!.publicDirection, 'Solothurn');
      expect(refreshed.directionSource, DirectionSource.ojpStopEvent);
    },
  );

  test(
    'refresh preserves trusted stationboard direction against GTFS last stop',
    () async {
      final service = _FeedTransportService(_feed());
      final refreshed = await service.refreshCandidateEta(
        _candidate(
          direction: 'Solothurn',
          source: DirectionSource.stationboard,
        ),
      );

      expect(refreshed, isNotNull);
      expect(refreshed!.publicDirection, 'Solothurn');
      expect(refreshed.directionSource, DirectionSource.stationboard);
    },
  );

  test(
    'refresh rejects the same trip id from a different service date',
    () async {
      final service = _FeedTransportService(_feed(startDate: '20260829'));

      final refreshed = await service.refreshCandidateEta(
        _candidate(
          direction: 'Solothurn',
          source: DirectionSource.gtfsRealtimeLastStop,
        ),
      );

      expect(refreshed, isNull);
    },
  );

  test(
    'refresh rejects a different trip with matching route and time',
    () async {
      final service = _FeedTransportService(_feed(tripId: 'other-trip-s20'));

      final refreshed = await service.refreshCandidateEta(
        _candidate(
          direction: 'Solothurn',
          source: DirectionSource.gtfsRealtimeLastStop,
        ),
      );

      expect(refreshed, isNull);
    },
  );

  test('valid realtime update changes only its exact trip', () async {
    final service = _FeedTransportService(_feed());
    final before = DateTime.now().add(const Duration(minutes: 10));

    final refreshed = await service.refreshCandidateEta(
      _candidate(
        direction: 'Solothurn',
        source: DirectionSource.gtfsRealtimeLastStop,
        etaLocal: before,
      ),
    );

    expect(refreshed, isNotNull);
    expect(refreshed!.etaLocal.isAfter(before), isTrue);
    expect(refreshed.tripId, 'trip-s20');
    expect(refreshed.startDate, '20260828');
  });

  test('adjacent same-line journeys refresh only the exact identity', () async {
    final feed = FeedMessage(
      entity: [
        ..._feed(
          tripId: 'trip-s20-a',
          startTime: '10:00:00',
          destinationMinutes: 24,
        ).entity,
        ..._feed(
          tripId: 'trip-s20-b',
          startTime: '10:30:00',
          destinationMinutes: 36,
        ).entity,
      ],
    );
    final service = _FeedTransportService(feed);

    final refreshed = await service.refreshCandidateEta(
      _candidate(
        tripId: 'trip-s20-b',
        startTime: '10:30:00',
        direction: 'Solothurn',
        source: DirectionSource.gtfsRealtimeLastStop,
      ),
    );

    expect(refreshed, isNotNull);
    expect(refreshed!.tripId, 'trip-s20-b');
    expect(refreshed.startTime, '10:30:00');
    expect(
      refreshed.etaLocal.difference(DateTime.now()).inMinutes,
      inInclusiveRange(34, 36),
    );
  });

  test('opposite-direction journey cannot capture an exact refresh', () async {
    final feed = FeedMessage(
      entity: [
        ..._feed(
          tripId: 'trip-east',
          startTime: '11:00:00',
          destinationMinutes: 25,
          terminalStopId: '8500991',
        ).entity,
        ..._feed(
          tripId: 'trip-west',
          startTime: '11:30:00',
          destinationMinutes: 35,
          terminalStopId: '8500992',
        ).entity,
      ],
    );
    final service = _FeedTransportService(feed);

    final refreshed = await service.refreshCandidateEta(
      _candidate(
        tripId: 'trip-west',
        startTime: '11:30:00',
        direction: '8500992',
        source: DirectionSource.gtfsRealtimeLastStop,
      ),
    );

    expect(refreshed, isNotNull);
    expect(refreshed!.tripId, 'trip-west');
    expect(refreshed.terminalStopIdCanon, '8500992');
  });

  test('exact identity accepts a large realtime ETA change', () async {
    final service = _FeedTransportService(_feed(destinationMinutes: 180));

    final refreshed = await service.refreshCandidateEta(
      _candidate(
        direction: 'Solothurn',
        source: DirectionSource.gtfsRealtimeLastStop,
        etaLocal: DateTime.now().add(const Duration(minutes: 5)),
      ),
    );

    expect(refreshed, isNotNull);
    expect(refreshed!.tripId, 'trip-s20');
    expect(
      refreshed.etaLocal.difference(DateTime.now()).inMinutes,
      inInclusiveRange(178, 180),
    );
  });

  test('provider disappearance returns no fabricated refresh', () async {
    final service = _SequenceFeedTransportService([FeedMessage(), _feed()]);
    final candidate = _candidate(
      direction: 'Solothurn',
      source: DirectionSource.gtfsRealtimeLastStop,
    );

    expect(await service.refreshCandidateEta(candidate), isNull);
    expect(await service.refreshCandidateEta(candidate), isNotNull);
  });

  test(
    'realtime row without trip identity cannot update a stable trip',
    () async {
      final service = _FeedTransportService(_feed(tripId: ''));

      final refreshed = await service.refreshCandidateEta(
        _candidate(
          direction: 'Solothurn',
          source: DirectionSource.gtfsRealtimeLastStop,
        ),
      );

      expect(refreshed, isNull);
    },
  );
}

FeedMessage _feed({
  TripDescriptor_ScheduleRelationship? relationship,
  String? originalTripId,
  String tripId = 'trip-s20',
  String startDate = '20260828',
  String startTime = '10:00:00',
  int destinationMinutes = 30,
  String terminalStopId = '8500212',
}) {
  final destinationEta = DateTime.now().add(
    Duration(minutes: destinationMinutes),
  );
  final originDeparture = destinationEta.subtract(const Duration(minutes: 10));
  final terminalEta = destinationEta.add(const Duration(minutes: 10));

  TripUpdate_StopTimeUpdate stop(String id, DateTime eta) {
    final seconds = eta.toUtc().millisecondsSinceEpoch ~/ 1000;
    return TripUpdate_StopTimeUpdate(
      stopId: id,
      arrival: TripUpdate_StopTimeEvent.fromJson('{"2":"$seconds"}'),
    );
  }

  final trip = TripDescriptor(
    tripId: tripId,
    routeId: 'S20',
    startDate: startDate,
    startTime: startTime,
    scheduleRelationship: relationship,
  );
  if (originalTripId != null) {
    final bytes = utf8.encode(originalTripId);
    trip.mergeFromBuffer(<int>[0x42, bytes.length, ...bytes]);
  }

  return FeedMessage(
    entity: [
      FeedEntity(
        id: 'entity-s20',
        tripUpdate: TripUpdate(
          trip: trip,
          stopTimeUpdate: [
            TripUpdate_StopTimeUpdate(
              stopSequence: 1,
              stopId: '8500001',
              departure: TripUpdate_StopTimeEvent.fromJson(
                '{"2":"${originDeparture.toUtc().millisecondsSinceEpoch ~/ 1000}"}',
              ),
            ),
            stop('8500207', destinationEta)..stopSequence = 2,
            stop(terminalStopId, terminalEta)..stopSequence = 3,
          ],
        ),
      ),
    ],
  );
}

TripCandidate _candidate({
  required String direction,
  required DirectionSource source,
  DateTime? etaLocal,
  String tripId = 'trip-s20',
  String startTime = '10:00:00',
}) {
  return TripCandidate(
    tripId: tripId,
    originalTripId: 'ch:1:sjyid:100060:SKI-429',
    routeId: 'S20',
    startDate: '20260828',
    startTime: startTime,
    stopId: '8500207',
    etaLocal: etaLocal ?? DateTime.now().add(const Duration(minutes: 30)),
    delaySeconds: 0,
    displayTrain: 'S20',
    vehicleLabel: 'Train',
    destinationMatched: true,
    upcomingStops: const [],
    terminalStopId: direction,
    terminalStopIdCanon: '',
    directionSource: source,
  );
}

class _FeedTransportService extends TransportService {
  _FeedTransportService(this.feed);

  final FeedMessage feed;

  @override
  Future<FeedMessage> fetchGtfsRtFeed() async => feed;
}

class _SequenceFeedTransportService extends TransportService {
  _SequenceFeedTransportService(this.feeds);

  final List<FeedMessage> feeds;
  int index = 0;

  @override
  Future<FeedMessage> fetchGtfsRtFeed() async => feeds[index++];
}
