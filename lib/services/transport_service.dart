import 'dart:async';
import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:http/http.dart' as http;

import '../models/trip_candidate.dart';
import 'matching_service.dart';
import 'ojp_public_direction_service.dart';

typedef CandidateTracer =
    void Function(String stage, List<TripCandidate> candidates, {int max});
typedef TransportHttpGet =
    Future<http.Response> Function(Uri uri, {Map<String, String>? headers});

String extractSwissOriginalTripId(TripDescriptor trip) {
  final values = trip.unknownFields.getField(8)?.lengthDelimited;
  if (values == null || values.length != 1) return '';
  try {
    return utf8.decode(values.single).trim();
  } on FormatException {
    return '';
  }
}

String? swissStopPointRefFromGtfsStopId(String raw) {
  final trimmed = raw.trim();
  final sloidMatch = RegExp(
    r'^ch:1:sloid:(\d+)(?::\d+)*$',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (sloidMatch != null) {
    final rawBase = sloidMatch.group(1)!;
    final base = rawBase.length == 7 && rawBase.startsWith('85')
        ? rawBase.substring(2)
        : rawBase;
    final didok = int.tryParse(base);
    return didok == null ? null : 'ch:1:sloid:$didok';
  }

  final digits = RegExp(
    r'\d+',
  ).allMatches(trimmed).map((match) => match.group(0)!).join();
  if (digits.length != 7 || !digits.startsWith('85')) return null;
  final didok = int.tryParse(digits.substring(2));
  if (didok == null) return null;
  return 'ch:1:sloid:$didok';
}

String? swissGtfsStopIdFromStopPointRef(String raw) {
  final ref = swissStopPointRefFromGtfsStopId(raw);
  if (ref == null) return null;
  final didokRaw = ref.substring('ch:1:sloid:'.length);
  final didok = int.tryParse(didokRaw);
  if (didok == null || didok < 0 || didok > 99999) return null;
  return '85${didok.toString().padLeft(5, '0')}';
}

enum StopResolutionFailure { notFound, temporaryUnavailable }

enum ArrivalFallbackFailure { temporaryUnavailable }

OjpLocationClient _selectOjpLocationClient(
  OjpPublicDirectionClient? stopEventClient,
  OjpLocationClient? locationClient,
) {
  if (locationClient != null) return locationClient;
  if (stopEventClient is OjpLocationClient) {
    return stopEventClient as OjpLocationClient;
  }
  return OjpStopEventClient();
}

enum _FallbackPrognosisSource { scheduled, arrival, departure }

class _FallbackTiming {
  const _FallbackTiming({
    required this.scheduledLocal,
    required this.etaLocal,
    required this.delaySeconds,
    required this.scheduledTimestamp,
    required this.prognosisSource,
    required this.rejectedPrognosis,
  });

  final DateTime scheduledLocal;
  final DateTime etaLocal;
  final int delaySeconds;
  final int scheduledTimestamp;
  final _FallbackPrognosisSource prognosisSource;
  final bool rejectedPrognosis;

  int get quality => switch (prognosisSource) {
    _FallbackPrognosisSource.arrival => 3,
    _FallbackPrognosisSource.departure => 2,
    _FallbackPrognosisSource.scheduled => 1,
  };
}

class _FallbackCandidateRecord {
  const _FallbackCandidateRecord({
    required this.candidate,
    required this.timingQuality,
  });

  final TripCandidate candidate;
  final int timingQuality;
}

class _OjpArrivalFallbackResult {
  const _OjpArrivalFallbackResult(this.candidates, {required this.failed});

  final List<TripCandidate> candidates;
  final bool failed;
}

class _FallbackDirectionHint {
  const _FallbackDirectionHint({
    required this.value,
    required this.destinationFoundInPassList,
    required this.passListDerivedValue,
    required this.source,
  });

  final String value;
  final bool destinationFoundInPassList;
  final String passListDerivedValue;
  final String source;
}

class _ResolvedFallbackDirection {
  const _ResolvedFallbackDirection(this.value, this.source);

  final String value;
  final String source;
}

class TransportService {
  TransportService({
    this.trace,
    this.traceCandidates,
    this.upcomingWindowHoursProvider,
    TransportHttpGet? httpGet,
    OjpPublicDirectionClient? ojpClient,
    OjpLocationClient? ojpLocationClient,
    String? Function()? ojpApiKeyProvider,
  }) : _httpGet = httpGet ?? http.get,
       _ojpClient = ojpClient ?? OjpStopEventClient(),
       _ojpLocationClient = _selectOjpLocationClient(
         ojpClient,
         ojpLocationClient,
       ),
       _ojpApiKeyProvider = ojpApiKeyProvider ?? _defaultOjpApiKey;

  final void Function(String message)? trace;
  final CandidateTracer? traceCandidates;
  final int Function()? upcomingWindowHoursProvider;
  final TransportHttpGet _httpGet;
  final OjpPublicDirectionClient _ojpClient;
  final OjpLocationClient _ojpLocationClient;
  final String? Function() _ojpApiKeyProvider;

  StopResolutionFailure? lastStopResolutionFailure;
  ArrivalFallbackFailure? lastArrivalFallbackFailure;

  static const Duration _gtfsRtMinInterval = Duration(seconds: 13);
  static const Duration _gtfsRtFeedCacheTtl = Duration(seconds: 20);
  static const Duration _stopNameFailureRetryDelay = Duration(seconds: 30);
  static const Duration _maxPlausibleEarlyPrognosis = Duration(hours: 1);
  static const Duration _maxPlausiblePositiveDelay = Duration(hours: 24);
  static const int _maxPickerHorizonHours = 6;

  DateTime? _lastGtfsRtCallAt;
  Future<http.Response>? _gtfsRtInFlight;
  FeedMessage? _cachedFeed;
  DateTime? _cachedFeedAt;

  final Map<String, String> _stopNameCache = {};
  final Map<String, Future<void>> _stopNameInFlight = {};
  final Map<String, DateTime> _stopNameFailureAt = {};
  final Map<String, String> _routeShortNameByRouteId = {};

  void _trace(String message) => trace?.call(message);

  static String? _defaultOjpApiKey() {
    try {
      return dotenv.env['OJP_API_KEY'];
    } catch (_) {
      return null;
    }
  }

  void _traceStageCandidates(
    String stage,
    List<TripCandidate> candidates, {
    int max = 6,
  }) {
    traceCandidates?.call(stage, candidates, max: max);
  }

  Future<http.Response> getGtfsRtResponse() => _getGtfsRtResponse();

  Future<http.Response> _getGtfsRtResponse() async {
    final key = dotenv.env['OPENTRANSPORTDATA_API_KEY'];
    if (key == null || key.trim().isEmpty || key == 'YOUR_API_KEY') {
      throw Exception('No real API key set in .env yet.');
    }
    if (_gtfsRtInFlight != null) return _gtfsRtInFlight!;

    final completer = Completer<http.Response>();
    _gtfsRtInFlight = completer.future;
    try {
      final now = DateTime.now();
      if (_lastGtfsRtCallAt != null) {
        final elapsed = now.difference(_lastGtfsRtCallAt!);
        if (elapsed < _gtfsRtMinInterval) {
          await Future.delayed(_gtfsRtMinInterval - elapsed);
        }
      }

      final uri = Uri.parse('https://api.opentransportdata.swiss/la/gtfs-rt');
      http.Response res = await _httpGet(
        uri,
        headers: {
          'Authorization': 'Bearer $key',
          'Accept':
              'application/x-protobuf, application/octet-stream;q=0.9, */*;q=0.8',
        },
      ).timeout(const Duration(seconds: 12));

      _lastGtfsRtCallAt = DateTime.now();

      if (res.statusCode == 429) {
        final retryAfterRaw = res.headers['retry-after'];
        final retrySeconds = int.tryParse((retryAfterRaw ?? '').trim());
        final wait = Duration(seconds: retrySeconds ?? 60);
        await Future.delayed(wait);

        res = await _httpGet(
          uri,
          headers: {
            'Authorization': 'Bearer $key',
            'Accept':
                'application/x-protobuf, application/octet-stream;q=0.9, */*;q=0.8',
          },
        ).timeout(const Duration(seconds: 12));

        _lastGtfsRtCallAt = DateTime.now();
      }

      completer.complete(res);
    } catch (e, st) {
      completer.completeError(e, st);
    } finally {
      _gtfsRtInFlight = null;
    }

    return completer.future;
  }

  Future<FeedMessage> fetchGtfsRtFeed() async {
    if (_cachedFeed != null && _cachedFeedAt != null) {
      final age = DateTime.now().difference(_cachedFeedAt!);
      if (age <= _gtfsRtFeedCacheTtl) return _cachedFeed!;
    }

    final res = await _getGtfsRtResponse();
    if (res.statusCode != 200) {
      throw Exception(
        'GTFS-RT HTTP ${res.statusCode} (${res.headers['content-type'] ?? 'unknown'})',
      );
    }

    final feed = FeedMessage.fromBuffer(res.bodyBytes);
    _cachedFeed = feed;
    _cachedFeedAt = DateTime.now();
    return feed;
  }

  Future<List<String>> resolveStopIdsFromName(String query) async {
    lastStopResolutionFailure = null;
    final uri = Uri.parse(
      'https://transport.opendata.ch/v1/locations?query=${Uri.encodeComponent(query)}&type=station',
    );

    http.Response res;
    try {
      res = await _httpGet(uri).timeout(const Duration(seconds: 6));
    } on TimeoutException {
      _trace(
        'Stop-id resolution failed query="$query" reason=timeout '
        'timeoutSeconds=6',
      );
      return _resolveStopIdsFromOjp(query);
    } catch (error) {
      _trace(
        'Stop-id resolution failed query="$query" '
        'reason=network-exception type=${error.runtimeType}',
      );
      return _resolveStopIdsFromOjp(query);
    }
    if (res.statusCode != 200) {
      _trace(
        'Stop-id resolution failed query="$query" '
        'reason=http-${res.statusCode}',
      );
      if (res.statusCode == 429 || res.statusCode >= 500) {
        return _resolveStopIdsFromOjp(query);
      }
      lastStopResolutionFailure = StopResolutionFailure.notFound;
      return const [];
    }

    dynamic decoded;
    try {
      decoded = json.decode(utf8.decode(res.bodyBytes, allowMalformed: true));
    } catch (error) {
      _trace(
        'Stop-id resolution failed query="$query" '
        'reason=malformed-json type=${error.runtimeType}',
      );
      return _resolveStopIdsFromOjp(query);
    }
    if (decoded is! Map) {
      return _resolveStopIdsFromOjp(query);
    }

    final stations = decoded['stations'];
    if (stations is! List || stations.isEmpty) {
      lastStopResolutionFailure = StopResolutionFailure.notFound;
      return const [];
    }

    final q = query.trim().toLowerCase();
    final scored = <({String canon, double score})>[];

    for (final s in stations) {
      if (s is! Map) continue;

      final name = (s['name'] ?? '').toString();
      final rawId = (s['id'] ?? '').toString();
      final canon = normalizeStopId(rawId);
      if (canon == null) continue;
      if (name.trim().isNotEmpty) {
        _stopNameCache.putIfAbsent(canon, () => name.trim());
      }

      double score = 0;
      if (canon.startsWith('85')) score += 5;

      final n = name.toLowerCase();
      if (n == q) score += 12;
      if (n.startsWith(q)) score += 7;
      if (n.contains(q)) score += 3;

      final apiScore = s['score'];
      if (apiScore is num) score += apiScore.toDouble();

      scored.add((canon: canon, score: score));
    }

    if (scored.isEmpty) {
      lastStopResolutionFailure = StopResolutionFailure.notFound;
      return const [];
    }

    scored.sort((a, b) => b.score.compareTo(a.score));

    final out = <String>[];
    final seen = <String>{};
    for (final x in scored) {
      if (seen.add(x.canon)) out.add(x.canon);
      if (out.length >= 8) break;
    }

    return out;
  }

  Future<List<String>> _resolveStopIdsFromOjp(String query) async {
    final apiKey = _ojpApiKeyProvider()?.trim() ?? '';
    if (apiKey.isEmpty || apiKey == 'YOUR_API_KEY') {
      lastStopResolutionFailure = StopResolutionFailure.temporaryUnavailable;
      _trace('OJP stop resolution skipped reason=missing-api-key');
      return const [];
    }

    try {
      final records = await _ojpLocationClient.fetchLocations(
        apiKey: apiKey,
        name: query,
        numberOfResults: 10,
      );
      final queryNorm = MatchingService.normalizeStationToken(query);
      final exact = records.where(
        (record) =>
            MatchingService.normalizeStationToken(record.name) == queryNorm,
      );
      final byStopId = <String, OjpLocationRecord>{};
      for (final record in exact) {
        final stopId = swissGtfsStopIdFromStopPointRef(record.stopPlaceRef);
        if (stopId != null) byStopId.putIfAbsent(stopId, () => record);
      }
      if (byStopId.length != 1) {
        lastStopResolutionFailure = StopResolutionFailure.notFound;
        _trace(
          'OJP stop resolution rejected query="$query" '
          'reason=${byStopId.isEmpty ? "no-exact-match" : "ambiguous-exact-match"}',
        );
        return const [];
      }

      final entry = byStopId.entries.single;
      _stopNameCache[entry.key] = entry.value.name;
      lastStopResolutionFailure = null;
      _trace(
        'OJP stop resolution confirmed query="$query" stopId=${entry.key}',
      );
      return <String>[entry.key];
    } catch (error) {
      lastStopResolutionFailure = StopResolutionFailure.temporaryUnavailable;
      _trace(
        'OJP stop resolution failed query="$query" '
        'reason=${error.runtimeType}',
      );
      return const [];
    }
  }

  String? normalizeStopId(String raw) {
    final digits = RegExp(
      r'\d+',
    ).allMatches(raw).map((m) => m.group(0)!).join();
    if (digits.isEmpty) return null;

    if (digits.length >= 7) {
      final tail7 = digits.substring(digits.length - 7);
      if (tail7.startsWith('85')) return tail7;

      for (int i = 0; i <= digits.length - 7; i++) {
        final w = digits.substring(i, i + 7);
        if (w.startsWith('85')) return w;
      }
      return tail7;
    }

    return digits;
  }

  static _FallbackTiming? _fallbackTimingFromStopMap(Map stopMap) {
    int? asPositiveInt(dynamic value) {
      final parsed = switch (value) {
        int v => v,
        num v => v.toInt(),
        null => null,
        _ => int.tryParse(value.toString()),
      };
      return parsed != null && parsed > 0 ? parsed : null;
    }

    DateTime? parseIsoFlexible(dynamic value) {
      final raw = value?.toString().trim() ?? '';
      if (raw.isEmpty) return null;
      return DateTime.tryParse(raw)?.toLocal();
    }

    final schedArrivalTs = asPositiveInt(stopMap['arrivalTimestamp']);
    final schedDepartureTs = asPositiveInt(stopMap['departureTimestamp']);
    final usesScheduledArrival = schedArrivalTs != null;
    final schedTs = schedArrivalTs ?? schedDepartureTs;
    if (schedTs == null) return null;

    final scheduledLocal = DateTime.fromMillisecondsSinceEpoch(
      schedTs * 1000,
      isUtc: true,
    ).toLocal();
    final prognosis = stopMap['prognosis'];
    final prognosisMap = prognosis is Map ? prognosis : null;
    final prognosisArrival = parseIsoFlexible(prognosisMap?['arrival']);
    final prognosisDeparture = parseIsoFlexible(prognosisMap?['departure']);

    var rejectedPrognosis = false;
    DateTime? plausible(DateTime? value) {
      if (value == null) return null;
      final delta = value.difference(scheduledLocal);
      if (delta < -_maxPlausibleEarlyPrognosis ||
          delta > _maxPlausiblePositiveDelay) {
        rejectedPrognosis = true;
        return null;
      }
      return value;
    }

    // Only apply realtime information for the same event kind that supplied
    // the schedule. Arrival stationboards can encode their scheduled arrival
    // in departureTimestamp; in that case prognosis.arrival is not a safe
    // substitute for a missing prognosis.departure. Missing matching realtime
    // data must leave the scheduled time intact.
    final selected = usesScheduledArrival
        ? plausible(prognosisArrival)
        : plausible(prognosisDeparture);
    final source = selected == null
        ? _FallbackPrognosisSource.scheduled
        : (usesScheduledArrival
              ? _FallbackPrognosisSource.arrival
              : _FallbackPrognosisSource.departure);
    final etaLocal = selected ?? scheduledLocal;

    return _FallbackTiming(
      scheduledLocal: scheduledLocal,
      etaLocal: etaLocal,
      delaySeconds: etaLocal.difference(scheduledLocal).inSeconds,
      scheduledTimestamp: schedTs,
      prognosisSource: source,
      rejectedPrognosis: rejectedPrognosis,
    );
  }

  Future<void> ensureStopName(String canonStopId) async {
    if (canonStopId.isEmpty) return;
    if (_stopNameCache.containsKey(canonStopId)) return;

    final lastFailure = _stopNameFailureAt[canonStopId];
    if (lastFailure != null &&
        DateTime.now().difference(lastFailure) < _stopNameFailureRetryDelay) {
      return;
    }

    if (_stopNameInFlight.containsKey(canonStopId)) {
      await _stopNameInFlight[canonStopId];
      return;
    }

    final fut = () async {
      try {
        final id = MatchingService.toOpendataId(canonStopId);

        http.Response res;
        final uri = Uri.parse(
          'https://transport.opendata.ch/v1/locations?id=${Uri.encodeComponent(id)}',
        );
        res = await _httpGet(uri).timeout(const Duration(seconds: 8));

        if (res.statusCode != 200) {
          final altUri = Uri.parse(
            'https://transport.opendata.ch/v1/locations?query=${Uri.encodeComponent(id)}&type=station',
          );
          res = await _httpGet(altUri).timeout(const Duration(seconds: 8));
        }

        if (res.statusCode != 200) {
          _recordStopNameFailure(canonStopId, 'http-${res.statusCode}');
          return;
        }

        final decoded = json.decode(
          utf8.decode(res.bodyBytes, allowMalformed: true),
        );
        final stations = (decoded is Map) ? decoded['stations'] : null;
        if (stations is! List || stations.isEmpty) {
          _recordStopNameFailure(canonStopId, 'empty-or-malformed-response');
          return;
        }

        Map? best;
        for (final s in stations) {
          if (s is! Map) continue;
          final idRaw = (s['id'] ?? '').toString();
          final idCanon = normalizeStopId(idRaw);
          if (idCanon == canonStopId) {
            best = s;
            break;
          }
        }
        best ??= stations.first is Map ? stations.first as Map : null;
        if (best == null) {
          _recordStopNameFailure(canonStopId, 'no-usable-station');
          return;
        }

        final name = (best['name'] ?? '').toString().trim();
        if (name.isEmpty) {
          _recordStopNameFailure(canonStopId, 'empty-name');
          return;
        }

        _stopNameCache[canonStopId] = name;
        _stopNameFailureAt.remove(canonStopId);
      } catch (error) {
        _recordStopNameFailure(canonStopId, 'exception=${error.runtimeType}');
      }
    }();

    _stopNameInFlight[canonStopId] = fut;
    try {
      await fut;
    } finally {
      _stopNameInFlight.remove(canonStopId);
    }
  }

  void _recordStopNameFailure(String canonStopId, String reason) {
    _stopNameFailureAt[canonStopId] = DateTime.now();
    _trace(
      'Stop-name resolution failed stopId=$canonStopId reason=$reason '
      'retryAfterSeconds=${_stopNameFailureRetryDelay.inSeconds}',
    );
  }

  Future<void> warmStopNamesForCandidates(
    List<TripCandidate> candidates,
  ) async {
    final ids = <String>{};

    for (final c in candidates) {
      final canon = normalizeStopId(c.stopId);
      if (canon != null) ids.add(canon);

      for (final s in c.upcomingStops) {
        ids.add(s.stopIdCanon);
        if (ids.length >= 20) break;
      }
      if (ids.length >= 20) break;
    }

    if (ids.isEmpty) return;
    await _ensureStopNamesBounded(ids);
  }

  Future<void> _ensureStopNamesBounded(
    Iterable<String> ids, {
    int maxConcurrent = 4,
  }) async {
    final pending = ids.toList();
    for (var start = 0; start < pending.length; start += maxConcurrent) {
      final end = (start + maxConcurrent).clamp(0, pending.length);
      await Future.wait(pending.sublist(start, end).map(ensureStopName));
    }
  }

  bool _canAttemptStopName(String canonStopId) {
    if (_stopNameCache.containsKey(canonStopId)) return false;
    final lastFailure = _stopNameFailureAt[canonStopId];
    return lastFailure == null ||
        DateTime.now().difference(lastFailure) >= _stopNameFailureRetryDelay;
  }

  String stopLabel(String rawStopId) {
    final canon = normalizeStopId(rawStopId) ?? rawStopId;
    final name = _stopNameCache[canon];
    if (name == null || name == 'Unknown') return canon;
    return '$name ($canon)';
  }

  String terminalLabel(TripCandidate c) {
    return MatchingService.terminalLabelFor(
      c,
      stopLabel: stopLabel,
      normalizeStopId: normalizeStopId,
    );
  }

  bool stopIdMatches(String stopCanon, String destCanon) {
    final a = normalizeStopId(stopCanon) ?? stopCanon;
    final b = normalizeStopId(destCanon) ?? destCanon;
    if (a == b) return true;

    final aName = (_stopNameCache[a] ?? '').trim();
    final bName = (_stopNameCache[b] ?? '').trim();
    if (aName.isEmpty || bName.isEmpty) return false;

    final aNorm = MatchingService.normalizeStationToken(aName);
    final bNorm = MatchingService.normalizeStationToken(bName);
    if (aNorm.isEmpty || bNorm.isEmpty) return false;

    return aNorm == bNorm;
  }

  /// Returns only stops that are positively proven to be downstream arrivals.
  ///
  /// GTFS-RT may omit earlier calls, so the first supplied update is never
  /// treated as the journey origin. Instead, an occurrence becomes eligible
  /// only after an earlier serviced update from this exact TripUpdate has been
  /// observed in valid journey order. A serviced departure-only occurrence can
  /// be prior-call evidence, but departure-only and skipped occurrences are
  /// never exposed as selectable destinations themselves.
  List<StopEta> _qualifiedDownstreamArrivals(
    TripUpdate tripUpdate,
    DateTime now,
  ) {
    final updates = tripUpdate.stopTimeUpdate;
    var lastSequence = -1;
    for (final update in updates) {
      if (!update.hasStopSequence()) continue;
      if (update.stopSequence <= lastSequence) {
        _trace(
          'GTFS-RT downstream qualification rejected reason=invalid-stop-order '
          'tripId="${tripUpdate.trip.tripId}"',
        );
        return const <StopEta>[];
      }
      lastSequence = update.stopSequence;
    }

    final lowerBound = now.subtract(const Duration(minutes: 2));
    final qualified = <StopEta>[];
    var hasPriorServicedCall = false;

    for (final update in updates) {
      final skipped =
          update.scheduleRelationship ==
          TripUpdate_StopTimeUpdate_ScheduleRelationship.SKIPPED;
      final arrivalTime = update.hasArrival() ? update.arrival.time.toInt() : 0;
      final departureTime = update.hasDeparture()
          ? update.departure.time.toInt()
          : 0;
      final hasUsableServiceEvent =
          !skipped && (arrivalTime != 0 || departureTime != 0);

      if (hasPriorServicedCall && !skipped && arrivalTime != 0) {
        final stopIdRaw = update.stopId;
        final stopCanon = normalizeStopId(stopIdRaw);
        if (stopIdRaw.isNotEmpty && stopCanon != null) {
          final etaLocal = DateTime.fromMillisecondsSinceEpoch(
            arrivalTime * 1000,
            isUtc: true,
          ).toLocal();
          if (!etaLocal.isBefore(lowerBound)) {
            qualified.add(
              StopEta(
                stopIdRaw: stopIdRaw,
                stopIdCanon: stopCanon,
                etaLocal: etaLocal,
                delaySeconds: update.arrival.delay.toInt(),
              ),
            );
          }
        }
      }

      if (hasUsableServiceEvent) hasPriorServicedCall = true;
    }

    return qualified;
  }

  List<TripCandidate> findCandidates(
    FeedMessage feed,
    String trainQuery,
    String destQuery, {
    required bool requireDestinationMatch,
  }) {
    final tq = _normalizeTrainToken(trainQuery);
    final destCanon = normalizeStopId(destQuery) ?? destQuery;

    final now = DateTime.now();
    final List<TripCandidate> out = [];

    for (final e in feed.entity) {
      if (!e.hasTripUpdate()) continue;

      final tu = e.tripUpdate;
      final trip = tu.trip;

      final relationship = trip.scheduleRelationship;
      if (relationship == TripDescriptor_ScheduleRelationship.CANCELED ||
          relationship == TripDescriptor_ScheduleRelationship.DELETED) {
        _trace(
          'GTFS-RT reject reason=schedule-relationship-${relationship.name.toLowerCase()} '
          'tripId="${trip.tripId}"',
        );
        continue;
      }
      final isScheduled =
          !trip.hasScheduleRelationship() ||
          relationship == TripDescriptor_ScheduleRelationship.SCHEDULED;
      final originalTripId = isScheduled
          ? extractSwissOriginalTripId(trip)
          : '';

      final tripId = trip.tripId;
      final routeId = trip.routeId;
      final tripShortName = _tripShortNameFromTripDescriptor(trip);
      final routeShortName = _routeShortNameFromRouteId(routeId);
      final displayTrain = routeId.isNotEmpty ? routeId : tripId;

      final displayNorm = _normalizeTrainToken(displayTrain);
      final tripNorm = _normalizeTrainToken(tripId);
      final routeNorm = _normalizeTrainToken(routeId);
      final tripShortNorm = _normalizeTrainToken(tripShortName);
      final routeShortNorm = _normalizeTrainToken(routeShortName);

      final rawLabels = <String>[
        displayTrain,
        routeId,
        tripId,
        tripShortName,
        routeShortName,
      ];
      final matchesTrain =
          tq.isEmpty ||
          MatchingService.matchesTrainQueryTokenAware(trainQuery, rawLabels);
      if (!matchesTrain) {
        _trace(
          'GTFS-RT reject reason=train_query_mismatch tripId="$tripId" routeId="$routeId" '
          'startDate="${trip.startDate}" startTime="${trip.startTime}" '
          'queryNorm="$tq" displayNorm="$displayNorm" routeNorm="$routeNorm" tripNorm="$tripNorm" '
          'tripShortNorm="$tripShortNorm" routeShortNorm="$routeShortNorm"',
        );
        continue;
      }
      _trace(
        'GTFS-RT match train queryNorm="$tq" routeNorm="$routeNorm" tripShortNorm="$tripShortNorm" '
        'routeShortNorm="$routeShortNorm" tripId="$tripId"',
      );

      final upcoming = _qualifiedDownstreamArrivals(tu, now);
      StopEta? matchedDest;
      String? matchedStopIdRaw;

      for (final stop in upcoming) {
        if (stopIdMatches(stop.stopIdCanon, destCanon) && matchedDest == null) {
          matchedDest = stop;
          matchedStopIdRaw = stop.stopIdRaw;
        }
      }

      if (upcoming.isEmpty) continue;
      final terminal = upcoming.last;
      upcoming.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
      var usedBaselMainFallback = false;

      if (requireDestinationMatch &&
          matchedDest == null &&
          MatchingService.isBaselMainStationQuery(destCanon)) {
        StopEta? baselMain;
        for (final s in upcoming) {
          if (_isBaselMainStationStopHintViaService(s)) {
            baselMain = s;
            break;
          }
        }
        if (baselMain != null) {
          matchedDest = baselMain;
          matchedStopIdRaw = baselMain.stopIdRaw;
          usedBaselMainFallback = true;
          _trace(
            'GTFS-RT destination fallback used=basel-main tripId="$tripId" routeId="$routeId" '
            'destCanon="$destCanon" matchedStopId="${baselMain.stopIdRaw}" etaLocal=${baselMain.etaLocal.toIso8601String()}',
          );
        }
      }

      if (requireDestinationMatch && matchedDest == null) {
        _trace(
          'GTFS-RT reject reason=destination_not_found tripId="$tripId" routeId="$routeId" '
          'startDate="${trip.startDate}" startTime="${trip.startTime}" queryNorm="$tq" '
          'displayNorm="$displayNorm" routeNorm="$routeNorm" tripNorm="$tripNorm" '
          'tripShortNorm="$tripShortNorm" routeShortNorm="$routeShortNorm" '
          'destCanon="$destCanon" destinationFound=false upcomingStops=${upcoming.length}',
        );
        continue;
      }

      final selected = matchedDest ?? upcoming.first;

      final candidate = TripCandidate(
        tripId: tripId,
        originalTripId: originalTripId,
        routeId: routeId,
        startDate: trip.startDate,
        startTime: trip.startTime,
        stopId: matchedStopIdRaw ?? selected.stopIdRaw,
        etaLocal: selected.etaLocal,
        delaySeconds: selected.delaySeconds,
        displayTrain: displayTrain,
        vehicleLabel: MatchingService.vehicleLabelFromDisplay(displayTrain),
        destinationMatched: matchedDest != null,
        upcomingStops: upcoming.take(40).toList(),
        terminalStopId: terminal.stopIdRaw,
        terminalStopIdCanon: terminal.stopIdCanon,
      );
      out.add(candidate);
      _trace(
        'GTFS-RT candidate found tripId=${candidate.tripId} routeId=${candidate.routeId} '
        'stopId=${candidate.stopId} etaLocal=${candidate.etaLocal.toIso8601String()} '
        'delaySeconds=${candidate.delaySeconds} terminal="${terminalLabel(candidate)}" '
        'directionSource=last-available-gtfs-rt-stop '
        'baselMainFallbackUsed=$usedBaselMainFallback',
      );
    }

    out.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    return out.take(15).toList();
  }

  Future<List<TripCandidate>> findCandidatesByTrainAndDestinationName(
    FeedMessage feed,
    String trainQuery,
    String destName,
  ) async {
    final trainOnly = findCandidates(
      feed,
      trainQuery,
      '0',
      requireDestinationMatch: false,
    );
    if (trainOnly.isEmpty) return const <TripCandidate>[];

    const maxCandidates = 15;
    const maxStopsPerCandidate = 40;
    const maxLookupsTotal = 25;

    final lookupIds = <String>{};
    for (final c in trainOnly.take(maxCandidates)) {
      for (final s in c.upcomingStops.take(maxStopsPerCandidate)) {
        if (_canAttemptStopName(s.stopIdCanon)) {
          lookupIds.add(s.stopIdCanon);
        }
        if (lookupIds.length >= maxLookupsTotal) break;
      }
      if (lookupIds.length >= maxLookupsTotal) break;
    }
    await _ensureStopNamesBounded(lookupIds);

    final out = <TripCandidate>[];

    for (final c in trainOnly.take(maxCandidates)) {
      StopEta? matched;

      for (final s in c.upcomingStops.take(maxStopsPerCandidate)) {
        final canon = s.stopIdCanon;
        final name = _stopNameCache[canon];
        if (name == null) continue;

        if (MatchingService.stationNameMatchesQuery(name, destName)) {
          matched = s;
          break;
        }
      }

      if (matched != null) out.add(c.copyWithDestination(matched));
    }

    out.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    return out;
  }

  Future<List<TripCandidate>> fallbackArrivalsAtDestination({
    required String trainQuery,
    required List<String> destStopIdCanons,
    String? destNameQuery,
    int limit = 100,
    bool resolveDestinationName = true,
  }) async {
    lastArrivalFallbackFailure = null;
    final tq = _normalizeTrainToken(trainQuery);
    final hasTrainFilter = tq.isNotEmpty;
    _trace(
      'Destination-fallback start destinationQuery="${destNameQuery ?? ""}" trainQueryNorm="$tq" trainFilter=$hasTrainFilter',
    );

    final uniqueStops = <String>{};
    final maxStops = hasTrainFilter ? 4 : 16;
    for (final s in destStopIdCanons) {
      final canon = normalizeStopId(s) ?? s;
      if (canon.isNotEmpty) uniqueStops.add(canon);
      if (uniqueStops.length >= maxStops) break;
    }

    if (resolveDestinationName && (destNameQuery ?? '').trim().isNotEmpty) {
      final extraResolved = await resolveStopIdsFromName(destNameQuery!);
      for (final raw in extraResolved) {
        final canon = normalizeStopId(raw) ?? raw;
        if (canon.isNotEmpty) uniqueStops.add(canon);
        if (uniqueStops.length >= maxStops) break;
      }
    }
    if (uniqueStops.isEmpty) return const <TripCandidate>[];

    // A Set preserves the caller/resolver relevance order. Do not sort IDs:
    // their numeric order has no relevance meaning.
    final orderedStops = uniqueStops.toList();
    _trace(
      'Destination-fallback fetch destinationQuery="${destNameQuery ?? ""}" '
      'resolvedStopIds=[${orderedStops.join(",")}] limit=$limit',
    );

    if ((destNameQuery ?? '').trim().isNotEmpty) {
      await _ensureStopNamesBounded(orderedStops);
    }
    final stopLabels = orderedStops.map((id) => stopLabel(id)).join(' | ');
    _trace('Destination-fallback stop names=$stopLabels');

    String normText(String s) {
      return s
          .toLowerCase()
          .replaceAll('ü', 'u')
          .replaceAll('ä', 'a')
          .replaceAll('ö', 'o')
          .replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }

    final queryNorm = normText(destNameQuery ?? '');
    final queryTokens = queryNorm
        .split(' ')
        .where((token) => token.isNotEmpty)
        .toSet();
    bool queryHasAny(List<String> toks) => toks.any(queryTokens.contains);

    // Bahnhof/HB/SBB express main-station intent, not a local sub-stop.
    // Ignore those aliases while ranking resolved stop names so an exact
    // "Oensingen, Bahnhof" bus-stop label does not outrank "Oensingen".
    const mainStationAliases = <String>{'bahnhof', 'hb', 'sbb'};
    final rankingQueryNorm = queryTokens
        .where((token) => !mainStationAliases.contains(token))
        .join(' ');

    String primaryDestCanon = orderedStops.first;
    double bestScore = -1e9;
    for (final canon in orderedStops) {
      final stopName = (_stopNameCache[canon] ?? '').trim();
      final stopNorm = normText(stopName);
      double score = 0;

      if (rankingQueryNorm.isNotEmpty) {
        if (stopNorm == rankingQueryNorm) {
          score += 120;
        } else if (stopNorm.startsWith(rankingQueryNorm)) {
          score += 70;
        } else if (stopNorm.contains(rankingQueryNorm)) {
          score += 45;
        }
      }

      if (stopNorm.contains('bahnhof') ||
          stopNorm.contains(' hb ') ||
          stopNorm.endsWith(' hb') ||
          stopNorm.contains(' sbb ') ||
          stopNorm.endsWith(' sbb')) {
        score += 8;
      }

      final qualifierGroups = <List<String>>[
        <String>['west'],
        <String>['ost'],
        <String>['nord'],
        <String>['allmend'],
        <String>['sud', 'sued'],
        <String>['zentrum'],
      ];
      for (final group in qualifierGroups) {
        final hasQualifier = group.any((t) => stopNorm.contains(t));
        if (!hasQualifier) continue;
        if (!queryHasAny(group)) score -= 30;
      }

      if (score > bestScore) {
        bestScore = score;
        primaryDestCanon = canon;
      }
    }

    final qualifierTokens = <String>[
      'west',
      'ost',
      'nord',
      'allmend',
      'sud',
      'sued',
      'zentrum',
    ];
    final queryWantsQualifier = qualifierTokens.any(queryTokens.contains);

    final List<String> stopsToFetch;
    if (queryWantsQualifier) {
      stopsToFetch = orderedStops;
    } else {
      stopsToFetch = <String>[primaryDestCanon];
      for (final canon in orderedStops) {
        if (canon == primaryDestCanon) continue;
        stopsToFetch.add(canon);
      }
    }
    _trace(
      'Destination-fallback selected primaryStopId=$primaryDestCanon '
      'primaryScore=$bestScore fetchStopIds=[${stopsToFetch.join(",")}]',
    );

    final now = DateTime.now();
    final lowerBound = now.subtract(const Duration(seconds: 15));
    final windowEnd = now.add(const Duration(hours: _maxPickerHorizonHours));
    _trace(
      'Upcoming window active: ${upcomingWindowHoursProvider?.call() ?? 2}h',
    );
    _trace('Upcoming window max horizon: ${_maxPickerHorizonHours}h');
    _trace(
      'Destination-fallback window lowerBound=${lowerBound.toIso8601String()} '
      'windowEnd=${windowEnd.toIso8601String()}',
    );

    final allByKey = <String, _FallbackCandidateRecord>{};
    final filteredByKey = <String, _FallbackCandidateRecord>{};
    var stationboardHadTransientFailure = false;
    String? ojpModeFallbackStopId;

    bool mergeCandidate(
      Map<String, _FallbackCandidateRecord> map,
      String key,
      _FallbackCandidateRecord record,
    ) {
      final prev = map[key];
      if (prev == null) {
        map[key] = record;
        return true;
      }
      if (record.timingQuality > prev.timingQuality) {
        map[key] = record;
        return true;
      }
      return false;
    }

    for (var stopIndex = 0; stopIndex < stopsToFetch.length; stopIndex++) {
      final destStopIdCanon = stopsToFetch[stopIndex];
      if (!queryWantsQualifier && stopIndex > 0) {
        if (stopIndex == 1) {
          _trace(
            'Destination-fallback primary empty; recovery alternatives attempted '
            'primaryStopId=$primaryDestCanon',
          );
        }
        _trace(
          'Destination-fallback recovery attempt stopId=$destStopIdCanon '
          'index=$stopIndex',
        );
      }
      final outputCountBefore = hasTrainFilter
          ? filteredByKey.length
          : allByKey.length;
      final stationId = MatchingService.toOpendataId(destStopIdCanon);
      final uri = Uri.parse(
        'https://transport.opendata.ch/v1/stationboard?id=${Uri.encodeComponent(stationId)}&type=arrival&limit=$limit',
      );

      http.Response res;
      try {
        res = await _httpGet(uri).timeout(const Duration(seconds: 6));
      } on TimeoutException {
        stationboardHadTransientFailure = true;
        _trace(
          'Destination-fallback stationboard failed stopId=$destStopIdCanon '
          'reason=timeout timeoutSeconds=6',
        );
        continue;
      } catch (error) {
        stationboardHadTransientFailure = true;
        _trace(
          'Destination-fallback stationboard failed stopId=$destStopIdCanon '
          'reason=network-or-decode-exception type=${error.runtimeType}',
        );
        continue;
      }
      if (res.statusCode != 200) {
        if (res.statusCode == 429 || res.statusCode >= 500) {
          stationboardHadTransientFailure = true;
        }
        _trace(
          'Destination-fallback stationboard failed stopId=$destStopIdCanon '
          'reason=http-${res.statusCode}',
        );
        continue;
      }

      dynamic decoded;
      try {
        decoded = json.decode(utf8.decode(res.bodyBytes, allowMalformed: true));
      } catch (error) {
        stationboardHadTransientFailure = true;
        _trace(
          'Destination-fallback stationboard failed stopId=$destStopIdCanon '
          'reason=malformed-json type=${error.runtimeType}',
        );
        continue;
      }
      final list = (decoded is Map) ? decoded['stationboard'] : null;
      if (list is! List || list.isEmpty) {
        _trace(
          'Destination-fallback stationboard empty stopId=$destStopIdCanon '
          'reason=${list is List ? "empty" : "malformed"}',
        );
        continue;
      }

      DateTime? earliestRawScheduled;
      DateTime? latestRawScheduled;
      var usableScheduledCount = 0;
      var matchingTrainCount = 0;
      var survivingEtaValidityCount = 0;
      var survivingWindowCount = 0;
      var rejectedPrognosisCount = 0;

      for (final item in list) {
        if (item is! Map) continue;

        final name = (item['name'] ?? '').toString();
        final category = (item['category'] ?? '').toString();
        final number = (item['number'] ?? '').toString();
        final catNum = (category + number).trim();

        final normName = _normalizeTrainToken(name);
        final normCatNum = _normalizeTrainToken(catNum);
        final matchesTrain =
            !hasTrainFilter ||
            MatchingService.matchesTrainQuery(tq, normCatNum) ||
            MatchingService.matchesTrainQuery(tq, normName);

        final stop = item['stop'];
        if (stop is! Map) continue;

        final Map stopMap = stop;
        final station = stopMap['station'];
        if (station is Map) {
          final officialName = (station['name'] ?? '').toString().trim();
          if (officialName.isNotEmpty) {
            _stopNameCache[destStopIdCanon] = officialName;
          }
        }
        final authoritativeMode = category.trim().toLowerCase();
        final requiresExplicitDownstreamProof =
            authoritativeMode == 'b' || authoritativeMode == 'bus';
        if (matchesTrain &&
            requiresExplicitDownstreamProof &&
            !_stationboardProvesDownstreamArrival(item, destStopIdCanon)) {
          ojpModeFallbackStopId ??= destStopIdCanon;
          _trace(
            'Destination-fallback stationboard bus rejected '
            'stopId=$destStopIdCanon line="$catNum" '
            'reason=downstream-arrival-not-proven',
          );
          continue;
        }
        final Map? prog = (stopMap['prognosis'] is Map)
            ? stopMap['prognosis'] as Map
            : null;

        final timing = _fallbackTimingFromStopMap(stopMap);
        if (timing == null) continue;
        usableScheduledCount++;
        if (earliestRawScheduled == null ||
            timing.scheduledLocal.isBefore(earliestRawScheduled)) {
          earliestRawScheduled = timing.scheduledLocal;
        }
        if (latestRawScheduled == null ||
            timing.scheduledLocal.isAfter(latestRawScheduled)) {
          latestRawScheduled = timing.scheduledLocal;
        }

        if (!matchesTrain) continue;
        matchingTrainCount++;
        survivingEtaValidityCount++;
        if (timing.rejectedPrognosis) rejectedPrognosisCount++;

        final etaLocal = timing.etaLocal;
        if (!etaLocal.isAfter(lowerBound) || etaLocal.isAfter(windowEnd)) {
          continue;
        }
        survivingWindowCount++;

        final displayLine = catNum.isNotEmpty ? catNum : name;
        final lineTrim = displayLine.trim();

        String display;
        if (lineTrim.isNotEmpty) {
          display = lineTrim;
        } else {
          final nameTrim = name.trim();
          display = nameTrim.isNotEmpty ? nameTrim : 'Train';
        }

        final directionHint = _deriveDirectionHintFromArrivalItem(
          item,
          destStopIdCanon,
        );
        final derivedTerminalRaw = directionHint.value.trim();
        final toRaw = (item['to'] ?? '').toString().trim();
        final sourceDestName = _stopNameCache[destStopIdCanon] ?? '';

        final resolvedDirection = await _resolveFallbackTerminalLabel(
          derivedTerminalRaw: derivedTerminalRaw,
          toRaw: toRaw,
          destName: sourceDestName,
        );
        final terminalName = resolvedDirection.value;

        final terminalKey = MatchingService.normalizeStationToken(terminalName);
        final platform = prog?['platform'] ?? stopMap['platform'];
        final platformKey = (platform ?? '').toString().trim().toLowerCase();

        final lineKey = lineTrim.isNotEmpty
            ? _normalizeTrainToken(lineTrim)
            : _normalizeTrainToken(display);
        final publicDirectionKey = MatchingService.normalizeStationToken(toRaw);
        final key = '${timing.scheduledTimestamp}|$lineKey|$publicDirectionKey';
        final fallbackTripId = 'fallback_$key';

        final cand = TripCandidate(
          tripId: fallbackTripId,
          routeId: lineTrim,
          startDate: '',
          startTime: '',
          stopId: destStopIdCanon,
          etaLocal: etaLocal,
          delaySeconds: timing.delaySeconds,
          displayTrain: display,
          vehicleLabel: MatchingService.vehicleLabelFromPublicMode(
            modeOrCategory: category,
            displayLine: display,
          ),
          destinationMatched: true,
          upcomingStops: const <StopEta>[],
          terminalStopId: terminalName.isNotEmpty
              ? terminalName
              : (item['to'] ?? '').toString(),
          terminalStopIdCanon: '',
          directionSource: DirectionSource.stationboard,
        );

        final record = _FallbackCandidateRecord(
          candidate: cand,
          timingQuality: timing.quality,
        );
        final storedAll = mergeCandidate(allByKey, key, record);
        final storedFiltered = matchesTrain
            ? mergeCandidate(filteredByKey, key, record)
            : false;

        if ((hasTrainFilter && storedFiltered) ||
            (!hasTrainFilter && storedAll)) {
          final terminalRendered = terminalLabel(cand);
          _trace(
            'Fallback arrival candidate found tripId=${cand.tripId} displayTrain="${cand.displayTrain}" '
            'stopId=${cand.stopId} etaLocal=${cand.etaLocal.toIso8601String()} delaySeconds=${cand.delaySeconds} '
            'terminalRaw="$derivedTerminalRaw" terminalNorm="$terminalKey" platform="$platformKey" '
            'terminalFinal="$terminalRendered" prognosisSource=${timing.prognosisSource.name} '
            'scheduledLocal=${timing.scheduledLocal.toIso8601String()} '
            'scheduledArrivalTs=${stopMap['arrivalTimestamp'] ?? "missing"} '
            'scheduledDepartureTs=${stopMap['departureTimestamp'] ?? "missing"} '
            'prognosisArrival="${prog?['arrival'] ?? "missing"}" '
            'prognosisDeparture="${prog?['departure'] ?? "missing"}" '
            'directionTo="$toRaw" passListDestinationFound=${directionHint.destinationFoundInPassList} '
            'passListDerived="${directionHint.passListDerivedValue}" '
            'directionDerivedSource=${directionHint.source} '
            'directionFinalSource=${resolvedDirection.source}',
          );
        }
      }

      _trace(
        'Destination-fallback raw coverage stopId=$destStopIdCanon rawCount=${list.length} '
        'usableScheduled=$usableScheduledCount '
        'earliestScheduled=${earliestRawScheduled?.toIso8601String() ?? "none"} '
        'latestScheduled=${latestRawScheduled?.toIso8601String() ?? "none"} '
        'matchingTrainBeforeEta=$matchingTrainCount '
        'survivingEtaValidity=$survivingEtaValidityCount '
        'rejectedPrognosis=$rejectedPrognosisCount '
        'survivingSixHourWindow=$survivingWindowCount',
      );

      final outputCountAfter = hasTrainFilter
          ? filteredByKey.length
          : allByKey.length;
      final producedUsableOutput = outputCountAfter > outputCountBefore;
      if (!queryWantsQualifier && producedUsableOutput) {
        if (stopIndex == 0) {
          _trace(
            'Destination-fallback primary satisfied; alternatives skipped '
            'primaryStopId=$primaryDestCanon outputCount=$outputCountAfter',
          );
        } else {
          _trace(
            'Destination-fallback recovery alternative succeeded '
            'stopId=$destStopIdCanon outputCount=$outputCountAfter',
          );
        }
        break;
      }
    }

    final all = allByKey.values.map((record) => record.candidate).toList();
    final filtered = filteredByKey.values
        .map((record) => record.candidate)
        .toList();
    var out = hasTrainFilter ? filtered : all;
    out.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));

    if (out.isEmpty &&
        (stationboardHadTransientFailure || ojpModeFallbackStopId != null)) {
      final ojpResult = await _fallbackOjpArrivalsAtDestination(
        trainQuery: trainQuery,
        destinationStopId: ojpModeFallbackStopId ?? primaryDestCanon,
        from: lowerBound,
        until: windowEnd,
        limit: limit,
      );
      out = ojpResult.candidates;
      if (out.isEmpty && ojpResult.failed) {
        lastArrivalFallbackFailure =
            ArrivalFallbackFailure.temporaryUnavailable;
      }
    }

    if (out.isNotEmpty) {
      _trace(
        'Destination-fallback merged broad count=${out.length} trainFilter=$hasTrainFilter '
        'minEta=${out.first.etaLocal.toIso8601String()} maxEta=${out.last.etaLocal.toIso8601String()}',
      );
    } else {
      _trace(
        'Destination-fallback merged broad count=0 trainFilter=$hasTrainFilter minEta=none maxEta=none',
      );
    }
    _traceStageCandidates(
      'Destination-fallback merged sample trainFilter=$hasTrainFilter',
      out,
      max: 8,
    );

    return out.take(limit).toList();
  }

  Future<_OjpArrivalFallbackResult> _fallbackOjpArrivalsAtDestination({
    required String trainQuery,
    required String destinationStopId,
    required DateTime from,
    required DateTime until,
    required int limit,
  }) async {
    final apiKey = _ojpApiKeyProvider()?.trim() ?? '';
    if (apiKey.isEmpty || apiKey == 'YOUR_API_KEY') {
      _trace('OJP arrival fallback skipped reason=missing-api-key');
      return const _OjpArrivalFallbackResult(<TripCandidate>[], failed: true);
    }
    final stopPointRef = swissStopPointRefFromGtfsStopId(destinationStopId);
    if (stopPointRef == null) {
      _trace('OJP arrival fallback skipped reason=unsupported-stop-id');
      return const _OjpArrivalFallbackResult(<TripCandidate>[], failed: true);
    }

    List<OjpStopEventRecord> records;
    try {
      _trace(
        'OJP arrival fallback requested stop=$stopPointRef '
        'trainQuery="${trainQuery.trim()}"',
      );
      records = await _ojpClient.fetchStopEvents(
        apiKey: apiKey,
        stopPointRef: stopPointRef,
        from: from,
        numberOfResults: limit.clamp(1, 200),
        eventType: OjpStopEventType.arrival,
      );
    } catch (error) {
      _trace('OJP arrival fallback failed reason=${error.runtimeType}');
      return const _OjpArrivalFallbackResult(<TripCandidate>[], failed: true);
    }

    final byKey = <String, TripCandidate>{};
    for (final record in records) {
      final scheduled = record.scheduledArrival?.toLocal();
      if (scheduled == null ||
          !record.isDestinationServiced ||
          !record.hasPreviousServicedCall ||
          swissStopPointRefFromGtfsStopId(record.stopPointRef) !=
              stopPointRef) {
        continue;
      }
      final publicLine = record.publicLineName.trim();
      if (publicLine.isEmpty ||
          (trainQuery.trim().isNotEmpty &&
              !MatchingService.matchesPublicServiceQuery(
                query: trainQuery,
                publicLine: publicLine,
                modeOrCategory: record.transportMode,
              ))) {
        continue;
      }

      var eta = scheduled;
      final estimated = record.estimatedArrival?.toLocal();
      if (estimated != null) {
        final delta = estimated.difference(scheduled);
        if (delta >= -_maxPlausibleEarlyPrognosis &&
            delta <= _maxPlausiblePositiveDelay) {
          eta = estimated;
        }
      }
      if (!eta.isAfter(from) || eta.isAfter(until)) continue;

      final operatingDay = _canonicalOperatingDay(record.operatingDayRef);
      if (record.journeyRef.isEmpty || operatingDay == null) continue;
      final stopPointName = record.stopPointName.trim();
      if (stopPointName.isNotEmpty) {
        _stopNameCache[destinationStopId] = stopPointName;
      }
      final scheduledTimestamp =
          scheduled.toUtc().millisecondsSinceEpoch ~/ 1000;
      final key = '${record.journeyRef}|$operatingDay|$scheduledTimestamp';
      final direction = record.destinationText.trim();
      byKey.putIfAbsent(
        key,
        () => TripCandidate(
          tripId: 'ojp_$key',
          originalTripId: record.journeyRef,
          routeId: publicLine,
          startDate: '',
          startTime: '',
          stopId: destinationStopId,
          etaLocal: eta,
          delaySeconds: eta.difference(scheduled).inSeconds,
          displayTrain: publicLine,
          vehicleLabel: MatchingService.vehicleLabelFromPublicMode(
            modeOrCategory: record.transportMode,
            displayLine: publicLine,
          ),
          destinationMatched: true,
          upcomingStops: const <StopEta>[],
          terminalStopId: direction,
          terminalStopIdCanon: '',
          directionSource: DirectionSource.ojpStopEvent,
        ),
      );
    }

    final output = byKey.values.toList()
      ..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    _trace(
      'OJP arrival fallback completed records=${records.length} '
      'qualified=${output.length}',
    );
    return _OjpArrivalFallbackResult(
      output.take(limit).toList(),
      failed: false,
    );
  }

  bool _stationboardProvesDownstreamArrival(
    Map item,
    String destinationStopId,
  ) {
    final stop = item['stop'];
    if (stop is! Map) return false;
    final station = stop['station'];
    final destinationStationId = station is Map
        ? normalizeStopId((station['id'] ?? '').toString())
        : null;
    final destinationLocation = stop['location'];
    final destinationLocationId = destinationLocation is Map
        ? normalizeStopId((destinationLocation['id'] ?? '').toString())
        : null;
    final requested = normalizeStopId(destinationStopId) ?? destinationStopId;
    final passList = item['passList'];
    if (passList is! List) return false;

    var hasPriorServicedCall = false;
    for (final call in passList) {
      if (call is! Map) continue;
      final callStation = call['station'];
      final callStationId = callStation is Map
          ? normalizeStopId((callStation['id'] ?? '').toString())
          : null;
      final callLocation = call['location'];
      final callLocationId = callLocation is Map
          ? normalizeStopId((callLocation['id'] ?? '').toString())
          : null;
      final isDestination =
          callStationId == requested ||
          callLocationId == requested ||
          (destinationStationId != null &&
              (callStationId == destinationStationId ||
                  callLocationId == destinationStationId)) ||
          (destinationLocationId != null &&
              (callStationId == destinationLocationId ||
                  callLocationId == destinationLocationId));
      final arrival = _positiveTimestamp(call['arrivalTimestamp']);
      final departure = _positiveTimestamp(call['departureTimestamp']);
      if (isDestination) return hasPriorServicedCall && arrival != null;
      if (arrival != null || departure != null) hasPriorServicedCall = true;
    }
    return false;
  }

  static int? _positiveTimestamp(dynamic value) {
    final parsed = switch (value) {
      int number => number,
      num number => number.toInt(),
      null => null,
      _ => int.tryParse(value.toString()),
    };
    return parsed != null && parsed > 0 ? parsed : null;
  }

  Future<TripCandidate?> refreshCandidateEta(TripCandidate c) async {
    final hasStableTripKey = c.startDate.isNotEmpty || c.startTime.isNotEmpty;

    if (hasStableTripKey) {
      final feed = await fetchGtfsRtFeed();
      final destCanon = normalizeStopId(c.stopId) ?? c.stopId;
      final now = DateTime.now();

      for (final e in feed.entity) {
        if (!e.hasTripUpdate()) continue;
        final tu = e.tripUpdate;
        final trip = tu.trip;

        final serviceDateMatch =
            c.startDate.isEmpty || trip.startDate == c.startDate;
        final startTimeMatch =
            c.startTime.isEmpty || trip.startTime == c.startTime;
        final tripIdMatch =
            trip.tripId.isNotEmpty &&
            trip.tripId == c.tripId &&
            serviceDateMatch &&
            startTimeMatch;
        final keyMatch =
            (!tripIdMatch) &&
            c.tripId.isEmpty &&
            trip.routeId == c.routeId &&
            serviceDateMatch &&
            startTimeMatch;

        if (!tripIdMatch && !keyMatch) continue;

        final upcoming = _qualifiedDownstreamArrivals(tu, now);
        StopEta? matched;

        for (final stop in upcoming) {
          if (stopIdMatches(stop.stopIdCanon, destCanon) && matched == null) {
            matched = stop;
          }
        }

        if (upcoming.isEmpty || matched == null) break;
        final terminal = upcoming.last;
        upcoming.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
        final chosenStop = matched;

        return TripCandidate(
          tripId: c.tripId,
          originalTripId: c.originalTripId,
          routeId: c.routeId,
          startDate: c.startDate,
          startTime: c.startTime,
          stopId: chosenStop.stopIdRaw,
          etaLocal: chosenStop.etaLocal,
          delaySeconds: chosenStop.delaySeconds,
          displayTrain: c.displayTrain,
          vehicleLabel: c.vehicleLabel,
          destinationMatched: true,
          upcomingStops: upcoming.take(40).toList(),
          terminalStopId:
              c.directionSource.confidence >
                  DirectionSource.gtfsRealtimeLastStop.confidence
              ? c.terminalStopId
              : terminal.stopIdRaw,
          terminalStopIdCanon:
              c.directionSource.confidence >
                  DirectionSource.gtfsRealtimeLastStop.confidence
              ? c.terminalStopIdCanon
              : terminal.stopIdCanon,
          directionSource: c.directionSource,
        );
      }

      _trace(
        'GTFS-RT refresh rejected reason=no-exact-usable-trip-update '
        'tripId="${c.tripId}" startDate="${c.startDate}" '
        'startTime="${c.startTime}" stopId="${c.stopId}"',
      );
      return null;
    }

    final destCanon = normalizeStopId(c.stopId) ?? c.stopId;
    final arrivals = await fallbackArrivalsAtDestination(
      trainQuery: c.displayTrain,
      destStopIdCanons: <String>[destCanon],
      destNameQuery: stopLabel(destCanon),
      limit: 40,
    );

    if (arrivals.isEmpty) return null;

    final pool = arrivals
        .where(
          (x) =>
              MatchingService.matchesTrainQuery(
                _normalizeTrainToken(c.displayTrain),
                _normalizeTrainToken(x.displayTrain),
              ) &&
              x.tripId == c.tripId,
        )
        .toList();

    if (pool.isEmpty) {
      _trace(
        'Fallback refresh rejected reason=no-exact-scheduled-journey '
        'requestedTripId="${c.tripId}" requestedDisplayTrain="${c.displayTrain}" '
        'arrivals=${arrivals.length}',
      );
      return null;
    }

    final best = pool.first;

    if (c.directionSource.confidence > best.directionSource.confidence) {
      return best.withPublicDirection(
        direction: c.publicDirection,
        source: c.directionSource,
      );
    }
    return best;
  }

  Future<List<TripCandidate>> enrichPublicDirections(
    List<TripCandidate> candidates,
  ) async {
    if (candidates.isEmpty) return candidates;

    final eligible = candidates
        .where(
          (candidate) =>
              candidate.originalTripId.startsWith('ch:1:sjyid:') &&
              _canonicalOperatingDay(candidate.startDate) != null &&
              candidate.destinationMatched,
        )
        .toList();
    if (eligible.isEmpty) {
      _trace('OJP direction skipped reason=no-eligible-candidate');
      return candidates;
    }

    final apiKey = _ojpApiKeyProvider()?.trim() ?? '';
    if (apiKey.isEmpty || apiKey == 'YOUR_API_KEY') {
      _trace('OJP direction skipped reason=missing-api-key');
      return candidates;
    }

    final stopPointRef = swissStopPointRefFromGtfsStopId(eligible.first.stopId);
    if (stopPointRef == null) {
      _trace('OJP direction skipped reason=unsupported-stop-id');
      return candidates;
    }

    final sameStop = eligible
        .where(
          (candidate) =>
              swissStopPointRefFromGtfsStopId(candidate.stopId) == stopPointRef,
        )
        .toList();
    if (sameStop.isEmpty) return candidates;

    final earliest = sameStop
        .map((candidate) => candidate.etaLocal)
        .reduce((a, b) => a.isBefore(b) ? a : b)
        .subtract(const Duration(minutes: 10));

    List<OjpStopEventRecord> records;
    try {
      _trace(
        'OJP direction request stop=$stopPointRef candidates=${sameStop.length}',
      );
      records = await _ojpClient.fetchStopEvents(
        apiKey: apiKey,
        stopPointRef: stopPointRef,
        from: earliest,
        numberOfResults: 200,
      );
    } on TimeoutException {
      _trace('OJP direction failed reason=timeout');
      return candidates;
    } catch (error) {
      _trace('OJP direction failed reason=${error.runtimeType}');
      return candidates;
    }

    final recordsByKey = <String, List<OjpStopEventRecord>>{};
    for (final record in records) {
      final day = _canonicalOperatingDay(record.operatingDayRef);
      if (day == null || record.journeyRef.isEmpty) continue;
      final key = '${record.journeyRef}|$day';
      recordsByKey.putIfAbsent(key, () => []).add(record);
    }

    var enrichedCount = 0;
    var ambiguousCount = 0;
    final output = <TripCandidate>[];
    for (final candidate in candidates) {
      if (swissStopPointRefFromGtfsStopId(candidate.stopId) != stopPointRef) {
        output.add(candidate);
        continue;
      }
      final day = _canonicalOperatingDay(candidate.startDate);
      if (day == null || candidate.originalTripId.isEmpty) {
        output.add(candidate);
        continue;
      }

      final matches = recordsByKey['${candidate.originalTripId}|$day'];
      if (matches == null || matches.isEmpty) {
        output.add(candidate);
        continue;
      }
      if (matches.length != 1) {
        ambiguousCount++;
        output.add(candidate);
        continue;
      }

      final publicDirection = matches.single.destinationText.trim();
      if (publicDirection.isEmpty) {
        output.add(candidate);
        continue;
      }

      final enriched = candidate.withPublicDirection(
        direction: publicDirection,
        source: DirectionSource.ojpStopEvent,
      );
      if (!identical(enriched, candidate)) enrichedCount++;
      output.add(enriched);
    }

    _trace(
      'OJP direction completed records=${records.length} enriched=$enrichedCount '
      'ambiguous=$ambiguousCount',
    );
    return output;
  }

  _FallbackDirectionHint _deriveDirectionHintFromArrivalItem(
    Map item,
    String destStopCanon,
  ) {
    final to = (item['to'] ?? '').toString().trim();
    final passList = item['passList'];
    final stop = item['stop'];
    final destStation = stop is Map ? stop['station'] : null;
    final destName = (destStation is Map ? destStation['name'] : '')
        .toString()
        .trim();
    final destLocation = stop is Map ? stop['location'] : null;
    final destLocationCanon = destLocation is Map
        ? normalizeStopId((destLocation['id'] ?? '').toString())
        : null;

    if (passList is List && passList.isNotEmpty) {
      String? terminalName;
      bool destSeen = false;

      for (final p in passList) {
        if (p is! Map) continue;
        final st = p['station'];
        if (st is! Map) continue;

        var name = (st['name'] ?? '').toString().trim();
        final idRaw = (st['id'] ?? '').toString();
        final canon = normalizeStopId(idRaw);
        final location = p['location'];
        final locationCanon = location is Map
            ? normalizeStopId((location['id'] ?? '').toString())
            : null;
        final isDestinationOccurrence =
            canon == destStopCanon ||
            locationCanon == destStopCanon ||
            (destLocationCanon != null &&
                (canon == destLocationCanon ||
                    locationCanon == destLocationCanon));

        if (isDestinationOccurrence) {
          destSeen = true;
          if (name.isEmpty) name = destName;
        }

        if (name.isNotEmpty) terminalName = name;
      }

      if (terminalName != null) {
        return _FallbackDirectionHint(
          value: terminalName,
          destinationFoundInPassList: destSeen,
          passListDerivedValue: terminalName,
          source: 'pass-list-terminal',
        );
      }

      if (destSeen && destName.isNotEmpty) {
        return _FallbackDirectionHint(
          value: destName,
          destinationFoundInPassList: true,
          passListDerivedValue: destName,
          source: 'pass-list-destination',
        );
      }

      if (to.isNotEmpty && to.toLowerCase() != destName.toLowerCase()) {
        return _FallbackDirectionHint(
          value: to,
          destinationFoundInPassList: destSeen,
          passListDerivedValue: '',
          source: 'item-to',
        );
      }

      return _FallbackDirectionHint(
        value: destName,
        destinationFoundInPassList: destSeen,
        passListDerivedValue: '',
        source: 'destination-name',
      );
    }

    if (to.isNotEmpty && to.toLowerCase() != destName.toLowerCase()) {
      return _FallbackDirectionHint(
        value: to,
        destinationFoundInPassList: false,
        passListDerivedValue: '',
        source: 'item-to',
      );
    }
    return _FallbackDirectionHint(
      value: destName,
      destinationFoundInPassList: false,
      passListDerivedValue: '',
      source: 'destination-name',
    );
  }

  Future<_ResolvedFallbackDirection> _resolveFallbackTerminalLabel({
    required String derivedTerminalRaw,
    required String toRaw,
    required String destName,
  }) async {
    var terminalName = derivedTerminalRaw.trim();
    final to = toRaw.trim();
    final dest = destName.trim();

    if (terminalName.isNotEmpty &&
        !_looksInternalStopTokenViaService(terminalName)) {
      return _ResolvedFallbackDirection(terminalName, 'derived-readable');
    }
    if (to.isNotEmpty && !_looksInternalStopTokenViaService(to)) {
      return _ResolvedFallbackDirection(to, 'item-to-readable');
    }

    final lookupRaw = terminalName.isNotEmpty ? terminalName : to;
    if (lookupRaw.isNotEmpty) {
      final canon = normalizeStopId(lookupRaw);
      if (canon != null) {
        await ensureStopName(canon);
        final cached = (_stopNameCache[canon] ?? '').trim();
        if (cached.isNotEmpty) {
          return _ResolvedFallbackDirection(cached, 'stop-name-lookup');
        }
      }
    }

    if (dest.isNotEmpty) {
      return _ResolvedFallbackDirection(dest, 'destination-name-fallback');
    }
    if (terminalName.isNotEmpty) {
      return _ResolvedFallbackDirection(
        terminalName,
        'derived-unresolved-fallback',
      );
    }
    return _ResolvedFallbackDirection(to, 'item-to-unresolved-fallback');
  }

  bool _looksInternalStopTokenViaService(String value) {
    return MatchingService.looksInternalStopToken(
      value,
      normalizeStopId: normalizeStopId,
    );
  }

  String _tripShortNameFromTripDescriptor(dynamic tripDescriptor) {
    try {
      final raw = (tripDescriptor as dynamic).tripShortName;
      if (raw is String) return raw;
    } catch (_) {}
    return '';
  }

  String _routeShortNameFromRouteId(String routeId) {
    if (routeId.isEmpty) return '';
    return _routeShortNameByRouteId[routeId] ?? '';
  }

  bool _isBaselMainStationStopHintViaService(StopEta stop) {
    return MatchingService.isBaselMainStationStopHint(
      stop,
      normalizeStopId: normalizeStopId,
      stopNameCache: _stopNameCache,
    );
  }
}

String? _canonicalOperatingDay(String raw) {
  final trimmed = raw.trim();
  if (RegExp(r'^\d{8}$').hasMatch(trimmed)) return trimmed;
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(trimmed)) {
    return trimmed.replaceAll('-', '');
  }
  return null;
}

String _normalizeTrainToken(String s) {
  return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}
