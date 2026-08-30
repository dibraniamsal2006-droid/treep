import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

enum NativeAlarmBackend { alarmKit, legacy, unavailable }

enum NativeAlarmAuthorization {
  notDetermined,
  denied,
  authorized,
  unsupported,
  unknown,
}

enum NativeAlarmState {
  scheduled,
  countdown,
  paused,
  alerting,
  bestEffort,
  unknown,
}

enum NativeAlarmProtectionStatus {
  protected,
  paused,
  missingBeforeFire,
  missingAfterFire,
  unverified,
}

class NativeAlarmCapabilities {
  const NativeAlarmCapabilities({
    required this.alarmKitSupported,
    required this.backend,
  });

  final bool alarmKitSupported;
  final NativeAlarmBackend backend;
}

class NativeAlarmRecord {
  const NativeAlarmRecord({
    required this.id,
    required this.requestedFireTime,
    required this.scheduledFireTime,
    required this.state,
    required this.backend,
    this.sessionId,
    this.revision,
  });

  final String id;
  final DateTime requestedFireTime;
  final DateTime? scheduledFireTime;
  final NativeAlarmState state;
  final NativeAlarmBackend backend;
  final String? sessionId;
  final int? revision;

  bool get isConfirmed =>
      backend == NativeAlarmBackend.alarmKit &&
      (state == NativeAlarmState.scheduled ||
          state == NativeAlarmState.countdown ||
          state == NativeAlarmState.alerting);
}

class NativeAlarmSessionSnapshot {
  const NativeAlarmSessionSnapshot({
    required this.reconciliationAvailable,
    this.lifecycleHealthy = true,
    required this.sessionExists,
    required this.isProtected,
    required this.protectionStatus,
    this.sessionId,
    this.revision,
    this.alarmId,
    this.requestedFireTime,
    this.state = NativeAlarmState.unknown,
    this.preparedSessionId,
    this.preparedRevision,
    this.preparedAlarmId,
  });

  final bool reconciliationAvailable;
  final bool lifecycleHealthy;
  final bool sessionExists;
  final bool isProtected;
  final NativeAlarmProtectionStatus protectionStatus;
  final String? sessionId;
  final int? revision;
  final String? alarmId;
  final DateTime? requestedFireTime;
  final NativeAlarmState state;
  final String? preparedSessionId;
  final int? preparedRevision;
  final String? preparedAlarmId;

  bool currentMatches(NativeAlarmRecord alarm) =>
      sessionId == alarm.sessionId &&
      revision == alarm.revision &&
      alarmId == alarm.id;

  bool preparedMatches(NativeAlarmRecord alarm) =>
      preparedSessionId == alarm.sessionId &&
      preparedRevision == alarm.revision &&
      preparedAlarmId == alarm.id;
}

class NativeAlarmScheduleResult {
  const NativeAlarmScheduleResult({
    required this.accepted,
    required this.confirmed,
    required this.backend,
    this.alarm,
    this.failure,
    this.unresolved = false,
  });

  final bool accepted;
  final bool confirmed;
  final NativeAlarmBackend backend;
  final NativeAlarmRecord? alarm;
  final String? failure;
  final bool unresolved;
}

class NativeAlarmQueryResult {
  const NativeAlarmQueryResult({required this.alarms, this.failure});
  final List<NativeAlarmRecord> alarms;
  final String? failure;
}

class AlarmOperationResult {
  const AlarmOperationResult.success()
    : succeeded = true,
      isAmbiguous = false,
      failure = null;
  const AlarmOperationResult.failure(this.failure)
    : succeeded = false,
      isAmbiguous = false;
  const AlarmOperationResult.ambiguous(this.failure)
    : succeeded = false,
      isAmbiguous = true;

  final bool succeeded;
  final bool isAmbiguous;
  final String? failure;
}

abstract interface class NativeAlarmGateway {
  Future<NativeAlarmCapabilities> capabilities();
  Future<NativeAlarmAuthorization> authorizationState();
  Future<NativeAlarmAuthorization> requestAuthorization();
  Future<NativeAlarmScheduleResult> schedule(DateTime fireAt);
  Future<AlarmOperationResult> promoteSession(NativeAlarmRecord alarm);
  Future<NativeAlarmSessionSnapshot> sessionSnapshot();
  Future<NativeAlarmQueryResult> alarms();
  Future<AlarmOperationResult> cancel(NativeAlarmRecord alarm);
  Future<AlarmOperationResult> stopAlerting(NativeAlarmRecord alarm);
  Future<AlarmOperationResult> startLegacyNow();
  Future<AlarmOperationResult> stopLegacyPlayback();
}

