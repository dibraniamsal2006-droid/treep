import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:treep/services/alarm_service.dart';

void main() {
  group('AlarmTransactionCoordinator', () {
    test(
      'keeps old alarm until a successful replacement is confirmed',
      () async {
        final native = _FakeNativeAlarmGateway();
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);

        await coordinator.arm(
          selection: 'old',
          plan: _plan(100),
          requestPermissions: true,
        );
        final old = coordinator.confirmed;
        final replacementGate = Completer<NotificationScheduleResult>();
        notifications.scheduleGate = replacementGate;

        final replacing = coordinator.arm(
          selection: 'new',
          plan: _plan(200),
          requestPermissions: false,
        );
        await Future<void>.delayed(Duration.zero);

        expect(coordinator.confirmed, same(old));
        expect(coordinator.confirmed?.selection, 'old');
        expect(native.cancelledIds, isEmpty);
        expect(notifications.cancelledBatches, isEmpty);

        replacementGate.complete(
          const NotificationScheduleResult(succeeded: true, ids: [200]),
        );
        final result = await replacing;

        expect(result.succeeded, isTrue);
        expect(coordinator.confirmed?.selection, 'new');
        expect(native.cancelledIds, ['native-1']);
        expect(notifications.cancelledBatches, [
          [100],
        ]);
      },
    );

    test(
      'failed replacement retains old confirmed and selected state',
      () async {
        final native = _FakeNativeAlarmGateway();
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);

        await coordinator.arm(
          selection: 'old',
          plan: _plan(100),
          requestPermissions: true,
        );
        final old = coordinator.confirmed;
        native.failNextSchedule = true;

        final result = await coordinator.arm(
          selection: 'new',
          plan: _plan(200),
          requestPermissions: false,
        );

        expect(result.succeeded, isFalse);
        expect(result.previousRetained, isTrue);
        expect(coordinator.confirmed, same(old));
        expect(coordinator.confirmed?.selection, 'old');
        expect(native.cancelledIds, isEmpty);
        expect(notifications.cancelledBatches, [
          [200],
        ]);
      },
    );

    test('stop cleans native state when notification IDs are empty', () async {
      final native = _FakeNativeAlarmGateway();
      final notifications = _FakeNotificationGateway()..failNextSchedule = true;
      final coordinator = _coordinator(native, notifications);

      final armed = await coordinator.arm(
        selection: 'native-only',
        plan: _plan(100),
        requestPermissions: true,
      );
      expect(armed.succeeded, isTrue);
      expect(coordinator.confirmed?.notificationIds, isEmpty);

      final stopped = await coordinator.stop();

      expect(stopped.succeeded, isTrue);
      expect(coordinator.confirmed, isNull);
      expect(native.stoppedIds, ['native-1']);
      expect(native.cancelledIds, ['native-1']);
      expect(notifications.cancelledBatches, [<int>[]]);
    });

    test(
      'stop failure retains the possibly-live native alarm identity',
      () async {
        final native = _FakeNativeAlarmGateway();
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);
        await coordinator.arm(
          selection: 'old',
          plan: _plan(100),
          requestPermissions: true,
        );
        final alarmId = coordinator.confirmed!.nativeAlarm!.id;
        native.failCancellation = true;

        final stopped = await coordinator.stop();

        expect(stopped.succeeded, isFalse);
        expect(coordinator.confirmed?.nativeAlarm?.id, alarmId);
        expect(coordinator.confirmed?.hasConfirmedNativeAlarm, isTrue);
      },
    );

    test('stop invalidates an in-flight replacement', () async {
      final native = _FakeNativeAlarmGateway();
      final notifications = _FakeNotificationGateway();
      final coordinator = _coordinator(native, notifications);
      await coordinator.arm(
        selection: 'old',
        plan: _plan(100),
        requestPermissions: true,
      );
      final replacementGate = Completer<NotificationScheduleResult>();
      notifications.scheduleGate = replacementGate;
      final replacing = coordinator.arm(
        selection: 'new',
        plan: _plan(200),
        requestPermissions: false,
      );
      await Future<void>.delayed(Duration.zero);

      await coordinator.stop();
      replacementGate.complete(
        const NotificationScheduleResult(succeeded: true, ids: [200]),
      );
      final result = await replacing;

      expect(result.succeeded, isFalse);
      expect(coordinator.confirmed, isNull);
      expect(native.cancelledIds, ['native-1']);
      expect(notifications.cancelledBatches, [
        [100],
        [200],
      ]);
    });

    test('automatic replacement does not request permissions', () async {
      final native = _FakeNativeAlarmGateway();
      final notifications = _FakeNotificationGateway();
      final coordinator = _coordinator(native, notifications);

      await coordinator.arm(
        selection: 'old',
        plan: _plan(100),
        requestPermissions: true,
      );
      native.authorizationRequests = 0;
      notifications.permissionRequests = 0;

      await coordinator.arm(
        selection: 'new',
        plan: _plan(200),
        requestPermissions: false,
      );

      expect(native.authorizationRequests, 0);
      expect(notifications.permissionRequests, 0);
    });

    test(
      'initial arm follows notification and AlarmKit permission paths',
      () async {
        final native = _FakeNativeAlarmGateway(
          authorization: NativeAlarmAuthorization.notDetermined,
        );
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);

        await coordinator.arm(
          selection: 'initial',
          plan: _plan(100),
          requestPermissions: true,
        );

        expect(notifications.permissionRequests, 1);
        expect(native.authorizationChecks, 1);
        expect(native.authorizationRequests, 1);
      },
    );

    test('failed prepared-notification cleanup remains tracked', () async {
      final native = _FakeNativeAlarmGateway()..failNextSchedule = true;
      final notifications = _FakeNotificationGateway()
        ..nextScheduleResult = const NotificationScheduleResult(
          succeeded: false,
          ids: [5013],
          failure: 'cluster scheduling failed',
        )
        ..cancellationFailures.add(5013);
      final coordinator = _coordinator(native, notifications);

      final armed = await coordinator.arm(
        selection: 'failed',
        plan: _plan(5000),
        requestPermissions: true,
      );

      expect(armed.succeeded, isFalse);
      expect(coordinator.pendingNotificationCleanupIds, {5013});

      notifications.cancellationFailures.clear();
      await coordinator.stop();
      expect(coordinator.pendingNotificationCleanupIds, isEmpty);
    });
  });

  test(
    'partial notification rollback retains only cancellation failures',
    () async {
      final attempted = <int>[];
      final result = await cancelNotificationIdsIndividually(
        ids: const [5012, 5013],
        cancel: (id) async {
          attempted.add(id);
          if (id == 5013) throw StateError('deliberate rollback failure');
        },
      );

      expect(attempted, [5012, 5013]);
      expect(result.succeeded, isFalse);
      expect(result.remainingIds, [5013]);
    },
  );

  test('fixed AlarmKit confirmation accepts only scheduled and alerting', () {
    NativeAlarmRecord record(NativeAlarmState state) => NativeAlarmRecord(
      id: state.name,
      requestedFireTime: DateTime(2026, 8, 28, 12),
      scheduledFireTime: DateTime(2026, 8, 28, 12),
      state: state,
      backend: NativeAlarmBackend.alarmKit,
    );

    expect(record(NativeAlarmState.scheduled).isConfirmed, isTrue);
    expect(record(NativeAlarmState.alerting).isConfirmed, isTrue);
    expect(record(NativeAlarmState.countdown).isConfirmed, isFalse);
    expect(record(NativeAlarmState.paused).isConfirmed, isFalse);
    expect(record(NativeAlarmState.unknown).isConfirmed, isFalse);
    expect(record(NativeAlarmState.bestEffort).isConfirmed, isFalse);
  });
}

