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
}

FeedMessage _feed({
  TripDescriptor_ScheduleRelationship? relationship,
  String? originalTripId,
}) {
  final destinationEta = DateTime.now().add(const Duration(minutes: 30));
  final terminalEta = destinationEta.add(const Duration(minutes: 10));

  TripUpdate_StopTimeUpdate stop(String id, DateTime eta) {
    final seconds = eta.toUtc().millisecondsSinceEpoch ~/ 1000;
    return TripUpdate_StopTimeUpdate(
      stopId: id,
      arrival: TripUpdate_StopTimeEvent.fromJson('{"2":"$seconds"}'),
    );
  }

  final trip = TripDescriptor(
    tripId: 'trip-s20',
    routeId: 'S20',
    startDate: '20260828',
    startTime: '10:00:00',
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
            stop('8500207', destinationEta),
            stop('8500212', terminalEta),
          ],
        ),
      ),
    ],
  );
}

TripCandidate _candidate({
  required String direction,
  required DirectionSource source,
}) {
  return TripCandidate(
    tripId: 'trip-s20',
    originalTripId: 'ch:1:sjyid:100060:SKI-429',
    routeId: 'S20',
    startDate: '20260828',
    startTime: '10:00:00',
    stopId: '8500207',
    etaLocal: DateTime.now().add(const Duration(minutes: 30)),
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
