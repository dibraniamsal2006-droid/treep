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
        expect(native.lifecycleEvents, [
          'promote:native-1',
          'promote:native-2',
          'cancel:native-1',
        ]);
        expect(notifications.cancelledBatches, [
          [100],
        ]);
      },
    );

    test('failed native session promotion leaves old alarm current', () async {
      final native = _FakeNativeAlarmGateway();
      final notifications = _FakeNotificationGateway();
      final coordinator = _coordinator(native, notifications);
      await coordinator.arm(
        selection: 'old',
        plan: _plan(100),
        requestPermissions: true,
      );
      final old = coordinator.confirmed;
      native.failPromotion = true;

      final result = await coordinator.arm(
        selection: 'new',
        plan: _plan(200),
        requestPermissions: false,
      );

      expect(result.succeeded, isFalse);
      expect(result.previousRetained, isTrue);
      expect(coordinator.confirmed, same(old));
      expect(native.cancelledIds, ['native-2']);
      expect(native.committedAlarm?.id, 'native-1');
    });

    test(
      'lost promotion response keeps B when snapshot proves native commit',
      () async {
        final native = _FakeNativeAlarmGateway();
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);
        await coordinator.arm(
          selection: 'old',
          plan: _plan(100),
          requestPermissions: true,
        );
        native.commitThenLosePromotionResponse = true;

        final result = await coordinator.arm(
          selection: 'new',
          plan: _plan(200),
          requestPermissions: false,
        );

        expect(result.succeeded, isTrue);
        expect(result.confirmed?.nativeAlarm?.id, 'native-2');
        expect(native.committedAlarm?.id, 'native-2');
        expect(native.cancelledIds, isNot(contains('native-2')));
      },
    );

    test(
      'exact B identity without proven protection remains unresolved',
      () async {
        final native = _FakeNativeAlarmGateway();
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);
        await coordinator.arm(
          selection: 'old',
          plan: _plan(100),
          requestPermissions: true,
        );
        native
          ..commitThenLosePromotionResponse = true
          ..snapshotProtectedOverride = false;

        final result = await coordinator.arm(
          selection: 'new',
          plan: _plan(200),
          requestPermissions: false,
        );

        expect(result.succeeded, isFalse);
        expect(result.transactionUnverified, isTrue);
        expect(coordinator.hasUnresolvedNativeTransaction, isTrue);
        expect(native.committedAlarm?.id, 'native-2');
        expect(native.cancelledIds, isNot(contains('native-2')));
      },
    );

    test(
      'ambiguous failed promotion rolls B back when A is proven current',
      () async {
        final native = _FakeNativeAlarmGateway();
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);
        await coordinator.arm(
          selection: 'old',
          plan: _plan(100),
          requestPermissions: true,
        );
        native.ambiguousPromotionWithoutCommit = true;

        final result = await coordinator.arm(
          selection: 'new',
          plan: _plan(200),
          requestPermissions: false,
        );

        expect(result.succeeded, isFalse);
        expect(result.previousRetained, isTrue);
        expect(coordinator.confirmed?.selection, 'old');
        expect(native.cancelledIds, ['native-2']);
      },
    );

    test(
      'unprotected A snapshot cannot authorize ambiguous B rollback',
      () async {
        final native = _FakeNativeAlarmGateway();
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);
        await coordinator.arm(
          selection: 'old',
          plan: _plan(100),
          requestPermissions: true,
        );
        native
          ..ambiguousPromotionWithoutCommit = true
          ..snapshotProtectedOverride = false;

        final result = await coordinator.arm(
          selection: 'new',
          plan: _plan(200),
          requestPermissions: false,
        );

        expect(result.succeeded, isFalse);
        expect(result.transactionUnverified, isTrue);
        expect(coordinator.hasUnresolvedNativeTransaction, isTrue);
        expect(native.committedAlarm?.id, 'native-1');
        expect(native.activeAlarms, contains('native-2'));
        expect(native.cancelledIds, isNot(contains('native-2')));
      },
    );

    test(
      'ambiguous promotion with unavailable snapshot never cancels B',
      () async {
        final native = _FakeNativeAlarmGateway();
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);
        await coordinator.arm(
          selection: 'old',
          plan: _plan(100),
          requestPermissions: true,
        );
        native.ambiguousPromotionWithoutCommit = true;
        native.failSnapshot = true;

        final result = await coordinator.arm(
          selection: 'new',
          plan: _plan(200),
          requestPermissions: false,
        );

        expect(result.succeeded, isFalse);
        expect(result.transactionUnverified, isTrue);
        expect(coordinator.hasUnresolvedNativeTransaction, isTrue);
        expect(native.cancelledIds, isNot(contains('native-2')));
        expect(native.activeAlarms, contains('native-2'));
      },
    );

    test(
      'ambiguous schedule keeps the owned native identity tracked',
      () async {
        final native = _FakeNativeAlarmGateway()..unresolvedNextSchedule = true;
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);

        final result = await coordinator.arm(
          selection: 'initial',
          plan: _plan(100),
          requestPermissions: true,
        );

        expect(result.succeeded, isFalse);
        expect(result.transactionUnverified, isTrue);
        expect(coordinator.hasUnresolvedNativeTransaction, isTrue);
        expect(native.cancelledIds, isEmpty);
        expect(native.activeAlarms, contains('native-1'));
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

    test(
      'newer arm wins when an older notification schedule finishes late',
      () async {
        final native = _FakeNativeAlarmGateway();
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);
        await coordinator.arm(
          selection: 'A',
          plan: _plan(100),
          requestPermissions: true,
        );
        final olderGate = Completer<NotificationScheduleResult>();
        notifications.scheduleGate = olderGate;

        final older = coordinator.arm(
          selection: 'B',
          plan: _plan(200),
          requestPermissions: false,
        );
        await Future<void>.delayed(Duration.zero);
        final newer = await coordinator.arm(
          selection: 'C',
          plan: _plan(300),
          requestPermissions: false,
        );
        olderGate.complete(
          const NotificationScheduleResult(succeeded: true, ids: [200]),
        );
        final stale = await older;

        expect(newer.succeeded, isTrue);
        expect(stale.succeeded, isFalse);
        expect(coordinator.confirmed?.selection, 'C');
        expect(notifications.cancelledBatches, contains(equals(<int>[200])));
        expect(native.committedAlarm?.id, 'native-2');
      },
    );

    test(
      'overlap during native transaction preserves the protected alarm',
      () async {
        final native = _FakeNativeAlarmGateway();
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);
        await coordinator.arm(
          selection: 'A',
          plan: _plan(100),
          requestPermissions: true,
        );
        final olderGate = Completer<void>();
        native.scheduleGate = olderGate;

        final older = coordinator.arm(
          selection: 'B',
          plan: _plan(200),
          requestPermissions: false,
        );
        await Future<void>.delayed(Duration.zero);
        final overlapping = await coordinator.arm(
          selection: 'C',
          plan: _plan(300),
          requestPermissions: false,
        );
        expect(overlapping.succeeded, isFalse);
        expect(overlapping.transactionUnverified, isTrue);
        expect(coordinator.confirmed?.selection, 'A');

        olderGate.complete();
        final completed = await older;

        expect(completed.succeeded, isTrue);
        expect(coordinator.confirmed?.selection, 'B');
        expect(native.committedAlarm?.id, 'native-2');
        expect(native.cancelledIds, contains('native-1'));
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

    test(
      'stop accepts failed native cancel when query proves absence',
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
        native
          ..activeAlarms.remove(alarmId)
          ..failCancellation = true;

        final stopped = await coordinator.stop();

        expect(stopped.succeeded, isTrue);
        expect(coordinator.confirmed, isNull);
        expect(native.cancelledIds, [alarmId]);
        expect(native.activeAlarms, isEmpty);
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

    test(
      'stop waits for suspended native schedule and removes late B',
      () async {
        final native = _FakeNativeAlarmGateway();
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);
        await coordinator.arm(
          selection: 'old',
          plan: _plan(100),
          requestPermissions: true,
        );
        final scheduleGate = Completer<void>();
        native.scheduleGate = scheduleGate;
        final replacing = coordinator.arm(
          selection: 'new',
          plan: _plan(200),
          requestPermissions: false,
        );
        await Future<void>.delayed(Duration.zero);

        var stopCompleted = false;
        final stopping = coordinator.stop().then((result) {
          stopCompleted = true;
          return result;
        });
        await Future<void>.delayed(Duration.zero);
        expect(stopCompleted, isFalse);

        scheduleGate.complete();
        final results = await Future.wait([replacing, stopping]);

        expect((results[0] as AlarmArmResult<String>).succeeded, isFalse);
        expect((results[1] as AlarmStopResult).succeeded, isTrue);
        expect(coordinator.confirmed, isNull);
        expect(coordinator.hasUnresolvedNativeTransaction, isFalse);
        expect(native.activeAlarms, isEmpty);
        expect(native.committedAlarm, isNull);
        expect(native.preparedAlarm, isNull);
        expect(native.retiringAlarm, isNull);
        expect(native.cancelledIds, containsAll(['native-1', 'native-2']));

        final rearmed = await coordinator.arm(
          selection: 'after-stop',
          plan: _plan(300),
          requestPermissions: false,
        );
        expect(rearmed.succeeded, isTrue);
      },
    );

    test(
      'failed late-schedule cleanup remains unresolved and blocks re-arm',
      () async {
        final native = _FakeNativeAlarmGateway();
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);
        await coordinator.arm(
          selection: 'old',
          plan: _plan(100),
          requestPermissions: true,
        );
        final scheduleGate = Completer<void>();
        native.scheduleGate = scheduleGate;
        final replacing = coordinator.arm(
          selection: 'new',
          plan: _plan(200),
          requestPermissions: false,
        );
        await Future<void>.delayed(Duration.zero);
        native.cancellationFailures.add('native-2');
        final stopping = coordinator.stop();

        scheduleGate.complete();
        await replacing;
        final stopped = await stopping;

        expect(stopped.succeeded, isFalse);
        expect(coordinator.hasUnresolvedNativeTransaction, isTrue);
        expect(native.activeAlarms, contains('native-2'));
        final schedulesBeforeRetry = native.schedules;
        final retry = await coordinator.arm(
          selection: 'blocked',
          plan: _plan(300),
          requestPermissions: false,
        );
        expect(retry.succeeded, isFalse);
        expect(retry.transactionUnverified, isTrue);
        expect(native.schedules, schedulesBeforeRetry);
      },
    );

    test(
      'stop waits for suspended promotion and removes late committed B',
      () async {
        final native = _FakeNativeAlarmGateway();
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);
        await coordinator.arm(
          selection: 'old',
          plan: _plan(100),
          requestPermissions: true,
        );
        final promotionGate = Completer<void>();
        native.promotionGate = promotionGate;
        final replacing = coordinator.arm(
          selection: 'new',
          plan: _plan(200),
          requestPermissions: false,
        );
        await Future<void>.delayed(Duration.zero);

        var stopCompleted = false;
        final stopping = coordinator.stop().then((result) {
          stopCompleted = true;
          return result;
        });
        await Future<void>.delayed(Duration.zero);
        expect(stopCompleted, isFalse);

        promotionGate.complete();
        await replacing;
        final stopped = await stopping;

        expect(stopped.succeeded, isTrue);
        expect(coordinator.confirmed, isNull);
        expect(coordinator.hasUnresolvedNativeTransaction, isFalse);
        expect(native.activeAlarms, isEmpty);
        expect(native.cancelledIds, containsAll(['native-1', 'native-2']));
      },
    );

    test(
      'failed late-promotion cleanup remains unresolved and blocks re-arm',
      () async {
        final native = _FakeNativeAlarmGateway();
        final notifications = _FakeNotificationGateway();
        final coordinator = _coordinator(native, notifications);
        await coordinator.arm(
          selection: 'old',
          plan: _plan(100),
          requestPermissions: true,
        );
        final promotionGate = Completer<void>();
        native.promotionGate = promotionGate;
        final replacing = coordinator.arm(
          selection: 'new',
          plan: _plan(200),
          requestPermissions: false,
        );
        await Future<void>.delayed(Duration.zero);
        native.cancellationFailures.add('native-2');
        final stopping = coordinator.stop();

        promotionGate.complete();
        await replacing;
        final stopped = await stopping;

        expect(stopped.succeeded, isFalse);
        expect(coordinator.hasUnresolvedNativeTransaction, isTrue);
        expect(native.activeAlarms, contains('native-2'));
        final schedulesBeforeRetry = native.schedules;
        final retry = await coordinator.arm(
          selection: 'blocked',
          plan: _plan(300),
          requestPermissions: false,
        );
        expect(retry.succeeded, isFalse);
        expect(retry.transactionUnverified, isTrue);
        expect(native.schedules, schedulesBeforeRetry);
      },
    );

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

  test('AlarmKit protected states include countdown but not paused', () {
    NativeAlarmRecord record(NativeAlarmState state) => NativeAlarmRecord(
      id: state.name,
      requestedFireTime: DateTime(2026, 8, 28, 12),
      scheduledFireTime: DateTime(2026, 8, 28, 12),
      state: state,
      backend: NativeAlarmBackend.alarmKit,
    );

    expect(record(NativeAlarmState.scheduled).isConfirmed, isTrue);
    expect(record(NativeAlarmState.alerting).isConfirmed, isTrue);
    expect(record(NativeAlarmState.countdown).isConfirmed, isTrue);
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
  final Set<String> cancellationFailures = <String>{};
  bool failQuery = false;
  int authorizationChecks = 0;
  int authorizationRequests = 0;
  int schedules = 0;
  bool failPromotion = false;
  bool commitThenLosePromotionResponse = false;
  bool ambiguousPromotionWithoutCommit = false;
  bool failSnapshot = false;
  bool unresolvedNextSchedule = false;
  bool? snapshotProtectedOverride;
  Completer<void>? scheduleGate;
  Completer<void>? promotionGate;
  final List<String> cancelledIds = [];
  final List<String> stoppedIds = [];
  final List<String> lifecycleEvents = [];
  final Map<String, NativeAlarmRecord> activeAlarms = {};
  NativeAlarmRecord? preparedAlarm;
  NativeAlarmRecord? committedAlarm;
  NativeAlarmRecord? retiringAlarm;

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
    final scheduleNumber = ++schedules;
    final gate = scheduleGate;
    scheduleGate = null;
    if (gate != null) await gate.future;
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
      id: 'native-$scheduleNumber',
      requestedFireTime: fireAt,
      scheduledFireTime: fireAt,
      state: NativeAlarmState.scheduled,
      backend: NativeAlarmBackend.alarmKit,
      sessionId: 'session-1',
      revision: scheduleNumber,
    );
    activeAlarms[alarm.id] = alarm;
    preparedAlarm = alarm;
    if (unresolvedNextSchedule) {
      unresolvedNextSchedule = false;
      final unresolved = NativeAlarmRecord(
        id: alarm.id,
        requestedFireTime: alarm.requestedFireTime,
        scheduledFireTime: null,
        state: NativeAlarmState.unknown,
        backend: NativeAlarmBackend.alarmKit,
        sessionId: alarm.sessionId,
        revision: alarm.revision,
      );
      activeAlarms[alarm.id] = unresolved;
      preparedAlarm = unresolved;
      return NativeAlarmScheduleResult(
        accepted: false,
        confirmed: false,
        backend: NativeAlarmBackend.alarmKit,
        alarm: unresolved,
        failure: 'schedule outcome unavailable',
        unresolved: true,
      );
    }
    return NativeAlarmScheduleResult(
      accepted: true,
      confirmed: true,
      backend: NativeAlarmBackend.alarmKit,
      alarm: alarm,
    );
  }

  @override
  Future<AlarmOperationResult> promoteSession(NativeAlarmRecord alarm) async {
    lifecycleEvents.add('promote:${alarm.id}');
    final gate = promotionGate;
    promotionGate = null;
    if (gate != null) await gate.future;
    if (committedAlarm?.id == alarm.id &&
        committedAlarm?.sessionId == alarm.sessionId &&
        committedAlarm?.revision == alarm.revision) {
      return const AlarmOperationResult.success();
    }
    if (failPromotion) {
      failPromotion = false;
      return const AlarmOperationResult.failure('promotion failed');
    }
    if (preparedAlarm?.id != alarm.id) {
      return const AlarmOperationResult.failure('prepared mismatch');
    }
    if (ambiguousPromotionWithoutCommit) {
      ambiguousPromotionWithoutCommit = false;
      return const AlarmOperationResult.ambiguous('bridge response lost');
    }
    final old = committedAlarm;
    committedAlarm = alarm;
    preparedAlarm = null;
    retiringAlarm = old;
    if (old != null) activeAlarms.remove(old.id);
    if (commitThenLosePromotionResponse) {
      commitThenLosePromotionResponse = false;
      return const AlarmOperationResult.ambiguous('bridge response lost');
    }
    return const AlarmOperationResult.success();
  }

  @override
  Future<NativeAlarmSessionSnapshot> sessionSnapshot() async {
    if (failSnapshot) {
      return const NativeAlarmSessionSnapshot(
        reconciliationAvailable: false,
        sessionExists: false,
        isProtected: false,
        protectionStatus: NativeAlarmProtectionStatus.unverified,
      );
    }
    final alarm = committedAlarm;
    final protected = snapshotProtectedOverride ?? alarm?.isConfirmed == true;
    return NativeAlarmSessionSnapshot(
      reconciliationAvailable: true,
      sessionExists: alarm != null,
      isProtected: protected,
      protectionStatus: protected
          ? NativeAlarmProtectionStatus.protected
          : NativeAlarmProtectionStatus.unverified,
      sessionId: alarm?.sessionId,
      revision: alarm?.revision,
      alarmId: alarm?.id,
      requestedFireTime: alarm?.requestedFireTime,
      state: alarm?.state ?? NativeAlarmState.unknown,
      preparedSessionId: preparedAlarm?.sessionId,
      preparedRevision: preparedAlarm?.revision,
      preparedAlarmId: preparedAlarm?.id,
    );
  }

  @override
  Future<NativeAlarmQueryResult> alarms() async => failQuery
      ? const NativeAlarmQueryResult(alarms: [], failure: 'query failed')
      : NativeAlarmQueryResult(alarms: activeAlarms.values.toList());

  @override
  Future<AlarmOperationResult> cancel(NativeAlarmRecord alarm) async {
    final alarmId = alarm.id;
    lifecycleEvents.add('cancel:$alarmId');
    cancelledIds.add(alarmId);
    if (failCancellation || cancellationFailures.contains(alarmId)) {
      return const AlarmOperationResult.failure('cancel failed');
    }
    activeAlarms.remove(alarmId);
    if (preparedAlarm?.id == alarmId) preparedAlarm = null;
    if (committedAlarm?.id == alarmId) committedAlarm = null;
    if (retiringAlarm?.id == alarmId) retiringAlarm = null;
    return const AlarmOperationResult.success();
  }

  @override
  Future<AlarmOperationResult> stopAlerting(NativeAlarmRecord alarm) async {
    stoppedIds.add(alarm.id);
    return const AlarmOperationResult.success();
  }

  @override
  Future<AlarmOperationResult> startLegacyNow() async =>
      const AlarmOperationResult.success();

  @override
  Future<AlarmOperationResult> stopLegacyPlayback() async =>
      const AlarmOperationResult.success();
}