AlarmTransactionCoordinator<String> _coordinator(
  _FakeNativeAlarmGateway native,
  _FakeNotificationGateway notifications,
) {
  return AlarmTransactionCoordinator<String>(
    native: native,
    notifications: notifications,
    nativeSchedulingEnabled: true,
    trace: (_) {},
  );
}

AlarmNotificationPlan _plan(int baseId) {
  return AlarmNotificationPlan(
    baseId: baseId,
    firstFire: DateTime(2026, 8, 28, 12),
    count: 1,
    interval: const Duration(seconds: 45),
    title: 'TREEP ALARM',
    body: 'Test',
  );
}

class _FakeNotificationGateway implements AlarmNotificationGateway {
  int permissionRequests = 0;
  bool failNextSchedule = false;
  NotificationScheduleResult? nextScheduleResult;
  Completer<NotificationScheduleResult>? scheduleGate;
  final List<List<int>> cancelledBatches = [];
  final Set<int> cancellationFailures = <int>{};

  @override
  Future<AlarmOperationResult> requestPermissions() async {
    permissionRequests++;
    return const AlarmOperationResult.success();
  }

  @override
  Future<NotificationScheduleResult> schedule(
    AlarmNotificationPlan plan,
  ) async {
    final gate = scheduleGate;
    scheduleGate = null;
    if (gate != null) return gate.future;
    final configured = nextScheduleResult;
    nextScheduleResult = null;
    if (configured != null) return configured;
    if (failNextSchedule) {
      failNextSchedule = false;
      return const NotificationScheduleResult(
        succeeded: false,
        ids: [],
        failure: 'deliberate failure',
      );
    }
    return NotificationScheduleResult(succeeded: true, ids: [plan.baseId]);
  }