class MethodChannelNativeAlarmGateway implements NativeAlarmGateway {
  const MethodChannelNativeAlarmGateway();

  static const _channel = MethodChannel('treep/alarm');

  @override
  Future<NativeAlarmCapabilities> capabilities() async {
    try {
      final value = _map(await _channel.invokeMethod<dynamic>('capabilities'));
      return NativeAlarmCapabilities(
        alarmKitSupported: value['alarmKitSupported'] == true,
        backend: _backend(value['backend']),
      );
    } catch (error) {
      debugPrint('[alarm] capabilities failed: $error');
      return const NativeAlarmCapabilities(
        alarmKitSupported: false,
        backend: NativeAlarmBackend.unavailable,
      );
    }
  }

  @override
  Future<NativeAlarmAuthorization> authorizationState() async {
    try {
      final value = _map(
        await _channel.invokeMethod<dynamic>('authorizationState'),
      );
      return _authorization(value['authorization']);
    } catch (error) {
      debugPrint('[alarm] authorization check failed: $error');
      return NativeAlarmAuthorization.unknown;
    }
  }

  @override
  Future<NativeAlarmAuthorization> requestAuthorization() async {
    try {
      final value = _map(
        await _channel.invokeMethod<dynamic>('requestAuthorization'),
      );
      return _authorization(value['authorization']);
    } catch (error) {
      debugPrint('[alarm] authorization request failed: $error');
      return NativeAlarmAuthorization.unknown;
    }
  }

  @override
  Future<NativeAlarmScheduleResult> schedule(DateTime fireAt) async {
    try {
      final value = _map(
        await _channel.invokeMethod<dynamic>('schedule', {
          'fireTimeMs': fireAt.millisecondsSinceEpoch,
        }),
      );
      final rawAlarm = value['alarm'];
      final alarm = rawAlarm is Map
          ? _record(_map(rawAlarm), fallbackFireTime: fireAt)
          : null;
      return NativeAlarmScheduleResult(
        accepted: value['accepted'] == true,
        confirmed: value['confirmed'] == true && alarm?.isConfirmed == true,
        backend: _backend(value['backend']),
        alarm: alarm,
        failure: value['failure']?.toString(),
        unresolved: value['unresolved'] == true,
      );
    } catch (error) {
      return NativeAlarmScheduleResult(
        accepted: false,
        confirmed: false,
        backend: NativeAlarmBackend.unavailable,
        failure: error.toString(),
      );
    }
  }

  @override
  Future<AlarmOperationResult> promoteSession(NativeAlarmRecord alarm) {
    final sessionId = alarm.sessionId;
    final revision = alarm.revision;
    if (sessionId == null || revision == null) {
      return Future.value(
        const AlarmOperationResult.failure(
          'Scheduled AlarmKit alarm has no prepared session identity',
        ),
      );
    }
    return _operation('promoteSession', {
      'sessionId': sessionId,
      'revision': revision,
      'alarmId': alarm.id,
    });
  }

  @override
  Future<NativeAlarmSessionSnapshot> sessionSnapshot() async {
    try {
      final value = _map(
        await _channel.invokeMethod<dynamic>('sessionSnapshot'),
      );
      return NativeAlarmSessionSnapshot(
        reconciliationAvailable: value['reconciliationAvailable'] == true,
        lifecycleHealthy: value['lifecycleHealth'] == 'healthy',
        sessionExists: value['sessionExists'] == true,
        isProtected: value['protected'] == true,
        protectionStatus: _protectionStatus(value['protectionStatus']),
        sessionId: value['sessionId']?.toString(),
        revision: (value['revision'] as num?)?.round(),
        alarmId: value['alarmId']?.toString(),
        requestedFireTime: _date(value['requestedFireTimeMs']),
        state: _state(value['state']),
        preparedSessionId: value['preparedSessionId']?.toString(),
        preparedRevision: (value['preparedRevision'] as num?)?.round(),
        preparedAlarmId: value['preparedAlarmId']?.toString(),
      );
    } catch (error) {
      debugPrint('[alarm] native session snapshot failed: $error');
      return const NativeAlarmSessionSnapshot(
        reconciliationAvailable: false,
        sessionExists: false,
        isProtected: false,
        protectionStatus: NativeAlarmProtectionStatus.unverified,
      );
    }
  }

