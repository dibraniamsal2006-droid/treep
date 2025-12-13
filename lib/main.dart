import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:http/http.dart' as http;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  runApp(const TreepApp());
}

class TreepApp extends StatelessWidget {
  const TreepApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Treep',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B5E20)),
        useMaterial3: true,
      ),
      home: const TreepHome(),
    );
  }
}

class TreepHome extends StatefulWidget {
  const TreepHome({super.key});

  @override
  State<TreepHome> createState() => _TreepHomeState();
}

class _TreepHomeState extends State<TreepHome> {
  final _trainController = TextEditingController();
  final _stationController = TextEditingController();
  double _minutesBefore = 3;
  bool _isTestingFeed = false;
  bool _isStartingTracking = false;
  String _trackingStatus = '';
  TripCandidate? _selectedCandidate;

  // GTFS-RT plan is limited (e.g. 5 calls / minute). We throttle requests to avoid 429.
// 5/min ~= 12s per call. Use 13s to be a little safer.
static const Duration _gtfsRtMinInterval = Duration(seconds: 13);
static const Duration _gtfsRtFeedCacheTtl = Duration(seconds: 20);
DateTime? _lastGtfsRtCallAt;
Future<http.Response>? _gtfsRtInFlight;

// Cache the last parsed feed briefly so “Test feed” + “Start tracking” doesn’t double-hit the rate limit.
FeedMessage? _cachedFeed;
DateTime? _cachedFeedAt;

String _hhmm(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

String _fmtDelay(int delaySeconds) {
  final mins = (delaySeconds / 60).round();
  if (mins == 0) return 'on time';
  return mins > 0 ? '+${mins}m' : '${mins}m';
}

  @override
  void dispose() {
    _trainController.dispose();
    _stationController.dispose();
    super.dispose();
  }

  Future<void> _startTracking() async {
    if (_isStartingTracking) return;

    final trainQuery = _trainController.text.trim();
    final destQuery = _stationController.text.trim();
    if (trainQuery.isEmpty || destQuery.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter train and destination.')),
      );
      return;
    }

    setState(() {
      _isStartingTracking = true;
      _trackingStatus = 'Searching matching trip…';
      _selectedCandidate = null;
    });

    try {
      final feed = await _fetchGtfsRtFeed();
      // Resolve destination: GTFS-RT uses numeric stop_id (e.g., 8503000). If user typed a station name,
      // resolve it to a stop_id first (temporary). Later we’ll replace this with GTFS-SA local mapping.
      String effectiveDest = destQuery;
      if (!RegExp(r'^\d+$').hasMatch(destQuery)) {
        setState(() {
          _trackingStatus = 'Resolving destination “$destQuery” to stop_id…';
        });

        final resolved = await _resolveStopIdFromName(destQuery);
        if (resolved == null) {
          setState(() {
            _trackingStatus =
                'Could not resolve “$destQuery”. Try a more specific name (e.g., “Zürich HB”) or enter the stop_id directly.';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Destination could not be resolved.'),
              duration: Duration(seconds: 4),
            ),
          );
          return;
        }

        effectiveDest = resolved;
        setState(() {
          _trackingStatus = 'Destination resolved: “$destQuery” → $effectiveDest';
        });
      }

      var candidates = _findCandidates(
        feed,
        trainQuery,
        effectiveDest,
        requireDestinationMatch: true,
      );

      final hadStrictMatch = candidates.isNotEmpty;

      // Fallback 1: still require the train match, but allow any destination.
      if (candidates.isEmpty) {
        candidates = _findCandidates(
          feed,
          trainQuery,
          effectiveDest,
          requireDestinationMatch: false,
        );
      }

      // Fallback 2: if we still have nothing, ignore the train query and show
      // upcoming trips that go to the destination. This helps when GTFS-RT route_id/trip_id
      // doesn’t contain human-friendly labels like “IC5”.
      final usedDestinationOnlyFallback = candidates.isEmpty;
      if (candidates.isEmpty) {
        candidates = _findCandidates(
          feed,
          '',
          effectiveDest,
          requireDestinationMatch: true,
        );
      }

      if (usedDestinationOnlyFallback && candidates.isNotEmpty) {
        setState(() {
          _trackingStatus =
              'No exact match for train “$trainQuery”. Showing trips that go to $effectiveDest — pick the right one.';
        });
      }

      if (!mounted) return;

      if (candidates.isEmpty) {
        setState(() {
          _trackingStatus =
              'No matching trip found (yet). Try again in a moment, or try a more specific train query (e.g., “IC 8” vs “IC8”).';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No matching trip found (yet).'),
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }

      // If multiple candidates, let the user choose.
      TripCandidate chosen;
      if (candidates.length == 1) {
        chosen = candidates.first;
      } else {
        chosen = await _pickCandidateBottomSheet(candidates);
      }

      if (!mounted) return;

      // If destination wasn't matched during fallback search, let the user pick a stop from upcoming stops.
      if (!hadStrictMatch && !chosen.destinationMatched) {
        final pickedStop = await _pickStopBottomSheet(
          title: 'Pick destination stop',
          stops: chosen.upcomingStops,
        );

        if (!mounted) return;

        if (pickedStop == null) {
          setState(() {
            _trackingStatus =
                'No stop selected. Tip: entering a numeric stop_id (e.g., 8503000) is most reliable for now.';
            _selectedCandidate = null;
          });
          return;
        }

        chosen = chosen.copyWithDestination(pickedStop);
      }

      final minsLeft = chosen.etaLocal.difference(DateTime.now()).inMinutes;
      final canonStop = _normalizeStopId(chosen.stopId) ?? chosen.stopId;

      setState(() {
        _selectedCandidate = chosen;
        _trackingStatus =
            'Selected ${chosen.displayTrain} → stop $canonStop • ETA ${_hhmm(chosen.etaLocal)} (in ${minsLeft}m) • ${_fmtDelay(chosen.delaySeconds)}';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tracking set (foreground prototype).')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _trackingStatus = 'Start tracking failed: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Start tracking failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isStartingTracking = false);
      }
    }
  }

  Future<http.Response> _getGtfsRtResponse() async {
    final key = dotenv.env['OPENTRANSPORTDATA_API_KEY'];
    if (key == null || key.trim().isEmpty || key == 'YOUR_API_KEY') {
      throw Exception('No real API key set in .env yet.');
    }

    // Deduplicate concurrent calls (e.g. user taps quickly or multiple buttons).
    if (_gtfsRtInFlight != null) {
      return _gtfsRtInFlight!;
    }

    final completer = Completer<http.Response>();
    _gtfsRtInFlight = completer.future;

    try {
      // Throttle to respect rate limits.
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
              'Accept':
                  'application/x-protobuf, application/octet-stream;q=0.9, */*;q=0.8',
            },
          )
          .timeout(const Duration(seconds: 12));

      // Record call time after the request finishes (counts against rate limit).
      _lastGtfsRtCallAt = DateTime.now();

      // If we hit rate-limit, wait then retry once.
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
                'Accept':
                    'application/x-protobuf, application/octet-stream;q=0.9, */*;q=0.8',
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

  Future<FeedMessage> _fetchGtfsRtFeed() async {
  // If we fetched very recently, reuse the parsed feed to avoid 429.
  if (_cachedFeed != null && _cachedFeedAt != null) {
    final age = DateTime.now().difference(_cachedFeedAt!);
    if (age <= _gtfsRtFeedCacheTtl) {
      return _cachedFeed!;
    }
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

  Future<String?> _resolveStopIdFromName(String query) async {
    // Temporary helper: uses the public transport.opendata.ch API to map station names to IDs.
    // Later we’ll replace this with local GTFS-SA stops.txt mapping.
    final uri = Uri.parse(
      'https://transport.opendata.ch/v1/locations?query=${Uri.encodeComponent(query)}&type=station',
    );

    final res = await http.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;

    final decoded = json.decode(utf8.decode(res.bodyBytes, allowMalformed: true));
    if (decoded is! Map) return null;

    final stations = decoded['stations'];
    if (stations is! List || stations.isEmpty) return null;

    // Prefer a station whose name matches well (case-insensitive contains).
    final q = query.toLowerCase();
    Map? best;
    for (final s in stations) {
      if (s is! Map) continue;
      final name = (s['name'] ?? '').toString();
      if (name.toLowerCase().contains(q)) {
        best = s;
        break;
      }
    }
    best ??= stations.first is Map ? stations.first as Map : null;
    if (best == null) return null;

    final rawId = (best['id'] ?? '').toString();
    return _normalizeStopId(rawId);
  }

  String? _normalizeStopId(String raw) {
    // Examples: "8503000", "008503000", or URN-like strings.
    final digits = RegExp(r'\d+').allMatches(raw).map((m) => m.group(0)!).join();
    if (digits.isEmpty) return null;

    // Swiss stop IDs are typically 7 digits starting with 85.
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

 List<TripCandidate> _findCandidates(
  FeedMessage feed,
  String trainQuery,
  String destQuery, {
  required bool requireDestinationMatch,
}) {
  final tq = _normalizeTrainToken(trainQuery);
  final destCanon = _normalizeStopId(destQuery) ?? destQuery;

  final now = DateTime.now();
  final List<TripCandidate> out = [];

  for (final e in feed.entity) {
    if (!e.hasTripUpdate()) continue;

    final tu = e.tripUpdate;
    final trip = tu.trip;

    final tripId = trip.tripId;
    final routeId = trip.routeId;
    final displayTrain = routeId.isNotEmpty ? routeId : tripId;

    final displayNorm = _normalizeTrainToken(displayTrain);
    final tripNorm = _normalizeTrainToken(tripId);
    final routeNorm = _normalizeTrainToken(routeId);

    final matchesTrain = tq.isEmpty ||
        displayNorm.contains(tq) ||
        tripNorm.contains(tq) ||
        routeNorm.contains(tq);
    if (!matchesTrain) continue;

    final List<StopEta> upcoming = [];
    StopEta? matchedDest;
    String? matchedStopIdRaw;

    for (final stu in tu.stopTimeUpdate) {
      final stopIdRaw = stu.stopId;
      if (stopIdRaw.isEmpty) continue;

      final stopCanon = _normalizeStopId(stopIdRaw);
      if (stopCanon == null) continue;

      final arrivalTime = stu.hasArrival() ? stu.arrival.time.toInt() : 0;
      final departureTime = stu.hasDeparture() ? stu.departure.time.toInt() : 0;
      final etaSec = arrivalTime != 0 ? arrivalTime : departureTime;
      if (etaSec == 0) continue;

      final etaLocal = DateTime.fromMillisecondsSinceEpoch(
        etaSec * 1000,
        isUtc: true,
      ).toLocal();

      if (etaLocal.isBefore(now.subtract(const Duration(minutes: 2)))) continue;

      final delaySeconds = stu.hasArrival()
          ? stu.arrival.delay.toInt()
          : (stu.hasDeparture() ? stu.departure.delay.toInt() : 0);

      final stop = StopEta(
        stopIdRaw: stopIdRaw,
        stopIdCanon: stopCanon,
        etaLocal: etaLocal,
        delaySeconds: delaySeconds,
      );

      upcoming.add(stop);

      if (stopCanon == destCanon && matchedDest == null) {
        matchedDest = stop;
        matchedStopIdRaw = stopIdRaw;
      }
    }

    if (upcoming.isEmpty) continue;

    if (requireDestinationMatch && matchedDest == null) {
      continue;
    }

    final selected = matchedDest ?? upcoming.first;

    out.add(
      TripCandidate(
        tripId: tripId,
        routeId: routeId,
        startDate: trip.startDate,
        startTime: trip.startTime,
        stopId: matchedStopIdRaw ?? selected.stopIdRaw,
        etaLocal: selected.etaLocal,
        delaySeconds: selected.delaySeconds,
        displayTrain: displayTrain,
        destinationMatched: matchedDest != null,
        upcomingStops: upcoming.take(40).toList(),
      ),
    );
  }

  out.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
  return out.take(15).toList();
}

  Future<TripCandidate> _pickCandidateBottomSheet(List<TripCandidate> candidates) async {
    final picked = await showModalBottomSheet<TripCandidate>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: candidates.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (ctx, i) {
              final c = candidates[i];
              final mins = c.etaLocal.difference(DateTime.now()).inMinutes;
              final canonStop = _normalizeStopId(c.stopId) ?? c.stopId;

              return ListTile(
                title: Text('${c.displayTrain} → stop $canonStop'),
                subtitle: Text(
                  'ETA ${_hhmm(c.etaLocal)} (in ${mins}m) • ${_fmtDelay(c.delaySeconds)}',
                ),
                onTap: () => Navigator.of(ctx).pop(c),
              );
            },
          ),
        );
      },
    );

    // If user dismisses, just pick the first.
    return picked ?? candidates.first;
  }
Future<StopEta?> _pickStopBottomSheet({
  required String title,
  required List<StopEta> stops,
}) async {
  final sorted = [...stops]..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));

