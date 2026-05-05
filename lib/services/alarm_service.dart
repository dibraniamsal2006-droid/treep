import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

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