  @override
  Future<NativeAlarmQueryResult> alarms() async {
    try {
      final value = _map(await _channel.invokeMethod<dynamic>('alarms'));
      final raw = value['alarms'];
      final alarms = raw is List
          ? raw
                .whereType<Map>()
                .map((item) => _record(_map(item)))
                .toList(growable: false)
          : const <NativeAlarmRecord>[];
      return NativeAlarmQueryResult(alarms: alarms);
    } catch (error) {
      debugPrint('[alarm] reconciliation failed: $error');
      return NativeAlarmQueryResult(
        alarms: const <NativeAlarmRecord>[],
        failure: error.toString(),
      );
    }
  }

  @override
  Future<AlarmOperationResult> cancel(NativeAlarmRecord alarm) =>
      _operation('cancel', {
        'alarmId': alarm.id,
        if (alarm.sessionId != null) 'sessionId': alarm.sessionId,
        if (alarm.revision != null) 'revision': alarm.revision,
      });
  @override
  Future<AlarmOperationResult> stopAlerting(NativeAlarmRecord alarm) =>
      _operation('stopAlerting', {
        'alarmId': alarm.id,
        if (alarm.sessionId != null) 'sessionId': alarm.sessionId,
        if (alarm.revision != null) 'revision': alarm.revision,
      });
  @override
  Future<AlarmOperationResult> startLegacyNow() =>
      _operation('startNow', {'loop': true});
  @override
  Future<AlarmOperationResult> stopLegacyPlayback() => _operation('stopLegacy');

  Future<AlarmOperationResult> _operation(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      final raw = await _channel.invokeMethod<dynamic>(method, arguments);
      if (raw is! Map) {
        return AlarmOperationResult.ambiguous(
          '$method returned malformed data',
        );
      }
      final value = _map(raw);
      if (value['succeeded'] is! bool) {
        return AlarmOperationResult.ambiguous('$method returned no outcome');
      }
      return value['succeeded'] == true
          ? const AlarmOperationResult.success()
          : AlarmOperationResult.failure(
              value['failure']?.toString() ?? '$method failed',
            );
    } catch (error) {
      return AlarmOperationResult.ambiguous(error.toString());
    }
  }

  static NativeAlarmRecord _record(
    Map<String, dynamic> value, {
    DateTime? fallbackFireTime,
  }) {
    return NativeAlarmRecord(
      id: value['id']?.toString() ?? '',
      requestedFireTime:
          _date(value['requestedFireTimeMs']) ??
          fallbackFireTime ??
          DateTime.fromMillisecondsSinceEpoch(0),
      scheduledFireTime: _date(value['scheduledFireTimeMs']),
      state: _state(value['state']),
      backend: _backend(value['backend']),
      sessionId: value['sessionId']?.toString(),
      revision: (value['revision'] as num?)?.round(),
    );
  }

  static Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : const {};
  static DateTime? _date(dynamic value) =>
      value is num ? DateTime.fromMillisecondsSinceEpoch(value.round()) : null;
  static NativeAlarmBackend _backend(dynamic value) => switch ('$value') {
    'alarmkit' => NativeAlarmBackend.alarmKit,
    'legacy' => NativeAlarmBackend.legacy,
    _ => NativeAlarmBackend.unavailable,
  };
  static NativeAlarmAuthorization _authorization(dynamic value) =>
      switch ('$value') {
        'notDetermined' => NativeAlarmAuthorization.notDetermined,
        'denied' => NativeAlarmAuthorization.denied,
        'authorized' => NativeAlarmAuthorization.authorized,
        'unsupported' => NativeAlarmAuthorization.unsupported,
        _ => NativeAlarmAuthorization.unknown,
      };
  static NativeAlarmState _state(dynamic value) => switch ('$value') {
    'scheduled' => NativeAlarmState.scheduled,
    'countdown' => NativeAlarmState.countdown,
    'paused' => NativeAlarmState.paused,
    'alerting' => NativeAlarmState.alerting,
    'bestEffort' => NativeAlarmState.bestEffort,
    _ => NativeAlarmState.unknown,
  };
  static NativeAlarmProtectionStatus _protectionStatus(dynamic value) =>
      switch ('$value') {
        'protected' => NativeAlarmProtectionStatus.protected,
        'paused' => NativeAlarmProtectionStatus.paused,
        'missingBeforeFire' => NativeAlarmProtectionStatus.missingBeforeFire,
        'missingAfterFire' => NativeAlarmProtectionStatus.missingAfterFire,
        _ => NativeAlarmProtectionStatus.unverified,
      };
}

