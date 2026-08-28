class StopEta {
  final String stopIdRaw;
  final String stopIdCanon;
  final DateTime etaLocal;
  final int delaySeconds;

  StopEta({
    required this.stopIdRaw,
    required this.stopIdCanon,
    required this.etaLocal,
    required this.delaySeconds,
  });
}

enum DirectionSource {
  gtfsRealtimeLastStop,
  stationboard,
  ojpStopEvent;

  int get confidence => switch (this) {
    gtfsRealtimeLastStop => 1,
    stationboard => 2,
    ojpStopEvent => 3,
  };
}

class TripCandidate {
  final String tripId;
  final String originalTripId;
  final String routeId;
  final String startDate;
  final String startTime;
  final String stopId;
  final DateTime etaLocal;
  final int delaySeconds;
  final String displayTrain;
  final String vehicleLabel;
  final bool destinationMatched;
  final List<StopEta> upcomingStops;
  final String terminalStopId;
  final String terminalStopIdCanon;
  final DirectionSource directionSource;

  TripCandidate({
    required this.tripId,
    this.originalTripId = '',
    required this.routeId,
    required this.startDate,
    required this.startTime,
    required this.stopId,
    required this.etaLocal,
    required this.delaySeconds,
    required this.displayTrain,
    required this.vehicleLabel,
    required this.destinationMatched,
    required this.upcomingStops,
    required this.terminalStopId,
    required this.terminalStopIdCanon,
    this.directionSource = DirectionSource.gtfsRealtimeLastStop,
  });

  String get publicDirection => terminalStopId;

  TripCandidate copyWith({
    String? tripId,
    String? originalTripId,
    String? routeId,
    String? startDate,
    String? startTime,
    String? stopId,
    DateTime? etaLocal,
    int? delaySeconds,
    String? displayTrain,
    String? vehicleLabel,
    bool? destinationMatched,
    List<StopEta>? upcomingStops,
    String? terminalStopId,
    String? terminalStopIdCanon,
    DirectionSource? directionSource,
  }) {
    return TripCandidate(
      tripId: tripId ?? this.tripId,
      originalTripId: originalTripId ?? this.originalTripId,
      routeId: routeId ?? this.routeId,
      startDate: startDate ?? this.startDate,
      startTime: startTime ?? this.startTime,
      stopId: stopId ?? this.stopId,
      etaLocal: etaLocal ?? this.etaLocal,
      delaySeconds: delaySeconds ?? this.delaySeconds,
      displayTrain: displayTrain ?? this.displayTrain,
      vehicleLabel: vehicleLabel ?? this.vehicleLabel,
      destinationMatched: destinationMatched ?? this.destinationMatched,
      upcomingStops: upcomingStops ?? this.upcomingStops,
      terminalStopId: terminalStopId ?? this.terminalStopId,
      terminalStopIdCanon: terminalStopIdCanon ?? this.terminalStopIdCanon,
      directionSource: directionSource ?? this.directionSource,
    );
  }

  TripCandidate withPublicDirection({
    required String direction,
    required DirectionSource source,
  }) {
    final trimmed = direction.trim();
    if (trimmed.isEmpty || source.confidence < directionSource.confidence) {
      return this;
    }
    if (trimmed == terminalStopId && source == directionSource) return this;
    return copyWith(
      terminalStopId: trimmed,
      terminalStopIdCanon: '',
      directionSource: source,
    );
  }

  TripCandidate copyWithDestination(StopEta stop) {
    return copyWith(
      stopId: stop.stopIdRaw,
      etaLocal: stop.etaLocal,
      delaySeconds: stop.delaySeconds,
      destinationMatched: true,
    );
  }
}
