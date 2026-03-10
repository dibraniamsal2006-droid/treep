//بسم الله الرحمن الرحيم

import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:http/http.dart' as http;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;


import 'package:shared_preferences/shared_preferences.dart';

// === TREEP: Preferences keys ===
const String kPrefsSkipVolumeDialogKey = 'treep_skip_volume_dialog';
const String kPrefsSleepLinesEnabledKey = 'treep_sleep_lines_enabled';
const String kPrefsUpcomingTripsLimitKey = 'treep_upcoming_trips_limit';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  await NotificationService.init();
  runApp(const TreepApp());
}

// === TREEP: ALARM BRIDGE START ===
// iOS loud alarm (best-effort) via native code. Android keeps using notifications for now.
class NativeAlarm {
  static const MethodChannel _ch = MethodChannel('treep/alarm');

  /// Arm a loud alarm that will start at [fireAtLocal] (local time).
  /// Returns true if the native side accepted the request.
  static Future<bool> armAt(DateTime fireAtLocal) async {
    final seconds = fireAtLocal.difference(DateTime.now()).inMilliseconds / 1000.0;
    final secs = seconds.isFinite ? seconds : 0.0;
    try {
      final ok = await _ch.invokeMethod<dynamic>('arm', <String, dynamic>{
        'secondsFromNow': secs < 0 ? 0.0 : secs,
        'loop': true,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  /// Start the loud alarm immediately (foreground fallback).
  static Future<void> startNow() async {
    try {
      await _ch.invokeMethod<dynamic>('startNow', <String, dynamic>{'loop': true});
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _ch.invokeMethod<dynamic>('stop');
    } catch (_) {}
  }
}
// === TREEP: ALARM BRIDGE END ===
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  static Future<void> init() async {
    if (_inited) return;

    tz.initializeTimeZones();
    try {
      // flutter_timezone can return either a String (most platforms) or a TimezoneInfo object (some platforms).
      // Keep it dynamic and normalize to a String safely.
      final dynamic tzInfo = await FlutterTimezone.getLocalTimezone();

      String name;
      if (tzInfo is String) {
        name = tzInfo;
      } else {
        // Try to read `.name` if it exists, otherwise fall back to `.toString()`.
        try {
          final dynamic maybeName = (tzInfo as dynamic).name;
          name = (maybeName == null) ? tzInfo.toString() : maybeName.toString();
        } catch (_) {
          name = tzInfo.toString();
        }
      }

      if (name.isNotEmpty) {
        tz.setLocalLocation(tz.getLocation(name));
      }
    } catch (_) {}

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      defaultPresentAlert: true,
      defaultPresentSound: true,
      defaultPresentBadge: true,
    );

    const settings = InitializationSettings(android: androidInit, iOS: iosInit);

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (_) {},
    );

    _inited = true;
  }

  static Future<void> requestPermissions() async {
    // iOS
    final ios = _plugin.resolvePlatformSpecificImplementation<
      IOSFlutterLocalNotificationsPlugin>();
    await ios?.requestPermissions(alert: true, badge: true, sound: true);

    // macOS (schadet nicht)
    final macos = _plugin.resolvePlatformSpecificImplementation<
      MacOSFlutterLocalNotificationsPlugin>();
    await macos?.requestPermissions(alert: true, badge: true, sound: true);

    // Android 13+
    final android = _plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
  }

  static Future<void> cancelIds(List<int> ids) async {
    for (final id in ids) {
      await _plugin.cancel(id);
    }
  }

  static NotificationDetails _details() {
    const android = AndroidNotificationDetails(
      'treep_alarm',
      'Treep Alarm',
      channelDescription: 'Wake-up alarms for train stops',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.alarm,
    );

    const ios = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
      // Custom sound bundled in iOS Runner (ios/Runner). Must be <30s.
      sound: 'alarm.wav',
      interruptionLevel: InterruptionLevel.timeSensitive,
    );

    return const NotificationDetails(android: android, iOS: ios);
  }

  static Future<void> scheduleAlarmCluster({
    required int baseId,
    required DateTime firstFire,
    required int count,
    required Duration interval,
    required String title,
    required String body,
  }) async {
    final details = _details();

    // iOS (and sometimes macOS) will throw if *any* scheduled date is not strictly in the future.
    // When users set an alarm very close to “now”, the conversion to TZDateTime plus scheduling
    // overhead can make the first item appear "in the past" by milliseconds.
    // So we clamp each scheduled time to be at least 2 seconds in the future.
    final minFuture = tz.TZDateTime.now(tz.local).add(const Duration(seconds: 2));

    for (int i = 0; i < count; i++) {
      final when = firstFire.add(interval * i);
      var zdt = tz.TZDateTime.from(when, tz.local);
      if (zdt.isBefore(minFuture)) {
        zdt = minFuture;
      }

      await _plugin.zonedSchedule(
        baseId + i,
        title,
        body,
        zdt,
        details,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: 'treep_alarm',
      );
    }
  }
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
  int _upcomingTripsLimit = 8; // how many upcoming connections to show
  double _minutesBefore = 3;
  bool _isTestingFeed = false;
  bool _isStartingTracking = false;
  String _trackingStatus = '';
  TripCandidate? _selectedCandidate;
  List<int> _alarmIds = <int>[];
  DateTime? _alarmFirstFire;
  bool _nativeAlarmArmed = false;
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

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sleepEnabled = prefs.getBool(kPrefsSleepLinesEnabledKey) ?? true;

      final rawLimit = prefs.getInt(kPrefsUpcomingTripsLimitKey) ?? 8;
      final limit = rawLimit.clamp(1, 20);