  return showModalBottomSheet<StopEta>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('${sorted.length} stops'),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: sorted.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final s = sorted[i];
                  final mins = s.etaLocal.difference(DateTime.now()).inMinutes;
                  return ListTile(
                    title: Text('stop_id ${s.stopIdCanon}'),
                    subtitle: Text('ETA in ${mins}m • delay ${s.delaySeconds}s\nraw: ${s.stopIdRaw}'),
                    isThreeLine: true,
                    onTap: () => Navigator.of(ctx).pop(s),
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}
  Future<void> _pingApi() async {
    if (_isTestingFeed) return;

    final key = dotenv.env['OPENTRANSPORTDATA_API_KEY'];

    // Immediate UI feedback so the user sees the tap worked.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Testing GTFS-RT feed…')),
    );

    if (key == null || key.trim().isEmpty || key == 'YOUR_API_KEY') {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No real API key set in .env yet.')),
      );
      return;
    }

    setState(() => _isTestingFeed = true);

    try {
      // Use the same throttled request logic as tracking.
      final res = await _getGtfsRtResponse();

      if (!mounted) return;

      final contentType = res.headers['content-type'] ?? 'unknown';
      final sizeBytes = res.bodyBytes.length;

      // Non-200: show quick info.
      if (res.statusCode != 200) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('GTFS-RT: HTTP ${res.statusCode} | $contentType'),
            duration: const Duration(seconds: 6),
          ),
        );
        return;
      }

      // If the endpoint ever returns JSON, show a tiny preview (safe).
      if (contentType.contains('json')) {
        final preview = utf8.decode(res.bodyBytes, allowMalformed: true);
        final shortPreview = preview.length > 140 ? preview.substring(0, 140) : preview;
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('GTFS-RT JSON: $sizeBytes bytes | ${shortPreview.replaceAll('\n', ' ')}'),
            duration: const Duration(seconds: 7),
          ),
        );
        return;
      }

      // ✅ Protobuf / octet-stream: parse GTFS-RT FeedMessage.
      FeedMessage feed;
      try {
        feed = FeedMessage.fromBuffer(res.bodyBytes);
      } catch (e) {
        final head = res.bodyBytes.take(12).toList();
        final hex = head.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('GTFS-RT parse failed: $e | $contentType | head: $hex'),
            duration: const Duration(seconds: 7),
          ),
        );
        return;
      }

      int tripUpdates = 0;
      int vehicles = 0;
      int alerts = 0;

      for (final e in feed.entity) {
        if (e.hasTripUpdate()) tripUpdates++;
        if (e.hasVehicle()) vehicles++;
        if (e.hasAlert()) alerts++;
      }

      String timeInfo = '';
      if (feed.header.hasTimestamp()) {
        final ts = feed.header.timestamp.toInt(); // seconds since epoch
        final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true).toLocal();
        timeInfo = ' | ${dt.toIso8601String()}';
      }

      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'GTFS-RT OK: ${feed.entity.length} entities | '
            'TripUpdates $tripUpdates | Vehicles $vehicles | Alerts $alerts'
            ' | $contentType | $sizeBytes bytes$timeInfo',
          ),
          duration: const Duration(seconds: 7),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('GTFS-RT test failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _isTestingFeed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F8E9),
      appBar: AppBar(
        title: const Text('Treep'),
        centerTitle: true,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.terrain, size: 48),
                const SizedBox(height: 16),
                TextField(
                  controller: _trainController,
                  decoration: const InputDecoration(
                    labelText: 'Train number (e.g., IC8)',
                    prefixIcon: Icon(Icons.train_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _stationController,
                  decoration: const InputDecoration(
                    labelText: 'Destination station (e.g., Olten)',
                    prefixIcon: Icon(Icons.location_on_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('Alarm before:'),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Slider(
                        value: _minutesBefore,
                        min: 1,
                        max: 15,
                        divisions: 14,
                        label: '${_minutesBefore.round()} min',
                        onChanged: (v) => setState(() => _minutesBefore = v),
                      ),
                    ),
                    Text('${_minutesBefore.round()}m'),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: (_isStartingTracking || _isTestingFeed) ? null : _startTracking,
                    child: Text(_isStartingTracking ? 'Starting…' : 'Start tracking'),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: (_isTestingFeed || _isStartingTracking) ? null : _pingApi,
                    child: Text(_isTestingFeed ? 'Testing…' : 'Test GTFS-RT feed'),
                  ),
                ),
                if (_trackingStatus.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Status', style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          Text(_trackingStatus),
                          if (_selectedCandidate != null) ...[
                            const SizedBox(height: 8),
                            Text('Trip: ${_selectedCandidate!.displayTrain}'),
                            Text('Stop: ${_selectedCandidate!.stopId}'),
                            Text('ETA: ${_selectedCandidate!.etaLocal}'),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
  final bool destinationMatched;
  final List<StopEta> upcomingStops;

  TripCandidate({
    required this.tripId,
    required this.routeId,
    required this.startDate,
    required this.startTime,
    required this.stopId,
    required this.etaLocal,
    required this.delaySeconds,
    required this.displayTrain,
    required this.destinationMatched,
    required this.upcomingStops,
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
      destinationMatched: true,
      upcomingStops: upcomingStops,
    );
  }
}
String _normalizeTrainToken(String s) {
  return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}