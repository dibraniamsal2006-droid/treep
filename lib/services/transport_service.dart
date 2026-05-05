import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:http/http.dart' as http;

import '../models/trip_candidate.dart';
import 'matching_service.dart';

typedef CandidateTracer = void Function(String stage, List<TripCandidate> candidates, {int max});

class TransportService {
  TransportService({
    this.trace,
    this.traceCandidates,
    this.upcomingWindowHoursProvider,
  });

  final void Function(String message)? trace;
  final CandidateTracer? traceCandidates;
  final int Function()? upcomingWindowHoursProvider;

  static const Duration _gtfsRtMinInterval = Duration(seconds: 13);
  static const Duration _gtfsRtFeedCacheTtl = Duration(seconds: 20);
  static const int _maxPickerHorizonHours = 6;

  DateTime? _lastGtfsRtCallAt;
  Future<http.Response>? _gtfsRtInFlight;
  FeedMessage? _cachedFeed;
  DateTime? _cachedFeedAt;

  final Map<String, String> _stopNameCache = {};
  final Map<String, Future<void>> _stopNameInFlight = {};
  final Map<String, String> _routeShortNameByRouteId = {};

  void _trace(String message) => trace?.call(message);
  void _traceStageCandidates(String stage, List<TripCandidate> candidates, {int max = 6}) {
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
      http.Response res = await http
          .get(
            uri,
            headers: {
              'Authorization': 'Bearer $key',
              'Accept': 'application/x-protobuf, application/octet-stream;q=0.9, */*;q=0.8',
            },
          )
          .timeout(const Duration(seconds: 12));

      _lastGtfsRtCallAt = DateTime.now();

      if (res.statusCode == 429) {
        final retryAfterRaw = res.headers['retry-after'];
        final retrySeconds = int.tryParse((retryAfterRaw ?? '').trim());
        final wait = Duration(seconds: retrySeconds ?? 60);
        await Future.delayed(wait);

        res = await http
            .get(
              uri,
              headers: {
                'Authorization': 'Bearer $key',
                'Accept': 'application/x-protobuf, application/octet-stream;q=0.9, */*;q=0.8',
              },
            )
            .timeout(const Duration(seconds: 12));

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
      throw Exception('GTFS-RT HTTP ${res.statusCode} (${res.headers['content-type'] ?? 'unknown'})');
    }

    final feed = FeedMessage.fromBuffer(res.bodyBytes);
    _cachedFeed = feed;
    _cachedFeedAt = DateTime.now();
    return feed;
  }