class AlarmNotificationPlan {
  const AlarmNotificationPlan({
    required this.baseId,
    required this.firstFire,
    required this.count,
    required this.interval,
    required this.title,
    required this.body,
  });
  final int baseId;
  final DateTime firstFire;
  final int count;
  final Duration interval;
  final String title;
  final String body;
}

class NotificationScheduleResult {
  const NotificationScheduleResult({
    required this.succeeded,
    required this.ids,
    this.failure,
  });
  final bool succeeded;
  final List<int> ids;
  final String? failure;
}

class NotificationCancelResult {
  const NotificationCancelResult({required this.remainingIds, this.failure});

  final List<int> remainingIds;
  final String? failure;
  bool get succeeded => remainingIds.isEmpty;
}

abstract interface class AlarmNotificationGateway {
  Future<AlarmOperationResult> requestPermissions();
  Future<NotificationScheduleResult> schedule(AlarmNotificationPlan plan);
  Future<NotificationCancelResult> cancelIds(List<int> ids);
}

class PluginAlarmNotificationGateway implements AlarmNotificationGateway {
  const PluginAlarmNotificationGateway();

  @override
  Future<AlarmOperationResult> requestPermissions() async {
    try {
      await NotificationService.requestPermissions();
      return const AlarmOperationResult.success();
    } catch (error) {
      return AlarmOperationResult.failure(error.toString());
    }
  }

  @override
  Future<NotificationScheduleResult> schedule(AlarmNotificationPlan plan) =>
      NotificationService.scheduleAlarmCluster(plan);

  @override
  Future<NotificationCancelResult> cancelIds(List<int> ids) =>
      NotificationService.cancelIds(ids);
}

class ConfirmedAlarm<T> {
  const ConfirmedAlarm({
    required this.selection,
    required this.fireTime,
    required this.notificationIds,
    required this.notificationFallbackConfirmed,
    required this.nativeAlarm,
  });
  final T selection;
  final DateTime fireTime;
  final List<int> notificationIds;
  final bool notificationFallbackConfirmed;
  final NativeAlarmRecord? nativeAlarm;
  bool get hasConfirmedNativeAlarm => nativeAlarm?.isConfirmed == true;
  bool get hasNotificationFallback =>
      notificationFallbackConfirmed && notificationIds.isNotEmpty;
}

class AlarmArmResult<T> {
  const AlarmArmResult({
    required this.succeeded,
    required this.confirmed,
    required this.previousRetained,
    required this.failures,
    this.transactionUnverified = false,
  });
  final bool succeeded;
  final ConfirmedAlarm<T>? confirmed;
  final bool previousRetained;
  final List<String> failures;
  final bool transactionUnverified;
}

class AlarmStopResult {
  const AlarmStopResult({required this.succeeded, required this.failures});
  final bool succeeded;
  final List<String> failures;
}

typedef AlarmTrace = void Function(String message);

class AlarmTransactionCoordinator<T> {
  AlarmTransactionCoordinator({
    required NativeAlarmGateway native,
    required AlarmNotificationGateway notifications,
    required bool nativeSchedulingEnabled,
    AlarmTrace? trace,
  }) : _native = native,
       _notifications = notifications,
       _nativeSchedulingEnabled = nativeSchedulingEnabled,
       _trace = trace ?? debugPrint;

  final NativeAlarmGateway _native;
  final AlarmNotificationGateway _notifications;
  final bool _nativeSchedulingEnabled;
  final AlarmTrace _trace;
  int _generation = 0;
  final Set<int> _pendingNotificationCleanupIds = <int>{};
  final Set<Completer<void>> _nativeTransactions = <Completer<void>>{};
  Future<AlarmStopResult>? _activeStop;
  ConfirmedAlarm<T>? confirmed;
  ConfirmedAlarm<T>? _unresolvedNativeTransaction;

  Set<int> get pendingNotificationCleanupIds =>
      Set<int>.unmodifiable(_pendingNotificationCleanupIds);
  bool get hasUnresolvedNativeTransaction =>
      _unresolvedNativeTransaction != null;

