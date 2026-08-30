import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:treep/services/live_activity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('treep/live_activity');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'startOrUpdate sends fixed timeline and future alarm identity',
    () async {
      MethodCall? captured;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            captured = call;
            return <String, Object>{
              'supported': true,
              'enabled': true,
              'succeeded': true,
              'activityId': 'activity-1',
              'action': 'started',
            };
          });
      final reference = DateTime(2026, 8, 29, 12);
      final alarm = reference.add(const Duration(minutes: 20));
      final arrival = reference.add(const Duration(minutes: 30));

      final result = await const MethodChannelLiveActivityGateway()
          .startOrUpdate(
            TreepLiveActivityContent(
              journeyId: 'journey-1',
              lineLabel: 'S22',
              destinationLabel: 'Oensingen',
              directionLabel: 'Oensingen',
              referenceTime: reference,
              alarmTime: alarm,
              arrivalTime: arrival,
              alarmId: 'alarm-1',
              alarmSessionId: 'session-1',
              alarmRevision: 7,
            ),
          );

      expect(result.succeeded, isTrue);
      expect(result.activityId, 'activity-1');
      expect(captured?.method, 'startOrUpdate');
      final arguments = Map<String, dynamic>.from(captured!.arguments as Map);
      expect(arguments['journeyId'], 'journey-1');
      expect(arguments['destinationLabel'], 'Oensingen');
      expect(arguments['referenceTimeMs'], reference.millisecondsSinceEpoch);
      expect(arguments['alarmTimeMs'], alarm.millisecondsSinceEpoch);
      expect(arguments['arrivalTimeMs'], arrival.millisecondsSinceEpoch);
      expect(arguments['phase'], 'tracking');
      expect(arguments['alarmId'], 'alarm-1');
      expect(arguments['alarmSessionId'], 'session-1');
      expect(arguments['alarmRevision'], 7);
    },
  );

  test(
    'native bridge failure is nonfatal and represented accurately',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'disabled');
          });
      final now = DateTime(2026, 8, 29, 12);

      final result = await const MethodChannelLiveActivityGateway()
          .startOrUpdate(
            TreepLiveActivityContent(
              journeyId: 'journey-1',
              lineLabel: 'S22',
              destinationLabel: 'Oensingen',
              directionLabel: 'Oensingen',
              referenceTime: now,
              alarmTime: now.add(const Duration(minutes: 20)),
              arrivalTime: now.add(const Duration(minutes: 30)),
            ),
          );

      expect(result.succeeded, isFalse);
      expect(result.failure, contains('disabled'));
    },
  );

  test(
    'end requests native dismissal without requiring a remembered ID',
    () async {
      MethodCall? captured;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            captured = call;
            return <String, Object>{
              'supported': true,
              'enabled': true,
              'succeeded': true,
            };
          });

      final result = await const MethodChannelLiveActivityGateway().end();

      expect(result.succeeded, isTrue);
      expect(captured?.method, 'end');
      expect(captured?.arguments, isEmpty);
    },
  );
}