  @override
  Future<NotificationCancelResult> cancelIds(List<int> ids) async {
    cancelledBatches.add(List<int>.of(ids));
    final remaining = ids
        .where(cancellationFailures.contains)
        .toList(growable: false);
    return NotificationCancelResult(
      remainingIds: remaining,
      failure: remaining.isEmpty ? null : 'deliberate cancellation failure',
    );
  }
}

class _FakeNativeAlarmGateway implements NativeAlarmGateway {
  _FakeNativeAlarmGateway({
    this.authorization = NativeAlarmAuthorization.authorized,
  });

  NativeAlarmAuthorization authorization;
  bool failNextSchedule = false;
  bool failCancellation = false;
  bool failQuery = false;
  int authorizationChecks = 0;
  int authorizationRequests = 0;
  int schedules = 0;
  final List<String> cancelledIds = [];
  final List<String> stoppedIds = [];
  final Map<String, NativeAlarmRecord> activeAlarms = {};

  @override
  Future<NativeAlarmCapabilities> capabilities() async {
    return const NativeAlarmCapabilities(
      alarmKitSupported: true,
      backend: NativeAlarmBackend.alarmKit,
    );
  }

  @override
  Future<NativeAlarmAuthorization> authorizationState() async {
    authorizationChecks++;
    return authorization;
  }

  @override
  Future<NativeAlarmAuthorization> requestAuthorization() async {
    authorizationRequests++;
    authorization = NativeAlarmAuthorization.authorized;
    return authorization;
  }

  @override
  Future<NativeAlarmScheduleResult> schedule(DateTime fireAt) async {
    schedules++;
    if (failNextSchedule) {
      failNextSchedule = false;
      return const NativeAlarmScheduleResult(
        accepted: false,
        confirmed: false,
        backend: NativeAlarmBackend.alarmKit,
        failure: 'deliberate failure',
      );
    }
    final alarm = NativeAlarmRecord(
      id: 'native-$schedules',
      requestedFireTime: fireAt,
      scheduledFireTime: fireAt,
      state: NativeAlarmState.scheduled,
      backend: NativeAlarmBackend.alarmKit,
    );
    activeAlarms[alarm.id] = alarm;
    return NativeAlarmScheduleResult(
      accepted: true,
      confirmed: true,
      backend: NativeAlarmBackend.alarmKit,
      alarm: alarm,
    );
  }

  @override
  Future<NativeAlarmQueryResult> alarms() async => failQuery
      ? const NativeAlarmQueryResult(alarms: [], failure: 'query failed')
      : NativeAlarmQueryResult(alarms: activeAlarms.values.toList());

  @override
  Future<AlarmOperationResult> cancel(String alarmId) async {
    cancelledIds.add(alarmId);
    if (failCancellation) {
      return const AlarmOperationResult.failure('cancel failed');
    }
    activeAlarms.remove(alarmId);
    return const AlarmOperationResult.success();
  }

  @override
  Future<AlarmOperationResult> stopAlerting(String alarmId) async {
    stoppedIds.add(alarmId);
    return const AlarmOperationResult.success();
  }

  @override
  Future<AlarmOperationResult> startLegacyNow() async =>
      const AlarmOperationResult.success();

  @override
  Future<AlarmOperationResult> stopLegacyPlayback() async =>
      const AlarmOperationResult.success();
}
