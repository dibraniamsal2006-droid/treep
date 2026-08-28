import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/trip_candidate.dart';
import '../services/alarm_service.dart';
import '../services/matching_service.dart';
import '../services/transport_service.dart';
import 'settings_screen.dart';

enum _PullUpFooterState { idle, loading, exhausted }

class LocalDirectionEnrichmentDecision {
  const LocalDirectionEnrichmentDecision({
    required this.original,
    required this.result,
    required this.counterpart,
    required this.etaDifferenceSeconds,
    required this.reason,
  });

  final TripCandidate original;
  final TripCandidate result;
  final TripCandidate? counterpart;
  final int? etaDifferenceSeconds;
  final String reason;

  bool get enriched => reason == 'enriched';
}

class LocalDirectionEnrichmentResult {
  const LocalDirectionEnrichmentResult({
    required this.candidates,
    required this.decisions,
  });

  final List<TripCandidate> candidates;
  final List<LocalDirectionEnrichmentDecision> decisions;

  int get enrichedCount =>
      decisions.where((decision) => decision.enriched).length;
}

LocalDirectionEnrichmentResult enrichLocalLineDirections({
  required List<TripCandidate> gtfsCandidates,
  required List<TripCandidate> stationboardCandidates,
  required String trainQuery,
  required bool Function(String a, String b) stopIdsMatch,
  required String Function(TripCandidate candidate) directionLabel,
  Duration maxEtaDifference = const Duration(minutes: 4),
  Duration ambiguityMargin = const Duration(seconds: 90),
}) {
  final queryNorm = MatchingService.normalizeTrainToken(trainQuery);

  bool matchesRequestedLine(TripCandidate candidate) {
    final displayNorm = MatchingService.normalizeTrainToken(
      candidate.displayTrain,
    );
    final routeNorm = MatchingService.normalizeTrainToken(candidate.routeId);
    return MatchingService.matchesTrainQuery(queryNorm, displayNorm) ||
        MatchingService.matchesTrainQuery(queryNorm, routeNorm);
  }

  String publicDirectionToken(TripCandidate candidate) {
    final withoutStopId = directionLabel(
      candidate,
    ).replaceFirst(RegExp(r'\s*\(\d+\)\s*$'), '');
    return MatchingService.normalizeStationToken(withoutStopId);
  }

  final output = <TripCandidate>[];
  final decisions = <LocalDirectionEnrichmentDecision>[];

  for (var gtfsIndex = 0; gtfsIndex < gtfsCandidates.length; gtfsIndex++) {
    final gtfs = gtfsCandidates[gtfsIndex];
    final eligible = <({int index, TripCandidate candidate, int etaDiff})>[];

    for (
      var fallbackIndex = 0;
      fallbackIndex < stationboardCandidates.length;
      fallbackIndex++
    ) {
      final fallback = stationboardCandidates[fallbackIndex];
      if (!matchesRequestedLine(gtfs) || !matchesRequestedLine(fallback)) {
        continue;
      }
      if (!gtfs.destinationMatched || !fallback.destinationMatched) continue;
      if (!stopIdsMatch(gtfs.stopId, fallback.stopId)) continue;

      eligible.add((
        index: fallbackIndex,
        candidate: fallback,
        etaDiff: gtfs.etaLocal.difference(fallback.etaLocal).inSeconds.abs(),
      ));
    }

    eligible.sort((a, b) => a.etaDiff.compareTo(b.etaDiff));
    if (eligible.isEmpty) {
      output.add(gtfs);
      decisions.add(
        LocalDirectionEnrichmentDecision(
          original: gtfs,
          result: gtfs,
          counterpart: null,
          etaDifferenceSeconds: null,
          reason: 'no-same-line-destination-counterpart',
        ),
      );
      continue;
    }

    final best = eligible.first;
    if (best.etaDiff > maxEtaDifference.inSeconds) {
      output.add(gtfs);
      decisions.add(
        LocalDirectionEnrichmentDecision(
          original: gtfs,
          result: gtfs,
          counterpart: best.candidate,
          etaDifferenceSeconds: best.etaDiff,
          reason: 'outside-time-window',
        ),
      );
      continue;
    }
    if (eligible.length > 1 &&
        eligible[1].etaDiff - best.etaDiff < ambiguityMargin.inSeconds) {
      output.add(gtfs);
      decisions.add(
        LocalDirectionEnrichmentDecision(
          original: gtfs,
          result: gtfs,
          counterpart: best.candidate,
          etaDifferenceSeconds: best.etaDiff,
          reason: 'ambiguous-stationboard-counterpart',
        ),
      );
      continue;
    }

    final reciprocalGtfs = <({int index, int etaDiff})>[];
    for (var otherIndex = 0; otherIndex < gtfsCandidates.length; otherIndex++) {
      final other = gtfsCandidates[otherIndex];
      if (!matchesRequestedLine(other) || !other.destinationMatched) continue;
      if (!stopIdsMatch(other.stopId, best.candidate.stopId)) continue;
      reciprocalGtfs.add((
        index: otherIndex,
        etaDiff: other.etaLocal
            .difference(best.candidate.etaLocal)
            .inSeconds
            .abs(),
      ));
    }
    reciprocalGtfs.sort((a, b) => a.etaDiff.compareTo(b.etaDiff));
    final reciprocalIsClear =
        reciprocalGtfs.isNotEmpty &&
        reciprocalGtfs.first.index == gtfsIndex &&
        (reciprocalGtfs.length == 1 ||
            reciprocalGtfs[1].etaDiff - reciprocalGtfs.first.etaDiff >=
                ambiguityMargin.inSeconds);
    if (!reciprocalIsClear) {
      output.add(gtfs);
      decisions.add(
        LocalDirectionEnrichmentDecision(
          original: gtfs,
          result: gtfs,
          counterpart: best.candidate,
          etaDifferenceSeconds: best.etaDiff,
          reason: 'ambiguous-gtfs-counterpart',
        ),
      );
      continue;
    }

    final fallbackDirection = publicDirectionToken(best.candidate);
    if (fallbackDirection.isEmpty || fallbackDirection == 'unknown') {
      output.add(gtfs);
      decisions.add(
        LocalDirectionEnrichmentDecision(
          original: gtfs,
          result: gtfs,
          counterpart: best.candidate,
          etaDifferenceSeconds: best.etaDiff,
          reason: 'counterpart-direction-unusable',
        ),
      );
      continue;
    }

    if (publicDirectionToken(gtfs) == fallbackDirection) {
      final result = gtfs.withPublicDirection(
        direction: best.candidate.publicDirection,
        source: DirectionSource.stationboard,
      );
      output.add(result);
      decisions.add(
        LocalDirectionEnrichmentDecision(
          original: gtfs,
          result: result,
          counterpart: best.candidate,
          etaDifferenceSeconds: best.etaDiff,
          reason: 'direction-already-correct',
        ),
      );
      continue;
    }

    final fallbackTerminalRaw = best.candidate.terminalStopId.trim();
    final enriched = gtfs.withPublicDirection(
      direction: fallbackTerminalRaw.isNotEmpty
          ? fallbackTerminalRaw
          : directionLabel(best.candidate),
      source: DirectionSource.stationboard,
    );
    output.add(enriched);
    decisions.add(
      LocalDirectionEnrichmentDecision(
        original: gtfs,
        result: enriched,
        counterpart: best.candidate,
        etaDifferenceSeconds: best.etaDiff,
        reason: 'enriched',
      ),
    );
  }

  return LocalDirectionEnrichmentResult(
    candidates: output,
    decisions: decisions,
  );
}

bool candidateNeedsDestinationConfirmation(TripCandidate candidate) {
  return !candidate.destinationMatched;
}

class TreepHome extends StatefulWidget {
  const TreepHome({
    super.key,
    this.onPreferencesChanged,
    this.transportService,
  });

  final Future<void> Function()? onPreferencesChanged;
  final TransportService? transportService;

  @override
  State<TreepHome> createState() => _TreepHomeState();
}

class _TreepHomeState extends State<TreepHome> {
  final _trainController = TextEditingController();
  final _stationController = TextEditingController();
  int _upcomingTripsLimit = 8; // how many upcoming connections to show
  int _upcomingWindowHours = 2;
  double _minutesBefore = 3;
  bool _isTestingFeed = false;
  bool _isStartingTracking = false;
  String _trackingStatus = '';
  TripCandidate? _selectedCandidate;
  static const NativeAlarmGateway _nativeAlarm =
      MethodChannelNativeAlarmGateway();
  late final AlarmTransactionCoordinator<TripCandidate> _alarmCoordinator;
  int _nextNotificationBaseId = DateTime.now().millisecondsSinceEpoch.remainder(
    1000000000,
  );
  DateTime? get _alarmFirstFire => _alarmCoordinator.confirmed?.fireTime;
  bool get _nativeAlarmArmed =>
      _alarmCoordinator.confirmed?.hasConfirmedNativeAlarm == true;
  // GTFS-RT plan is limited (e.g. 5 calls / minute). We throttle requests to avoid 429.
  // 5/min ~= 12s per call. Use 13s to be a little safer.
  Timer? _foregroundArmTimer;
  Timer? _ringTimer;
  Timer? _liveUpdateTimer;
  Timer? _sliderDebounce;
  int _rescheduleToken = 0;
  bool _isRescheduling = false;
  bool _isRinging = false;
  Timer? _selfTestStopper;
  Timer? _selfTestHapticTimer;
  bool _isSelfTesting = false;
  final Random _rng = Random();
  DateTime? _lastAlarmUxAt;

  bool _sleepLinesEnabled = true;
  bool _sleepOverlayShowing = false;
  Timer? _sleepOverlayTimer;
  static const int _maxPickerHorizonHours = 6;
  late final TransportService _transportService;

