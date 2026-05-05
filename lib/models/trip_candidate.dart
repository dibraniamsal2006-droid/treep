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

class TripCandidate {
  final String tripId;
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

  TripCandidate({
    required this.tripId,
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
  });

  TripCandidate copyWithDestination(StopEta stop) {
    return TripCandidate(
      tripId: tripId,
      routeId: routeId,
      startDate: startDate,
      startTime: startTime,
      stopId: stop.stopIdRaw,
      etaLocal: stop.etaLocal,
      delaySeconds: stop.delaySeconds,
      displayTrain: displayTrain,
      vehicleLabel: vehicleLabel,
      destinationMatched: true,
      upcomingStops: upcomingStops,
      terminalStopId: terminalStopId,
      terminalStopIdCanon: terminalStopIdCanon,
    );
  }
}