  Future<AlarmArmResult<T>> arm({
    required T selection,
    required AlarmNotificationPlan plan,
    required bool requestPermissions,
  }) async {
    if (_unresolvedNativeTransaction != null ||
        _activeStop != null ||
        _nativeTransactions.isNotEmpty) {
      return AlarmArmResult<T>(
        succeeded: false,
        confirmed: confirmed,
        previousRetained: false,
        failures: const [
          'native alarm lifecycle is unresolved or still in progress; stop or relaunch before re-arming',
        ],
        transactionUnverified: true,
      );
    }
    final generation = ++_generation;
    final previous = confirmed;
    _trace(
      previous == null
          ? '[alarm] initial-arm requested'
          : '[alarm] replacement requested old=${previous.nativeAlarm?.id ?? "fallback"} newFire=${plan.firstFire.toIso8601String()}',
    );
    final failures = <String>[];
    if (requestPermissions) {
      final permission = await _notifications.requestPermissions();
      if (!permission.succeeded) {
        failures.add('notification permission: ${permission.failure}');
      }
    }

    var capabilities = const NativeAlarmCapabilities(
      alarmKitSupported: false,
      backend: NativeAlarmBackend.unavailable,
    );
    var authorization = NativeAlarmAuthorization.unsupported;
    if (_nativeSchedulingEnabled) {
      capabilities = await _native.capabilities();
      final backend = switch (capabilities.backend) {
        NativeAlarmBackend.alarmKit => 'alarmkit',
        NativeAlarmBackend.legacy => 'legacy',
        NativeAlarmBackend.unavailable => 'unavailable',
      };
      _trace('[alarm] backend=$backend');
      if (capabilities.alarmKitSupported) {
        authorization = await _native.authorizationState();
        _trace('[alarm] authorization=${authorization.name}');
        if (requestPermissions &&
            authorization == NativeAlarmAuthorization.notDetermined) {
          authorization = await _native.requestAuthorization();
          _trace('[alarm] authorization=${authorization.name}');
        }
      }
    }

    final notifications = await _notifications.schedule(plan);
    if (!notifications.succeeded) {
      failures.add('notification schedule: ${notifications.failure}');
    }
    if (generation != _generation) {
      final preparedNotifications = ConfirmedAlarm<T>(
        selection: selection,
        fireTime: plan.firstFire,
        notificationIds: List<int>.unmodifiable(notifications.ids),
        notificationFallbackConfirmed: notifications.succeeded,
        nativeAlarm: null,
      );
      await _discard(preparedNotifications, failures);
      failures.add('arm superseded by a newer lifecycle operation');
      return AlarmArmResult<T>(
        succeeded: false,
        confirmed: confirmed,
        previousRetained: confirmed != null,
        failures: List<String>.unmodifiable(failures),
      );
    }

    NativeAlarmScheduleResult? native;
    final useAlarmKit =
        capabilities.alarmKitSupported &&
        authorization == NativeAlarmAuthorization.authorized;
    final useLegacy =
        _nativeSchedulingEnabled && !capabilities.alarmKitSupported;
    final nativeTransaction = useAlarmKit || useLegacy
        ? _beginNativeTransaction()
        : null;
    try {
      if (useAlarmKit || useLegacy) {
        _trace('[alarm] native schedule requested');
        native = await _native.schedule(plan.firstFire);
        if (native.confirmed) {
          _trace('[alarm] native schedule confirmed id=${native.alarm?.id}');
        } else if (!native.accepted || native.failure != null) {
          failures.add('native schedule: ${native.failure ?? "not confirmed"}');
        }
      } else if (capabilities.alarmKitSupported) {
        failures.add('AlarmKit authorization=${authorization.name}');
      }

      final prepared = ConfirmedAlarm<T>(
        selection: selection,
        fireTime: plan.firstFire,
        notificationIds: List<int>.unmodifiable(notifications.ids),
        notificationFallbackConfirmed: notifications.succeeded,
        nativeAlarm: native?.alarm,
      );
      if (generation != _generation) {
        await _discard(prepared, failures);
        failures.add('arm superseded by a newer lifecycle operation');
        return AlarmArmResult<T>(
          succeeded: false,
          confirmed: confirmed,
          previousRetained: confirmed != null,
          failures: List<String>.unmodifiable(failures),
          transactionUnverified: _unresolvedNativeTransaction != null,
        );
      }
      if (native?.unresolved == true) {
        _unresolvedNativeTransaction = prepared;
        failures.add('native schedule ownership remains unverified');
        _trace(
          '[alarm] native schedule outcome unverified; owned alarm retained id=${prepared.nativeAlarm?.id}',
        );
        return AlarmArmResult<T>(
          succeeded: false,
          confirmed: previous,
          previousRetained: previous != null,
          failures: List<String>.unmodifiable(failures),
          transactionUnverified: true,
        );
      }
      // A replacement may not silently downgrade an existing confirmed
      // AlarmKit alarm. On legacy platforms, the completed notification
      // cluster is the confirmed protection path.
      final usable = useAlarmKit
          ? prepared.hasConfirmedNativeAlarm
          : previous?.hasConfirmedNativeAlarm == true
          ? prepared.hasConfirmedNativeAlarm
          : prepared.hasConfirmedNativeAlarm ||
                prepared.hasNotificationFallback;
      if (!usable) {
        await _discard(prepared, failures);
        if (previous != null) {
          _trace('[alarm] replacement failed; previous retained');
        }
        return AlarmArmResult<T>(
          succeeded: false,
          confirmed: previous,
          previousRetained: previous != null,
          failures: List<String>.unmodifiable(failures),
          transactionUnverified: _unresolvedNativeTransaction != null,
        );
      }

      final preparedNative = prepared.nativeAlarm;
      if (preparedNative?.backend == NativeAlarmBackend.alarmKit) {
        final promotion = await _native.promoteSession(preparedNative!);
        if (generation != _generation) {
          await _discard(prepared, failures);
          failures.add('arm superseded during native session promotion');
          return AlarmArmResult<T>(
            succeeded: false,
            confirmed: confirmed,
            previousRetained: confirmed != null,
            failures: List<String>.unmodifiable(failures),
            transactionUnverified: _unresolvedNativeTransaction != null,
          );
        }
        if (!promotion.succeeded) {
          failures.add('native session promotion: ${promotion.failure}');
          if (promotion.isAmbiguous) {
            final snapshot = await _native.sessionSnapshot();
            if (snapshot.reconciliationAvailable &&
                snapshot.lifecycleHealthy &&
                snapshot.isProtected &&
                snapshot.currentMatches(preparedNative)) {
              _trace(
                '[alarm] ambiguous promotion reconciled as committed id=${preparedNative.id}',
              );
            } else if (_snapshotProvesPreparedNotCommitted(
              snapshot,
              preparedNative,
              previous?.nativeAlarm,
            )) {
              await _discard(prepared, failures);
              if (previous != null) {
                _trace('[alarm] replacement failed; previous retained');
              }
              return AlarmArmResult<T>(
                succeeded: false,
                confirmed: previous,
                previousRetained: previous != null,
                failures: List<String>.unmodifiable(failures),
                transactionUnverified: _unresolvedNativeTransaction != null,
              );
            } else {
              // The bridge may have lost the response after native commit.
              // Keep both protection paths until explicit stop or restart.
              _unresolvedNativeTransaction = prepared;
              _trace(
                '[alarm] promotion outcome unverified; prepared alarm retained id=${preparedNative.id}',
              );
              return AlarmArmResult<T>(
                succeeded: false,
                confirmed: previous,
                previousRetained: false,
                failures: List<String>.unmodifiable(failures),
                transactionUnverified: true,
              );
            }
          } else {
            await _discard(prepared, failures);
            if (previous != null) {
              _trace('[alarm] replacement failed; previous retained');
            }
            return AlarmArmResult<T>(
              succeeded: false,
              confirmed: previous,
              previousRetained: previous != null,
              failures: List<String>.unmodifiable(failures),
              transactionUnverified: _unresolvedNativeTransaction != null,
            );
          }
        }
      }

      // Promote B before retiring A. Retirement failure can only leave
      // duplicate protection; it cannot remove the newly confirmed alarm.
      confirmed = prepared;
      _unresolvedNativeTransaction = null;
      if (previous != null) {
        _trace(
          '[alarm] replacement confirmed new=${prepared.nativeAlarm?.id ?? "fallback"}',
        );
        final remaining = await _retire(previous, failures);
        if (remaining != null) {
          _pendingNotificationCleanupIds.addAll(remaining.notificationIds);
        }
      }
      if (failures.isNotEmpty) {
        _trace(
          '[alarm] arm confirmed with fallback warnings: ${failures.join("; ")}',
        );
      }
      return AlarmArmResult<T>(
        succeeded: true,
        confirmed: prepared,
        previousRetained: false,
        failures: List<String>.unmodifiable(failures),
      );
    } finally {
      if (nativeTransaction != null) {
        _finishNativeTransaction(nativeTransaction);
      }
    }
  }

