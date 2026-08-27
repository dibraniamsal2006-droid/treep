import '../models/trip_candidate.dart';

typedef StopIdNormalizer = String? Function(String raw);
typedef StopLabelResolver = String Function(String rawStopId);
typedef TraceLogger = void Function(String message);
typedef DirectionKeyResolver = String Function(TripCandidate candidate);
typedef TerminalLabelResolver = String Function(TripCandidate candidate);

enum _TrainIdentityKind {
  empty,
  lettersOnly,
  digitsOnly,
  lettersAndDigits,
  mixed,
}

class _PublicTrainIdentity {
  const _PublicTrainIdentity({
    required this.normalizedRaw,
    required this.letters,
    required this.digits,
    required this.kind,
  });

  factory _PublicTrainIdentity.parse(String raw) {
    final normalizedRaw = MatchingService.normalizeTrainToken(raw);
    final letters = normalizedRaw.replaceAll(RegExp(r'\d+'), '');
    final digits = normalizedRaw.replaceAll(RegExp(r'\D+'), '');

    final _TrainIdentityKind kind;
    if (normalizedRaw.isEmpty) {
      kind = _TrainIdentityKind.empty;
    } else if (letters.isNotEmpty &&
        digits.isEmpty &&
        letters == normalizedRaw) {
      kind = _TrainIdentityKind.lettersOnly;
    } else if (letters.isEmpty &&
        digits.isNotEmpty &&
        digits == normalizedRaw) {
      kind = _TrainIdentityKind.digitsOnly;
    } else if (letters.isNotEmpty &&
        digits.isNotEmpty &&
        normalizedRaw == '$letters$digits') {
      kind = _TrainIdentityKind.lettersAndDigits;
    } else {
      kind = _TrainIdentityKind.mixed;
    }

    return _PublicTrainIdentity(
      normalizedRaw: normalizedRaw,
      letters: letters,
      digits: digits,
      kind: kind,
    );
  }

  final String normalizedRaw;
  final String letters;
  final String digits;
  final _TrainIdentityKind kind;

  bool get isEmpty => kind == _TrainIdentityKind.empty;
  bool get isLettersOnly => kind == _TrainIdentityKind.lettersOnly;
  bool get isDigitsOnly => kind == _TrainIdentityKind.digitsOnly;
  bool get isLettersAndDigits => kind == _TrainIdentityKind.lettersAndDigits;
}

class MatchingService {
  static bool looksInternalStopToken(
    String value, {
    required StopIdNormalizer normalizeStopId,
  }) {
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
    final digits = RegExp(
      r'\d+',
    ).allMatches(canonOrDigits).map((m) => m.group(0)!).join();

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
    return _matchesTrainIdentity(
      _PublicTrainIdentity.parse(tq),
      _PublicTrainIdentity.parse(candidateNorm),
      allowCollapsedAdditionalNumber: true,
    );
  }

  static bool _matchesTrainIdentity(
    _PublicTrainIdentity query,
    _PublicTrainIdentity candidate, {
    required bool allowCollapsedAdditionalNumber,
  }) {
    if (query.isEmpty) return true;
    if (candidate.isEmpty) return false;

    if (candidate.normalizedRaw == query.normalizedRaw) return true;

    // If the query contains both letters and digits (e.g. "s3", "ic5"),
    // require an exact (letters, digits) match. This avoids S3 matching S33.
    if (query.isLettersAndDigits) {
      if (candidate.isLettersAndDigits &&
          candidate.letters == query.letters &&
          candidate.digits == query.digits) {
        return true;
      }

      // Some existing callers compact the raw label before matching, so
      // "IR55 2317" arrives here as "ir552317". Recover only a leading exact
      // 1-3 digit public identity followed by a four-digit train number. The
      // split is derived independently of the query, so IR5 still cannot match
      // IR55 2317. Short continuations stay strict, protecting S3/S33, S2/S20,
      // and IC5/IC51.
      if (allowCollapsedAdditionalNumber &&
          candidate.isLettersAndDigits &&
          candidate.letters == query.letters &&
          candidate.digits.length >= 5 &&
          candidate.digits.length <= 7) {
        final publicDigits = candidate.digits.substring(
          0,
          candidate.digits.length - 4,
        );
        if (publicDigits == query.digits) return true;
      }

      return false;
    }

    // Digits-only query (e.g. "111") can match within a line id like "b111".
    if (query.isDigitsOnly) {
      return candidate.normalizedRaw.contains(query.digits);
    }

    // Letters-only query (rare) -> prefix match.
    if (query.isLettersOnly) {
      return candidate.normalizedRaw.startsWith(query.letters);
    }

    return candidate.normalizedRaw.contains(query.normalizedRaw);
  }

  static String? extractPublicLineId(String rawLabel) {
    final raw = rawLabel.trim();
    if (raw.isEmpty) return null;

    // Match forms like "IR55", "IR 55", "IC-5", "S 20".
    final m = RegExp(
      r'\b([a-z]{1,4})\s*[-/]?\s*(\d{1,3})\b',
      caseSensitive: false,
    ).firstMatch(raw);
    if (m != null) {
      final letters = m.group(1) ?? '';
      final digits = m.group(2) ?? '';
      if (letters.isNotEmpty && digits.isNotEmpty) {
        return _PublicTrainIdentity.parse('$letters$digits').normalizedRaw;
      }
    }

    final compact = RegExp(
      r'\b([a-z]{1,4}\d{1,3})\b',
      caseSensitive: false,
    ).firstMatch(raw);
    if (compact != null) {
      return _PublicTrainIdentity.parse(compact.group(1) ?? '').normalizedRaw;
    }
    return null;
  }

