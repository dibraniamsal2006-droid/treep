import '../models/trip_candidate.dart';

typedef StopIdNormalizer = String? Function(String raw);
typedef StopLabelResolver = String Function(String rawStopId);
typedef TraceLogger = void Function(String message);
typedef DirectionKeyResolver = String Function(TripCandidate candidate);
typedef TerminalLabelResolver = String Function(TripCandidate candidate);

class MatchingService {
  static bool looksInternalStopToken(String value, {required StopIdNormalizer normalizeStopId}) {
    final raw = value.trim();
    if (raw.isEmpty) return false;
    if (RegExp(r'^\d+$').hasMatch(raw)) return true;
    final canon = normalizeStopId(raw);
    if (canon == null) return false;
    // If it has no letters and normalizes to a stop id, treat as internal-ish id.
    return !RegExp(r'[a-zA-Z]').hasMatch(raw);
  }

  static String normalizeTrainToken(String s) {
    // Normalize "IC 5" == "IC5" == "ic5".
    return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  static String toOpendataId(String canonOrDigits) {
    // transport.opendata.ch station ids are commonly 7 digits (e.g. 8503000).
    // Some APIs also accept 9 digits with leading zeros, but padding can *break* matching
    // for certain stations. So: keep 7-digit IDs as-is; keep 9-digit IDs as-is; otherwise pad.
    final digits = RegExp(r'\d+')
        .allMatches(canonOrDigits)
        .map((m) => m.group(0)!)
        .join();

    if (digits.isEmpty) return canonOrDigits;
    if (digits.length == 7 || digits.length == 9) return digits;

    // Fallback: pad to 9.
    return digits.padLeft(9, '0');
  }

  // Station-name matching helper (diacritics/light normalization).
  static String normalizeStationToken(String s) {
    final lower = s.toLowerCase();

    // Minimal diacritic folding for common Swiss names.
    final folded = lower
        .replaceAll('ä', 'a')
        .replaceAll('ö', 'o')
        .replaceAll('ü', 'u')
        .replaceAll('é', 'e')
        .replaceAll('è', 'e')
        .replaceAll('ê', 'e')
        .replaceAll('à', 'a')
        .replaceAll('â', 'a')
        .replaceAll('î', 'i')
        .replaceAll('ï', 'i')
        .replaceAll('ç', 'c')
        .replaceAll('ñ', 'n');

    // Keep only letters/numbers to match "Zürich HB" == "ZurichHB".
    return folded.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  static bool stationNameMatchesQuery(String stationName, String query) {
    final nRaw = stationName.trim();
    final qRaw = query.trim();
    if (qRaw.isEmpty || nRaw.isEmpty) return false;

    final n = normalizeStationToken(nRaw);
    final q = normalizeStationToken(qRaw);
    if (q.isEmpty || n.isEmpty) return false;

    // Exact normalized match always wins.
    if (n == q) return true;

    // If user typed a longer string, allow reverse containment.
    if (q.contains(n)) return true;

    // For short queries, keep fuzzy contains (helps typing).
    if (q.length <= 4) {
      return n.contains(q) || q.contains(n);
    }

    // For normal queries (e.g. "Solothurn"), avoid matching sub-stations like "Solothurn West".
    // Allow only exact base name matches, or common station qualifiers.
    if (n.startsWith(q)) {
      final rest = n.substring(q.length);

      const allowed = <String>{
        'bahnhof',
        'hb',
        'sbb',
        'station',
        'railwaystation',
      };

      if (rest.isEmpty) return true;
      if (allowed.contains(rest)) return true;

      // Otherwise it's a different place (e.g. west/allmend/sued, etc.).
      return false;
    }

    return false;
  }

  static bool matchesTrainQuery(String tq, String candidateNorm) {
    if (tq.isEmpty) return true;
    if (candidateNorm.isEmpty) return false;

    if (candidateNorm == tq) return true;

    // If the query contains both letters and digits (e.g. "s3", "ic5"),
    // require an exact (letters, digits) match. This avoids S3 matching S33.
    final qLetters = tq.replaceAll(RegExp(r'\d+'), '');
    final qDigits = tq.replaceAll(RegExp(r'\D+'), '');
    if (qLetters.isNotEmpty && qDigits.isNotEmpty) {
      final cLetters = candidateNorm.replaceAll(RegExp(r'\d+'), '');
      final cDigits = candidateNorm.replaceAll(RegExp(r'\D+'), '');
      return cLetters == qLetters && cDigits == qDigits;
    }

    // Digits-only query (e.g. "111") can match within a line id like "b111".
    if (qLetters.isEmpty && qDigits.isNotEmpty) {
      return candidateNorm.contains(qDigits);
    }

    // Letters-only query (rare) -> prefix match.
    if (qLetters.isNotEmpty && qDigits.isEmpty) {
      return candidateNorm.startsWith(qLetters);
    }

    return candidateNorm.contains(tq);
  }

  static String? extractPublicLineId(String rawLabel) {
    final raw = rawLabel.trim().toLowerCase();
    if (raw.isEmpty) return null;

    // Match forms like "IR55", "IR 55", "IC-5", "S 20".
    final m = RegExp(r'\b([a-z]{1,4})\s*[-/]?\s*(\d{1,3})\b').firstMatch(raw);
    if (m != null) {
      final letters = m.group(1) ?? '';
      final digits = m.group(2) ?? '';
      if (letters.isNotEmpty && digits.isNotEmpty) return '$letters$digits';
    }

    final compact = RegExp(r'\b([a-z]{1,4}\d{1,3})\b').firstMatch(raw);
    if (compact != null) {
      return compact.group(1);
    }
    return null;
  }

  static bool matchesFallbackPublicLabel(String trainQuery, TripCandidate candidate) {
    final queryNorm = normalizeTrainToken(trainQuery);
    if (queryNorm.isEmpty) return true;

    final qLetters = queryNorm.replaceAll(RegExp(r'\d+'), '');
    final qDigits = queryNorm.replaceAll(RegExp(r'\D+'), '');

    final displayNorm = normalizeTrainToken(candidate.displayTrain);
    final routeNorm = normalizeTrainToken(candidate.routeId);
    if (matchesTrainQuery(queryNorm, displayNorm) || matchesTrainQuery(queryNorm, routeNorm)) {
      return true;
    }

    final displayLineId = extractPublicLineId(candidate.displayTrain);
    final routeLineId = extractPublicLineId(candidate.routeId);
    if (displayLineId != null && displayLineId == queryNorm) return true;
    if (routeLineId != null && routeLineId == queryNorm) return true;

    // For letters-only queries (EC/IC/IR), keep relaxed prefix behavior.
    if (qLetters.isNotEmpty && qDigits.isEmpty) {
      if (displayNorm.startsWith(qLetters) || routeNorm.startsWith(qLetters)) return true;
    }

    return false;
  }

  static List<String> trainLabelTokens(String raw) {
    final lower = raw.toLowerCase();
    final parts = lower.split(RegExp(r'[^a-z0-9]+'));
    final out = <String>[];
    for (final p in parts) {
      final t = p.trim();
      if (t.isEmpty) continue;
      if (!RegExp(r'[a-z]').hasMatch(t)) continue;
      out.add(t);
    }
    return out;
  }

  static bool matchesTrainQueryTokenAware(String trainQuery, List<String> rawLabels) {
    final tq = normalizeTrainToken(trainQuery);
    if (tq.isEmpty) return true;

    final qLetters = tq.replaceAll(RegExp(r'\d+'), '');
    final qDigits = tq.replaceAll(RegExp(r'\D+'), '');

    for (final raw in rawLabels) {
      final norm = normalizeTrainToken(raw);
      if (matchesTrainQuery(tq, norm)) return true;

      final tokens = trainLabelTokens(raw);
      for (final token in tokens) {
        final tokenNorm = normalizeTrainToken(token);
        if (tokenNorm.isEmpty) continue;

        final tLetters = tokenNorm.replaceAll(RegExp(r'\d+'), '');
        final tDigits = tokenNorm.replaceAll(RegExp(r'\D+'), '');

        // letters+digits query: strict exact letters+digits (protects S3 vs S33)
        if (qLetters.isNotEmpty && qDigits.isNotEmpty) {
          if (tLetters == qLetters && tDigits == qDigits) return true;
          continue;
        }

        // letters-only query: tolerant prefix on token ("EC" matches "EC7", "ECE")
        if (qLetters.isNotEmpty && qDigits.isEmpty) {
          if (tLetters.startsWith(qLetters)) return true;
          continue;
        }

        // digits-only query: keep broad matching behavior
        if (qLetters.isEmpty && qDigits.isNotEmpty) {
          if (tokenNorm.contains(qDigits)) return true;
        }
      }
    }

    return false;
  }

  static bool isBaselMainStationQuery(String destCanon) {
    return destCanon == '8500010';
  }

  static bool isBaselMainStationStopHint(
    StopEta stop, {
    required StopIdNormalizer normalizeStopId,
    required Map<String, String> stopNameCache,
  }) {
    final stopCanon = normalizeStopId(stop.stopIdCanon) ?? stop.stopIdCanon;
    if (stopCanon == '8500010') return true;

    final rawDigits = RegExp(r'\d+').allMatches(stop.stopIdRaw).map((m) => m.group(0)!).join();
    if (rawDigits.contains('8500010')) return true;

    final name = (stopNameCache[stopCanon] ?? '').toLowerCase();
    if (name.contains('basel') && name.contains('sbb') && !name.contains('bad')) {
      return true;
    }

    return false;
  }

  static bool isLettersOnlyLongDistanceQuery(String trainQuery) {
    final tq = normalizeTrainToken(trainQuery);
    if (tq.isEmpty) return false;
    final letters = tq.replaceAll(RegExp(r'\d+'), '');
    final digits = tq.replaceAll(RegExp(r'\D+'), '');
    if (letters.isEmpty || digits.isNotEmpty) return false;
    return letters == 'ec' || letters == 'ic' || letters == 'ir';
  }

  static bool shouldUseGtfsBridgeForQuery(String trainQuery) {
    final tq = normalizeTrainToken(trainQuery);
    if (tq.isEmpty) return false;

    final letters = tq.replaceAll(RegExp(r'\d+'), '');
    final digits = tq.replaceAll(RegExp(r'\D+'), '');
    if (letters.isEmpty) return false;

    // Existing long-distance letters-only queries (EC/IC/IR).
    if (digits.isEmpty) {
      return isLettersOnlyLongDistanceQuery(trainQuery);
    }

    // letters+digits line ids (IR55, IC5, S20, S3, ...).
    return true;
  }

  static String gtfsBridgeDecisionReason(String trainQuery) {
    final tq = normalizeTrainToken(trainQuery);
    if (tq.isEmpty) return 'empty-query';

    final letters = tq.replaceAll(RegExp(r'\d+'), '');
    final digits = tq.replaceAll(RegExp(r'\D+'), '');
    if (letters.isEmpty) return 'digits-only-query';

    // Disable bridge for S-lines (S3, S20, SN1, ...).
    if (RegExp(r'^sn?\d+$').hasMatch(tq)) {
      return 'local-s-line';
    }

    if (digits.isEmpty) {
      return isLettersOnlyLongDistanceQuery(trainQuery) ? 'long-distance-letters' : 'letters-only-not-supported';
    }

    return 'letters+digits-supported';
  }

  static bool shouldUseGtfsBridgeForQueryWithLocalGuard(String trainQuery) {
    final reason = gtfsBridgeDecisionReason(trainQuery);
    return shouldUseGtfsBridgeForQuery(trainQuery) &&
        reason != 'local-s-line' &&
        reason != 'letters-only-not-supported';
  }

  static String vehicleLabelFromDisplay(String displayTrain) {
    final n = normalizeTrainToken(displayTrain);
    if (n.startsWith('b')) return 'Bus';
    return 'Train';
  }

  static String terminalLabelFor(
    TripCandidate candidate, {
    required StopLabelResolver stopLabel,
    required StopIdNormalizer normalizeStopId,
  }) {
    final canon = candidate.terminalStopIdCanon.trim();
    if (canon.isNotEmpty) return stopLabel(canon);

    final raw = candidate.terminalStopId.trim();
    if (raw.isEmpty) return 'Unknown direction';

    final maybeCanon = normalizeStopId(raw);
    if (maybeCanon != null) return stopLabel(maybeCanon);

    return raw;
  }

  static String directionKeyFor(
    TripCandidate candidate, {
    required StopIdNormalizer normalizeStopId,
  }) {
    final canon = candidate.terminalStopIdCanon.trim();
    if (canon.isNotEmpty) return canon;

    final raw = candidate.terminalStopId.trim();
    if (raw.isEmpty) return 'unknown';

    final maybeCanon = normalizeStopId(raw);
    if (maybeCanon != null) return maybeCanon;

    return normalizeStationToken(raw);
  }

  static List<TripCandidate> dedupeCandidates(
    List<TripCandidate> input, {
    required StopIdNormalizer normalizeStopId,
    required TraceLogger trace,
    required DirectionKeyResolver directionKeyFor,
    required TerminalLabelResolver terminalLabelFor,
  }) {
    // Deduplicate by trip identity + matched stop.
    // tripId/startDate/startTime are stable in GTFS-RT; stopId can vary by platform.
    final seen = <String, TripCandidate>{};
    trace('Dedupe before count=${input.length}');

    for (var i = 0; i < input.length; i++) {
      final c = input[i];
      final stopCanon = normalizeStopId(c.stopId) ?? c.stopId;

      // GTFS-RT trips have stable (tripId,startDate,startTime). Stationboard fallback doesn't.
      // When startDate/startTime are empty, include ETA+direction so we don't collapse all future trains.
      final hasStableTripKey = c.startDate.isNotEmpty || c.startTime.isNotEmpty;
      final etaSec = c.etaLocal.toUtc().millisecondsSinceEpoch ~/ 1000;

      final key = hasStableTripKey
          ? '${c.tripId}|${c.startDate}|${c.startTime}|$stopCanon'
          : '${c.tripId}|$etaSec|${normalizeTrainToken(c.displayTrain)}|$stopCanon|${directionKeyFor(c)}';
      trace(
        'Dedupe before[#${i + 1}] key="$key" stable=$hasStableTripKey '
        'tripId=${c.tripId} displayTrain="${c.displayTrain}" stopId=$stopCanon '
        'eta=${c.etaLocal.toIso8601String()} terminal="${terminalLabelFor(c)}"',
      );

      final prev = seen[key];
      if (prev == null || c.etaLocal.isBefore(prev.etaLocal)) {
        seen[key] = c;
      }
    }

    final out = seen.values.toList()..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    trace('Dedupe after count=${out.length}');
    return out;
  }
}