  Future<AlarmStopResult> stop() {
    final active = _activeStop;
    if (active != null) return active;
    final stopping = _stopAndRelease();
    _activeStop = stopping;
    return stopping;
  }

  Future<AlarmStopResult> _stopAndRelease() async {
    try {
      return await _stop();
    } finally {
      _activeStop = null;
    }
  }

  Future<AlarmStopResult> _stop() async {
    final generation = ++_generation;
    final current = confirmed;
    final failures = <String>[];
    var legacyRemoved = true;
    if (_nativeSchedulingEnabled) {
      final legacy = await _native.stopLegacyPlayback();
      legacyRemoved = legacy.succeeded;
      if (!legacy.succeeded) failures.add('legacy stop: ${legacy.failure}');
    }
    ConfirmedAlarm<T>? remaining;
    if (current != null) {
      remaining = await _retire(
        current,
        failures,
        stopAlerting: true,
        legacyRemoved: legacyRemoved,
      );
    }
    await _waitForNativeTransactions();
    final unresolved = _unresolvedNativeTransaction;
    if (unresolved != null &&
        unresolved.nativeAlarm?.id != current?.nativeAlarm?.id) {
      final unresolvedRemaining = await _retire(
        unresolved,
        failures,
        stopAlerting: true,
        legacyRemoved: legacyRemoved,
      );
      if (unresolvedRemaining == null) {
        _unresolvedNativeTransaction = null;
      } else {
        _unresolvedNativeTransaction = unresolvedRemaining;
      }
    }
    if (_pendingNotificationCleanupIds.isNotEmpty) {
      final pending = await _notifications.cancelIds(
        _pendingNotificationCleanupIds.toList(growable: false),
      );
      _pendingNotificationCleanupIds
        ..clear()
        ..addAll(pending.remainingIds);
      if (!pending.succeeded) {
        failures.add('pending notification cleanup: ${pending.failure}');
      }
    }
    if (generation == _generation) {
      confirmed = remaining;
    }
    return AlarmStopResult(
      succeeded:
          failures.isEmpty &&
          remaining == null &&
          _unresolvedNativeTransaction == null &&
          _pendingNotificationCleanupIds.isEmpty,
      failures: List<String>.unmodifiable(failures),
    );
  }