      if (!mounted) return;
      setState(() {
        _sleepLinesEnabled = sleepEnabled;
        _upcomingTripsLimit = limit;
      });
    } catch (_) {}
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    await _loadPrefs();
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
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
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
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
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
  static const Duration _gtfsRtMinInterval = Duration(seconds: 13);
  static const Duration _gtfsRtFeedCacheTtl = Duration(seconds: 20);
  DateTime? _lastGtfsRtCallAt;
  Future<http.Response>? _gtfsRtInFlight;

  // Cache the last parsed feed briefly so “Test feed” + “Start tracking” doesn’t double-hit the rate limit.
  FeedMessage? _cachedFeed;
  DateTime? _cachedFeedAt;

  // stop_id → human station name (cached). This is a temporary mapping using transport.opendata.ch.
  // Later we can replace with local GTFS stops.txt for speed and reliability.
  final Map<String, String> _stopNameCache = {}; // canonStopId -> name
  final Map<String, Future<void>> _stopNameInFlight = {}; // dedupe requests
  // Optional static GTFS route_short_name lookup (route_id -> short name).
  // Keep empty by default; if populated later, train matching will use it.
  final Map<String, String> _routeShortNameByRouteId = {};

  String _hhmm(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
  // === TREEP: ALARM LOGIC START ===
  Future<void> _stopAlarm() async {
    _stopForegroundRing();
    await NativeAlarm.stop();
    _liveUpdateTimer?.cancel();
    _liveUpdateTimer = null;
    _sliderDebounce?.cancel();
    _sliderDebounce = null;
    if (_alarmIds.isEmpty) return;
    await NotificationService.cancelIds(_alarmIds);
    if (!mounted) return;
    setState(() {
      _alarmIds = <int>[];
      _alarmFirstFire = null;
      _nativeAlarmArmed = false;
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
      if (_alarmIds.isEmpty) return;

      setState(() => _isRinging = true);

      // iOS: start the native loud alarm once when we reach the ring time.
      // (This is the only reliable way to get real audio in the foreground.)
      if (Platform.isIOS) {
        NativeAlarm.startNow();
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
          content: const Text('You are approaching your stop.\n\nPress STOP to silence the alarm.'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _stopAlarm();
              },
              child: const Text(
                'STOP ALARM',
                style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
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
    if (_alarmIds.isEmpty || _alarmFirstFire == null) return; // nur wenn armed
    if (_isRescheduling) return;

    try {
      final updated = await _refreshCandidateEta(current);
      if (!mounted) return;
      if (updated == null) return;
      _traceCandidate('Live-update current', current, source: 'tick-before-compare');
      _traceCandidate('Live-update fetched', updated, source: 'tick-before-compare');

      final etaDiff = updated.etaLocal.difference(current.etaLocal).inSeconds.abs();
      final delayDiff = (updated.delaySeconds - current.delaySeconds).abs();
      if (etaDiff < 30 && delayDiff < 30) return;

      await _rescheduleAlarmWith(updated, reason: 'Verspätung/Update');
    } catch (_) {}
  }

  Future<TripCandidate?> _refreshCandidateEta(TripCandidate c) async {
    _traceCandidate('Live-update start', c, source: 'refresh-input');
    final hasStableTripKey = c.startDate.isNotEmpty || c.startTime.isNotEmpty;

    // 1) GTFS-RT Refresh (wenn TripKey stabil ist)
    if (hasStableTripKey) {
      final feed = await _fetchGtfsRtFeed();
      final destCanon = _normalizeStopId(c.stopId) ?? c.stopId;
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
        StopEta? terminal;

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

          if (_stopIdMatches(stopCanon, destCanon) && matched == null) {
            matched = stop;
          }
        }

        if (upcoming.isEmpty) return null;
        upcoming.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
        terminal = upcoming.last;

        final chosenStop = matched ?? upcoming.first;

        final refreshed = TripCandidate(
          tripId: c.tripId,
          routeId: c.routeId,
          startDate: c.startDate,
          startTime: c.startTime,
          stopId: chosenStop.stopIdRaw,
          etaLocal: chosenStop.etaLocal,
          delaySeconds: chosenStop.delaySeconds,
          displayTrain: c.displayTrain,
          vehicleLabel: c.vehicleLabel,
          destinationMatched: matched != null,
          upcomingStops: upcoming.take(40).toList(),
          terminalStopId: terminal.stopIdRaw,
          terminalStopIdCanon: terminal.stopIdCanon,
        );
        _traceCandidate('Live-update GTFS result', refreshed, source: 'refresh-gtfs');
        return refreshed;
      }
      return null;
    }

    // 2) Stationboard Refresh (wenn kein stabiler TripKey)
    final destCanon = _normalizeStopId(c.stopId) ?? c.stopId;
    final arrivals = await _fallbackArrivalsAtDestination(
      trainQuery: c.displayTrain,
      destStopIdCanons: <String>[destCanon],
      limit: 100,
    );

    if (arrivals.isEmpty) return null;

    final myDirKey = _directionKeyFor(c);
    final sameDir = arrivals.where((x) => _directionKeyFor(x) == myDirKey).toList();
    final pool = sameDir.isNotEmpty ? sameDir : arrivals;

    pool.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));

    TripCandidate best = pool.first;
    int bestDiff = best.etaLocal.difference(c.etaLocal).inSeconds.abs();
    for (final x in pool.take(_upcomingTripsLimit)) {
      final d = x.etaLocal.difference(c.etaLocal).inSeconds.abs();
      if (d < bestDiff) {
        best = x;
        bestDiff = d;
      }
    }

    _traceCandidate('Live-update fallback result', best, source: 'refresh-fallback');
    return best;
  }

  Future<void> _rescheduleAlarmWith(TripCandidate updated, {required String reason}) async {
    if (!mounted) return;

    _isRescheduling = true;
    final token = ++_rescheduleToken;

    setState(() {
      _selectedCandidate = updated;
      _trackingStatus =
          'Update: $reason — ETA ${_hhmm(updated.etaLocal)} (${_fmtDelay(updated.delaySeconds)})';
    });
    _traceCandidate('selectedCandidate reassigned', updated, source: 'live-update');

    try {
      await _armAlarmFor(updated, showUx: false);
    } finally {
      if (token == _rescheduleToken) {
        _isRescheduling = false;
        if (mounted) {
          setState(() {}); // sorgt dafür, dass "Alarm: armed for ..." sicher neu rendert
        }
      }
    }
  }
  Future<void> _armAlarmFor(TripCandidate chosen, {bool showUx = true}) async {
    await _stopAlarm();
    await NotificationService.requestPermissions();

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

    final baseId = (DateTime.now().millisecondsSinceEpoch % 1000000);
    final ids = List<int>.generate(count, (i) => baseId + i);

    final title = 'TREEP ALARM';
    final body =
        '${chosen.vehicleLabel}: ${chosen.displayTrain} → ${_terminalLabelFor(chosen)}\n'
        'Your stop: ${_stopLabel(chosen.stopId)} • ETA ${_hhmm(chosen.etaLocal)}';

    // UX (dialog + snackbar + sleep-line overlay) should only appear on explicit user action
    // and not more often than once every 30 seconds.
    final nowForUx = DateTime.now();
    final allowUx = showUx && (_lastAlarmUxAt == null || nowForUx.difference(_lastAlarmUxAt!) > const Duration(seconds: 30));

    // Show an explicit OK dialog (user can disable it via “Nicht mehr anzeigen”).
    // Only when the user explicitly sets the alarm (not when we silently re-schedule).
    if (allowUx) {
      await _maybeShowVolumeAndFocusDialog();
    }

    await NotificationService.scheduleAlarmCluster(
      baseId: baseId,
      firstFire: first,
      count: count,
      interval: interval,
      title: title,
      body: body,
    );

    // Best-effort iOS loud alarm (native). Android continues with notifications only.
    final nativeOk = Platform.isIOS ? await NativeAlarm.armAt(first) : false;

    if (!mounted) return;
    setState(() {
      _alarmIds = ids;
      _alarmFirstFire = first;
      _nativeAlarmArmed = nativeOk;
    });
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
  }

  Future<void> _onMinutesBeforeChanged(double v) async {
    if (!mounted) return;
    setState(() => _minutesBefore = v);

    _sliderDebounce?.cancel();
    _sliderDebounce = Timer(const Duration(milliseconds: 450), () async {
      final c = _selectedCandidate;
      if (c == null) return;
      if (_alarmIds.isEmpty || _alarmFirstFire == null) return;

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
        await NativeAlarm.startNow();
      } else {
        SystemSound.play(SystemSoundType.alert);
      }
    } catch (_) {}

    int tick = 0;
    _selfTestHapticTimer?.cancel();
    _selfTestHapticTimer = Timer.periodic(const Duration(milliseconds: 350), (_) {
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
        await NativeAlarm.stop();
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
                      onChanged: (v) => setLocalState(() => dontShowAgain = v ?? false),
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
    final terminalLabel = _terminalLabelFor(c);
    final src = source == null || source.isEmpty ? '' : ' source=$source';
    _trace(
      '$stage$src tripId=${c.tripId} routeId=${c.routeId} stopId=${c.stopId} '
      'etaLocal=${c.etaLocal.toIso8601String()} delaySeconds=${c.delaySeconds} '
      'displayTrain="${c.displayTrain}" terminalLabel="$terminalLabel"',
    );
  }

  void _traceCandidatePool(String stage, List<TripCandidate> candidates, {String? source}) {
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

  void _traceDirectionBuckets(String stage, Map<String, List<TripCandidate>> byDir) {
    _trace('$stage bucketCount=${byDir.length}');
    final keys = byDir.keys.toList()..sort();
    for (final key in keys) {
      final list = [...(byDir[key] ?? const <TripCandidate>[])]
        ..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
      _trace('$stage bucket="$key" count=${list.length}');
      for (final c in list) {
        _trace(
          '$stage item bucket="$key" eta=${c.etaLocal.toIso8601String()} '
          'displayTrain="${c.displayTrain}" terminal="${_terminalLabelFor(c)}" tripId=${c.tripId}',
        );
      }
    }
  }

  void _traceStageCandidates(String stage, List<TripCandidate> candidates, {int max = 6}) {
    _trace('$stage count=${candidates.length}');
    final sorted = [...candidates]..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    for (final c in sorted.take(max)) {
      _trace(
        '$stage item displayTrain="${c.displayTrain}" eta=${c.etaLocal.toIso8601String()} '
        'delaySeconds=${c.delaySeconds} terminalLabel="${_terminalLabelFor(c)}" '
        'stopId=${c.stopId} tripId=${c.tripId}',
      );
    }
  }

  bool _looksInternalStopToken(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return false;
    if (RegExp(r'^\d+$').hasMatch(raw)) return true;
    final canon = _normalizeStopId(raw);
    if (canon == null) return false;
    // If it has no letters and normalizes to a stop id, treat as internal-ish id.
    return !RegExp(r'[a-zA-Z]').hasMatch(raw);
  }

  List<TripCandidate> _dropPastCandidates(List<TripCandidate> input, {required String stage}) {
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
  }) _runTrainQueryFallbackPostPipeline({
    required String scenarioTag,
    required String trainQueryNorm,
    required List<TripCandidate> broadArrivalCandidates,
  }) {
    final filtered = broadArrivalCandidates
        .where((c) {
          final candidateNorm = _normalizeTrainToken(c.displayTrain);
          return _matchesTrainQuery(trainQueryNorm, candidateNorm);
        })
        .toList()
      ..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    _trace('Train-specific fallback filtered count=${filtered.length}');
    _traceStageCandidates('Fallback public-filter leave $scenarioTag', filtered);

    for (final c in filtered.take(10)) {
      _trace(
        'Train-specific fallback candidate displayTrain="${c.displayTrain}" '
        'eta=${c.etaLocal.toIso8601String()} delaySeconds=${c.delaySeconds} '
        'terminal="${_terminalLabelFor(c)}" tripId=${c.tripId} stopId=${c.stopId}',
      );
    }

    final fresh = _dropPastCandidates(
      filtered,
      stage: 'Train-specific fallback filtered pool',
    );
    _trace('Train-specific fallback stale-filter count=${fresh.length}');
    _traceStageCandidates('Fallback stale-filter leave $scenarioTag', fresh);

    final deduped = _dedupeCandidates(fresh)..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    _trace('Train-specific fallback dedupe count=${deduped.length}');
    _traceStageCandidates('Fallback dedupe leave $scenarioTag', deduped);

    return (filtered: filtered, fresh: fresh, deduped: deduped);
  }

  Future<String> _resolveFallbackTerminalLabel({
    required String derivedTerminalRaw,
    required String toRaw,
    required String destName,
  }) async {
    var terminalName = derivedTerminalRaw.trim();
    final to = toRaw.trim();
    final dest = destName.trim();

    // 1) explicit readable terminal station name
    if (terminalName.isNotEmpty && !_looksInternalStopToken(terminalName)) {
      return terminalName;
    }

    // 2) readable destination text from `to`
    if (to.isNotEmpty && !_looksInternalStopToken(to)) {
      return to;
    }

    // 3) stop-name cache lookup from any internal-looking token
    final lookupRaw = terminalName.isNotEmpty ? terminalName : to;
    if (lookupRaw.isNotEmpty) {
      final canon = _normalizeStopId(lookupRaw);
      if (canon != null) {
        await _ensureStopName(canon);
        final cached = (_stopNameCache[canon] ?? '').trim();
        if (cached.isNotEmpty && cached != 'Unknown') {
          return cached;
        }
      }
    }

    // 4) absolute last resort: destination name, then raw id/text
    if (dest.isNotEmpty) return dest;
    if (terminalName.isNotEmpty) return terminalName;
    return to;
  }

  int _pickerTakePerDirection() {
    return _upcomingTripsLimit < 3 ? 3 : _upcomingTripsLimit;
  }

  String _toOpendataId(String canonOrDigits) {
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

  bool _stopIdMatches(String stopCanon, String destCanon) {
    // First try strict normalized stop-id equality.
    final a = _normalizeStopId(stopCanon) ?? stopCanon;
    final b = _normalizeStopId(destCanon) ?? destCanon;
    if (a == b) return true;

    // Fallback: some feeds use sibling/main/platform stop_ids for the same station
    // (for example a resolved destination id vs a GTFS/stationboard stop id).
    // If we already know both station names and they normalize to the same base token,
    // treat them as the same logical station.
    final aName = (_stopNameCache[a] ?? '').trim();
    final bName = (_stopNameCache[b] ?? '').trim();
    if (aName.isEmpty || bName.isEmpty) return false;

    final aNorm = _normalizeStationToken(aName);
    final bNorm = _normalizeStationToken(bName);
    if (aNorm.isEmpty || bNorm.isEmpty) return false;

    return aNorm == bNorm;
  }

  // Station-name matching helper (diacritics/light normalization).
  String _normalizeStationToken(String s) {
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

  bool _stationNameMatchesQuery(String stationName, String query) {
    final nRaw = stationName.trim();
    final qRaw = query.trim();
    if (qRaw.isEmpty || nRaw.isEmpty) return false;

    final n = _normalizeStationToken(nRaw);
    final q = _normalizeStationToken(qRaw);
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

  bool _matchesTrainQuery(String tq, String candidateNorm) {
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

  String? _extractPublicLineId(String rawLabel) {
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

  // ignore: unused_element
  bool _matchesFallbackPublicLabel(String trainQuery, TripCandidate c) {
    final queryNorm = _normalizeTrainToken(trainQuery);
    if (queryNorm.isEmpty) return true;

    final qLetters = queryNorm.replaceAll(RegExp(r'\d+'), '');
    final qDigits = queryNorm.replaceAll(RegExp(r'\D+'), '');

    final displayNorm = _normalizeTrainToken(c.displayTrain);
    final routeNorm = _normalizeTrainToken(c.routeId);
    if (_matchesTrainQuery(queryNorm, displayNorm) || _matchesTrainQuery(queryNorm, routeNorm)) {
      return true;
    }

    final displayLineId = _extractPublicLineId(c.displayTrain);
    final routeLineId = _extractPublicLineId(c.routeId);
    if (displayLineId != null && displayLineId == queryNorm) return true;
    if (routeLineId != null && routeLineId == queryNorm) return true;

    // For letters-only queries (EC/IC/IR), keep relaxed prefix behavior.
    if (qLetters.isNotEmpty && qDigits.isEmpty) {
      if (displayNorm.startsWith(qLetters) || routeNorm.startsWith(qLetters)) return true;
    }

    return false;
  }

  List<String> _trainLabelTokens(String raw) {
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

  bool _matchesTrainQueryTokenAware(String trainQuery, List<String> rawLabels) {
    final tq = _normalizeTrainToken(trainQuery);
    if (tq.isEmpty) return true;

    final qLetters = tq.replaceAll(RegExp(r'\d+'), '');
    final qDigits = tq.replaceAll(RegExp(r'\D+'), '');

    for (final raw in rawLabels) {
      final norm = _normalizeTrainToken(raw);
      if (_matchesTrainQuery(tq, norm)) return true;

      final tokens = _trainLabelTokens(raw);
      for (final token in tokens) {
        final tokenNorm = _normalizeTrainToken(token);
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

  bool _isBaselMainStationQuery(String destCanon) {
    return destCanon == '8500010';
  }

  bool _isBaselMainStationStopHint(StopEta stop) {
    final stopCanon = _normalizeStopId(stop.stopIdCanon) ?? stop.stopIdCanon;
    if (stopCanon == '8500010') return true;

    final rawDigits = RegExp(r'\d+').allMatches(stop.stopIdRaw).map((m) => m.group(0)!).join();
    if (rawDigits.contains('8500010')) return true;

    final name = (_stopNameCache[stopCanon] ?? '').toLowerCase();
    if (name.contains('basel') && name.contains('sbb') && !name.contains('bad')) {
      return true;
    }

    return false;
  }

  bool _isLettersOnlyLongDistanceQuery(String trainQuery) {
    final tq = _normalizeTrainToken(trainQuery);
    if (tq.isEmpty) return false;
    final letters = tq.replaceAll(RegExp(r'\d+'), '');
    final digits = tq.replaceAll(RegExp(r'\D+'), '');
    if (letters.isEmpty || digits.isNotEmpty) return false;
    return letters == 'ec' || letters == 'ic' || letters == 'ir';
  }

  bool _shouldUseGtfsBridgeForQuery(String trainQuery) {
    final tq = _normalizeTrainToken(trainQuery);
    if (tq.isEmpty) return false;

    final letters = tq.replaceAll(RegExp(r'\d+'), '');
    final digits = tq.replaceAll(RegExp(r'\D+'), '');
    if (letters.isEmpty) return false;

    // Existing long-distance letters-only queries (EC/IC/IR).
    if (digits.isEmpty) {
      return _isLettersOnlyLongDistanceQuery(trainQuery);
    }

    // letters+digits line ids (IR55, IC5, S20, S3, ...).
    return true;
  }

  String _gtfsBridgeDecisionReason(String trainQuery) {
    final tq = _normalizeTrainToken(trainQuery);
    if (tq.isEmpty) return 'empty-query';

    final letters = tq.replaceAll(RegExp(r'\d+'), '');
    final digits = tq.replaceAll(RegExp(r'\D+'), '');
    if (letters.isEmpty) return 'digits-only-query';

    // Disable bridge for S-lines (S3, S20, SN1, ...).
    if (RegExp(r'^sn?\d+$').hasMatch(tq)) {
      return 'local-s-line';
    }

    if (digits.isEmpty) {
      return _isLettersOnlyLongDistanceQuery(trainQuery) ? 'long-distance-letters' : 'letters-only-not-supported';
    }

    return 'letters+digits-supported';
  }

  bool _shouldUseGtfsBridgeForQueryWithLocalGuard(String trainQuery) {
    final reason = _gtfsBridgeDecisionReason(trainQuery);
    return _shouldUseGtfsBridgeForQuery(trainQuery) && reason != 'local-s-line' && reason != 'letters-only-not-supported';
  }

  TripCandidate? _bridgeFallbackCandidateToGtfs({
    required TripCandidate fallbackCandidate,
    required FeedMessage feed,
    required String destStopCanon,
  }) {
    _traceCandidate('GTFS bridge start', fallbackCandidate, source: 'fallback-seed');

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

    final fallbackTermNorm = _normalizeStationToken(_terminalLabelFor(fallbackCandidate));
    final fallbackStopCanon = _normalizeStopId(fallbackCandidate.stopId) ?? fallbackCandidate.stopId;

    TripCandidate? best;
    double? bestScore;
    double? secondBestScore;

    for (final g in gtfsPool) {
      final etaDiffSec = g.etaLocal.difference(fallbackCandidate.etaLocal).inSeconds.abs();
      final gtfsTermNorm = _normalizeStationToken(_terminalLabelFor(g));

      double terminalPenalty = 0;
      if (fallbackTermNorm.isNotEmpty && gtfsTermNorm.isNotEmpty) {
        if (fallbackTermNorm == gtfsTermNorm) {
          terminalPenalty = 0;
        } else if (gtfsTermNorm.contains(fallbackTermNorm) || fallbackTermNorm.contains(gtfsTermNorm)) {
          terminalPenalty = 90;
        } else {
          terminalPenalty = 300;
        }
      }

      final gtfsStopCanon = _normalizeStopId(g.stopId) ?? g.stopId;
      final sameDest = _stopIdMatches(gtfsStopCanon, fallbackStopCanon) || _stopIdMatches(gtfsStopCanon, destStopCanon);

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

    final clearWinner = secondBestScore == null || (secondBestScore - bestScore) >= 90;
    final plausibleTime = best.etaLocal.difference(fallbackCandidate.etaLocal).inSeconds.abs() <= 15 * 60;
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
    var mergedTerminalRaw = fallbackTerminalRaw.isNotEmpty ? fallbackTerminalRaw : gtfsTerminalRaw;
    var mergedTerminalCanon = fallbackTerminalCanon;
    if (mergedTerminalRaw.isEmpty && mergedTerminalCanon.isEmpty) {
      mergedTerminalRaw = gtfsTerminalRaw;
      mergedTerminalCanon = gtfsTerminalCanon;
    }

    final merged = TripCandidate(
      // Keep GTFS identity/timing for realtime refresh correctness.
      tripId: best.tripId,
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
      destinationMatched: best.destinationMatched || fallbackCandidate.destinationMatched,
      upcomingStops: best.upcomingStops,
      terminalStopId: mergedTerminalRaw,
      terminalStopIdCanon: mergedTerminalCanon,
    );

    _trace(
      'GTFS bridge chosen fallbackDisplayTrain="${fallbackCandidate.displayTrain}" '
      'gtfsDisplayTrain="${best.displayTrain}"',
    );
    _trace(
      'GTFS bridge merged finalDisplayTrain="${merged.displayTrain}" '
      'finalTerminal="${_terminalLabelFor(merged)}"',
    );
    _traceCandidate('GTFS bridge chosen', best, source: 'bridge-result');
    _traceCandidate('GTFS bridge merged', merged, source: 'bridge-result');
    return merged;
  }

  String _vehicleLabelFromDisplay(String displayTrain) {
    final n = _normalizeTrainToken(displayTrain);
    if (n.startsWith('b')) return 'Bus';
    return 'Train';
  }

  /// Fallback when destination-by-ID matching fails:
  /// Look at the stops of trips that match the train query and try to find a stop whose *name*
  /// matches the user-entered destination string.
  Future<List<TripCandidate>> _findCandidatesByTrainAndDestinationName(
    FeedMessage feed,
    String trainQuery,
    String destName,
  ) async {
    // Get trips for this train, even if we don't know the destination stop_id yet.
    // We pass a nonsense destQuery so we don't accidentally match everything.
    final trainOnly = _findCandidates(
      feed,
      trainQuery,
      '0',
      requireDestinationMatch: false,
    );

    if (trainOnly.isEmpty) return const <TripCandidate>[];

    // We'll resolve station names for a limited number of stops to keep network calls small.
    const maxCandidates = 8;
    const maxStopsPerCandidate = 30;
    const maxLookupsTotal = 25;

    int lookups = 0;
    final out = <TripCandidate>[];

    for (final c in trainOnly.take(maxCandidates)) {
      StopEta? matched;

      for (final s in c.upcomingStops.take(maxStopsPerCandidate)) {
        // Resolve name if needed.
        final canon = s.stopIdCanon;
        if (!_stopNameCache.containsKey(canon) && lookups < maxLookupsTotal) {
          lookups++;
          await _ensureStopName(canon);
        }

        final name = _stopNameCache[canon];
        if (name == null || name == 'Unknown') continue;

        if (_stationNameMatchesQuery(name, destName)) {
          matched = s;
          break;
        }
      }

      if (matched != null) {
        out.add(c.copyWithDestination(matched));
      }

      // If we already have multiple good matches, stop early.
      if (out.length >= 10) break;
    }

    out.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    return out;
  }
  Future<void> _ensureStopName(String canonStopId) async {
    if (canonStopId.isEmpty) return;
    if (_stopNameCache.containsKey(canonStopId)) return;

    // Deduplicate parallel requests.
    if (_stopNameInFlight.containsKey(canonStopId)) {
      await _stopNameInFlight[canonStopId];
      return;
    }

    final fut = () async {
      try {
        final id = _toOpendataId(canonStopId);

        http.Response res;

        // First try exact id lookup.
        final uri = Uri.parse(
          'https://transport.opendata.ch/v1/locations?id=${Uri.encodeComponent(id)}',
        );
        res = await http.get(uri).timeout(const Duration(seconds: 8));

        // Some stop_ids don't resolve via `?id=` (especially terminal/platform variants).
        // Fallback to a query lookup before giving up.
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

        final decoded = json.decode(
          utf8.decode(res.bodyBytes, allowMalformed: true),
        );
        final stations = (decoded is Map) ? decoded['stations'] : null;
        if (stations is! List || stations.isEmpty) {
          _stopNameCache[canonStopId] = 'Unknown';
          return;
        }

        // Try to pick the station whose normalized id matches exactly.
        Map? best;
        for (final s in stations) {
          if (s is! Map) continue;
          final idRaw = (s['id'] ?? '').toString();
          final idCanon = _normalizeStopId(idRaw);
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

  Future<void> _warmStopNamesForCandidates(List<TripCandidate> candidates) async {
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

    await Future.wait(ids.map(_ensureStopName));

    if (mounted) setState(() {});
  }

  String _stopLabel(String rawStopId) {
    final canon = _normalizeStopId(rawStopId) ?? rawStopId;
    final name = _stopNameCache[canon];
    if (name == null || name == 'Unknown') return canon;
    return '$name ($canon)';
  }

  List<TripCandidate> _dedupeCandidates(List<TripCandidate> input) {
    // Deduplicate by trip identity + matched stop.
    // tripId/startDate/startTime are stable in GTFS-RT; stopId can vary by platform.
    final seen = <String, TripCandidate>{};
    _trace('Dedupe before count=${input.length}');

    for (var i = 0; i < input.length; i++) {
      final c = input[i];
      final stopCanon = _normalizeStopId(c.stopId) ?? c.stopId;

      // GTFS-RT trips have stable (tripId,startDate,startTime). Stationboard fallback doesn't.
      // When startDate/startTime are empty, include ETA+direction so we don't collapse all future trains.
      final hasStableTripKey = c.startDate.isNotEmpty || c.startTime.isNotEmpty;
      final etaSec = c.etaLocal.toUtc().millisecondsSinceEpoch ~/ 1000;

      final key = hasStableTripKey
          ? '${c.tripId}|${c.startDate}|${c.startTime}|$stopCanon'
          : '${c.tripId}|$etaSec|${_normalizeTrainToken(c.displayTrain)}|$stopCanon|${_directionKeyFor(c)}';
      _trace(
        'Dedupe before[#${i + 1}] key="$key" stable=$hasStableTripKey '
        'tripId=${c.tripId} displayTrain="${c.displayTrain}" stopId=$stopCanon '
        'eta=${c.etaLocal.toIso8601String()} terminal="${_terminalLabelFor(c)}"',
      );

      final prev = seen[key];
      if (prev == null || c.etaLocal.isBefore(prev.etaLocal)) {
        seen[key] = c;
      }
    }

    final out = seen.values.toList()..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    _trace('Dedupe after count=${out.length}');
    return out;
  }

  String _terminalLabelFor(TripCandidate c) {
    final canon = c.terminalStopIdCanon.trim();
    if (canon.isNotEmpty) return _stopLabel(canon);

    final raw = c.terminalStopId.trim();
    if (raw.isEmpty) return 'Unknown direction';

    final maybeCanon = _normalizeStopId(raw);
    if (maybeCanon != null) return _stopLabel(maybeCanon);

    return raw;
  }

  String _directionKeyFor(TripCandidate c) {
    final canon = c.terminalStopIdCanon.trim();
    if (canon.isNotEmpty) return canon;

    final raw = c.terminalStopId.trim();
    if (raw.isEmpty) return 'unknown';

    final maybeCanon = _normalizeStopId(raw);
    if (maybeCanon != null) return maybeCanon;

    return _normalizeStationToken(raw);
  }

  Future<String> _pickDirectionBottomSheet(List<TripCandidate> candidates) async {
    final Map<String, List<TripCandidate>> groups = {};
    for (final c in candidates) {
      final key = _directionKeyFor(c);
      groups.putIfAbsent(key, () => <TripCandidate>[]).add(c);
    }
    _traceDirectionBuckets('Direction-grouping', groups);
    // Warm station names for digit direction keys (GTFS stop_ids) so we show names instead of raw codes.
    final digitKeys = groups.keys.where((k) => RegExp(r'^\\d+$').hasMatch(k)).toSet();
    if (digitKeys.isNotEmpty) {
      await Future.wait(digitKeys.map(_ensureStopName));
      if (!mounted) return 'unknown';
    }

    final options = groups.entries
        .where((e) => e.key != 'unknown' && e.key.isNotEmpty)
        .map((e) {
          final list = [...e.value]..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
          final first = list.first;
          return (key: e.key, label: _terminalLabelFor(first), nextEta: first.etaLocal, count: list.length);
        })
        .toList();

    if (options.isEmpty) return 'unknown';
    options.sort((a, b) => a.nextEta.compareTo(b.nextEta));

    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: options.length,
            separatorBuilder: (_, unusedIndex) => const Divider(height: 1),
            itemBuilder: (ctx, i) {
              final o = options[i];
              final mins = o.nextEta.difference(DateTime.now()).inMinutes;
              return ListTile(
                title: Text('→ ${o.label}'),
                subtitle: Text('Next in ${mins}m • ${_hhmm(o.nextEta)} • ${o.count} upcoming'),
                onTap: () => Navigator.of(ctx).pop(o.key),
              );
            },
          ),
        );
      },
    );

    return picked ?? options.first.key;
  }

  Future<TripCandidate> _pickTripInDirectionBottomSheet({
    required List<TripCandidate> candidates,
  }) async {
    final list = [...candidates]..sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    for (final c in list) {
      _trace(
        'Trip-picker candidate eta=${c.etaLocal.toIso8601String()} '
        'displayTrain="${c.displayTrain}" terminal="${_terminalLabelFor(c)}" tripId=${c.tripId}',
      );
    }

    final picked = await showModalBottomSheet<TripCandidate>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: list.length,
            separatorBuilder: (_, unusedIndex) => const Divider(height: 1),
            itemBuilder: (ctx, i) {
              final c = list[i];
              final mins = c.etaLocal.difference(DateTime.now()).inMinutes;
              return ListTile(
                title: Text('${_hhmm(c.etaLocal)} (in ${mins}m)'),
                subtitle: Text('${c.displayTrain} → ${_terminalLabelFor(c)} • ${_fmtDelay(c.delaySeconds)}'),
                onTap: () => Navigator.of(ctx).pop(c),
              );
            },
          ),
        );
      },
    );

    return picked ?? list.first;
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
          _trackingStatus = 'Checking upcoming arrivals at ${_stopLabel(destCanon)}…';
        });

        final arrivalCandidates = await _fallbackArrivalsAtDestination(
          trainQuery: '',
          destStopIdCanons: destWasName ? destAlternatives : <String>[destCanon],
          destNameQuery: destWasName ? destQuery : null,
          limit: 100,
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
        var candidates = _dedupeCandidates(arrivalCandidates);
        candidates = _dropPastCandidates(candidates, stage: 'No-train fallback pool');
        if (candidates.isEmpty) {
          setState(() {
            _trackingStatus = 'No upcoming arrivals found (stale candidates removed).';
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
          final key = _directionKeyFor(c);
          byDir.putIfAbsent(key, () => <TripCandidate>[]).add(c);
        }
        _traceDirectionBuckets('Direction-grouping startTracking-noTrain', byDir);

        final dirKeys = byDir.keys.where((k) => k != 'unknown' && k.isNotEmpty).toList();

        String chosenDir = 'unknown';
        if (dirKeys.length > 1) {
          chosenDir = await _pickDirectionBottomSheet(candidates);
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

        TripCandidate chosen;
        if (dirCandidates.length == 1) {
          chosen = dirCandidates.first;
        } else {
          final pickerLimit = _pickerTakePerDirection();
          chosen = await _pickTripInDirectionBottomSheet(
            candidates: dirCandidates.take(pickerLimit).toList(),
          );
        }
        _traceCandidate('Final-selection chosen', chosen, source: 'fallback-arrivals-no-train');
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
        _traceCandidate('selectedCandidate assigned', chosen, source: 'fallback-arrivals-no-train');

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
          final resolvedIds = await _resolveStopIdsFromName(destQuery);
          final idsToTry = resolvedIds.isNotEmpty ? resolvedIds : destAlternatives;

          for (final id in idsToTry.isEmpty ? <String>[effectiveDest] : idsToTry) {
            candidates.addAll(
              _findCandidates(
                feed,
                trainQuery,
                id,
                requireDestinationMatch: true,
              ),
            );
          }
          candidates = _dedupeCandidates(candidates);
        } else {
          candidates = _findCandidates(
            feed,
            trainQuery,
            effectiveDest,
            requireDestinationMatch: true,
          );
        }
        _traceStageCandidates('GTFS strict leave $scenarioTag', candidates);
        _traceCandidatePool('GTFS-RT candidate pool', candidates, source: 'gtfs-rt-strict');

        // Warm station name cache for the destination itself (nice labels).
        final destCanonWarm = _normalizeStopId(effectiveDest) ?? effectiveDest;
        await _ensureStopName(destCanonWarm);

        bool usedArrivalsFallback = false;
        bool usedGtfsBridge = false;
        final hadStrictMatch = candidates.isNotEmpty;
        var trainFallbackBroadCount = 0;
        var trainFallbackFilteredCount = 0;
        var trainFallbackStaleRemoved = 0;
        var trainFallbackFinalCount = 0;
        var trainFallbackAttempted = false;

        // If GTFS-RT did not find a strict match, prefer stationboard (arrivals) as the next step.
        // This produces much nicer direction labels ("to") and often has better coverage.
        if (candidates.isEmpty) {
          final destCanon = _normalizeStopId(effectiveDest) ?? effectiveDest;
          final resolvedForFallback = destWasName ? destAlternatives : <String>[destCanon];
          final queryNorm = _normalizeTrainToken(trainQuery);
          _trace(
            'Train query fallback-first mode query="$trainQuery" queryNorm="$queryNorm" '
            'resolvedStopIds=${resolvedForFallback.join(",")} strictGtfsCount=${candidates.length}',
          );

          setState(() {
            _trackingStatus = 'No GTFS-RT match yet. Checking upcoming arrivals at ${_stopLabel(destCanon)}…';
          });

          final broadArrivalCandidates = await _fallbackArrivalsAtDestination(
            trainQuery: '',
            destStopIdCanons: resolvedForFallback,
            destNameQuery: destWasName ? destQuery : null,
            limit: 220,
          );

          if (!mounted) return;
          _traceStageCandidates('Fallback broad leave $scenarioTag', broadArrivalCandidates);
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

          _trace('Train-specific fallback broad pool count=${broadArrivalCandidates.length} queryNorm="$queryNorm"');
          trainFallbackAttempted = true;
          trainFallbackBroadCount = broadArrivalCandidates.length;
          if (broadArrivalCandidates.isEmpty) {
            _trace('Train-specific fallback no-match reason=broad_pool_empty queryNorm="$queryNorm"');
          }

          final postFallback = _runTrainQueryFallbackPostPipeline(
            scenarioTag: scenarioTag,
            trainQueryNorm: queryNorm,
            broadArrivalCandidates: broadArrivalCandidates,
          );
          trainFallbackFilteredCount = postFallback.filtered.length;
          trainFallbackStaleRemoved = postFallback.filtered.length - postFallback.fresh.length;
          trainFallbackFinalCount = postFallback.deduped.length;

          if (postFallback.filtered.isEmpty) {
            _trace('Train-specific fallback no public-label match queryNorm="$queryNorm"');
            _trace('Train-specific fallback no-match reason=filtered_pool_empty queryNorm="$queryNorm"');
          }

          if (postFallback.fresh.isEmpty && postFallback.filtered.isNotEmpty) {
            _trace('Train-specific fallback no-match reason=all_filtered_removed_as_stale queryNorm="$queryNorm"');
          }
          if (postFallback.deduped.isEmpty && postFallback.fresh.isNotEmpty) {
            _trace('Train-specific fallback no-match reason=all_removed_by_dedupe queryNorm="$queryNorm"');
          }

          if (postFallback.deduped.isNotEmpty) {
            _trace('Train-specific fallback final pool count=${postFallback.deduped.length}');
            for (final c in postFallback.deduped) {
              _trace(
                'Train-specific final fallback candidate displayTrain="${c.displayTrain}" '
                'eta=${c.etaLocal.toIso8601String()} terminal="${_terminalLabelFor(c)}" tripId=${c.tripId}',
              );
            }

            candidates = postFallback.deduped;
            usedArrivalsFallback = true;

            final bridgeReason = _gtfsBridgeDecisionReason(trainQuery);
            final bridgeEnabled = _shouldUseGtfsBridgeForQueryWithLocalGuard(trainQuery);
            _trace(
              'GTFS bridge enabled queryNorm="$queryNorm" strictPoolEmpty=true fallbackCount=${postFallback.deduped.length} enabled=$bridgeEnabled reason=$bridgeReason',
            );
            if (!bridgeEnabled && bridgeReason == 'local-s-line') {
              _trace('GTFS bridge skipped for local-line queryNorm="$queryNorm"');
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
              _trace('Train-specific fallback bridge enriched count=$bridgedCount total=${bridgedPool.length}');
              if (bridgedCount > 0) {
                usedGtfsBridge = true;
                candidates = _dedupeCandidates(bridgedPool);
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
            _traceStageCandidates('Selection input leave $scenarioTag', candidates);

            await _warmStopNamesForCandidates(candidates);
            _traceCandidatePool(
              'Fallback arrivals candidate pool',
              candidates,
              source: usedGtfsBridge ? 'gtfs-bridge-from-fallback' : 'fallback-arrivals-train-filtered',
            );

            setState(() {
              _trackingStatus =
                  'Showing upcoming arrivals at ${_stopLabel(destCanon)} — pick direction & time.';
            });
          }
        }

        // If we still have nothing, keep the older GTFS-based fallbacks.
        // Fallback 1: still require the train match, but allow any destination.
        if (candidates.isEmpty) {
          candidates = _findCandidates(
            feed,
            trainQuery,
            effectiveDest,
            requireDestinationMatch: false,
          );
        }

        // Fallback 2 (important): if the user typed a destination *name* (e.g. "Oensingen") and we
        // couldn't match by stop_id, try matching against stop *names* inside the train's upcoming stops.
        if (candidates.isEmpty && destWasName) {
          final nameMatched = await _findCandidatesByTrainAndDestinationName(
            feed,
            trainQuery,
            destQuery,
          );

          if (!mounted) return;

          if (nameMatched.isNotEmpty) {
            candidates = nameMatched;
            _traceCandidatePool(
              'GTFS-name-match candidate pool',
              candidates,
              source: 'gtfs-stop-name-fallback',
            );
            setState(() {
              _trackingStatus =
                  'Destination matched by name: “$destQuery” (from train stops) — pick the right trip if needed.';
            });
          }
        }

        // Fallback 3: only when train query is empty — show trips that go to the destination.
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
            destStopIdCanons: destWasName ? destAlternatives : <String>[destCanon],
            destNameQuery: destWasName ? destQuery : null,
            limit: 100,
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
          candidates = _dedupeCandidates(arrivalCandidates);
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

        final Map<String, List<TripCandidate>> byDir = {};
        for (final c in candidates) {
          final key = _directionKeyFor(c);
          byDir.putIfAbsent(key, () => <TripCandidate>[]).add(c);
        }
        _traceDirectionBuckets('Direction-grouping startTracking-train', byDir);

        final dirKeys = byDir.keys.where((k) => k != 'unknown' && k.isNotEmpty).toList();

        String chosenDir = 'unknown';
        if (dirKeys.length > 1) {
          chosenDir = await _pickDirectionBottomSheet(candidates);
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
        _traceStageCandidates('Direction pool leave $scenarioTag', dirCandidates);
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
          source: usedGtfsBridge ? 'gtfs-bridge' : (usedArrivalsFallback ? 'fallback-arrivals' : 'gtfs-rt'),
        );
        _traceCandidatePool(
          'Final-selection direction pool',
          dirCandidates.take(_pickerTakePerDirection()).toList(),
          source: usedGtfsBridge ? 'gtfs-bridge' : (usedArrivalsFallback ? 'fallback-arrivals' : 'gtfs-rt'),
        );

        TripCandidate chosen;
        if (dirCandidates.length == 1) {
          chosen = dirCandidates.first;
        } else {
          final pickerLimit = _pickerTakePerDirection();
          chosen = await _pickTripInDirectionBottomSheet(
            candidates: dirCandidates.take(pickerLimit).toList(),
          );
        }
        _traceCandidate(
          'Final-selection chosen',
          chosen,
          source: usedGtfsBridge ? 'gtfs-bridge' : (usedArrivalsFallback ? 'fallback-arrivals' : 'gtfs-rt'),
        );
        _trace(
          'Final-selection reason=${usedGtfsBridge ? "gtfs-bridge" : (usedArrivalsFallback ? "fallback-arrivals" : "gtfs-rt")}',
        );
        _trace('Pipeline leave $scenarioTag chosenTripId=${chosen.tripId}');

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
        final niceStop = _stopLabel(chosen.stopId);

        setState(() {
          _selectedCandidate = chosen;
          _trackingStatus =
            'Selected ${chosen.displayTrain} → $niceStop • ETA ${_hhmm(chosen.etaLocal)} (in ${minsLeft}m) • ${_fmtDelay(chosen.delaySeconds)}'
        '${usedArrivalsFallback ? "\n(Fallback: destination arrivals)" :""}';
        });
        _traceCandidate(
          'selectedCandidate assigned',
          chosen,
          source: usedGtfsBridge ? 'gtfs-bridge' : (usedArrivalsFallback ? 'fallback-arrivals' : 'gtfs-rt'),
        );

        await _armAlarmFor(chosen, showUx: false);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tracking set (foreground prototype).')),
        );
        return;
      }
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
        final canon = _normalizeStopId(idRaw);

        if (destSeen && name.isNotEmpty) {
          nameAfterDest = name;
          break;
        }

        if (!destSeen && canon == destStopCanon) {
          destSeen = true;
          continue;
        }

        if (!destSeen && name.isNotEmpty) {
          fallbackLastName = name;
        }
      }

      if (nameAfterDest != null) {
        if (kDebugMode) {
          debugPrint('[Treep][Arrivals] Terminal via passList: $nameAfterDest for $destStopCanon');
        }
        return nameAfterDest;
      }

      if (!destSeen && fallbackLastName != null && fallbackLastName.isNotEmpty) {
        return fallbackLastName;
      }
    }

    if (to.isNotEmpty && to.toLowerCase() != destName.toLowerCase()) {
      return to;
    }
    return destName;
  }
  Future<List<TripCandidate>> _fallbackArrivalsAtDestination({
    required String trainQuery,
    required List<String> destStopIdCanons,
    String? destNameQuery,
    int limit = 100,
  }) async {
    final tq = _normalizeTrainToken(trainQuery);
    final hasTrainFilter = tq.isNotEmpty;
    _trace(
      'Destination-fallback start destinationQuery="${destNameQuery ?? ""}" trainQueryNorm="$tq" trainFilter=$hasTrainFilter',
    );

    // Try multiple stop_ids for the same station name (parent station vs platforms, etc.)
    // and merge results.
    final uniqueStops = <String>{};
    final maxStops = hasTrainFilter ? 4 : 16;
    for (final s in destStopIdCanons) {
      final canon = _normalizeStopId(s) ?? s;
      if (canon.isNotEmpty) uniqueStops.add(canon);
      if (uniqueStops.length >= maxStops) break; // keep requests small
    }
    if (uniqueStops.isEmpty) return const <TripCandidate>[];

    // Use a stable order (Set iteration order is not guaranteed).
    var orderedStops = uniqueStops.toList()..sort();

    // In broad destination fallback (trainFilter=false), widen with sibling/main station ids
    // from the destination query to avoid underfetching at big hubs (e.g. Olten variants).
    if (!hasTrainFilter && (destNameQuery ?? '').trim().isNotEmpty) {
      final extraResolved = await _resolveStopIdsFromName(destNameQuery!);
      for (final raw in extraResolved) {
        final canon = _normalizeStopId(raw) ?? raw;
        if (canon.isNotEmpty) uniqueStops.add(canon);
        if (uniqueStops.length >= maxStops) break;
      }
      orderedStops = uniqueStops.toList()..sort();
    }
    _trace(
      'Destination-fallback fetch destinationQuery="${destNameQuery ?? ""}" '
      'resolvedStopIds=[${orderedStops.join(",")}] limit=$limit',
    );

    // Warm cache so labels look nice.
    await Future.wait(orderedStops.map(_ensureStopName));
    final stopLabels = orderedStops.map((id) => _stopLabel(id)).join(' | ');
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

    // Pick one canonical destination id so duplicates across platform/child stop_ids collapse to the main station.
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
        if (!queryHasAny(group)) {
          score -= 30;
        }
      }

      if (score > bestScore) {
        bestScore = score;
        primaryDestCanon = canon;
      }
    }

    // If the user typed a plain base station name (e.g. "Solothurn"), do NOT fetch stationboards
    // for sub-stations like "Solothurn West" / "Solothurn Allmend".
    // Only widen to multiple stop_ids when the query explicitly contains such qualifiers.
    final qualifierTokens = <String>['west', 'allmend', 'sud', 'sued', 'zentrum'];
    final queryNormForStops = queryNorm; // already normalized above
    final queryWantsQualifier = qualifierTokens.any((t) => queryNormForStops.contains(t));

    final List<String> stopsToFetch = !hasTrainFilter
        ? orderedStops
        : (queryWantsQualifier ? orderedStops : <String>[primaryDestCanon]);
    _trace('Destination-fallback fetch-expanded stopIds=${stopsToFetch.join(",")}');

    final now = DateTime.now();
    // Keep only plausible near-future arrivals to avoid wild “time jumps”.
    final lowerBound = now.subtract(const Duration(seconds: 15));
    final windowEnd = now.add(const Duration(minutes: 180));
    _trace(
      'Destination-fallback window lowerBound=${lowerBound.toIso8601String()} '
      'windowEnd=${windowEnd.toIso8601String()}',
    );

    // Human label for fallback direction display.
    final destName = _stopNameCache[primaryDestCanon] ?? '';

    // Deduplicate across multiple stop_ids (platform vs parent station) and keep the “best” version.
    final allByKey = <String, TripCandidate>{};
    final filteredByKey = <String, TripCandidate>{};

    bool mergeCandidate(Map<String, TripCandidate> map, String key, TripCandidate cand) {
      final prev = map[key];
      if (prev == null) {
        map[key] = cand;
        return true;
      }
      // Prefer entries that actually have delay information.
      if (prev.delaySeconds == 0 && cand.delaySeconds != 0) {
        map[key] = cand;
        return true;
      }
      // Prefer the larger (absolute) delay if both have one.
      if (cand.delaySeconds.abs() > prev.delaySeconds.abs()) {
        map[key] = cand;
        return true;
      }
      // Otherwise keep the first.
      return false;
    }

    for (final destStopIdCanon in stopsToFetch) {
      final stationId = _toOpendataId(destStopIdCanon);

      final uri = Uri.parse(
        'https://transport.opendata.ch/v1/stationboard'
        '?id=${Uri.encodeComponent(stationId)}'
        '&type=arrival'
        '&limit=$limit',
      );

      http.Response res;
      try {
        res = await http.get(uri).timeout(const Duration(seconds: 10));
      } catch (_) {
        continue;
      }
      if (res.statusCode != 200) continue;

      final decoded = json.decode(
        utf8.decode(res.bodyBytes, allowMalformed: true),
      );

      final list = (decoded is Map) ? decoded['stationboard'] : null;
      if (list is! List || list.isEmpty) continue;
      _trace('Destination-fallback raw fetch stopId=$destStopIdCanon count=${list.length}');

      for (final item in list) {
        if (item is! Map) continue;

        final name = (item['name'] ?? '').toString(); // e.g. "S 20" / "IC 5"
        final category = (item['category'] ?? '').toString();
        final number = (item['number'] ?? '').toString();
        final catNum = (category + number).trim(); // e.g. "S20"

        final normName = _normalizeTrainToken(name);
        final normCatNum = _normalizeTrainToken(catNum);

        final matchesTrain = !hasTrainFilter ||
            _matchesTrainQuery(tq, normCatNum) ||
            _matchesTrainQuery(tq, normName);

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

        // scheduled: prefer arrivalTimestamp (type=arrival) else departureTimestamp
        final schedArrivalTs = asInt(stopMap['arrivalTimestamp']);
        final schedDepartureTs = asInt(stopMap['departureTimestamp']);
        final int? schedTs = schedArrivalTs ?? schedDepartureTs;
        if (schedTs == null || schedTs <= 0) {
          continue; // cannot compute delay without scheduled time
        }
        final schedLocal = DateTime.fromMillisecondsSinceEpoch(schedTs * 1000, isUtc: true).toLocal();

        // realtime prognosis ISO: prefer arrival else departure
        final String? progArrivalIso = prog == null ? null : prog['arrival']?.toString();
        final String? progDepartureIso = prog == null ? null : prog['departure']?.toString();

        final DateTime? progArrivalLocal = parseIsoFlexible(progArrivalIso);
        final DateTime? progDepartureLocal = parseIsoFlexible(progDepartureIso);

        DateTime? bestProg;
        int bestAbs = 1 << 30;

        void consider(DateTime? dt) {
          if (dt == null) return;
          final abs = (dt.difference(schedLocal).inSeconds).abs();
          if (abs > 6 * 60 * 60) return; // ignore insane prognosis
          if (abs < bestAbs) {
            bestAbs = abs;
            bestProg = dt;
          }
        }

        // choose prognosis time that best matches this item's schedule
        consider(progArrivalLocal);
        consider(progDepartureLocal);

        // ETA = realtime if present else scheduled
        final etaLocal = bestProg ?? schedLocal;

        if (!etaLocal.isAfter(lowerBound) || etaLocal.isAfter(windowEnd)) continue;

        // delaySeconds always derived from eta - sched
        final delaySeconds = etaLocal.difference(schedLocal).inSeconds;

        final effectiveTs = etaLocal.toUtc().millisecondsSinceEpoch ~/ 1000;

        final displayLine = catNum.isNotEmpty ? catNum : name; // e.g. "T8", "IR55"
        final lineTrim = displayLine.trim();

        // Display label: always show the public line id; only fall back to name if catNum is empty.
        String display;
        if (lineTrim.isNotEmpty) {
          display = lineTrim;
        } else {
          final nameTrim = name.trim();
          display = nameTrim.isNotEmpty ? nameTrim : 'Train';
        }

        // Deduplicate across multiple stop_ids and keep terminal/platform so big hubs don’t collapse wrongly.
        final derivedTerminalRaw = _deriveTerminalNameFromArrivalItem(item, destStopIdCanon).trim();
        final toRaw = (item['to'] ?? '').toString().trim();

        final terminalName = await _resolveFallbackTerminalLabel(
          derivedTerminalRaw: derivedTerminalRaw,
          toRaw: toRaw,
          destName: destName,
        );

        final terminalKey = _normalizeStationToken(terminalName);

        // Platform can differ and matters at big stations.
        final platform = prog?['platform'] ?? stopMap['platform'];
        final platformKey = (platform ?? '').toString().trim().toLowerCase();

        final lineKey = lineTrim.isNotEmpty ? _normalizeTrainToken(lineTrim) : _normalizeTrainToken(display);
        final key = '$effectiveTs|$lineKey|$terminalKey|$platformKey';

        final fallbackTripId = <String>[
          lineKey,
          effectiveTs.toString(),
          terminalKey,
          platformKey,
        ].join('_');

        final cand = TripCandidate(
          tripId: fallbackTripId,
          routeId: lineTrim,
          startDate: '',
          startTime: '',
          // IMPORTANT: use one canonical destination id so duplicates across platform stop_ids collapse.
          stopId: primaryDestCanon,
          etaLocal: etaLocal,
          delaySeconds: delaySeconds,
          displayTrain: display,
          vehicleLabel: _vehicleLabelFromDisplay(display),
          destinationMatched: true,
          upcomingStops: const <StopEta>[],
          terminalStopId: terminalName.isNotEmpty ? terminalName : (item['to'] ?? '').toString(),
          terminalStopIdCanon: '',
        );

        final storedAll = mergeCandidate(allByKey, key, cand);
        final storedFiltered = matchesTrain ? mergeCandidate(filteredByKey, key, cand) : false;

        if ((hasTrainFilter && storedFiltered) || (!hasTrainFilter && storedAll)) {
          final terminalRendered = _terminalLabelFor(cand);
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
    _traceStageCandidates(
      'Destination-fallback merged sample trainFilter=$hasTrainFilter',
      out,
      max: 8,
    );
    return out.take(limit).toList();
  }

Future<List<String>> _resolveStopIdsFromName(String query) async {
  final uri = Uri.parse(
    'https://transport.opendata.ch/v1/locations?query=${Uri.encodeComponent(query)}&type=station',
  );

  final res = await http.get(uri).timeout(const Duration(seconds: 10));
  if (res.statusCode != 200) return const [];

  final decoded = json.decode(
    utf8.decode(res.bodyBytes, allowMalformed: true),
  );
  if (decoded is! Map) return const [];

  final stations = decoded['stations'];
  if (stations is! List || stations.isEmpty) return const [];

  final q = query.trim().toLowerCase();

  final scored = <({String canon, double score})>[];

  for (final s in stations) {
    if (s is! Map) continue;

    final name = (s['name'] ?? '').toString();
    final rawId = (s['id'] ?? '').toString();
    final canon = _normalizeStopId(rawId);
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
      final tripShortName = _tripShortNameFromTripDescriptor(trip);
      final routeShortName = _routeShortNameFromRouteId(routeId);
      final displayTrain = routeId.isNotEmpty ? routeId : tripId;

      final displayNorm = _normalizeTrainToken(displayTrain);
      final tripNorm = _normalizeTrainToken(tripId);
      final routeNorm = _normalizeTrainToken(routeId);
      final tripShortNorm = _normalizeTrainToken(tripShortName);
      final routeShortNorm = _normalizeTrainToken(routeShortName);

      final rawLabels = <String>[displayTrain, routeId, tripId, tripShortName, routeShortName];
      final matchesTrain = tq.isEmpty || _matchesTrainQueryTokenAware(trainQuery, rawLabels);
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

        if (_stopIdMatches(stopCanon, destCanon) && matchedDest == null) {
          matchedDest = stop;
          matchedStopIdRaw = stopIdRaw;
        }
      }

      if (upcoming.isEmpty) continue;
      upcoming.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
      var usedBaselMainFallback = false;

      if (requireDestinationMatch && matchedDest == null && _isBaselMainStationQuery(destCanon)) {
        StopEta? baselMain;
        for (final s in upcoming) {
          if (_isBaselMainStationStopHint(s)) {
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
          vehicleLabel: _vehicleLabelFromDisplay(displayTrain),
          destinationMatched: matchedDest != null,
          upcomingStops: upcoming.take(40).toList(),
          terminalStopId: terminal.stopIdRaw,
          terminalStopIdCanon: terminal.stopIdCanon,
        );
      out.add(candidate);
      _trace(
        'GTFS-RT candidate found tripId=${candidate.tripId} routeId=${candidate.routeId} '
        'stopId=${candidate.stopId} etaLocal=${candidate.etaLocal.toIso8601String()} '
        'delaySeconds=${candidate.delaySeconds} terminal="${_terminalLabelFor(candidate)}" '
        'baselMainFallbackUsed=$usedBaselMainFallback',
      );
    }

    out.sort((a, b) => a.etaLocal.compareTo(b.etaLocal));
    return out.take(15).toList();
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
                separatorBuilder: (_, unusedIndex) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final s = sorted[i];
                  final mins = s.etaLocal.difference(DateTime.now()).inMinutes;
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
        final head = res.bodyBytes.take(_upcomingTripsLimit).toList();
        final hex = head.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
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
    final c = _selectedCandidate;
    final hasAlarm = _alarmIds.isNotEmpty && _alarmFirstFire != null;

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
                    child: Text(_isStartingTracking ? 'Starting…' : 'Start tracking'),
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
                        const Text('Status', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 6),
                        Text(_trackingStatus.isEmpty ? '—' : _trackingStatus),

                        if (c != null) ...[
                          const SizedBox(height: 10),
                          Text('${c.vehicleLabel}: ${c.displayTrain}'),
                          Text('Alarm at: ${_stopLabel(c.stopId)}'),
                          Text('Direction: ${_terminalLabelFor(c)}'),
                          Text('Arrives: ${_hhmm(c.etaLocal)} • ${_fmtDelay(c.delaySeconds)}'),
                        ],

                        if (hasAlarm) ...[
                          const SizedBox(height: 10),
                          Text('Alarm: armed for ${_hhmm(_alarmFirstFire!)} (repeats until you stop)'),
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
                                    onPressed: c == null ? null : () => _armAlarmFor(c, showUx: true),
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
                              onPressed: _isSelfTesting ? null : _runAlarmSelfTest,
                              icon: const Icon(Icons.volume_up_outlined),
                              label: Text(_isSelfTesting ? 'Testing…' : 'Test alarm (3s)'),
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
String _normalizeTrainToken(String s) {
  // Normalize "IC 5" == "IC5" == "ic5".
  return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _sleepLines = true;
  bool _showTipsDialog = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hintPopupEnabled = !(prefs.getBool(kPrefsSkipVolumeDialogKey) ?? false);
      final sleepEnabled = prefs.getBool(kPrefsSleepLinesEnabledKey) ?? true;
      if (!mounted) return;
      setState(() {
        _showTipsDialog = hintPopupEnabled;
        _sleepLines = sleepEnabled;
      });
    } catch (_) {}
  }

  Future<void> _setSleepLines(bool v) async {
    setState(() => _sleepLines = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPrefsSleepLinesEnabledKey, v);
  }

  Future<void> _setShowTips(bool v) async {
    setState(() => _showTipsDialog = v);
    final prefs = await SharedPreferences.getInstance();
    // We store the inverse as "skip" for backwards-compat.
    await prefs.setBool(kPrefsSkipVolumeDialogKey, !v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Sprüche aktivieren'),
            subtitle: const Text('Treep zeigt nach dem Alarm setzen zufällige Sprüche.'),
            value: _sleepLines,
            onChanged: (v) => _setSleepLines(v),
          ),
          SwitchListTile(
            title: const Text('Hinweis-Popup anzeigen'),
            subtitle: const Text('Kurzer Check (Lautstärke / Fokus / Bluetooth) vor dem Schlafen.'),
            value: _showTipsDialog,
            onChanged: (v) => _setShowTips(v),
          ),
          const Divider(height: 1),
          ListTile(
            title: const Text('Sprüche-Sammlung (bald)'),
            subtitle: const Text('Später: gesammelt / selten / trophies.'),
            trailing: const Icon(Icons.lock_outline),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Coming soon.')),
              );
            },
          ),
          ListTile(
            title: const Text('Stats (bald)'),
            subtitle: const Text('Später: Reaktionszeit, längster Sleep, usw.'),
            trailing: const Icon(Icons.lock_outline),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Coming soon.')),
              );
            },
          ),
        ],
      ),
    );
  }
}