  Future<List<String>> resolveStopIdsFromName(String query) async {
    final uri = Uri.parse(
      'https://transport.opendata.ch/v1/locations?query=${Uri.encodeComponent(query)}&type=station',
    );

    final res = await http.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return const [];

    final decoded = json.decode(utf8.decode(res.bodyBytes, allowMalformed: true));
    if (decoded is! Map) return const [];

    final stations = decoded['stations'];
    if (stations is! List || stations.isEmpty) return const [];

    final q = query.trim().toLowerCase();
    final scored = <({String canon, double score})>[];

    for (final s in stations) {
      if (s is! Map) continue;

      final name = (s['name'] ?? '').toString();
      final rawId = (s['id'] ?? '').toString();
      final canon = normalizeStopId(rawId);
      if (canon == null) continue;

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

    if (scored.isEmpty) return const [];

    scored.sort((a, b) => b.score.compareTo(a.score));

    final out = <String>[];
    final seen = <String>{};
    for (final x in scored) {
      if (seen.add(x.canon)) out.add(x.canon);
      if (out.length >= 8) break;
    }

    return out;
  }

  String? normalizeStopId(String raw) {
    final digits = RegExp(r'\d+').allMatches(raw).map((m) => m.group(0)!).join();
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

  Future<void> ensureStopName(String canonStopId) async {
    if (canonStopId.isEmpty) return;
    if (_stopNameCache.containsKey(canonStopId)) return;

    if (_stopNameInFlight.containsKey(canonStopId)) {
      await _stopNameInFlight[canonStopId];
      return;
    }

    final fut = () async {
      try {
        final id = MatchingService.toOpendataId(canonStopId);

        http.Response res;
        final uri = Uri.parse('https://transport.opendata.ch/v1/locations?id=${Uri.encodeComponent(id)}');
        res = await http.get(uri).timeout(const Duration(seconds: 8));

        if (res.statusCode != 200) {
          final altUri = Uri.parse(
            'https://transport.opendata.ch/v1/locations?query=${Uri.encodeComponent(id)}&type=station',
          );
          res = await http.get(altUri).timeout(const Duration(seconds: 8));
        }

        if (res.statusCode != 200) {
          _stopNameCache[canonStopId] = 'Unknown';
          return;
        }

        final decoded = json.decode(utf8.decode(res.bodyBytes, allowMalformed: true));
        final stations = (decoded is Map) ? decoded['stations'] : null;
        if (stations is! List || stations.isEmpty) {
          _stopNameCache[canonStopId] = 'Unknown';
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
          _stopNameCache[canonStopId] = 'Unknown';
          return;
        }

        final name = (best['name'] ?? '').toString();
        _stopNameCache[canonStopId] = name.isNotEmpty ? name : 'Unknown';
      } catch (_) {
        _stopNameCache[canonStopId] = 'Unknown';
      }
    }();

    _stopNameInFlight[canonStopId] = fut;
    await fut;
    _stopNameInFlight.remove(canonStopId);
  }

  Future<void> warmStopNamesForCandidates(List<TripCandidate> candidates) async {
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
    await Future.wait(ids.map(ensureStopName));
  }

  String stopLabel(String rawStopId) {
    final canon = normalizeStopId(rawStopId) ?? rawStopId;
    final name = _stopNameCache[canon];
    if (name == null || name == 'Unknown') return canon;
    return '$name ($canon)';
  }

  String terminalLabel(TripCandidate c) {
    return MatchingService.terminalLabelFor(c, stopLabel: stopLabel, normalizeStopId: normalizeStopId);
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

      final rawLabels = <String>[displayTrain, routeId, tripId, tripShortName, routeShortName];
      final matchesTrain = tq.isEmpty || MatchingService.matchesTrainQueryTokenAware(trainQuery, rawLabels);
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

      final List<StopEta> upcoming = [];
      StopEta? matchedDest;
      String? matchedStopIdRaw;

      for (final stu in tu.stopTimeUpdate) {
        final stopIdRaw = stu.stopId;
        if (stopIdRaw.isEmpty) continue;

        final stopCanon = normalizeStopId(stopIdRaw);
        if (stopCanon == null) continue;

        final arrivalTime = stu.hasArrival() ? stu.arrival.time.toInt() : 0;
        final departureTime = stu.hasDeparture() ? stu.departure.time.toInt() : 0;
        final etaSec = arrivalTime != 0 ? arrivalTime : departureTime;
        if (etaSec == 0) continue;

        final etaLocal = DateTime.fromMillisecondsSinceEpoch(etaSec * 1000, isUtc: true).toLocal();
        if (etaLocal.isBefore(now.subtract(const Duration(minutes: 2)))) continue;

        final arrivalDelay = stu.hasArrival() ? stu.arrival.delay.toInt() : 0;
        final departureDelay = stu.hasDeparture() ? stu.departure.delay.toInt() : 0;
        final delaySeconds = arrivalDelay != 0 ? arrivalDelay : departureDelay;

        final stop = StopEta(
          stopIdRaw: stopIdRaw,
          stopIdCanon: stopCanon,
          etaLocal: etaLocal,
          delaySeconds: delaySeconds,
        );

        upcoming.add(stop);

        if (stopIdMatches(stopCanon, destCanon) && matchedDest == null) {
          matchedDest = stop;
          matchedStopIdRaw = stopIdRaw;
        }
      }

      if (upcoming.isEmpty) continue;
      upcoming.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
      var usedBaselMainFallback = false;

      if (requireDestinationMatch && matchedDest == null && MatchingService.isBaselMainStationQuery(destCanon)) {
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
      final terminal = upcoming.last;

      final candidate = TripCandidate(
        tripId: tripId,
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
    final trainOnly = findCandidates(feed, trainQuery, '0', requireDestinationMatch: false);
    if (trainOnly.isEmpty) return const <TripCandidate>[];

    const maxCandidates = 8;
    const maxStopsPerCandidate = 30;
    const maxLookupsTotal = 25;

    int lookups = 0;
    final out = <TripCandidate>[];

    for (final c in trainOnly.take(maxCandidates)) {
      StopEta? matched;

      for (final s in c.upcomingStops.take(maxStopsPerCandidate)) {
        final canon = s.stopIdCanon;
        if (!_stopNameCache.containsKey(canon) && lookups < maxLookupsTotal) {
          lookups++;
          await ensureStopName(canon);
        }

        final name = _stopNameCache[canon];
        if (name == null || name == 'Unknown') continue;

        if (MatchingService.stationNameMatchesQuery(name, destName)) {
          matched = s;
          break;
        }
      }

      if (matched != null) out.add(c.copyWithDestination(matched));
      if (out.length >= 10) break;
    }

    out.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    return out;
  }

  Future<List<TripCandidate>> fallbackArrivalsAtDestination({
    required String trainQuery,
    required List<String> destStopIdCanons,
    String? destNameQuery,
    int limit = 100,
  }) async {
    final tq = _normalizeTrainToken(trainQuery);
    final hasTrainFilter = tq.isNotEmpty;
    _trace('Destination-fallback start destinationQuery="${destNameQuery ?? ""}" trainQueryNorm="$tq" trainFilter=$hasTrainFilter');

    final uniqueStops = <String>{};
    final maxStops = hasTrainFilter ? 4 : 16;
    for (final s in destStopIdCanons) {
      final canon = normalizeStopId(s) ?? s;
      if (canon.isNotEmpty) uniqueStops.add(canon);
      if (uniqueStops.length >= maxStops) break;
    }
    if (uniqueStops.isEmpty) return const <TripCandidate>[];

    var orderedStops = uniqueStops.toList()..sort();

    if (!hasTrainFilter && (destNameQuery ?? '').trim().isNotEmpty) {
      final extraResolved = await resolveStopIdsFromName(destNameQuery!);
      for (final raw in extraResolved) {
        final canon = normalizeStopId(raw) ?? raw;
        if (canon.isNotEmpty) uniqueStops.add(canon);
        if (uniqueStops.length >= maxStops) break;
      }
      orderedStops = uniqueStops.toList()..sort();
    }
    _trace(
      'Destination-fallback fetch destinationQuery="${destNameQuery ?? ""}" '
      'resolvedStopIds=[${orderedStops.join(",")}] limit=$limit',
    );

    await Future.wait(orderedStops.map(ensureStopName));
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
    bool queryHasAny(List<String> toks) => toks.any((t) => queryNorm.contains(t));

    String primaryDestCanon = orderedStops.first;
    double bestScore = -1e9;
    for (final canon in orderedStops) {
      final stopName = (_stopNameCache[canon] ?? '').trim();
      final stopNorm = normText(stopName);
      double score = 0;

      if (queryNorm.isNotEmpty) {
        if (stopNorm == queryNorm) {
          score += 120;
        } else if (stopNorm.startsWith(queryNorm)) {
          score += 70;
        } else if (stopNorm.contains(queryNorm)) {
          score += 45;
        }
      }

      if (stopNorm.contains('bahnhof') || stopNorm.contains(' hb ') || stopNorm.endsWith(' hb') || stopNorm.contains(' sbb ')) {
        score += 8;
      }

      final qualifierGroups = <List<String>>[
        <String>['west'],
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

    final qualifierTokens = <String>['west', 'allmend', 'sud', 'sued', 'zentrum'];
    final queryWantsQualifier = qualifierTokens.any((t) => queryNorm.contains(t));

    final List<String> stopsToFetch = !hasTrainFilter
        ? orderedStops
        : (queryWantsQualifier ? orderedStops : <String>[primaryDestCanon]);
    _trace('Destination-fallback fetch-expanded stopIds=${stopsToFetch.join(",")}');

    final now = DateTime.now();
    final lowerBound = now.subtract(const Duration(seconds: 15));
    final windowEnd = now.add(const Duration(hours: _maxPickerHorizonHours));
    _trace('Upcoming window active: ${upcomingWindowHoursProvider?.call() ?? 2}h');
    _trace('Upcoming window max horizon: ${_maxPickerHorizonHours}h');
    _trace(
      'Destination-fallback window lowerBound=${lowerBound.toIso8601String()} '
      'windowEnd=${windowEnd.toIso8601String()}',
    );

    final destName = _stopNameCache[primaryDestCanon] ?? '';
    final allByKey = <String, TripCandidate>{};
    final filteredByKey = <String, TripCandidate>{};

    bool mergeCandidate(Map<String, TripCandidate> map, String key, TripCandidate cand) {
      final prev = map[key];
      if (prev == null) {
        map[key] = cand;
        return true;
      }
      if (prev.delaySeconds == 0 && cand.delaySeconds != 0) {
        map[key] = cand;
        return true;
      }
      if (cand.delaySeconds.abs() > prev.delaySeconds.abs()) {
        map[key] = cand;
        return true;
      }
      return false;
    }

    for (final destStopIdCanon in stopsToFetch) {
      final stationId = MatchingService.toOpendataId(destStopIdCanon);
      final uri = Uri.parse(
        'https://transport.opendata.ch/v1/stationboard?id=${Uri.encodeComponent(stationId)}&type=arrival&limit=$limit',
      );

      http.Response res;
      try {
        res = await http.get(uri).timeout(const Duration(seconds: 10));
      } catch (_) {
        continue;
      }
      if (res.statusCode != 200) continue;

      final decoded = json.decode(utf8.decode(res.bodyBytes, allowMalformed: true));
      final list = (decoded is Map) ? decoded['stationboard'] : null;
      if (list is! List || list.isEmpty) continue;
      _trace('Destination-fallback raw fetch stopId=$destStopIdCanon count=${list.length}');

      for (final item in list) {
        if (item is! Map) continue;

        final name = (item['name'] ?? '').toString();
        final category = (item['category'] ?? '').toString();
        final number = (item['number'] ?? '').toString();
        final catNum = (category + number).trim();

        final normName = _normalizeTrainToken(name);
        final normCatNum = _normalizeTrainToken(catNum);
        final matchesTrain = !hasTrainFilter ||
            MatchingService.matchesTrainQuery(tq, normCatNum) ||
            MatchingService.matchesTrainQuery(tq, normName);

        final stop = item['stop'];
        if (stop is! Map) continue;

        final Map stopMap = stop;
        final Map? prog = (stopMap['prognosis'] is Map) ? stopMap['prognosis'] as Map : null;

        int? asInt(dynamic v) {
          if (v == null) return null;
          if (v is int) return v;
          if (v is num) return v.toInt();
          return int.tryParse(v.toString());
        }

        DateTime? parseIsoFlexible(String? value) {
          if (value == null) return null;
          final s = value.trim();
          if (s.isEmpty) return null;
          try {
            return DateTime.parse(s).toLocal();
          } catch (_) {
            return null;
          }
        }

        final schedArrivalTs = asInt(stopMap['arrivalTimestamp']);
        final schedDepartureTs = asInt(stopMap['departureTimestamp']);
        final int? schedTs = schedArrivalTs ?? schedDepartureTs;
        if (schedTs == null || schedTs <= 0) continue;
        final schedLocal = DateTime.fromMillisecondsSinceEpoch(schedTs * 1000, isUtc: true).toLocal();

        final String? progArrivalIso = prog == null ? null : prog['arrival']?.toString();
        final String? progDepartureIso = prog == null ? null : prog['departure']?.toString();

        final DateTime? progArrivalLocal = parseIsoFlexible(progArrivalIso);
        final DateTime? progDepartureLocal = parseIsoFlexible(progDepartureIso);

        DateTime? bestProg;
        int bestAbs = 1 << 30;

        void consider(DateTime? dt) {
          if (dt == null) return;
          final abs = (dt.difference(schedLocal).inSeconds).abs();
          if (abs > 6 * 60 * 60) return;
          if (abs < bestAbs) {
            bestAbs = abs;
            bestProg = dt;
          }
        }

        consider(progArrivalLocal);
        consider(progDepartureLocal);

        final etaLocal = bestProg ?? schedLocal;
        if (!etaLocal.isAfter(lowerBound) || etaLocal.isAfter(windowEnd)) continue;

        final delaySeconds = etaLocal.difference(schedLocal).inSeconds;
        final effectiveTs = etaLocal.toUtc().millisecondsSinceEpoch ~/ 1000;

        final displayLine = catNum.isNotEmpty ? catNum : name;
        final lineTrim = displayLine.trim();

        String display;
        if (lineTrim.isNotEmpty) {
          display = lineTrim;
        } else {
          final nameTrim = name.trim();
          display = nameTrim.isNotEmpty ? nameTrim : 'Train';
        }

        final derivedTerminalRaw = _deriveTerminalNameFromArrivalItem(item, destStopIdCanon).trim();
        final toRaw = (item['to'] ?? '').toString().trim();

        final terminalName = await _resolveFallbackTerminalLabel(
          derivedTerminalRaw: derivedTerminalRaw,
          toRaw: toRaw,
          destName: destName,
        );

        final terminalKey = MatchingService.normalizeStationToken(terminalName);
        final platform = prog?['platform'] ?? stopMap['platform'];
        final platformKey = (platform ?? '').toString().trim().toLowerCase();

        final lineKey = lineTrim.isNotEmpty ? _normalizeTrainToken(lineTrim) : _normalizeTrainToken(display);
        final key = '$effectiveTs|$lineKey|$terminalKey|$platformKey';

        final fallbackTripId = <String>[lineKey, effectiveTs.toString(), terminalKey, platformKey].join('_');

        final cand = TripCandidate(
          tripId: fallbackTripId,
          routeId: lineTrim,
          startDate: '',
          startTime: '',
          stopId: primaryDestCanon,
          etaLocal: etaLocal,
          delaySeconds: delaySeconds,
          displayTrain: display,
          vehicleLabel: MatchingService.vehicleLabelFromDisplay(display),
          destinationMatched: true,
          upcomingStops: const <StopEta>[],
          terminalStopId: terminalName.isNotEmpty ? terminalName : (item['to'] ?? '').toString(),
          terminalStopIdCanon: '',
        );

        final storedAll = mergeCandidate(allByKey, key, cand);
        final storedFiltered = matchesTrain ? mergeCandidate(filteredByKey, key, cand) : false;

        if ((hasTrainFilter && storedFiltered) || (!hasTrainFilter && storedAll)) {
          final terminalRendered = terminalLabel(cand);
          _trace(
            'Fallback arrival candidate found tripId=${cand.tripId} displayTrain="${cand.displayTrain}" '
            'stopId=${cand.stopId} etaLocal=${cand.etaLocal.toIso8601String()} delaySeconds=${cand.delaySeconds} '
            'terminalRaw="$derivedTerminalRaw" terminalNorm="$terminalKey" platform="$platformKey" '
            'terminalFinal="$terminalRendered"',
          );
        }
      }
    }

    final all = allByKey.values.toList();
    final filtered = filteredByKey.values.toList();
    final out = hasTrainFilter ? filtered : all;
    out.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));

    if (out.isNotEmpty) {
      _trace(
        'Destination-fallback merged broad count=${out.length} trainFilter=$hasTrainFilter '
        'minEta=${out.first.etaLocal.toIso8601String()} maxEta=${out.last.etaLocal.toIso8601String()}',
      );
    } else {
      _trace('Destination-fallback merged broad count=0 trainFilter=$hasTrainFilter minEta=none maxEta=none');
    }
    _traceStageCandidates('Destination-fallback merged sample trainFilter=$hasTrainFilter', out, max: 8);

    return out.take(limit).toList();
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

        final tripIdMatch = trip.tripId.isNotEmpty && trip.tripId == c.tripId;
        final keyMatch = (!tripIdMatch) &&
            trip.routeId == c.routeId &&
            (c.startDate.isEmpty || trip.startDate == c.startDate) &&
            (c.startTime.isEmpty || trip.startTime == c.startTime);

        if (!tripIdMatch && !keyMatch) continue;

        final upcoming = <StopEta>[];
        StopEta? matched;

        for (final stu in tu.stopTimeUpdate) {
          final stopIdRaw = stu.stopId;
          if (stopIdRaw.isEmpty) continue;

          final stopCanon = normalizeStopId(stopIdRaw);
          if (stopCanon == null) continue;

          final arrivalTime = stu.hasArrival() ? stu.arrival.time.toInt() : 0;
          final departureTime = stu.hasDeparture() ? stu.departure.time.toInt() : 0;
          final etaSec = arrivalTime != 0 ? arrivalTime : departureTime;
          if (etaSec == 0) continue;

          final etaLocal = DateTime.fromMillisecondsSinceEpoch(etaSec * 1000, isUtc: true).toLocal();
          if (etaLocal.isBefore(now.subtract(const Duration(minutes: 2)))) continue;

          final arrivalDelay = stu.hasArrival() ? stu.arrival.delay.toInt() : 0;
          final departureDelay = stu.hasDeparture() ? stu.departure.delay.toInt() : 0;
          final delaySeconds = arrivalDelay != 0 ? arrivalDelay : departureDelay;

          final stop = StopEta(
            stopIdRaw: stopIdRaw,
            stopIdCanon: stopCanon,
            etaLocal: etaLocal,
            delaySeconds: delaySeconds,
          );

          upcoming.add(stop);
          if (stopIdMatches(stopCanon, destCanon) && matched == null) matched = stop;
        }

        if (upcoming.isEmpty) return null;
        upcoming.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
        final terminal = upcoming.last;
        final chosenStop = matched ?? upcoming.first;

        return TripCandidate(
          tripId: c.tripId,
          routeId: c.routeId,
          startDate: c.startDate,
          startTime: c.startTime,
          stopId: matched?.stopIdRaw ?? chosenStop.stopIdRaw,
          etaLocal: chosenStop.etaLocal,
          delaySeconds: chosenStop.delaySeconds,
          displayTrain: c.displayTrain,
          vehicleLabel: c.vehicleLabel,
          destinationMatched: matched != null,
          upcomingStops: upcoming.take(40).toList(),
          terminalStopId: terminal.stopIdRaw,
          terminalStopIdCanon: terminal.stopIdCanon,
        );
      }
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
        .where((x) => MatchingService.matchesTrainQuery(_normalizeTrainToken(c.displayTrain), _normalizeTrainToken(x.displayTrain)))
        .toList();

    if (pool.isEmpty) return arrivals.first;

    TripCandidate best = pool.first;
    int bestAbs = best.etaLocal.difference(c.etaLocal).inSeconds.abs();

    for (final x in pool.skip(1)) {
      final abs = x.etaLocal.difference(c.etaLocal).inSeconds.abs();
      if (abs < bestAbs) {
        best = x;
        bestAbs = abs;
      }
    }

    return best;
  }

  String _deriveTerminalNameFromArrivalItem(Map item, String destStopCanon) {
    final to = (item['to'] ?? '').toString().trim();
    final passList = item['passList'];
    final stop = item['stop'];
    final destStation = stop is Map ? stop['station'] : null;
    final destName = (destStation is Map ? destStation['name'] : '').toString().trim();

    if (passList is List && passList.isNotEmpty) {
      String? nameAfterDest;
      String? fallbackLastName;
      bool destSeen = false;

      for (final p in passList) {
        if (p is! Map) continue;
        final st = p['station'];
        if (st is! Map) continue;

        final name = (st['name'] ?? '').toString().trim();
        final idRaw = (st['id'] ?? '').toString();
        final canon = normalizeStopId(idRaw);

        if (destSeen && name.isNotEmpty) {
          nameAfterDest = name;
          break;
        }

        if (!destSeen && canon == destStopCanon) {
          destSeen = true;
          continue;
        }

        if (!destSeen && name.isNotEmpty) fallbackLastName = name;
      }

      if (nameAfterDest != null) {
        if (kDebugMode) {
          debugPrint('[Treep][Arrivals] Terminal via passList: $nameAfterDest for $destStopCanon');
        }
        return nameAfterDest;
      }

      if (!destSeen && fallbackLastName != null && fallbackLastName.isNotEmpty) return fallbackLastName;
    }

    if (to.isNotEmpty && to.toLowerCase() != destName.toLowerCase()) return to;
    return destName;
  }

  Future<String> _resolveFallbackTerminalLabel({
    required String derivedTerminalRaw,
    required String toRaw,
    required String destName,
  }) async {
    var terminalName = derivedTerminalRaw.trim();
    final to = toRaw.trim();
    final dest = destName.trim();

    if (terminalName.isNotEmpty && !_looksInternalStopTokenViaService(terminalName)) return terminalName;
    if (to.isNotEmpty && !_looksInternalStopTokenViaService(to)) return to;

    final lookupRaw = terminalName.isNotEmpty ? terminalName : to;
    if (lookupRaw.isNotEmpty) {
      final canon = normalizeStopId(lookupRaw);
      if (canon != null) {
        await ensureStopName(canon);
        final cached = (_stopNameCache[canon] ?? '').trim();
        if (cached.isNotEmpty && cached != 'Unknown') return cached;
      }
    }

    if (dest.isNotEmpty) return dest;
    if (terminalName.isNotEmpty) return terminalName;
    return to;
  }

  bool _looksInternalStopTokenViaService(String value) {
    return MatchingService.looksInternalStopToken(value, normalizeStopId: normalizeStopId);
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

String _normalizeTrainToken(String s) {
  return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}