  bool _snapshotProvesPreparedNotCommitted(
    NativeAlarmSessionSnapshot snapshot,
    NativeAlarmRecord prepared,
    NativeAlarmRecord? previous,
  ) {
    if (!snapshot.reconciliationAvailable ||
        !snapshot.lifecycleHealthy ||
        !snapshot.preparedMatches(prepared) ||
        !snapshot.isProtected) {
      return false;
    }
    if (previous == null || previous.backend != NativeAlarmBackend.alarmKit) {
      return false;
    }
    return snapshot.currentMatches(previous);
  }

  Future<void> _discard(ConfirmedAlarm<T> alarm, List<String> failures) async {
    final remaining = await _retire(alarm, failures);
    if (remaining == null) return;
    _pendingNotificationCleanupIds.addAll(remaining.notificationIds);
    if (remaining.nativeAlarm != null) {
      _unresolvedNativeTransaction = remaining;
      _trace(
        '[alarm] prepared cleanup unverified; owned alarm retained id=${remaining.nativeAlarm?.id}',
      );
    }
  }

  Completer<void> _beginNativeTransaction() {
    final transaction = Completer<void>();
    _nativeTransactions.add(transaction);
    return transaction;
  }

  void _finishNativeTransaction(Completer<void> transaction) {
    _nativeTransactions.remove(transaction);
    if (!transaction.isCompleted) transaction.complete();
  }

  Future<void> _waitForNativeTransactions() async {
    while (_nativeTransactions.isNotEmpty) {
      final active = _nativeTransactions.toList(growable: false);
      await Future.wait(active.map((transaction) => transaction.future));
    }
  }

