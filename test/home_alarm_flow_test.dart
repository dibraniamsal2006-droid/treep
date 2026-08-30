import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:treep/models/trip_candidate.dart';
import 'package:treep/screens/active_journey_screen.dart';
import 'package:treep/screens/home_screen.dart';
import 'package:treep/screens/settings_screen.dart';
import 'package:treep/services/alarm_service.dart';
import 'package:treep/services/live_activity_service.dart';
import 'package:treep/services/transport_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      kPrefsSkipVolumeDialogKey: true,
      kPrefsSleepLinesEnabledKey: false,
    });
  });

  testWidgets('Home omits alarm offset and normal layout does not scroll', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final notifications = _RecordingNotificationGateway();
    await _pumpHome(tester, notifications);

    expect(find.byKey(const Key('alarm-offset-slider')), findsNothing);
    expect(find.text('Alarm offset'), findsNothing);
    expect(find.textContaining("We'll wake you"), findsNothing);
    expect(find.textContaining('Test alarm'), findsNothing);
    expect(
      tester
          .widget<SingleChildScrollView>(
            find.byKey(const Key('home-scroll-view')),
          )
          .physics,
      isA<NeverScrollableScrollPhysics>(),
    );
  });

  testWidgets('train input keeps focus and identity across keyboard insets', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final notifications = _RecordingNotificationGateway();
    final coordinator = _coordinator(notifications);
    final service = _SingleCandidateTransportService();

    await _pumpFocusHome(
      tester,
      coordinator: coordinator,
      service: service,
      bottomInset: 0,
    );
    final input = find.byKey(const Key('train-input'));
    final beforeWidget = tester.widget<TextField>(input);
    final beforeElement = tester.element(input);
    await tester.tap(input);
    await tester.enterText(input, 'S20');
    expect(beforeWidget.focusNode?.hasFocus, isTrue);

    await _pumpFocusHome(
      tester,
      coordinator: coordinator,
      service: service,
      bottomInset: 360,
    );

    final afterWidget = tester.widget<TextField>(input);
    expect(afterWidget.focusNode, same(beforeWidget.focusNode));
    expect(afterWidget.controller, same(beforeWidget.controller));
    expect(tester.element(input), same(beforeElement));
    expect(afterWidget.focusNode?.hasFocus, isTrue);
    expect(afterWidget.controller?.text, 'S20');
    expect(
      tester
          .widget<SingleChildScrollView>(
            find.byKey(const Key('home-scroll-view')),
          )
          .physics,
      isA<ClampingScrollPhysics>(),
    );
  });

  testWidgets('destination input stays focused and usable with keyboard open', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final notifications = _RecordingNotificationGateway();
    final coordinator = _coordinator(notifications);
    final service = _SingleCandidateTransportService();

    await _pumpFocusHome(
      tester,
      coordinator: coordinator,
      service: service,
      bottomInset: 0,
    );
    final input = find.byKey(const Key('destination-input'));
    final beforeWidget = tester.widget<TextField>(input);
    final beforeElement = tester.element(input);
    await tester.tap(input);
    await tester.enterText(input, 'Oensingen');

    await _pumpFocusHome(
      tester,
      coordinator: coordinator,
      service: service,
      bottomInset: 360,
    );

    final afterWidget = tester.widget<TextField>(input);
    expect(afterWidget.focusNode, same(beforeWidget.focusNode));
    expect(afterWidget.controller, same(beforeWidget.controller));
    expect(tester.element(input), same(beforeElement));
    expect(afterWidget.focusNode?.hasFocus, isTrue);
    expect(afterWidget.controller?.text, 'Oensingen');
    expect(find.byKey(const Key('choose-journey-button')), findsOneWidget);
  });

  testWidgets('review offset updates copy and alarm time without arming', (
    tester,
  ) async {
    final notifications = _RecordingNotificationGateway();
    await _pumpHome(tester, notifications);
    await _openJourneyReview(tester);

    final slider = tester.widget<Slider>(
      find.byKey(const Key('alarm-offset-slider')),
    );
    final alarmValueFinder = find.descendant(
      of: find.byKey(const Key('review-alarm-time')),
      matching: find.byType(Text),
    );
    final before = tester.widget<Text>(alarmValueFinder.last).data;
    slider.onChanged?.call(8);
    await tester.pump();

    final after = tester.widget<Text>(alarmValueFinder.last).data;
    expect(
      tester.widget<Text>(find.byKey(const Key('alarm-offset-value'))).data,
      '8 min before',
    );
    expect(after, isNot(before));

    expect(notifications.permissionCalls, 0);
    expect(notifications.scheduleCalls, 0);
  });

  test('wake-offset labels use the slider value mapping', () {
    expect(wakeOffsetNormalizedPosition(1), 0);
    expect(wakeOffsetNormalizedPosition(3), closeTo(2 / 14, 0.000001));
    expect(wakeOffsetNormalizedPosition(5), closeTo(4 / 14, 0.000001));
    expect(wakeOffsetNormalizedPosition(10), closeTo(9 / 14, 0.000001));
    expect(wakeOffsetNormalizedPosition(15), 1);
  });

  testWidgets('wake-offset label centers follow the actual slider track', (
    tester,
  ) async {
    await _pumpHome(tester, _RecordingNotificationGateway());
    await _openJourneyReview(tester);

    final track = tester.getRect(
      find.byKey(const Key('alarm-offset-label-track')),
    );
    for (final mark in const <int>[1, 3, 5, 10, 15]) {
      final center = tester.getCenter(
        find.byKey(Key('alarm-offset-label-$mark')),
      );
      final expected =
          track.left +
          track.width * wakeOffsetNormalizedPosition(mark.toDouble());
      expect(center.dx, closeTo(expected, 0.01), reason: '$mark minute mark');
    }
  });

  testWidgets('lowercase query is replaced by canonical destination label', (
    tester,
  ) async {
    final notifications = _RecordingNotificationGateway();
    await _pumpHome(tester, notifications);
    await tester.enterText(
      find.byKey(const Key('destination-input')),
      'oensingen',
    );

    await _openJourneyReview(tester);

    expect(
      tester.widget<Text>(find.byKey(const Key('review-destination'))).data,
      'Oensingen',
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('journey-review-sheet')),
        matching: find.text('oensingen'),
      ),
      findsNothing,
    );
  });

  testWidgets('canonical Unicode station name is preserved in review UI', (
    tester,
  ) async {
    final notifications = _RecordingNotificationGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: TreepHome(
          transportService: _SingleCandidateTransportService(
            officialStopName: 'Oensingen, Bahnhof Süd',
          ),
          alarmCoordinator: _coordinator(notifications),
          confirmationDuration: const Duration(milliseconds: 200),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('train-input')), 'S22');
    await tester.enterText(
      find.byKey(const Key('destination-input')),
      'Oensingen',
    );

    await _openJourneyReview(tester);

    expect(find.text('Oensingen, Bahnhof Süd'), findsOneWidget);
    expect(find.textContaining('SÃ¼d'), findsNothing);
  });

  testWidgets(
    'Basel query displays resolved Basel SBB independently of direction',
    (tester) async {
      final notifications = _RecordingNotificationGateway();
      await tester.pumpWidget(
        MaterialApp(
          home: TreepHome(
            transportService: _SingleCandidateTransportService(
              tripId: 's3-basel-trip',
              line: 'S3',
              stopId: '8500010',
              officialStopName: 'Basel SBB',
              direction: 'Laufen',
            ),
            alarmCoordinator: _coordinator(notifications),
            confirmationDuration: const Duration(milliseconds: 200),
          ),
        ),
      );
      await tester.enterText(find.byKey(const Key('train-input')), 'S3');
      await tester.enterText(
        find.byKey(const Key('destination-input')),
        'basel',
      );
      await tester.tap(find.byKey(const Key('choose-journey-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Arrival at Basel SBB'), findsOneWidget);
      expect(find.text('Direction Laufen'), findsOneWidget);
      expect(find.text('Arrival at basel'), findsNothing);
    },
  );

  testWidgets('Home CTA opens journey selection without arming', (
    tester,
  ) async {
    final notifications = _RecordingNotificationGateway();
    await _pumpHome(tester, notifications);

    await _openJourneySelection(tester);

    expect(
      find.byKey(const Key('journey-choice-s22-test-trip')),
      findsOneWidget,
    );
    expect(find.text('Direction Oensingen'), findsOneWidget);
    expect(find.text('Arrival at Oensingen'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.textContaining('8500207'),
      ),
      findsNothing,
    );
    expect(notifications.permissionCalls, 0);
    expect(notifications.scheduleCalls, 0);
  });

  testWidgets('journey selection opens review without arming', (tester) async {
    final notifications = _RecordingNotificationGateway();
    await _pumpHome(tester, notifications);

    await _openJourneyReview(tester);

    expect(find.byKey(const Key('journey-review-sheet')), findsOneWidget);
    expect(find.text('Selected journey'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('review-line')),
        matching: find.text('S22'),
      ),
      findsOneWidget,
    );
    expect(find.text('Direction Oensingen'), findsOneWidget);
    expect(find.byKey(const Key('review-destination')), findsOneWidget);
    expect(find.text('Set alarm'), findsOneWidget);
    expect(notifications.permissionCalls, 0);
    expect(notifications.scheduleCalls, 0);
  });

  testWidgets('selected journey Set alarm arms once and confirms first', (
    tester,
  ) async {
    final notifications = _RecordingNotificationGateway();
    await _pumpHome(tester, notifications);
    await _openJourneyReview(tester);

    final setAlarm = tester.widget<TreepPressableButton>(
      find.byKey(const Key('review-set-alarm-button')),
    );
    setAlarm.onPressed?.call();
    setAlarm.onPressed?.call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    expect(notifications.permissionCalls, 1);
    expect(notifications.scheduleCalls, 1);
    expect(find.byKey(const Key('alarm-confirmation')), findsOneWidget);
    expect(find.text('Active journey'), findsNothing);

    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Active journey'), findsOneWidget);
  });

  testWidgets(
    'confirmation remains over Home while Active Journey transition begins',
    (tester) async {
      final notifications = _RecordingNotificationGateway();
      await _pumpHome(tester, notifications);
      await _openJourneyReview(tester);

      await tester.tap(find.byKey(const Key('review-set-alarm-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.byKey(const Key('alarm-confirmation')), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 190));
      expect(find.text('Active journey'), findsOneWidget);
      expect(find.byKey(const Key('alarm-confirmation')), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 470));
      expect(find.text('Active journey'), findsOneWidget);
      expect(find.byKey(const Key('alarm-confirmation')), findsNothing);
    },
  );

  testWidgets('technical journey identifier is never rendered as a line', (
    tester,
  ) async {
    const technicalId = 'ojp:96260:0:H:j26';
    final notifications = _RecordingNotificationGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: TreepHome(
          transportService: _SingleCandidateTransportService(line: technicalId),
          alarmCoordinator: _coordinator(notifications),
          confirmationDuration: const Duration(milliseconds: 200),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('train-input')), '129');
    await tester.enterText(
      find.byKey(const Key('destination-input')),
      'Oensingen',
    );

    await _openJourneyReview(tester);

    expect(find.text(technicalId), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('review-line')),
        matching: find.text('Train'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('confirmation gives the Treep signature intentional emphasis', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      kPrefsSkipVolumeDialogKey: true,
      kPrefsSleepLinesEnabledKey: true,
    });
    final notifications = _RecordingNotificationGateway();
    await _pumpHome(tester, notifications);
    await _openJourneyReview(tester);

    await tester.tap(find.byKey(const Key('review-set-alarm-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    final signature = tester.widget<Text>(
      find.byKey(const Key('confirmation-flavor')),
    );
    expect(signature.data, 'Heute wird nicht verpasst. Versprochen. 🤝');
    expect(signature.style?.color, const Color(0xFFAADDBE));

    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('failed arm stays on Home without confirmation or journey', (
    tester,
  ) async {
    final notifications = _RecordingNotificationGateway(failSchedule: true);
    await _pumpHome(tester, notifications);
    await _openJourneyReview(tester);

    await tester.tap(find.byKey(const Key('review-set-alarm-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(notifications.scheduleCalls, 1);
    expect(find.byKey(const Key('alarm-confirmation')), findsNothing);
    expect(find.text('Active journey'), findsNothing);
    expect(
      find.text('Alarm could not be confirmed. No Active Journey was opened.'),
      findsOneWidget,
    );
  });

  testWidgets('Active Journey keeps countdown and metadata separated', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final notifications = _RecordingNotificationGateway();
    await _showActiveJourney(tester, notifications);

    final ring = find.byKey(const Key('journey-progress-ring'));
    final metadata = find.byKey(const Key('journey-metadata'));
    expect(ring, findsOneWidget);
    expect(tester.widget<JourneyProgressRing>(ring).diameter, greaterThan(320));
    expect(find.byKey(const Key('journey-countdown')), findsOneWidget);
    expect(metadata, findsOneWidget);
    expect(find.byKey(const Key('journey-destination')), findsOneWidget);
    expect(find.ancestor(of: metadata, matching: ring), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const Key('journey-destination'))).data,
      'Oensingen',
    );
    final direction = tester.widget<Text>(
      find.byKey(const Key('journey-direction')),
    );
    expect(direction.data, 'Direction Oensingen');
    expect(direction.style?.color, treepMuted);
    final active = find.byType(ActiveJourneyScreen);
    expect(
      find.descendant(of: active, matching: find.textContaining('8500207')),
      findsNothing,
    );
    expect(
      find.descendant(of: active, matching: find.textContaining('on time')),
      findsNothing,
    );
  });

  testWidgets('Active Journey fits a small iPhone viewport', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: ActiveJourneyScreen(
          activatedAt: DateTime.now(),
          alarmTime: DateTime.now().add(const Duration(minutes: 20)),
          arrivalTime: DateTime.now().add(const Duration(minutes: 23)),
          lineLabel: 'S22',
          destinationLabel: 'Oensingen',
          directionLabel: 'Solothurn',
          isCancelling: false,
          onCancel: () {},
        ),
      ),
    );
    await tester.ensureVisible(find.byKey(const Key('cancel-alarm-button')));
    await tester.pump();

    expect(find.byKey(const Key('journey-progress-ring')), findsOneWidget);
    expect(find.byKey(const Key('cancel-alarm-button')), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const Key('active-journey-standard-layout')),
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Active Journey respects physical-iPhone safe area and cancel hit target',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var cancelCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 700),
              padding: EdgeInsets.only(top: 47, bottom: 34),
            ),
            child: ActiveJourneyScreen(
              activatedAt: DateTime.now(),
              alarmTime: DateTime.now().add(const Duration(minutes: 20)),
              arrivalTime: DateTime.now().add(const Duration(minutes: 23)),
              lineLabel: 'S22',
              destinationLabel: 'Oensingen',
              directionLabel: 'Solothurn',
              isCancelling: false,
              onCancel: () => cancelCalls++,
            ),
          ),
        ),
      );

      final cancel = find.byKey(const Key('cancel-alarm-button'));
      final rect = tester.getRect(cancel);
      expect(rect.height, greaterThanOrEqualTo(44));
      expect(rect.bottom, lessThanOrEqualTo(700 - 34));
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(cancel);
      await tester.pump();
      expect(cancelCalls, 1);
    },
  );

  test('train tail starts and locomotive front finishes at twelve', () {
    const radius = 141.0;
    expect(
      journeyLastWagonTailAngleForProgress(0, radius: radius),
      closeTo(-math.pi / 2, 0.000001),
    );
    expect(
      journeyLocomotiveFrontAngleForProgress(1, radius: radius),
      closeTo(-math.pi / 2 - math.pi * 2, 0.000001),
    );
  });

  test('train and completed ring advance counter-clockwise', () {
    expect(
      journeyTrainAngleForProgress(0.25),
      lessThan(journeyTrainAngleForProgress(0)),
    );
    expect(journeyCompletedSweepForProgress(0.5), closeTo(-math.pi, 0.000001));
    expect(
      journeyCompletedSweepForProgress(1),
      closeTo(-math.pi * 2, 0.000001),
    );
    expect(treepCompleted, const Color(0xFFDCE3DF));
  });

  test('train model contains one locomotive and exactly five wagons', () {
    expect(journeyPassengerWagonCount, 5);
    expect(journeyPassengerWagonCount + 1, 6);
  });

  test('default confirmation duration is 500 ms longer', () {
    expect(treepConfirmationDuration, const Duration(milliseconds: 3750));
  });

  test('iPhone orientation is portrait-only while iPad remains unchanged', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final phoneStart = plist.indexOf(
      '<key>UISupportedInterfaceOrientations</key>',
    );
    final ipadStart = plist.indexOf(
      '<key>UISupportedInterfaceOrientations~ipad</key>',
    );
    final phoneOrientations = plist.substring(phoneStart, ipadStart);
    expect(phoneOrientations, contains('UIInterfaceOrientationPortrait'));
    expect(phoneOrientations, isNot(contains('Landscape')));
    expect(
      plist.substring(ipadStart),
      contains('UIInterfaceOrientationLandscapeLeft'),
    );
  });

  testWidgets('successful cancellation runs once and slides Home', (
    tester,
  ) async {
    final notifications = _RecordingNotificationGateway();
    final liveActivity = _RecordingLiveActivityGateway();
    await _showActiveJourney(tester, notifications, liveActivity: liveActivity);

    expect(liveActivity.startCalls, 1);
    expect(liveActivity.lastContent?.lineLabel, 'S22');
    expect(liveActivity.lastContent?.destinationLabel, 'Oensingen');

    await tester.ensureVisible(find.byKey(const Key('cancel-alarm-button')));
    await tester.tap(find.byKey(const Key('cancel-alarm-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(notifications.cancelCalls, 1);
    expect(liveActivity.endCalls, 1);
    expect(find.text('Where are you going?'), findsOneWidget);
    expect(find.text('Active journey'), findsNothing);
    expect(find.byKey(const Key('journey-progress-ring')), findsNothing);
  });

  testWidgets('failed cancellation keeps the active protection state visible', (
    tester,
  ) async {
    final notifications = _RecordingNotificationGateway(failCancel: true);
    final liveActivity = _RecordingLiveActivityGateway();
    await _showActiveJourney(tester, notifications, liveActivity: liveActivity);

    await tester.ensureVisible(find.byKey(const Key('cancel-alarm-button')));
    await tester.tap(find.byKey(const Key('cancel-alarm-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(notifications.cancelCalls, 1);
    expect(liveActivity.endCalls, 0);
    expect(find.text('Active journey'), findsOneWidget);
    expect(find.byKey(const Key('cancel-error')), findsOneWidget);
    expect(find.text('Cancel alarm'), findsOneWidget);
  });

  testWidgets('Live Activity failure cannot block confirmed alarm UX', (
    tester,
  ) async {
    final notifications = _RecordingNotificationGateway();
    final liveActivity = _RecordingLiveActivityGateway(failStart: true);

    await _showActiveJourney(tester, notifications, liveActivity: liveActivity);

    expect(notifications.scheduleCalls, 1);
    expect(liveActivity.startCalls, 1);
    expect(find.text('Active journey'), findsOneWidget);
  });

  testWidgets('failed alarm arm never starts a Live Activity', (tester) async {
    final notifications = _RecordingNotificationGateway(failSchedule: true);
    final liveActivity = _RecordingLiveActivityGateway();
    await _pumpHome(tester, notifications, liveActivityGateway: liveActivity);
    await _openJourneyReview(tester);

    await tester.tap(find.byKey(const Key('review-set-alarm-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(liveActivity.startCalls, 0);
    expect(find.text('Active journey'), findsNothing);
    expect(
      find.text('Alarm could not be set. Please try again.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'older realtime response cannot regress a newer confirmed alarm',
    (tester) async {
      final notifications = _RecordingNotificationGateway();
      final coordinator = _coordinator(notifications);
      final service = _PollingTransportService();
      await _pumpInjectedHome(
        tester,
        coordinator: coordinator,
        service: service,
      );
      await _openJourneyReview(tester);
      await tester.tap(find.byKey(const Key('review-set-alarm-button')));
      await tester.pump(const Duration(milliseconds: 750));
      expect(find.text('Active journey'), findsOneWidget);

      await tester.pump(const Duration(seconds: 25));
      expect(service.pendingRefreshes, hasLength(1));
      await tester.pump(const Duration(seconds: 25));
      expect(service.pendingRefreshes, hasLength(2));

      final newerEta = DateTime.now().add(const Duration(minutes: 50));
      service.pendingRefreshes[1].complete(service.candidateAt(newerEta));
      await tester.pump();
      await tester.pump();
      expect(coordinator.confirmed?.selection.etaLocal, newerEta);

      final staleEta = DateTime.now().add(const Duration(minutes: 40));
      service.pendingRefreshes[0].complete(service.candidateAt(staleEta));
      await tester.pump();
      await tester.pump();

      expect(coordinator.confirmed?.selection.etaLocal, newerEta);
    },
  );

  testWidgets('Live Activity update failure cannot roll back replacement', (
    tester,
  ) async {
    final notifications = _RecordingNotificationGateway();
    final coordinator = _coordinator(notifications);
    final service = _ImmediateRefreshTransportService();
    final liveActivity = _RecordingLiveActivityGateway(failStartOnCall: 2);
    await _pumpInjectedHome(
      tester,
      coordinator: coordinator,
      service: service,
      liveActivityGateway: liveActivity,
    );
    await _openJourneyReview(tester);
    await tester.tap(find.byKey(const Key('review-set-alarm-button')));
    await tester.pump(const Duration(milliseconds: 750));

    await tester.pump(const Duration(seconds: 25));
    await tester.pump();

    expect(notifications.scheduleCalls, 2);
    expect(liveActivity.startCalls, 2);
    expect(coordinator.confirmed?.selection.etaLocal, service.updatedEta);
    expect(find.text('Active journey'), findsOneWidget);
  });

  testWidgets('Live Activity end failure cannot block confirmed cancellation', (
    tester,
  ) async {
    final notifications = _RecordingNotificationGateway();
    final liveActivity = _RecordingLiveActivityGateway(failEnd: true);
    await _showActiveJourney(tester, notifications, liveActivity: liveActivity);

    await tester.ensureVisible(find.byKey(const Key('cancel-alarm-button')));
    await tester.tap(find.byKey(const Key('cancel-alarm-button')));
    await tester.pump(const Duration(milliseconds: 500));

    expect(notifications.cancelCalls, 1);
    expect(liveActivity.endCalls, 1);
    expect(find.text('Where are you going?'), findsOneWidget);
    expect(find.text('Active journey'), findsNothing);
  });

  testWidgets('AlarmKit schedule failure cannot show alarm success', (
    tester,
  ) async {
    final notifications = _RecordingNotificationGateway();
    final coordinator = AlarmTransactionCoordinator<TripCandidate>(
      native: _ControlledNativeAlarmGateway(),
      notifications: notifications,
      nativeSchedulingEnabled: true,
    );
    await _pumpInjectedHome(
      tester,
      coordinator: coordinator,
      service: _SingleCandidateTransportService(),
    );
    await _openJourneyReview(tester);

    await tester.tap(find.byKey(const Key('review-set-alarm-button')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(coordinator.confirmed, isNull);
    expect(find.byKey(const Key('alarm-confirmation')), findsNothing);
    expect(find.text('Active journey'), findsNothing);
  });

  testWidgets('unresolved native transaction cannot show alarm success', (
    tester,
  ) async {
    final notifications = _RecordingNotificationGateway();
    final coordinator = AlarmTransactionCoordinator<TripCandidate>(
      native: _ControlledNativeAlarmGateway(unresolved: true),
      notifications: notifications,
      nativeSchedulingEnabled: true,
    );
    await _pumpInjectedHome(
      tester,
      coordinator: coordinator,
      service: _SingleCandidateTransportService(),
    );
    await _openJourneyReview(tester);

    await tester.tap(find.byKey(const Key('review-set-alarm-button')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(coordinator.confirmed, isNull);
    expect(coordinator.hasUnresolvedNativeTransaction, isTrue);
    expect(find.byKey(const Key('alarm-confirmation')), findsNothing);
    expect(find.text('Active journey'), findsNothing);
  });
}

Future<void> _pumpHome(
  WidgetTester tester,
  _RecordingNotificationGateway notifications, {
  LiveActivityGateway? liveActivityGateway,
}) async {
  final coordinator = _coordinator(notifications);
  await tester.pumpWidget(
    MaterialApp(
      home: TreepHome(
        transportService: _SingleCandidateTransportService(),
        alarmCoordinator: coordinator,
        liveActivityGateway: liveActivityGateway,
        confirmationDuration: const Duration(milliseconds: 200),
      ),
    ),
  );
  await tester.enterText(find.byType(TextField).at(0), 'S22');
  await tester.enterText(find.byType(TextField).at(1), 'Oensingen');
  await tester.ensureVisible(find.byKey(const Key('choose-journey-button')));
  await tester.pump();
}

Future<void> _pumpInjectedHome(
  WidgetTester tester, {
  required AlarmTransactionCoordinator<TripCandidate> coordinator,
  required TransportService service,
  LiveActivityGateway? liveActivityGateway,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: TreepHome(
        transportService: service,
        alarmCoordinator: coordinator,
        liveActivityGateway: liveActivityGateway,
        confirmationDuration: const Duration(milliseconds: 200),
      ),
    ),
  );
  await tester.enterText(find.byType(TextField).at(0), 'S22');
  await tester.enterText(find.byType(TextField).at(1), 'Oensingen');
  await tester.ensureVisible(find.byKey(const Key('choose-journey-button')));
  await tester.pump();
}

AlarmTransactionCoordinator<TripCandidate> _coordinator(
  _RecordingNotificationGateway notifications,
) => AlarmTransactionCoordinator<TripCandidate>(
  native: const MethodChannelNativeAlarmGateway(),
  notifications: notifications,
  nativeSchedulingEnabled: false,
);

Future<void> _pumpFocusHome(
  WidgetTester tester, {
  required AlarmTransactionCoordinator<TripCandidate> coordinator,
  required TransportService service,
  required double bottomInset,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(viewInsets: EdgeInsets.only(bottom: bottomInset)),
        child: child!,
      ),
      home: TreepHome(
        key: const Key('focus-test-home'),
        transportService: service,
        alarmCoordinator: coordinator,
        confirmationDuration: const Duration(milliseconds: 200),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _openJourneySelection(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('choose-journey-button')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byKey(const Key('journey-choice-s22-test-trip')), findsOneWidget);
}

Future<void> _openJourneyReview(WidgetTester tester) async {
  await _openJourneySelection(tester);
  await tester.tap(find.byKey(const Key('journey-choice-s22-test-trip')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  expect(find.byKey(const Key('journey-review-sheet')), findsOneWidget);
}

Future<void> _showActiveJourney(
  WidgetTester tester,
  _RecordingNotificationGateway notifications, {
  LiveActivityGateway? liveActivity,
}) async {
  await _pumpHome(tester, notifications, liveActivityGateway: liveActivity);
  await _openJourneyReview(tester);
  await tester.tap(find.byKey(const Key('review-set-alarm-button')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 30));
  expect(find.byKey(const Key('alarm-confirmation')), findsOneWidget);
  await tester.pump(const Duration(milliseconds: 220));
  await tester.pump(const Duration(milliseconds: 500));
  expect(find.text('Active journey'), findsOneWidget);
}

class _SingleCandidateTransportService extends TransportService {
  _SingleCandidateTransportService({
    this.tripId = 's22-test-trip',
    this.line = 'S22',
    this.stopId = '8500207',
    this.officialStopName = 'Oensingen',
    this.direction = 'Oensingen',
  });

  final String tripId;
  final String line;
  final String stopId;
  final String officialStopName;
  final String direction;

  @override
  Future<List<String>> resolveStopIdsFromName(String query) async => [stopId];

  @override
  Future<FeedMessage> fetchGtfsRtFeed() async => FeedMessage();

  @override
  List<TripCandidate> findCandidates(
    FeedMessage feed,
    String trainQuery,
    String destQuery, {
    required bool requireDestinationMatch,
  }) => requireDestinationMatch ? [_candidate()] : const [];

  @override
  Future<void> ensureStopName(String canonStopId) async {}

  @override
  Future<void> warmStopNamesForCandidates(
    List<TripCandidate> candidates,
  ) async {}

  @override
  String stopLabel(String rawStopId) =>
      rawStopId == stopId ? '$officialStopName ($stopId)' : rawStopId;

  @override
  bool stopIdMatches(String stopCanon, String destCanon) =>
      stopCanon == destCanon;

  TripCandidate _candidate() => TripCandidate(
    tripId: tripId,
    routeId: line,
    startDate: '20260829',
    startTime: '07:15:00',
    stopId: stopId,
    etaLocal: DateTime.now().add(const Duration(minutes: 30)),
    delaySeconds: 0,
    displayTrain: line,
    vehicleLabel: 'Train',
    destinationMatched: true,
    upcomingStops: const [],
    terminalStopId: direction,
    terminalStopIdCanon: '',
  );
}

class _PollingTransportService extends _SingleCandidateTransportService {
  final List<Completer<TripCandidate?>> pendingRefreshes = [];

  TripCandidate candidateAt(DateTime eta) =>
      _candidate().copyWith(etaLocal: eta);

  @override
  Future<TripCandidate?> refreshCandidateEta(TripCandidate candidate) {
    final completer = Completer<TripCandidate?>();
    pendingRefreshes.add(completer);
    return completer.future;
  }
}

class _ImmediateRefreshTransportService
    extends _SingleCandidateTransportService {
  late final DateTime updatedEta = DateTime.now().add(
    const Duration(minutes: 50),
  );
  bool refreshed = false;

  @override
  Future<TripCandidate?> refreshCandidateEta(TripCandidate candidate) async {
    if (refreshed) return null;
    refreshed = true;
    return candidate.copyWith(etaLocal: updatedEta);
  }
}

class _RecordingNotificationGateway implements AlarmNotificationGateway {
  _RecordingNotificationGateway({
    this.failSchedule = false,
    this.failCancel = false,
  });

  final bool failSchedule;
  final bool failCancel;
  int permissionCalls = 0;
  int scheduleCalls = 0;
  int cancelCalls = 0;

  @override
  Future<AlarmOperationResult> requestPermissions() async {
    permissionCalls++;
    return const AlarmOperationResult.success();
  }

  @override
  Future<NotificationScheduleResult> schedule(
    AlarmNotificationPlan plan,
  ) async {
    scheduleCalls++;
    if (failSchedule) {
      return const NotificationScheduleResult(
        succeeded: false,
        ids: [],
        failure: 'fixture schedule failure',
      );
    }
    return NotificationScheduleResult(succeeded: true, ids: [plan.baseId]);
  }

  @override
  Future<NotificationCancelResult> cancelIds(List<int> ids) async {
    cancelCalls++;
    return NotificationCancelResult(
      remainingIds: failCancel ? List<int>.of(ids) : const [],
      failure: failCancel ? 'fixture cancel failure' : null,
    );
  }
}

class _RecordingLiveActivityGateway implements LiveActivityGateway {
  _RecordingLiveActivityGateway({
    this.failStart = false,
    this.failStartOnCall,
    this.failEnd = false,
  });

  final bool failStart;
  final int? failStartOnCall;
  final bool failEnd;
  int startCalls = 0;
  int endCalls = 0;
  TreepLiveActivityContent? lastContent;

  @override
  Future<LiveActivityOperationResult> startOrUpdate(
    TreepLiveActivityContent content,
  ) async {
    startCalls++;
    lastContent = content;
    if (failStart || startCalls == failStartOnCall) {
      return const LiveActivityOperationResult(
        succeeded: false,
        supported: true,
        enabled: false,
        failure: 'fixture Live Activity failure',
      );
    }
    return const LiveActivityOperationResult(
      succeeded: true,
      supported: true,
      enabled: true,
      activityId: 'activity-1',
      action: 'started',
    );
  }

  @override
  Future<LiveActivityOperationResult> end({String? activityId}) async {
    endCalls++;
    if (failEnd) {
      return const LiveActivityOperationResult(
        succeeded: false,
        supported: true,
        enabled: true,
        failure: 'fixture Live Activity end failure',
      );
    }
    return const LiveActivityOperationResult(
      succeeded: true,
      supported: true,
      enabled: true,
    );
  }
}

class _ControlledNativeAlarmGateway implements NativeAlarmGateway {
  _ControlledNativeAlarmGateway({this.unresolved = false});

  final bool unresolved;

  @override
  Future<NativeAlarmCapabilities> capabilities() async =>
      const NativeAlarmCapabilities(
        alarmKitSupported: true,
        backend: NativeAlarmBackend.alarmKit,
      );

  @override
  Future<NativeAlarmAuthorization> authorizationState() async =>
      NativeAlarmAuthorization.authorized;

  @override
  Future<NativeAlarmAuthorization> requestAuthorization() async =>
      NativeAlarmAuthorization.authorized;

  @override
  Future<NativeAlarmScheduleResult> schedule(DateTime fireAt) async {
    if (!unresolved) {
      return const NativeAlarmScheduleResult(
        accepted: false,
        confirmed: false,
        backend: NativeAlarmBackend.alarmKit,
        failure: 'fixture AlarmKit schedule failure',
      );
    }
    final record = NativeAlarmRecord(
      id: 'unresolved-alarm',
      requestedFireTime: fireAt,
      scheduledFireTime: null,
      state: NativeAlarmState.unknown,
      backend: NativeAlarmBackend.alarmKit,
      sessionId: 'session-1',
      revision: 1,
    );
    return NativeAlarmScheduleResult(
      accepted: false,
      confirmed: false,
      backend: NativeAlarmBackend.alarmKit,
      alarm: record,
      failure: 'fixture unresolved schedule',
      unresolved: true,
    );
  }

  @override
  Future<AlarmOperationResult> promoteSession(NativeAlarmRecord alarm) async =>
      const AlarmOperationResult.success();

  @override
  Future<NativeAlarmSessionSnapshot> sessionSnapshot() async =>
      const NativeAlarmSessionSnapshot(
        reconciliationAvailable: false,
        sessionExists: false,
        isProtected: false,
        protectionStatus: NativeAlarmProtectionStatus.unverified,
      );

  @override
  Future<NativeAlarmQueryResult> alarms() async =>
      const NativeAlarmQueryResult(alarms: []);

  @override
  Future<AlarmOperationResult> cancel(NativeAlarmRecord alarm) async =>
      const AlarmOperationResult.success();

  @override
  Future<AlarmOperationResult> stopAlerting(NativeAlarmRecord alarm) async =>
      const AlarmOperationResult.success();

  @override
  Future<AlarmOperationResult> startLegacyNow() async =>
      const AlarmOperationResult.success();

  @override
  Future<AlarmOperationResult> stopLegacyPlayback() async =>
      const AlarmOperationResult.success();
}