  static bool matchesFallbackPublicLabel(
    String trainQuery,
    TripCandidate candidate,
  ) {
    final query = _PublicTrainIdentity.parse(trainQuery);
    if (query.isEmpty) return true;

    final display = _PublicTrainIdentity.parse(candidate.displayTrain);
    final route = _PublicTrainIdentity.parse(candidate.routeId);
    if (_matchesTrainIdentity(
      query,
      display,
      allowCollapsedAdditionalNumber: true,
    )) {
      return true;
    }

    final displayLineId = extractPublicLineId(candidate.displayTrain);
    final routeLineId = extractPublicLineId(candidate.routeId);
    if (displayLineId != null && displayLineId == query.normalizedRaw) {
      return true;
    }
    if (routeLineId != null && routeLineId == query.normalizedRaw) return true;

    // A route id may be a technical GTFS identifier. Preserve exact/category
    // matching, but do not infer a public line plus train number from a
    // delimiter-free route id as we do for the public display label.
    if (_matchesTrainIdentity(
      query,
      route,
      allowCollapsedAdditionalNumber: false,
    )) {
      return true;
    }

    // For letters-only queries (EC/IC/IR), keep relaxed prefix behavior.
    if (query.isLettersOnly) {
      if (display.normalizedRaw.startsWith(query.letters) ||
          route.normalizedRaw.startsWith(query.letters)) {
        return true;
      }
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
      if (_PublicTrainIdentity.parse(t).letters.isEmpty) continue;
      out.add(t);
    }
    return out;
  }

  static bool matchesTrainQueryTokenAware(
    String trainQuery,
    List<String> rawLabels,
  ) {
    final query = _PublicTrainIdentity.parse(trainQuery);
    if (query.isEmpty) return true;

    for (final raw in rawLabels) {
      final candidate = _PublicTrainIdentity.parse(raw);
      if (_matchesTrainIdentity(
        query,
        candidate,
        allowCollapsedAdditionalNumber: true,
      )) {
        return true;
      }

      final publicLineId = extractPublicLineId(raw);
      if (publicLineId != null && publicLineId == query.normalizedRaw) {
        return true;
      }

      final tokens = trainLabelTokens(raw);
      for (final token in tokens) {
        final tokenIdentity = _PublicTrainIdentity.parse(token);
        if (tokenIdentity.isEmpty) continue;

        // letters+digits query: strict exact letters+digits (protects S3 vs S33)
        if (query.isLettersAndDigits) {
          if (tokenIdentity.letters == query.letters &&
              tokenIdentity.digits == query.digits) {
            return true;
          }
          continue;
        }

        // letters-only query: tolerant prefix on token ("EC" matches "EC7", "ECE")
        if (query.isLettersOnly) {
          if (tokenIdentity.letters.startsWith(query.letters)) return true;
          continue;
        }

        // digits-only query: keep broad matching behavior
        if (query.isDigitsOnly) {
          if (tokenIdentity.normalizedRaw.contains(query.digits)) return true;
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

    final rawDigits = RegExp(
      r'\d+',
    ).allMatches(stop.stopIdRaw).map((m) => m.group(0)!).join();
    if (rawDigits.contains('8500010')) return true;

    final name = (stopNameCache[stopCanon] ?? '').toLowerCase();
    if (name.contains('basel') &&
        name.contains('sbb') &&
        !name.contains('bad')) {
      return true;
    }

    return false;
  }

  static bool isLettersOnlyLongDistanceQuery(String trainQuery) {
    final query = _PublicTrainIdentity.parse(trainQuery);
    if (!query.isLettersOnly) return false;
    return query.letters == 'ec' ||
        query.letters == 'ic' ||
        query.letters == 'ir';
  }

  static bool shouldUseGtfsBridgeForQuery(String trainQuery) {
    final query = _PublicTrainIdentity.parse(trainQuery);
    if (query.isEmpty || query.letters.isEmpty) return false;

    // Existing long-distance letters-only queries (EC/IC/IR).
    if (query.isLettersOnly) {
      return isLettersOnlyLongDistanceQuery(trainQuery);
    }

    // letters+digits line ids (IR55, IC5, S20, S3, ...).
    return true;
  }

  static String gtfsBridgeDecisionReason(String trainQuery) {
    final query = _PublicTrainIdentity.parse(trainQuery);
    if (query.isEmpty) return 'empty-query';
    if (query.letters.isEmpty) return 'digits-only-query';

    // Disable bridge for S-lines (S3, S20, SN1, ...).
    if (RegExp(r'^sn?\d+$').hasMatch(query.normalizedRaw)) {
      return 'local-s-line';
    }

    if (query.isLettersOnly) {
      return isLettersOnlyLongDistanceQuery(trainQuery)
          ? 'long-distance-letters'
          : 'letters-only-not-supported';
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

    final out = seen.values.toList()
      ..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    trace('Dedupe after count=${out.length}');
    return out;
  }
}