  Future<ConfirmedAlarm<T>?> _retire(
    ConfirmedAlarm<T> alarm,
    List<String> failures, {
    bool stopAlerting = false,
    bool legacyRemoved = true,
  }) async {
    final native = alarm.nativeAlarm;
    NativeAlarmRecord? remainingNative;
    if (native?.backend == NativeAlarmBackend.alarmKit) {
      AlarmOperationResult? stopResult;
      if (stopAlerting) {
        stopResult = await _native.stopAlerting(native!);
        if (!stopResult.succeeded) {
          _trace('[alarm] native stop failed id=${native.id}');
        }
      }
      _trace('[alarm] native cancel requested id=${native!.id}');
      final cancelResult = await _native.cancel(native);
      if (!cancelResult.succeeded) {
        _trace('[alarm] native cancel failed id=${native.id}');
        final query = await _native.alarms();
        if (query.failure != null) {
          failures.add('native cancel: ${cancelResult.failure}');
          failures.add('native reconciliation: ${query.failure}');
          remainingNative = native;
        } else {
          final matches = query.alarms.where(
            (candidate) => candidate.id == native.id,
          );
          remainingNative = matches.isEmpty ? null : matches.first;
          if (remainingNative != null) {
            failures.add('native cancel: ${cancelResult.failure}');
          } else {
            _trace('[alarm] native removal confirmed by reconciliation');
          }
        }
      }
      if (remainingNative != null && stopResult?.succeeded == false) {
        failures.add('native stop: ${stopResult?.failure}');
      }
    } else if (native?.backend == NativeAlarmBackend.legacy && !legacyRemoved) {
      remainingNative = native;
    }

    // Intentionally called even for an empty list (O4 regression guard).
    final notifications = await _notifications.cancelIds(alarm.notificationIds);
    if (!notifications.succeeded) {
      failures.add('notification cancel: ${notifications.failure}');
    }
    if (remainingNative == null && notifications.remainingIds.isEmpty) {
      return null;
    }
    return ConfirmedAlarm<T>(
      selection: alarm.selection,
      fireTime: alarm.fireTime,
      notificationIds: List<int>.unmodifiable(notifications.remainingIds),
      notificationFallbackConfirmed: alarm.notificationFallbackConfirmed,
      nativeAlarm: remainingNative,
    );
  }
}

@visibleForTesting
Future<NotificationCancelResult> cancelNotificationIdsIndividually({
  required Iterable<int> ids,
  required Future<void> Function(int id) cancel,
}) async {
  final remaining = <int>[];
  Object? firstFailure;
  for (final id in ids) {
    try {
      await cancel(id);
    } catch (error) {
      firstFailure ??= error;
      remaining.add(id);
    }
  }
  return NotificationCancelResult(
    remainingIds: List<int>.unmodifiable(remaining),
    failure: firstFailure == null
        ? null
        : '${remaining.length} notification cancellation(s) failed: $firstFailure',
  );
}

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
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
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
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    await ios?.requestPermissions(alert: true, badge: true, sound: true);

    // macOS (schadet nicht)
    final macos = _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >();
    await macos?.requestPermissions(alert: true, badge: true, sound: true);

    // Android 13+
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.requestNotificationsPermission();
  }

  static Future<NotificationCancelResult> cancelIds(List<int> ids) =>
      cancelNotificationIdsIndividually(
        ids: ids,
        cancel: (id) => _plugin.cancel(id),
      );

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

  static Future<NotificationScheduleResult> scheduleAlarmCluster(
    AlarmNotificationPlan plan,
  ) async {
    final details = _details();
    final scheduledIds = <int>[];

    // iOS (and sometimes macOS) will throw if *any* scheduled date is not strictly in the future.
    // When users set an alarm very close to “now”, the conversion to TZDateTime plus scheduling
    // overhead can make the first item appear "in the past" by milliseconds.
    // So we clamp each scheduled time to be at least 2 seconds in the future.
    final minFuture = tz.TZDateTime.now(
      tz.local,
    ).add(const Duration(seconds: 2));

    try {
      for (int i = 0; i < plan.count; i++) {
        final when = plan.firstFire.add(plan.interval * i);
        var zdt = tz.TZDateTime.from(when, tz.local);
        if (zdt.isBefore(minFuture)) {
          zdt = minFuture;
        }
        final id = plan.baseId + i;
        await _plugin.zonedSchedule(
          id,
          plan.title,
          plan.body,
          zdt,
          details,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          payload: 'treep_alarm',
        );
        scheduledIds.add(id);
      }
      return NotificationScheduleResult(
        succeeded: true,
        ids: List<int>.unmodifiable(scheduledIds),
      );
    } catch (error) {
      final rollback = await cancelNotificationIdsIndividually(
        ids: scheduledIds,
        cancel: (id) => _plugin.cancel(id),
      );
      if (!rollback.succeeded) {
        debugPrint(
          '[alarm] notification rollback incomplete remaining=${rollback.remainingIds.length}',
        );
      }
      return NotificationScheduleResult(
        succeeded: false,
        ids: rollback.remainingIds,
        failure: rollback.failure == null
            ? error.toString()
            : '$error; ${rollback.failure}',
      );
    }
  }
}