  @override
  void initState() {
    super.initState();
    _alarmCoordinator = AlarmTransactionCoordinator<TripCandidate>(
      native: _nativeAlarm,
      notifications: const PluginAlarmNotificationGateway(),
      nativeSchedulingEnabled: Platform.isIOS,
    );
    _transportService =
        widget.transportService ??
        TransportService(
          trace: _trace,
          traceCandidates: _traceStageCandidates,
          upcomingWindowHoursProvider: () => _upcomingWindowHours,
        );
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sleepEnabled = prefs.getBool(kPrefsSleepLinesEnabledKey) ?? true;

      final rawLimit = prefs.getInt(kPrefsUpcomingTripsLimitKey) ?? 8;
      final limit = rawLimit.clamp(1, 20);
      final rawWindowHours = prefs.getInt(kPrefsUpcomingWindowHoursKey) ?? 2;
      final windowHours = <int>{2, 4, 6}.contains(rawWindowHours)
          ? rawWindowHours
          : 2;

      if (!mounted) return;
      setState(() {
        _sleepLinesEnabled = sleepEnabled;
        _upcomingTripsLimit = limit;
        _upcomingWindowHours = windowHours;
      });
    } catch (_) {}
  }

  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
    await _loadPrefs();
    await widget.onPreferencesChanged?.call();
  }

  static const List<String> _sleepLines = <String>[
    'Gute Nacht – Treep passt auf. 😴',
    'Schlaf gut. Ich schrei dich rechtzeitig an. ⏰',
    'Ayay Captain. Schlafmodus aktiviert. 🫡',
    'Wir sehen uns, wenn du ankommst. 👀',
    'Wenn du das hörst, bist du zu weit gefahren… Spaß. 😅',
    'No worries – ich weck dich. 🙏',
    'Train & Sleep – Mission gestartet. 🚆',
    'Leg dich hin, ich mach den Rest. 💤',
    'Bitte nicht schnarchen – der Zug hört mit. 🤫',
    'Der nächste Halt gehört dir. 🧠',
    'Alarm ist geladen. Schlaf jetzt. 🔋',
    'Einmal kurz wegpennen – ich regel. ✅',
    'Heute wird nicht verpasst. Versprochen. 🤝',
    'Du pennst, ich tracke. Deal. 🤝',
    'Gönn dir Schlaf – ich bin dein Backup. 🛟',
  ];

  String _pickSleepLine() {
    if (!_sleepLinesEnabled) return '';
    return _sleepLines[_rng.nextInt(_sleepLines.length)];
  }

  Future<void> _showSleepLineOverlay(String line) async {
    if (!_sleepLinesEnabled) return;
    final text = line.trim();
    if (text.isEmpty) return;
    if (!mounted) return;
    if (_sleepOverlayShowing) return;

    _sleepOverlayShowing = true;

    // Make sure we don't leak timers.
    _sleepOverlayTimer?.cancel();

    bool didAutoPop = false;

    // Auto-close after a short time.
    _sleepOverlayTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      if (didAutoPop) return;
      didAutoPop = true;
      // Only pop the root dialog route we opened (best-effort).
      final nav = Navigator.of(context, rootNavigator: true);
      if (nav.canPop()) nav.pop();
    });

    await showGeneralDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierLabel: 'sleep_line',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, a1, a2) {
        return SafeArea(
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 22),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(
                      blurRadius: 22,
                      offset: Offset(0, 10),
                      color: Colors.black26,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('😴', style: TextStyle(fontSize: 26)),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        text,
                        style: const TextStyle(
                          fontSize: 16,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, anim, sec, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    ).whenComplete(() {
      _sleepOverlayTimer?.cancel();
      _sleepOverlayTimer = null;
      _sleepOverlayShowing = false;
    });
  }

  String _hhmm(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  // === TREEP: ALARM LOGIC START ===
  Future<void> _stopAlarm() async {
    _stopForegroundRing();
    _liveUpdateTimer?.cancel();
    _liveUpdateTimer = null;
    _sliderDebounce?.cancel();
    _sliderDebounce = null;
    _rescheduleToken++;
    _isRescheduling = false;
    final result = await _alarmCoordinator.stop();
    if (!result.succeeded) {
      debugPrint('[alarm] stop cleanup failed: ${result.failures.join("; ")}');
    }
    if (!mounted) return;
    setState(() {
      if (!result.succeeded) {
        _trackingStatus = 'Alarm stopped; native cleanup needs checking.';
      }
    });
  }

  void _startForegroundRing(DateTime firstFire) {
    _foregroundArmTimer?.cancel();
    _ringTimer?.cancel();
    _isRinging = false;

    final delay = firstFire.difference(DateTime.now());
    final wait = delay.isNegative ? Duration.zero : delay;

    _foregroundArmTimer = Timer(wait, () {
      if (!mounted) return;
      if (_alarmCoordinator.confirmed == null) return;

      setState(() => _isRinging = true);

      // iOS: start the native loud alarm once when we reach the ring time.
      // (This is the only reliable way to get real audio in the foreground.)
      if (Platform.isIOS) {
        _nativeAlarm.startLegacyNow();
      }

      // HARD loop until Stop is pressed
      _ringTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        try {
          // Always keep haptics as a safety net.
          HapticFeedback.heavyImpact();

          // Non‑iOS fallback: try to make *some* noise in foreground.
          if (!Platform.isIOS) {
            SystemSound.play(SystemSoundType.alert);
          }
        } catch (_) {}
      });

      // Visual emergency dialog (forces user attention)
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('⏰ TREEP ALARM'),
          content: const Text(
            'You are approaching your stop.\n\nPress STOP to silence the alarm.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _stopAlarm();
              },
              child: const Text(
                'STOP ALARM',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  void _stopForegroundRing() {
    _foregroundArmTimer?.cancel();
    _foregroundArmTimer = null;
    _ringTimer?.cancel();
    _ringTimer = null;

    _selfTestStopper?.cancel();
    _selfTestStopper = null;
    _selfTestHapticTimer?.cancel();
    _selfTestHapticTimer = null;

    if (mounted && _isRinging) setState(() => _isRinging = false);
    if (mounted && _isSelfTesting) setState(() => _isSelfTesting = false);
  }

  void _startLiveUpdates() {
    _liveUpdateTimer?.cancel();
    _liveUpdateTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      _tickLiveUpdate();
    });
  }

  Future<void> _tickLiveUpdate() async {
    if (!mounted) return;
    final current = _selectedCandidate;
    if (current == null) return;
    if (_alarmCoordinator.confirmed == null) return; // nur wenn armed
    if (_isRescheduling) return;

    try {
      final updated = await _refreshCandidateEta(current);
      if (!mounted) return;
      if (updated == null) return;
      _traceCandidate(
        'Live-update current',
        current,
        source: 'tick-before-compare',
      );
      _traceCandidate(
        'Live-update fetched',
        updated,
        source: 'tick-before-compare',
      );

      final etaDiff = updated.etaLocal
          .difference(current.etaLocal)
          .inSeconds
          .abs();
      final delayDiff = (updated.delaySeconds - current.delaySeconds).abs();
      if (etaDiff < 30 && delayDiff < 30) return;

      await _rescheduleAlarmWith(updated, reason: 'Verspätung/Update');
    } catch (error) {
      debugPrint('[alarm] live refresh failed: $error');
    }
  }

  Future<TripCandidate?> _refreshCandidateEta(TripCandidate c) async {
    _traceCandidate('Live-update start', c, source: 'refresh-input');
    final refreshed = await _transportService.refreshCandidateEta(c);
    if (refreshed != null) {
      _traceCandidate(
        'Live-update service result',
        refreshed,
        source: 'refresh-service',
      );
    }
    return refreshed;
  }

  Future<void> _rescheduleAlarmWith(
    TripCandidate updated, {
    required String reason,
  }) async {
    if (!mounted) return;

    _isRescheduling = true;
    final token = ++_rescheduleToken;

    try {
      final succeeded = await _armAlarmFor(
        updated,
        showUx: false,
        requestPermissions: false,
      );
      if (succeeded && mounted) {
        setState(() {
          _selectedCandidate = updated;
          _trackingStatus =
              'Update: $reason — ETA ${_hhmm(updated.etaLocal)} (${_fmtDelay(updated.delaySeconds)})';
        });
        _traceCandidate(
          'selectedCandidate reassigned',
          updated,
          source: 'live-update-confirmed',
        );
      } else if (!succeeded) {
        debugPrint('[alarm] replacement failed; previous retained');
      }
    } finally {
      if (token == _rescheduleToken) {
        _isRescheduling = false;
        if (mounted) {
          setState(
            () {},
          ); // sorgt dafür, dass "Alarm: armed for ..." sicher neu rendert
        }
      }
    }
  }

  Future<bool> _armAlarmFor(
    TripCandidate chosen, {
    bool showUx = true,
    bool requestPermissions = true,
  }) async {
    final minsBefore = _minutesBefore.round();
    final now = DateTime.now();
    DateTime first = chosen.etaLocal.subtract(Duration(minutes: minsBefore));
    // Give ourselves enough buffer so iOS scheduling never sees a "past" timestamp.
    // 10s is still instant for the user, but avoids edge-case races.
    final minFirst = now.add(const Duration(seconds: 10));
    if (first.isBefore(minFirst)) {
      first = minFirst;
    }

    const interval = Duration(seconds: 45);
    const count = 12;

    final baseId = _nextNotificationBaseId;
    _nextNotificationBaseId += count;

    final title = 'TREEP ALARM';
    final body =
        '${chosen.vehicleLabel}: ${chosen.displayTrain} → ${_terminalLabel(chosen)}\n'
        'Your stop: ${_stopLabel(chosen.stopId)} • ETA ${_hhmm(chosen.etaLocal)}';

    // UX (dialog + snackbar + sleep-line overlay) should only appear on explicit user action
    // and not more often than once every 30 seconds.
    final nowForUx = DateTime.now();
    final allowUx =
        showUx &&
        (_lastAlarmUxAt == null ||
            nowForUx.difference(_lastAlarmUxAt!) > const Duration(seconds: 30));

    // Show an explicit OK dialog (user can disable it via “Nicht mehr anzeigen”).
    // Only when the user explicitly sets the alarm (not when we silently re-schedule).
    if (allowUx) {
      await _maybeShowVolumeAndFocusDialog();
    }

    final result = await _alarmCoordinator.arm(
      selection: chosen,
      requestPermissions: requestPermissions,
      plan: AlarmNotificationPlan(
        baseId: baseId,
        firstFire: first,
        count: count,
        interval: interval,
        title: title,
        body: body,
      ),
    );

    if (!result.succeeded) {
      debugPrint(
        '[alarm] arm failed retained=${result.previousRetained}: ${result.failures.join("; ")}',
      );
      return false;
    }
    if (!mounted) return false;
    setState(() {});
    _startForegroundRing(first);
    _startLiveUpdates();

    if (allowUx) {
      _lastAlarmUxAt = nowForUx;

      // Friendly line (unique Treep vibe) — shown ONLY as overlay.
      final sleepLine = _pickSleepLine();

      // Kurze Bestätigung (SnackBar) – ohne Spruch (damit nichts doppelt vorkommt).
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Alarm gesetzt für ${_hhmm(first)}.'),
          duration: const Duration(seconds: 2),
        ),
      );

      // Spruch als Overlay (abgedunkelter Hintergrund), geht automatisch weg.
      // Post-frame, damit es zuverlässig über allem erscheint.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showSleepLineOverlay(sleepLine);
      });
    }
    return true;
  }

  Future<void> _onMinutesBeforeChanged(double v) async {
    if (!mounted) return;
    setState(() => _minutesBefore = v);

    _sliderDebounce?.cancel();
    _sliderDebounce = Timer(const Duration(milliseconds: 450), () async {
      final c = _selectedCandidate;
      if (c == null) return;
      if (_alarmCoordinator.confirmed == null) return;

      await _rescheduleAlarmWith(
        c,
        reason: 'Alarm-Vorlauf geändert (${_minutesBefore.round()}m)',
      );
    });
  }

  Future<void> _runAlarmSelfTest() async {
    if (_isSelfTesting) return;

    // Make sure permissions exist (helps first-run).
    await NotificationService.requestPermissions();

    if (!mounted) return;
    setState(() => _isSelfTesting = true);

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Self-test (3s): Turn MEDIA volume up in Control Center. If Bluetooth is on, sound may play on AirPods/Bluetooth device.',
        ),
        duration: Duration(seconds: 4),
      ),
    );

    // Start sound (foreground) + strong haptics pattern for 3 seconds.
    try {
      if (Platform.isIOS) {
        await _nativeAlarm.startLegacyNow();
      } else {
        SystemSound.play(SystemSoundType.alert);
      }
    } catch (_) {}

    int tick = 0;
    _selfTestHapticTimer?.cancel();
    _selfTestHapticTimer = Timer.periodic(const Duration(milliseconds: 350), (
      _,
    ) {
      // A slightly "aggressive" pattern (heavy-heavy-light) without being too spammy.
      tick++;
      try {
        if (tick % 3 == 0) {
          HapticFeedback.lightImpact();
        } else {
          HapticFeedback.heavyImpact();
        }
      } catch (_) {}
    });

    _selfTestStopper?.cancel();
    _selfTestStopper = Timer(const Duration(seconds: 3), () async {
      try {
        await _nativeAlarm.stopLegacyPlayback();
      } catch (_) {}
      _selfTestHapticTimer?.cancel();
      _selfTestHapticTimer = null;
      if (!mounted) return;
      setState(() => _isSelfTesting = false);
    });
  }

  Future<void> _maybeShowVolumeAndFocusDialog() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final skip = prefs.getBool(kPrefsSkipVolumeDialogKey) ?? false;
      if (skip || !mounted) return;

      bool dontShowAgain = false;

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setLocalState) {
              return AlertDialog(
                title: const Text('Quick check before you sleep'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '• Medien-Lautstärke hoch (Control Center)\n'
                      '• Wenn Bluetooth verbunden ist: Sound kann auf AirPods/Auto gehen\n'
                      '• Wenn du Fokus/Nicht stören nutzt: Treep als zeitkritisch zulassen',
                    ),
                    const SizedBox(height: 12),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: dontShowAgain,
                      onChanged: (v) =>
                          setLocalState(() => dontShowAgain = v ?? false),
                      title: const Text('Nicht mehr anzeigen'),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('OK'),
                  ),
                ],
              );
            },
          );
        },
      );

      if (dontShowAgain) {
        await prefs.setBool(kPrefsSkipVolumeDialogKey, true);
      }
    } catch (_) {
      // Falls prefs/dialog aus irgendeinem Grund nicht geht: nicht blockieren.
      return;
    }
  }

  // === TREEP: ALARM LOGIC END ===
  String _fmtDelay(int delaySeconds) {
    final mins = (delaySeconds / 60).round();
    if (delaySeconds.abs() < 30) return 'on time';
    return mins > 0 ? '+${mins}m' : '${mins}m';
  }

  void _trace(String message) {
    if (!kDebugMode) return;
    debugPrint('[Treep][Trace] $message');
  }

  void _traceCandidate(String stage, TripCandidate c, {String? source}) {
    final terminalLabel = _terminalLabel(c);
    final src = source == null || source.isEmpty ? '' : ' source=$source';
    _trace(
      '$stage$src tripId=${c.tripId} routeId=${c.routeId} stopId=${c.stopId} '
      'etaLocal=${c.etaLocal.toIso8601String()} delaySeconds=${c.delaySeconds} '
      'displayTrain="${c.displayTrain}" terminalLabel="$terminalLabel"',
    );
  }

  void _traceCandidatePool(
    String stage,
    List<TripCandidate> candidates, {
    String? source,
  }) {
    final src = source == null || source.isEmpty ? '' : ' source=$source';
    _trace('$stage$src count=${candidates.length}');
    final maxItems = candidates.length > 20 ? 20 : candidates.length;
    for (var i = 0; i < maxItems; i++) {
      _traceCandidate('$stage[#${i + 1}]', candidates[i], source: source);
    }
    if (candidates.length > maxItems) {
      _trace('$stage truncated=${candidates.length - maxItems}');
    }
  }

  void _traceDirectionBuckets(
    String stage,
    Map<String, List<TripCandidate>> byDir,
  ) {
    _trace('$stage bucketCount=${byDir.length}');
    const maxItemsPerDirection = 6;
    final keys = byDir.keys.toList()..sort();
    for (final key in keys) {
      final list = [...(byDir[key] ?? const <TripCandidate>[])]
        ..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
      _trace('$stage bucket="$key" count=${list.length}');
      for (final c in list.take(maxItemsPerDirection)) {
        _trace(
          '$stage item bucket="$key" eta=${c.etaLocal.toIso8601String()} '
          'displayTrain="${c.displayTrain}" terminal="${_terminalLabel(c)}" tripId=${c.tripId}',
        );
      }
      if (list.length > maxItemsPerDirection) {
        _trace(
          '$stage bucket="$key" truncated=${list.length - maxItemsPerDirection}',
        );
      }
    }
  }

  void _traceStageCandidates(
    String stage,
    List<TripCandidate> candidates, {
    int max = 6,
  }) {
    _trace('$stage count=${candidates.length}');
    final sorted = [...candidates]
      ..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    for (final c in sorted.take(max)) {
      _trace(
        '$stage item displayTrain="${c.displayTrain}" eta=${c.etaLocal.toIso8601String()} '
        'delaySeconds=${c.delaySeconds} terminalLabel="${_terminalLabel(c)}" '
        'stopId=${c.stopId} tripId=${c.tripId}',
      );
    }
  }

  List<TripCandidate> _dropPastCandidates(
    List<TripCandidate> input, {
    required String stage,
  }) {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(seconds: 60));
    final out = input.where((c) => !c.etaLocal.isBefore(cutoff)).toList()
      ..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    final removed = input.length - out.length;
    if (removed > 0) {
      _trace('$stage removedPast=$removed now=${now.toIso8601String()}');
    }
    return out;
  }

  ({
    List<TripCandidate> filtered,
    List<TripCandidate> fresh,
    List<TripCandidate> deduped,
  })
  _runTrainQueryFallbackPostPipeline({
    required String scenarioTag,
    required String trainQueryNorm,
    required List<TripCandidate> broadArrivalCandidates,
  }) {
    final filtered = broadArrivalCandidates.where((c) {
      final candidateNorm = _normalizeTrainToken(c.displayTrain);
      return MatchingService.matchesTrainQuery(trainQueryNorm, candidateNorm);
    }).toList()..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    _trace('Train-specific fallback filtered count=${filtered.length}');
    _traceStageCandidates(
      'Fallback public-filter leave $scenarioTag',
      filtered,
    );

    for (final c in filtered.take(10)) {
      _trace(
        'Train-specific fallback candidate displayTrain="${c.displayTrain}" '
        'eta=${c.etaLocal.toIso8601String()} delaySeconds=${c.delaySeconds} '
        'terminal="${_terminalLabel(c)}" tripId=${c.tripId} stopId=${c.stopId}',
      );
    }

    final fresh = _dropPastCandidates(
      filtered,
      stage: 'Train-specific fallback filtered pool',
    );
    _trace('Train-specific fallback stale-filter count=${fresh.length}');
    _traceStageCandidates('Fallback stale-filter leave $scenarioTag', fresh);

    final deduped = _dedupeCandidatesViaService(fresh)
      ..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    _trace('Train-specific fallback dedupe count=${deduped.length}');
    _traceStageCandidates('Fallback dedupe leave $scenarioTag', deduped);

    return (filtered: filtered, fresh: fresh, deduped: deduped);
  }

  int _pickerTakePerDirection() {
    return _upcomingTripsLimit < 3 ? 3 : _upcomingTripsLimit;
  }

  void _cancelTrackingSelection(String stage) {
    _trace('Pipeline cancelled stage=$stage reason=picker-dismissed');
    if (!mounted) return;
    setState(() {
      _selectedCandidate = null;
      _trackingStatus = 'Selection cancelled. No tracking was started.';
    });
  }

  bool _stopIdMatches(String stopCanon, String destCanon) {
    return _transportService.stopIdMatches(stopCanon, destCanon);
  }

  TripCandidate? _bridgeFallbackCandidateToGtfs({
    required TripCandidate fallbackCandidate,
    required FeedMessage feed,
    required String destStopCanon,
  }) {
    _traceCandidate(
      'GTFS bridge start',
      fallbackCandidate,
      source: 'fallback-seed',
    );

    final gtfsPool = _findCandidates(
      feed,
      '',
      destStopCanon,
      requireDestinationMatch: true,
    );
    if (gtfsPool.isEmpty) {
      _trace(
        'GTFS bridge no-candidates reason=gtfs_pool_empty '
        'fallbackTripId=${fallbackCandidate.tripId} destStopCanon=$destStopCanon',
      );
      return null;
    }

    final fallbackTermNorm = MatchingService.normalizeStationToken(
      _terminalLabel(fallbackCandidate),
    );
    final fallbackStopCanon =
        _normalizeStopId(fallbackCandidate.stopId) ?? fallbackCandidate.stopId;

    TripCandidate? best;
    double? bestScore;
    double? secondBestScore;

    for (final g in gtfsPool) {
      final etaDiffSec = g.etaLocal
          .difference(fallbackCandidate.etaLocal)
          .inSeconds
          .abs();
      final gtfsTermNorm = MatchingService.normalizeStationToken(
        _terminalLabel(g),
      );

      double terminalPenalty = 0;
      if (fallbackTermNorm.isNotEmpty && gtfsTermNorm.isNotEmpty) {
        if (fallbackTermNorm == gtfsTermNorm) {
          terminalPenalty = 0;
        } else if (gtfsTermNorm.contains(fallbackTermNorm) ||
            fallbackTermNorm.contains(gtfsTermNorm)) {
          terminalPenalty = 90;
        } else {
          terminalPenalty = 300;
        }
      }

      final gtfsStopCanon = _normalizeStopId(g.stopId) ?? g.stopId;
      final sameDest =
          _stopIdMatches(gtfsStopCanon, fallbackStopCanon) ||
          _stopIdMatches(gtfsStopCanon, destStopCanon);

      var score = etaDiffSec.toDouble() + terminalPenalty;
      if (sameDest) score -= 40;
      if (g.destinationMatched) score -= 20;

      _trace(
        'GTFS bridge score fallbackTripId=${fallbackCandidate.tripId} '
        'gtfsTripId=${g.tripId} gtfsRouteId=${g.routeId} '
        'etaDiffSec=$etaDiffSec terminalPenalty=${terminalPenalty.toStringAsFixed(0)} '
        'sameDest=$sameDest score=${score.toStringAsFixed(1)}',
      );

      if (bestScore == null || score < bestScore) {
        secondBestScore = bestScore;
        bestScore = score;
        best = g;
      } else if (secondBestScore == null || score < secondBestScore) {
        secondBestScore = score;
      }
    }

    if (best == null || bestScore == null) {
      _trace(
        'GTFS bridge no-candidates reason=no_scored_result fallbackTripId=${fallbackCandidate.tripId}',
      );
      return null;
    }

    final clearWinner =
        secondBestScore == null || (secondBestScore - bestScore) >= 90;
    final plausibleTime =
        best.etaLocal.difference(fallbackCandidate.etaLocal).inSeconds.abs() <=
        15 * 60;
    if (!clearWinner || !plausibleTime) {
      _trace(
        'GTFS bridge no-candidates reason=not_clear '
        'fallbackTripId=${fallbackCandidate.tripId} bestScore=${bestScore.toStringAsFixed(1)} '
        'secondBestScore=${secondBestScore?.toStringAsFixed(1) ?? "none"} '
        'etaDiffSec=${best.etaLocal.difference(fallbackCandidate.etaLocal).inSeconds.abs()}',
      );
      return null;
    }

    final fallbackTerminalRaw = fallbackCandidate.terminalStopId.trim();
    final fallbackTerminalCanon = fallbackCandidate.terminalStopIdCanon.trim();
    final gtfsTerminalRaw = best.terminalStopId.trim();
    final gtfsTerminalCanon = best.terminalStopIdCanon.trim();

    // Preserve user-facing fallback labels. Only use GTFS terminal when fallback has no usable terminal text.
    var mergedTerminalRaw = fallbackTerminalRaw.isNotEmpty
        ? fallbackTerminalRaw
        : gtfsTerminalRaw;
    var mergedTerminalCanon = fallbackTerminalCanon;
    if (mergedTerminalRaw.isEmpty && mergedTerminalCanon.isEmpty) {
      mergedTerminalRaw = gtfsTerminalRaw;
      mergedTerminalCanon = gtfsTerminalCanon;
    }

    final merged = TripCandidate(
      // Keep GTFS identity/timing for realtime refresh correctness.
      tripId: best.tripId,
      originalTripId: best.originalTripId,
      routeId: best.routeId,
      startDate: best.startDate,
      startTime: best.startTime,
      // Keep fallback destination display identity to avoid internal stop ids in UI.
      stopId: fallbackCandidate.stopId,
      etaLocal: best.etaLocal,
      delaySeconds: best.delaySeconds,
      // Keep public-facing line labeling from fallback stationboard.
      displayTrain: fallbackCandidate.displayTrain,
      vehicleLabel: fallbackCandidate.vehicleLabel,
      destinationMatched:
          best.destinationMatched || fallbackCandidate.destinationMatched,
      upcomingStops: best.upcomingStops,
      terminalStopId: mergedTerminalRaw,
      terminalStopIdCanon: mergedTerminalCanon,
      directionSource: fallbackCandidate.directionSource,
    );

    _trace(
      'GTFS bridge chosen fallbackDisplayTrain="${fallbackCandidate.displayTrain}" '
      'gtfsDisplayTrain="${best.displayTrain}"',
    );
    _trace(
      'GTFS bridge merged finalDisplayTrain="${merged.displayTrain}" '
      'finalTerminal="${_terminalLabel(merged)}"',
    );
    _traceCandidate('GTFS bridge chosen', best, source: 'bridge-result');
    _traceCandidate('GTFS bridge merged', merged, source: 'bridge-result');
    return merged;
  }

  /// Fallback when destination-by-ID matching fails:
  /// Look at the stops of trips that match the train query and try to find a stop whose *name*
  /// matches the user-entered destination string.
  Future<List<TripCandidate>> _findCandidatesByTrainAndDestinationName(
    FeedMessage feed,
    String trainQuery,
    String destName,
  ) async {
    return _transportService.findCandidatesByTrainAndDestinationName(
      feed,
      trainQuery,
      destName,
    );
  }

  Future<void> _ensureStopName(String canonStopId) async {
    await _transportService.ensureStopName(canonStopId);
  }

  Future<void> _warmStopNamesForCandidates(
    List<TripCandidate> candidates,
  ) async {
    final ids = <String>{};

    for (final c in candidates) {
      final canon = _normalizeStopId(c.stopId);
      if (canon != null) ids.add(canon);

      for (final s in c.upcomingStops) {
        ids.add(s.stopIdCanon);
        if (ids.length >= 20) break;
      }
      if (ids.length >= 20) break;
    }

    if (ids.isEmpty) return;
    await _transportService.warmStopNamesForCandidates(candidates);

    if (mounted) setState(() {});
  }

  String _stopLabel(String rawStopId) {
    return _transportService.stopLabel(rawStopId);
  }

  List<TripCandidate> _dedupeCandidatesViaService(List<TripCandidate> input) {
    return MatchingService.dedupeCandidates(
      input,
      normalizeStopId: _normalizeStopId,
      trace: _trace,
      directionKeyFor: _directionKey,
      terminalLabelFor: _terminalLabel,
    );
  }

  String _terminalLabel(TripCandidate c) {
    return MatchingService.terminalLabelFor(
      c,
      stopLabel: _stopLabel,
      normalizeStopId: _normalizeStopId,
    );
  }

  String _directionKey(TripCandidate c) {
    return MatchingService.directionKeyFor(
      c,
      normalizeStopId: _normalizeStopId,
    );
  }

  Widget _buildLoadMoreFooter({
    required _PullUpFooterState state,
    required String idleText,
    required String loadingText,
    required String exhaustedText,
    VoidCallback? onTap,
  }) {
    final baseStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Colors.grey.shade600,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.1,
    );

    Widget child;
    switch (state) {
      case _PullUpFooterState.idle:
        child = Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.expand_more,
              size: 16,
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.85),
            ),
            const SizedBox(width: 6),
            Text(
              idleText,
              style: baseStyle?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        );
        break;
      case _PullUpFooterState.loading:
        child = Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 8),
            Text(loadingText, style: baseStyle),
          ],
        );
        break;
      case _PullUpFooterState.exhausted:
        child = Text(
          exhaustedText,
          style: baseStyle,
          textAlign: TextAlign.center,
        );
        break;
    }

    final footer = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      alignment: Alignment.center,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeOutCubic,
        child: KeyedSubtree(
          key: ValueKey<_PullUpFooterState>(state),
          child: child,
        ),
      ),
    );
    if (onTap == null || state != _PullUpFooterState.idle) return footer;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: footer),
    );
  }

  Future<String?> _pickDirectionBottomSheet(
    List<TripCandidate> candidates,
  ) async {
    final Map<String, List<TripCandidate>> groups = {};
    for (final c in candidates) {
      final key = _directionKey(c);
      groups.putIfAbsent(key, () => <TripCandidate>[]).add(c);
    }
    _traceDirectionBuckets('Direction-grouping', groups);
    // Warm station names for digit direction keys (GTFS stop_ids) so we show names instead of raw codes.
    final digitKeys = groups.keys
        .where((k) => RegExp(r'^\\d+$').hasMatch(k))
        .toSet();
    if (digitKeys.isNotEmpty) {
      await Future.wait(digitKeys.map(_ensureStopName));
      if (!mounted) return 'unknown';
    }

    final options = groups.entries
        .where((e) => e.key != 'unknown' && e.key.isNotEmpty)
        .map((e) {
          final list = [...e.value]
            ..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
          final first = list.first;
          return (key: e.key, label: _terminalLabel(first), allItems: list);
        })
        .toList();

    if (options.isEmpty) return 'unknown';
    final initialWindowHours = _upcomingWindowHours.clamp(
      2,
      _maxPickerHorizonHours,
    );
    final anchor = DateTime.now();

    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        var loadedHours = initialWindowHours;
        List<({String key, String label, DateTime nextEta, int visibleCount})>
        visibleDirectionsForHours(int hours) {
          final end = anchor.add(Duration(hours: hours));
          final out =
              <
                ({String key, String label, DateTime nextEta, int visibleCount})
              >[];
          for (final o in options) {
            final vis = o.allItems
                .where((c) => !c.etaLocal.isAfter(end))
                .toList();
            if (vis.isEmpty) continue;
            vis.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
            out.add((
              key: o.key,
              label: o.label,
              nextEta: vis.first.etaLocal,
              visibleCount: vis.length,
            ));
          }
          out.sort((a, b) => a.nextEta.compareTo(b.nextEta));
          return out;
        }

        var visibleOptions = visibleDirectionsForHours(loadedHours);
        _trace(
          'Picker directions windowEnd=${anchor.add(Duration(hours: loadedHours)).toIso8601String()} '
          'totalDirections=${options.length} visibleDirections=${visibleOptions.length} '
          'visibleConnections=${visibleOptions.fold<int>(0, (s, o) => s + o.visibleCount)}',
        );
        var footerState = loadedHours >= _maxPickerHorizonHours
            ? _PullUpFooterState.exhausted
            : _PullUpFooterState.idle;

        return StatefulBuilder(
          builder: (ctx, setModalState) {
            Future<void> loadMore() async {
              if (loadedHours >= _maxPickerHorizonHours) {
                setModalState(() {
                  footerState = _PullUpFooterState.exhausted;
                });
                _trace('Picker directions exhausted reached (max horizon)');
                return;
              }
              setModalState(() => footerState = _PullUpFooterState.loading);

              var nextHours = loadedHours;
              final oldVisible = visibleOptions;
              var nextVisible = oldVisible;

              while (nextHours < _maxPickerHorizonHours) {
                nextHours += initialWindowHours;
                if (nextHours > _maxPickerHorizonHours) {
                  nextHours = _maxPickerHorizonHours;
                }
                nextVisible = visibleDirectionsForHours(nextHours);
                final oldConn = oldVisible.fold<int>(
                  0,
                  (s, o) => s + o.visibleCount,
                );
                final newConn = nextVisible.fold<int>(
                  0,
                  (s, o) => s + o.visibleCount,
                );
                if (newConn > oldConn) break;
                if (nextHours >= _maxPickerHorizonHours) break;
              }

              setModalState(() {
                loadedHours = nextHours;
                visibleOptions = nextVisible;
                footerState = loadedHours >= _maxPickerHorizonHours
                    ? _PullUpFooterState.exhausted
                    : _PullUpFooterState.idle;
              });
              _trace(
                'Picker directions loadMore windowEnd=${anchor.add(Duration(hours: loadedHours)).toIso8601String()} '
                'appendedVisible=${visibleOptions.fold<int>(0, (s, o) => s + o.visibleCount) - oldVisible.fold<int>(0, (s, o) => s + o.visibleCount)} '
                'visibleDirections=${visibleOptions.length}',
              );
            }

            return SafeArea(
              child: ListView.separated(
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: visibleOptions.length + 1,
                separatorBuilder: (_, i) => i >= visibleOptions.length - 1
                    ? const SizedBox.shrink()
                    : const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  if (i == visibleOptions.length) {
                    return _buildLoadMoreFooter(
                      state: footerState,
                      idleText: 'Show later directions',
                      loadingText: 'Loading later directions...',
                      exhaustedText:
                          'No more directions in the next $_maxPickerHorizonHours hours',
                      onTap: () {
                        _trace('Picker directions footer tapped');
                        loadMore();
                      },
                    );
                  }
                  final o = visibleOptions[i];
                  final mins = o.nextEta.difference(DateTime.now()).inMinutes;
                  return ListTile(
                    title: Text('→ ${o.label}'),
                    subtitle: Text(
                      'Next in ${mins}m • ${_hhmm(o.nextEta)} • ${o.visibleCount} upcoming',
                    ),
                    onTap: () => Navigator.of(ctx).pop(o.key),
                  );
                },
              ),
            );
          },
        );
      },
    );

    return picked;
  }

  Future<TripCandidate?> _pickTripInDirectionBottomSheet({
    required List<TripCandidate> candidates,
  }) async {
    final list = [...candidates]
      ..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    final initialWindowHours = _upcomingWindowHours.clamp(
      2,
      _maxPickerHorizonHours,
    );
    final anchor = DateTime.now();
    for (final c in list.take(12)) {
      _trace(
        'Trip-picker candidate eta=${c.etaLocal.toIso8601String()} '
        'displayTrain="${c.displayTrain}" terminal="${_terminalLabel(c)}" tripId=${c.tripId}',
      );
    }
    if (list.length > 12) {
      _trace('Trip-picker candidates truncated=${list.length - 12}');
    }

    final picked = await showModalBottomSheet<TripCandidate>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        var loadedHours = initialWindowHours;
        List<TripCandidate> visibleConnectionsForHours(int hours) {
          final end = anchor.add(Duration(hours: hours));
          return list.where((c) => !c.etaLocal.isAfter(end)).toList()
            ..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
        }

        var visibleConnections = visibleConnectionsForHours(loadedHours);
        _trace(
          'Picker connections windowEnd=${anchor.add(Duration(hours: loadedHours)).toIso8601String()} '
          'totalConnections=${list.length} visibleConnections=${visibleConnections.length}',
        );
        var footerState = loadedHours >= _maxPickerHorizonHours
            ? _PullUpFooterState.exhausted
            : _PullUpFooterState.idle;

        return StatefulBuilder(
          builder: (ctx, setModalState) {
            Future<void> loadMore() async {
              if (loadedHours >= _maxPickerHorizonHours) {
                setModalState(() {
                  footerState = _PullUpFooterState.exhausted;
                });
                _trace('Picker connections exhausted reached (max horizon)');
                return;
              }
              setModalState(() => footerState = _PullUpFooterState.loading);

              var nextHours = loadedHours;
              final oldVisible = visibleConnections;
              var nextVisible = oldVisible;
              while (nextHours < _maxPickerHorizonHours) {
                nextHours += initialWindowHours;
                if (nextHours > _maxPickerHorizonHours) {
                  nextHours = _maxPickerHorizonHours;
                }
                nextVisible = visibleConnectionsForHours(nextHours);
                if (nextVisible.length > oldVisible.length) break;
                if (nextHours >= _maxPickerHorizonHours) break;
              }

              setModalState(() {
                loadedHours = nextHours;
                visibleConnections = nextVisible;
                footerState = loadedHours >= _maxPickerHorizonHours
                    ? _PullUpFooterState.exhausted
                    : _PullUpFooterState.idle;
              });
              _trace(
                'Picker connections loadMore windowEnd=${anchor.add(Duration(hours: loadedHours)).toIso8601String()} '
                'nextBlockAppended=${visibleConnections.length - oldVisible.length} visibleConnections=${visibleConnections.length}',
              );
              if (loadedHours >= _maxPickerHorizonHours) {
                _trace('Picker connections exhausted reached after load');
              }
            }

            return SafeArea(
              child: ListView.separated(
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: visibleConnections.length + 1,
                separatorBuilder: (_, i) => i >= visibleConnections.length - 1
                    ? const SizedBox.shrink()
                    : const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  if (i == visibleConnections.length) {
                    return _buildLoadMoreFooter(
                      state: footerState,
                      idleText: 'Show more',
                      loadingText: 'Loading more...',
                      exhaustedText:
                          'No more connections in the next $_maxPickerHorizonHours hours',
                      onTap: () {
                        _trace('Picker connections footer tapped');
                        _trace(
                          'Picker connections load triggered source=footer-tap',
                        );
                        loadMore();
                      },
                    );
                  }
                  final c = visibleConnections[i];
                  final mins = c.etaLocal.difference(DateTime.now()).inMinutes;
                  return ListTile(
                    title: Text('${_hhmm(c.etaLocal)} (in ${mins}m)'),
                    subtitle: Text(
                      '${c.displayTrain} → ${_terminalLabel(c)} • ${_fmtDelay(c.delaySeconds)}',
                    ),
                    onTap: () => Navigator.of(ctx).pop(c),
                  );
                },
              ),
            );
          },
        );
      },
    );

    return picked;
  }

  @override
  void dispose() {
    _sliderDebounce?.cancel();
    _sliderDebounce = null;

    _liveUpdateTimer?.cancel();
    _liveUpdateTimer = null;

    _foregroundArmTimer?.cancel();
    _foregroundArmTimer = null;

    _ringTimer?.cancel();
    _ringTimer = null;

    _selfTestStopper?.cancel();
    _selfTestStopper = null;

    _selfTestHapticTimer?.cancel();
    _selfTestHapticTimer = null;

    _sleepOverlayTimer?.cancel();
    _sleepOverlayTimer = null;

    _trainController.dispose();
    _stationController.dispose();
    super.dispose();
  }

  Future<void> _startTracking() async {
    if (_isStartingTracking) return;

    final trainQuery = _trainController.text.trim();
    final destQuery = _stationController.text.trim();
    final destWasName = !RegExp(r'^\d+$').hasMatch(destQuery);
    if (destQuery.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a destination.')),
      );
      return;
    }
    // Removed _testFeed() nested function.
    setState(() {
      _isStartingTracking = true;
      _trackingStatus = 'Searching matching trip…';
      _selectedCandidate = null;
    });
    _trace(
      '_startTracking begin trainQuery="$trainQuery" destinationQuery="$destQuery" destWasName=$destWasName',
    );

    try {
      // Resolve destination: GTFS-RT uses numeric stop_id (e.g., 8503000). If user typed a station name,
      // resolve it to a stop_id first (temporary). Later we’ll replace this with GTFS-SA local mapping.
      String effectiveDest = destQuery;
      List<String> destAlternatives = [destQuery];
      if (!RegExp(r'^\d+$').hasMatch(destQuery)) {
        if (!mounted) return;
        setState(() {
          _trackingStatus = 'Resolving destination “$destQuery” to stop_id…';
        });

        final resolvedIds = await _resolveStopIdsFromName(destQuery);
        if (!mounted) return;
        _trace(
          '_startTracking destination resolvedIds for "$destQuery": '
          '${resolvedIds.isEmpty ? '(none)' : resolvedIds.join(', ')}',
        );

        if (resolvedIds.isEmpty) {
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

        // Keep *all* possible stop_ids for this station name.
        // Many stations have multiple IDs (platform vs parent station). GTFS-RT may use any of them.
        destAlternatives = resolvedIds;

        // Try to find a strict match for THIS train against ANY of the resolved stop_ids.
        // (this will only be used if trainQuery is NOT empty and we continue to GTFS-RT logic)
        // NOTE: moved feed fetch below for GTFS-RT branch.
        // We'll only use this if trainQuery is not empty.
        // So, only fetch feed if needed below.
        // (No code here.)
        // Pick a representative stop_id (for display + later fallbacks), but keep the list for matching.
        // Prefer one that appears in strict matches; otherwise fall back to the top-scored resolved id.
        String picked = destAlternatives.first;
        effectiveDest = picked;

        final nice = _stopLabel(effectiveDest);
        setState(() {
          _trackingStatus =
              'Destination resolved: “$destQuery” → $nice (alt stop_ids: ${destAlternatives.take(3).join(', ')}${destAlternatives.length > 3 ? ', …' : ''})';
        });
      }
      _trace(
        '_startTracking destination effectiveDest=$effectiveDest resolvedStopIds=${destAlternatives.join(",")}',
      );

      // If the user did NOT enter a train/line, avoid scanning GTFS-RT (huge stations can produce lots of entities).
      // Instead, use stationboard arrivals immediately. This is also nicer because it yields human direction labels.
      if (trainQuery.trim().isEmpty) {
        final destCanon = _normalizeStopId(effectiveDest) ?? effectiveDest;

        setState(() {
          _trackingStatus =
              'Checking upcoming arrivals at ${_stopLabel(destCanon)}…';
        });

        final arrivalCandidates = await _fallbackArrivalsAtDestination(
          trainQuery: '',
          destStopIdCanons: destWasName
              ? destAlternatives
              : <String>[destCanon],
          destNameQuery: destWasName ? destQuery : null,
          limit: 100,
          resolveDestinationName: false,
        );

        if (!mounted) return;

        if (arrivalCandidates.isEmpty) {
          setState(() {
            _trackingStatus =
                'No upcoming arrivals found. Try again in a moment or enter a specific line (e.g., “IC5”, “S2”).';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No upcoming arrivals found.'),
              duration: Duration(seconds: 4),
            ),
          );
          return;
        }

        // Treat this as a destination-arrivals based selection.
        var candidates = _dedupeCandidatesViaService(arrivalCandidates);
        candidates = _dropPastCandidates(
          candidates,
          stage: 'No-train fallback pool',
        );
        if (candidates.isEmpty) {
          setState(() {
            _trackingStatus =
                'No upcoming arrivals found (stale candidates removed).';
          });
          return;
        }
        _traceCandidatePool(
          'Final-selection pool',
          candidates,
          source: 'fallback-arrivals-no-train',
        );

        // Names for the destination itself are already warmed inside the fallback.
        // Keep status short.
        setState(() {
          _trackingStatus =
              'Showing upcoming arrivals at ${_stopLabel(destCanon)} — pick direction & time.';
        });

        // Continue with direction/trip picking logic (shared below).
        // Warm cache for nicer labels.
        await _warmStopNamesForCandidates(candidates);

        final terminalIds = <String>{};
        for (final c in candidates) {
          final canon = c.terminalStopIdCanon.trim();
          if (canon.isNotEmpty) terminalIds.add(canon);
          if (terminalIds.length >= 12) break;
        }
        await Future.wait(terminalIds.map(_ensureStopName));

        final Map<String, List<TripCandidate>> byDir = {};
        for (final c in candidates) {
          final key = _directionKey(c);
          byDir.putIfAbsent(key, () => <TripCandidate>[]).add(c);
        }
        _traceDirectionBuckets(
          'Direction-grouping startTracking-noTrain',
          byDir,
        );

        final dirKeys = byDir.keys
            .where((k) => k != 'unknown' && k.isNotEmpty)
            .toList();

        String? chosenDir = 'unknown';
        if (dirKeys.length > 1) {
          chosenDir = await _pickDirectionBottomSheet(candidates);
          if (chosenDir == null) {
            _cancelTrackingSelection('no-train-direction-picker');
            return;
          }
        } else if (dirKeys.length == 1) {
          chosenDir = dirKeys.first;
        }

        var dirCandidates = candidates;
        if (chosenDir != 'unknown' && byDir.containsKey(chosenDir)) {
          dirCandidates = [...byDir[chosenDir]!];
        } else {
          dirCandidates = [...candidates];
        }
        dirCandidates = _dropPastCandidates(
          dirCandidates,
          stage: 'No-train direction pool',
        );
        if (dirCandidates.isEmpty) {
          setState(() {
            _trackingStatus = 'No upcoming trips left in this direction.';
          });
          return;
        }
        _traceCandidatePool(
          'Final-selection direction pool',
          dirCandidates.take(_pickerTakePerDirection()).toList(),
          source: 'fallback-arrivals-no-train',
        );

        late final TripCandidate chosen;
        if (dirCandidates.length == 1) {
          chosen = dirCandidates.first;
        } else {
          final picked = await _pickTripInDirectionBottomSheet(
            candidates: dirCandidates,
          );
          if (picked == null) {
            _cancelTrackingSelection('no-train-trip-picker');
            return;
          }
          chosen = picked;
        }
        _traceCandidate(
          'Final-selection chosen',
          chosen,
          source: 'fallback-arrivals-no-train',
        );
        _trace('Final-selection reason=fallback-arrivals-no-train');

        if (!mounted) return;

        // No strict match in this flow, so let the user pick destination stop if not matched.
        // But arrivals fallback always marks destinationMatched true.
        // If not, could add logic here.

        final minsLeft = chosen.etaLocal.difference(DateTime.now()).inMinutes;
        final niceStop = _stopLabel(chosen.stopId);

        setState(() {
          _selectedCandidate = chosen;
          _trackingStatus =
              'Selected ${chosen.displayTrain} → $niceStop • ETA ${_hhmm(chosen.etaLocal)} (in ${minsLeft}m) • ${_fmtDelay(chosen.delaySeconds)}'
              '\n(Fallback: destination arrivals)';
        });
        _traceCandidate(
          'selectedCandidate assigned',
          chosen,
          source: 'fallback-arrivals-no-train',
        );

        await _armAlarmFor(chosen, showUx: false);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tracking set (foreground prototype).')),
        );
        return;
      } else {
        // trainQuery is NOT empty: use GTFS-RT logic as before.
        final scenarioTag =
            'scenario trainQuery="${_normalizeTrainToken(trainQuery)}" destinationQuery="${destQuery.trim().toLowerCase()}"';
        _trace('Pipeline enter $scenarioTag');
        final feed = await _fetchGtfsRtFeed();

        // Strict destination match: if the destination was entered by *name*, we may have multiple
        // possible stop_ids. Try all of them and merge.
        var candidates = <TripCandidate>[];

        if (destWasName) {
          final idsToTry = destAlternatives;

          for (final id
              in idsToTry.isEmpty ? <String>[effectiveDest] : idsToTry) {
            candidates.addAll(
              _findCandidates(
                feed,
                trainQuery,
                id,
                requireDestinationMatch: true,
              ),
            );
          }
          candidates = _dedupeCandidatesViaService(candidates);
        } else {
          candidates = _findCandidates(
            feed,
            trainQuery,
            effectiveDest,
            requireDestinationMatch: true,
          );
        }
        _traceStageCandidates('GTFS strict leave $scenarioTag', candidates);
        _traceCandidatePool(
          'GTFS-RT candidate pool',
          candidates,
          source: 'gtfs-rt-strict',
        );

        // Warm station name cache for the destination itself (nice labels).
        final destCanonWarm = _normalizeStopId(effectiveDest) ?? effectiveDest;
        await _ensureStopName(destCanonWarm);

        bool usedArrivalsFallback = false;
        bool usedGtfsBridge = false;
        final hadStrictMatch = candidates.isNotEmpty;
        var candidateSource = hadStrictMatch ? 'gtfs-rt-strict' : 'none';
        var trainFallbackBroadCount = 0;
        var trainFallbackFilteredCount = 0;
        var trainFallbackStaleRemoved = 0;
        var trainFallbackFinalCount = 0;
        var trainFallbackAttempted = false;

        final isLocalLineQuery =
            MatchingService.gtfsBridgeDecisionReason(trainQuery) ==
            'local-s-line';

        // A destination-aware name rescue is more trustworthy than broad
        // train-only GTFS results and must run before either broad fallback.
        if (candidates.isEmpty && destWasName) {
          final nameMatched = await _findCandidatesByTrainAndDestinationName(
            feed,
            trainQuery,
            destQuery,
          );

          if (!mounted) return;
          if (nameMatched.isNotEmpty) {
            candidates = nameMatched;
            candidateSource = 'gtfs-stop-name-rescue';
            _traceCandidatePool(
              'GTFS-name-match candidate pool',
              candidates,
              source: candidateSource,
            );
            setState(() {
              _trackingStatus =
                  'Destination matched by name: “$destQuery” (from train stops) — pick the right trip if needed.';
            });
          }
        }

        // If GTFS-RT did not find a strict match, prefer stationboard (arrivals) as the next step.
        // This produces much nicer direction labels ("to") and often has better coverage.
        if (candidates.isEmpty) {
          final destCanon = _normalizeStopId(effectiveDest) ?? effectiveDest;
          final resolvedForFallback = destWasName
              ? destAlternatives
              : <String>[destCanon];
          final queryNorm = _normalizeTrainToken(trainQuery);
          _trace(
            'Train query fallback-first mode query="$trainQuery" queryNorm="$queryNorm" '
            'resolvedStopIds=${resolvedForFallback.join(",")} strictGtfsCount=${candidates.length}',
          );

          setState(() {
            _trackingStatus =
                'No GTFS-RT match yet. Checking upcoming arrivals at ${_stopLabel(destCanon)}…';
          });

          final broadArrivalCandidates = await _fallbackArrivalsAtDestination(
            trainQuery: '',
            destStopIdCanons: resolvedForFallback,
            destNameQuery: destWasName ? destQuery : null,
            limit: 220,
            resolveDestinationName: false,
          );

          if (!mounted) return;
          _traceStageCandidates(
            'Fallback broad leave $scenarioTag',
            broadArrivalCandidates,
          );
          if (broadArrivalCandidates.isNotEmpty) {
            final sortedBroad = [...broadArrivalCandidates]
              ..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
            _trace(
              'Train-specific fallback broad minEta=${sortedBroad.first.etaLocal.toIso8601String()} '
              'maxEta=${sortedBroad.last.etaLocal.toIso8601String()}',
            );
          } else {
            _trace('Train-specific fallback broad minEta=none maxEta=none');
          }

          _trace(
            'Train-specific fallback broad pool count=${broadArrivalCandidates.length} queryNorm="$queryNorm"',
          );
          trainFallbackAttempted = true;
          trainFallbackBroadCount = broadArrivalCandidates.length;
          if (broadArrivalCandidates.isEmpty) {
            _trace(
              'Train-specific fallback no-match reason=broad_pool_empty queryNorm="$queryNorm"',
            );
          }

          final postFallback = _runTrainQueryFallbackPostPipeline(
            scenarioTag: scenarioTag,
            trainQueryNorm: queryNorm,
            broadArrivalCandidates: broadArrivalCandidates,
          );
          trainFallbackFilteredCount = postFallback.filtered.length;
          trainFallbackStaleRemoved =
              postFallback.filtered.length - postFallback.fresh.length;
          trainFallbackFinalCount = postFallback.deduped.length;

          if (postFallback.filtered.isEmpty) {
            _trace(
              'Train-specific fallback no public-label match queryNorm="$queryNorm"',
            );
            _trace(
              'Train-specific fallback no-match reason=filtered_pool_empty queryNorm="$queryNorm"',
            );
          }

          if (postFallback.fresh.isEmpty && postFallback.filtered.isNotEmpty) {
            _trace(
              'Train-specific fallback no-match reason=all_filtered_removed_as_stale queryNorm="$queryNorm"',
            );
          }
          if (postFallback.deduped.isEmpty && postFallback.fresh.isNotEmpty) {
            _trace(
              'Train-specific fallback no-match reason=all_removed_by_dedupe queryNorm="$queryNorm"',
            );
          }

          if (postFallback.deduped.isNotEmpty) {
            _trace(
              'Train-specific fallback final pool count=${postFallback.deduped.length}',
            );
            for (final c in postFallback.deduped) {
              _trace(
                'Train-specific final fallback candidate displayTrain="${c.displayTrain}" '
                'eta=${c.etaLocal.toIso8601String()} terminal="${_terminalLabel(c)}" tripId=${c.tripId}',
              );
            }

            candidates = postFallback.deduped;
            usedArrivalsFallback = true;
            candidateSource = 'fallback-arrivals-train-filtered';

            final bridgeReason = MatchingService.gtfsBridgeDecisionReason(
              trainQuery,
            );
            final bridgeEnabled =
                MatchingService.shouldUseGtfsBridgeForQueryWithLocalGuard(
                  trainQuery,
                );
            _trace(
              'GTFS bridge enabled queryNorm="$queryNorm" strictPoolEmpty=true fallbackCount=${postFallback.deduped.length} enabled=$bridgeEnabled reason=$bridgeReason',
            );
            if (!bridgeEnabled && bridgeReason == 'local-s-line') {
              _trace(
                'GTFS bridge skipped for local-line queryNorm="$queryNorm"',
              );
            }

            if (bridgeEnabled) {
              final bridgedPool = <TripCandidate>[];
              var bridgedCount = 0;
              for (final fb in postFallback.deduped) {
                final bridged = _bridgeFallbackCandidateToGtfs(
                  fallbackCandidate: fb,
                  feed: feed,
                  destStopCanon: destCanon,
                );
                if (bridged != null) {
                  bridgedPool.add(bridged);
                  bridgedCount++;
                } else {
                  bridgedPool.add(fb);
                }
              }
              _trace(
                'Train-specific fallback bridge enriched count=$bridgedCount total=${bridgedPool.length}',
              );
              if (bridgedCount > 0) {
                usedGtfsBridge = true;
                candidateSource = 'gtfs-bridge-from-fallback';
                candidates = _dedupeCandidatesViaService(bridgedPool);
                _traceCandidatePool(
                  'GTFS bridge candidate pool',
                  candidates,
                  source: 'gtfs-bridge-from-fallback',
                );
              }
            }
            _trace(
              'Train query fallback-first final selection pool count=${candidates.length} '
              'source=${usedGtfsBridge ? "gtfs-bridge" : "fallback"}',
            );
            _traceStageCandidates(
              'Selection input leave $scenarioTag',
              candidates,
            );

            await _warmStopNamesForCandidates(candidates);
            _traceCandidatePool(
              'Fallback arrivals candidate pool',
              candidates,
              source: usedGtfsBridge
                  ? 'gtfs-bridge-from-fallback'
                  : 'fallback-arrivals-train-filtered',
            );

            setState(() {
              _trackingStatus =
                  'Showing upcoming arrivals at ${_stopLabel(destCanon)} — pick direction & time.';
            });
          }
        }

        // True last resort: keep train matching but allow an unverified
        // destination. Candidate-specific confirmation remains mandatory below.
        if (candidates.isEmpty) {
          candidates = _findCandidates(
            feed,
            trainQuery,
            effectiveDest,
            requireDestinationMatch: false,
          );
          if (candidates.isNotEmpty) {
            candidateSource = 'gtfs-train-only-unverified';
            _traceCandidatePool(
              'GTFS broad train-only candidate pool',
              candidates,
              source: candidateSource,
            );
            setState(() {
              _trackingStatus =
                  'Only train matches were found. Destination confirmation will be required before tracking starts.';
            });
          }
        }

        final hasGtfsDirectionSource =
            candidateSource == 'gtfs-rt-strict' ||
            candidateSource == 'gtfs-stop-name-rescue' ||
            candidateSource == 'gtfs-train-only-unverified';
        if (candidates.isNotEmpty &&
            isLocalLineQuery &&
            hasGtfsDirectionSource) {
          final directionSource = candidateSource;
          final destCanon = _normalizeStopId(effectiveDest) ?? effectiveDest;
          final localDirectionCandidates = await _fallbackArrivalsAtDestination(
            trainQuery: trainQuery,
            destStopIdCanons: destWasName
                ? destAlternatives
                : <String>[destCanon],
            destNameQuery: destWasName ? destQuery : null,
            limit: 220,
            resolveDestinationName: false,
          );
          if (!mounted) return;

          final enrichment = enrichLocalLineDirections(
            gtfsCandidates: candidates,
            stationboardCandidates: localDirectionCandidates,
            trainQuery: trainQuery,
            stopIdsMatch: _stopIdMatches,
            directionLabel: _terminalLabel,
          );
          candidates = enrichment.candidates;
          if (enrichment.enrichedCount > 0) {
            candidateSource = '$directionSource-local-direction-enriched';
          }
          _trace(
            'Local-line direction enrichment source=$directionSource '
            'gtfsCount=${candidates.length} '
            'stationboardCount=${localDirectionCandidates.length} '
            'enrichedCount=${enrichment.enrichedCount}',
          );
          for (final decision in enrichment.decisions.take(12)) {
            final counterpart = decision.counterpart;
            _trace(
              'Local-line direction decision gtfsTripId=${decision.original.tripId} '
              'gtfsEta=${decision.original.etaLocal.toIso8601String()} '
              'gtfsDirection="${_terminalLabel(decision.original)}" '
              'stationboardTripId=${counterpart?.tripId ?? "none"} '
              'stationboardEta=${counterpart?.etaLocal.toIso8601String() ?? "none"} '
              'stationboardDirection="${counterpart == null ? "" : _terminalLabel(counterpart)}" '
              'etaDiffSec=${decision.etaDifferenceSeconds ?? -1} '
              'result=${decision.reason} '
              'finalDirection="${_terminalLabel(decision.result)}"',
            );
          }
          if (enrichment.decisions.length > 12) {
            _trace(
              'Local-line direction decisions truncated=${enrichment.decisions.length - 12}',
            );
          }
        }

        if (candidates.isNotEmpty) {
          final beforeOjp = candidates;
          candidates = await _transportService.enrichPublicDirections(
            candidates,
          );
          if (!mounted) return;
          final ojpEnriched = candidates
              .where(
                (candidate) =>
                    candidate.directionSource == DirectionSource.ojpStopEvent,
              )
              .length;
          if (ojpEnriched > 0) {
            candidateSource = '$candidateSource-ojp-direction';
          }
          _trace(
            'OJP public-direction enrichment input=${beforeOjp.length} '
            'output=${candidates.length} trusted=$ojpEnriched',
          );
        }

        // This branch is retained for compatibility if the surrounding flow is
        // later reused without a train query.
        if (candidates.isEmpty && trainQuery.trim().isEmpty) {
          candidates = _findCandidates(
            feed,
            '',
            effectiveDest,
            requireDestinationMatch: true,
          );
        }

        if (!mounted) return;

        if (candidates.isEmpty) {
          final destCanon = _normalizeStopId(effectiveDest) ?? effectiveDest;

          // If the user entered a train query, do NOT show all arrivals as fallback.
          if (trainQuery.trim().isNotEmpty) {
            _trace(
              'No matching trip found reason=train-path-empty queryNorm="${_normalizeTrainToken(trainQuery)}" '
              'strictMatch=$hadStrictMatch trainFallbackAttempted=$trainFallbackAttempted '
              'trainFallbackBroadCount=$trainFallbackBroadCount trainFallbackFilteredCount=$trainFallbackFilteredCount '
              'trainFallbackStaleRemoved=$trainFallbackStaleRemoved trainFallbackFinalCount=$trainFallbackFinalCount',
            );
            _trace('Pipeline abort $scenarioTag stage=no-match');
            setState(() {
              _trackingStatus =
                  'No matching trip found (yet). Double-check the line/train name (e.g., “S3” not “S33”) or leave it empty to see all departures.';
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('No matching trip found (yet).'),
                duration: Duration(seconds: 4),
              ),
            );
            return;
          }

          // As a final attempt, try stationboard without filtering (sometimes route ids are weird).
          final arrivalCandidates = await _fallbackArrivalsAtDestination(
            trainQuery: '',
            destStopIdCanons: destWasName
                ? destAlternatives
                : <String>[destCanon],
            destNameQuery: destWasName ? destQuery : null,
            limit: 100,
            resolveDestinationName: false,
          );

          if (!mounted) return;

          if (arrivalCandidates.isEmpty) {
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

          usedArrivalsFallback = true;
          candidateSource = 'fallback-arrivals-unfiltered';
          candidates = _dedupeCandidatesViaService(arrivalCandidates);
          await _warmStopNamesForCandidates(candidates);
          _traceCandidatePool(
            'Fallback arrivals candidate pool',
            candidates,
            source: 'fallback-arrivals-unfiltered',
          );

          setState(() {
            _trackingStatus =
                'Showing upcoming arrivals at ${_stopLabel(destCanon)} — pick direction & time.';
          });
        } else {
          // Warm cache for nicer labels when we used GTFS candidates.
          await _warmStopNamesForCandidates(candidates);
        }

        final terminalIds = <String>{};
        for (final c in candidates) {
          final canon = c.terminalStopIdCanon.trim();
          if (canon.isNotEmpty) terminalIds.add(canon);
          if (terminalIds.length >= 12) break;
        }
        await Future.wait(terminalIds.map(_ensureStopName));

        _trace(
          'Search candidate source selected=$candidateSource count=${candidates.length}',
        );

        final Map<String, List<TripCandidate>> byDir = {};
        for (final c in candidates) {
          final key = _directionKey(c);
          byDir.putIfAbsent(key, () => <TripCandidate>[]).add(c);
        }
        _traceDirectionBuckets('Direction-grouping startTracking-train', byDir);

        final dirKeys = byDir.keys
            .where((k) => k != 'unknown' && k.isNotEmpty)
            .toList();

        String? chosenDir = 'unknown';
        if (dirKeys.length > 1) {
          chosenDir = await _pickDirectionBottomSheet(candidates);
          if (chosenDir == null) {
            _cancelTrackingSelection('train-direction-picker');
            return;
          }
        } else if (dirKeys.length == 1) {
          chosenDir = dirKeys.first;
        }

        var dirCandidates = candidates;
        if (chosenDir != 'unknown' && byDir.containsKey(chosenDir)) {
          dirCandidates = [...byDir[chosenDir]!];
        } else {
          dirCandidates = [...candidates];
        }
        dirCandidates = _dropPastCandidates(
          dirCandidates,
          stage: 'Train-path direction pool',
        );
        _traceStageCandidates(
          'Direction pool leave $scenarioTag',
          dirCandidates,
        );
        if (dirCandidates.isEmpty) {
          setState(() {
            _trackingStatus = 'No upcoming trips left in this direction.';
          });
          _trace('Pipeline abort $scenarioTag stage=direction-empty');
          return;
        }
        _traceCandidatePool(
          'Final-selection pool',
          candidates,
          source: candidateSource,
        );
        _traceCandidatePool(
          'Final-selection direction pool',
          dirCandidates.take(_pickerTakePerDirection()).toList(),
          source: candidateSource,
        );

        late TripCandidate chosen;
        if (dirCandidates.length == 1) {
          chosen = dirCandidates.first;
        } else {
          final picked = await _pickTripInDirectionBottomSheet(
            candidates: dirCandidates,
          );
          if (picked == null) {
            _cancelTrackingSelection('train-trip-picker');
            return;
          }
          chosen = picked;
        }
        _traceCandidate(
          'Final-selection chosen',
          chosen,
          source: candidateSource,
        );
        _trace('Final-selection reason=$candidateSource');
        _trace('Pipeline leave $scenarioTag chosenTripId=${chosen.tripId}');

        if (!mounted) return;

        // If destination wasn't matched during fallback search, let the user pick a stop from upcoming stops.
        if (candidateNeedsDestinationConfirmation(chosen)) {
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
        final niceStop = _stopLabel(chosen.stopId);

        setState(() {
          _selectedCandidate = chosen;
          _trackingStatus =
              'Selected ${chosen.displayTrain} → $niceStop • ETA ${_hhmm(chosen.etaLocal)} (in ${minsLeft}m) • ${_fmtDelay(chosen.delaySeconds)}'
              '${usedArrivalsFallback ? "\n(Fallback: destination arrivals)" : ""}';
        });
        _traceCandidate(
          'selectedCandidate assigned',
          chosen,
          source: candidateSource,
        );

        await _armAlarmFor(chosen, showUx: false);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tracking set (foreground prototype).')),
        );
        return;
      }
    } catch (error, stackTrace) {
      final stackPreview = stackTrace
          .toString()
          .split('\n')
          .take(8)
          .join(' | ');
      _trace(
        'Start tracking failed errorType=${error.runtimeType} error="$error" '
        'stack="$stackPreview"',
      );
      if (!mounted) return;
      setState(() {
        _trackingStatus = 'Search failed. Check your connection and try again.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Search failed. Please check your connection and retry.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isStartingTracking = false);
      }
    }
  }

  Future<http.Response> _getGtfsRtResponse() async =>
      _transportService.getGtfsRtResponse();

  Future<FeedMessage> _fetchGtfsRtFeed() async =>
      _transportService.fetchGtfsRtFeed();

  Future<List<TripCandidate>> _fallbackArrivalsAtDestination({
    required String trainQuery,
    required List<String> destStopIdCanons,
    String? destNameQuery,
    int limit = 100,
    bool resolveDestinationName = true,
  }) async {
    return _transportService.fallbackArrivalsAtDestination(
      trainQuery: trainQuery,
      destStopIdCanons: destStopIdCanons,
      destNameQuery: destNameQuery,
      limit: limit,
      resolveDestinationName: resolveDestinationName,
    );
  }

  Future<List<String>> _resolveStopIdsFromName(String query) async =>
      _transportService.resolveStopIdsFromName(query);

  String? _normalizeStopId(String raw) =>
      _transportService.normalizeStopId(raw);

  List<TripCandidate> _findCandidates(
    FeedMessage feed,
    String trainQuery,
    String destQuery, {
    required bool requireDestinationMatch,
  }) {
    return _transportService.findCandidates(
      feed,
      trainQuery,
      destQuery,
      requireDestinationMatch: requireDestinationMatch,
    );
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
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
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
                  separatorBuilder: (_, unusedIndex) =>
                      const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final s = sorted[i];
                    final mins = s.etaLocal
                        .difference(DateTime.now())
                        .inMinutes;
                    return ListTile(
                      title: Text(_stopLabel(s.stopIdRaw)),
                      subtitle: Text(
                        'ETA ${_hhmm(s.etaLocal)} (in ${mins}m) • ${_fmtDelay(s.delaySeconds)}',
                      ),
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

  // Backwards-compat: UI calls `_testFeed`.
  Future<void> _testFeed() async => _pingApi();

  Future<void> _pingApi() async {
    if (_isTestingFeed) return;

    final key = dotenv.env['OPENTRANSPORTDATA_API_KEY'];

    // Immediate UI feedback so the user sees the tap worked.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Testing GTFS-RT feed…')));

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
        final shortPreview = preview.length > 140
            ? preview.substring(0, 140)
            : preview;
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'GTFS-RT JSON: $sizeBytes bytes | ${shortPreview.replaceAll('\n', ' ')}',
            ),
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
        final head = res.bodyBytes.take(_upcomingTripsLimit).toList();
        final hex = head
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(' ');
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('GTFS-RT parse failed: $e | head: $hex'),
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
        final dt = DateTime.fromMillisecondsSinceEpoch(
          ts * 1000,
          isUtc: true,
        ).toLocal();
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('GTFS-RT test failed: $e')));
    } finally {
      if (mounted) setState(() => _isTestingFeed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _selectedCandidate;
    final hasAlarm = _alarmCoordinator.confirmed != null;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const SizedBox(width: 48),
                      const Icon(Icons.terrain, size: 44),
                      IconButton(
                        tooltip: 'Settings',
                        onPressed: _openSettings,
                        icon: const Icon(Icons.settings),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  TextField(
                    controller: _trainController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Train / line (optional, e.g., IC8)',
                      prefixIcon: Icon(Icons.train),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),

                  TextField(
                    controller: _stationController,
                    decoration: const InputDecoration(
                      labelText: 'Destination station (e.g., Olten)',
                      prefixIcon: Icon(Icons.place_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),

                  Row(
                    children: [
                      const Text('Alarm before:'),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Slider(
                          value: _minutesBefore,
                          min: 1,
                          max: 15,
                          divisions: 14,
                          onChanged: _onMinutesBeforeChanged,
                        ),
                      ),
                      Text('${_minutesBefore.round()}m'),
                    ],
                  ),

                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: _isStartingTracking ? null : _startTracking,
                    child: Text(
                      _isStartingTracking ? 'Starting…' : 'Start tracking',
                    ),
                  ),

                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _isTestingFeed ? null : _testFeed,
                    child: const Text('Test GTFS-RT feed'),
                  ),

                  const SizedBox(height: 14),
                  // === TREEP: STATUS UI START ===
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Theme.of(context).dividerColor),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Status',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 6),
                        Text(_trackingStatus.isEmpty ? '—' : _trackingStatus),

                        if (c != null) ...[
                          const SizedBox(height: 10),
                          Text('${c.vehicleLabel}: ${c.displayTrain}'),
                          Text('Alarm at: ${_stopLabel(c.stopId)}'),
                          Text('Direction: ${_terminalLabel(c)}'),
                          Text(
                            'Arrives: ${_hhmm(c.etaLocal)} • ${_fmtDelay(c.delaySeconds)}',
                          ),
                        ],

                        if (hasAlarm) ...[
                          const SizedBox(height: 10),
                          Text(
                            'Alarm: armed for ${_hhmm(_alarmFirstFire!)} (repeats until you stop)',
                          ),
                          Text(
                            'Audio alarm: ${Platform.isIOS ? (_nativeAlarmArmed ? "ON" : "OFF (check iOS native)") : "(iOS only)"}',
                          ),
                        ],

                        const SizedBox(height: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.green,
                                      foregroundColor: Colors.white,
                                    ),
                                    onPressed: c == null
                                        ? null
                                        : () => _armAlarmFor(c, showUx: true),
                                    child: const Text('Set alarm'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red,
                                      foregroundColor: Colors.white,
                                    ),
                                    onPressed: hasAlarm ? _stopAlarm : null,
                                    child: const Text('Stop alarm'),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              onPressed: _isSelfTesting
                                  ? null
                                  : _runAlarmSelfTest,
                              icon: const Icon(Icons.volume_up_outlined),
                              label: Text(
                                _isSelfTesting ? 'Testing…' : 'Test alarm (3s)',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // === TREEP: STATUS UI END ===
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _normalizeTrainToken(String s) {
  // Normalize "IC 5" == "IC5" == "ic5".
  return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}
