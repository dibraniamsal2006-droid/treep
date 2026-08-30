import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:http/http.dart' as http;
import 'package:treep/models/trip_candidate.dart';
import 'package:treep/services/alarm_service.dart';
import 'package:treep/services/ojp_public_direction_service.dart';
import 'package:treep/services/transport_service.dart';

const int defaultReliabilitySeed = 830291;

enum ReliabilityCampaign {
  alarmTransaction,
  journeyIdentity,
  stopQualification,
  providerResilience,
}

class ReliabilityScenario {
  const ReliabilityScenario({
    required this.id,
    required this.seed,
    required this.campaign,
    required this.variant,
    required this.noiseJourneys,
    required this.delayMinutes,
    required this.tripId,
    required this.originalTripId,
    required this.route,
    required this.startDate,
    required this.startTime,
    required this.direction,
    required this.destinationStop,
    required this.orderedStops,
  });

  final int id;
  final int seed;
  final ReliabilityCampaign campaign;
  final String variant;
  final int noiseJourneys;
  final int delayMinutes;
  final String tripId;
  final String originalTripId;
  final String route;
  final String startDate;
  final String startTime;
  final String direction;
  final String destinationStop;
  final List<String> orderedStops;

  String get signature =>
      '$id|$seed|${campaign.name}|$variant|$noiseJourneys|$delayMinutes|'
      '$tripId|$originalTripId|$route|$startDate|$startTime|$direction|'
      '$destinationStop|${orderedStops.join('>')}';
}

class ReliabilityScenarioGenerator {
  const ReliabilityScenarioGenerator({required this.masterSeed});

  final int masterSeed;

  int scenarioSeed(int scenarioId) {
    var value = masterSeed & 0x7fffffff;
    value = (value ^ ((scenarioId + 1) * 0x45d9f3b)) & 0x7fffffff;
    value = (value * 1103515245 + 12345) & 0x7fffffff;
    return value;
  }

  ReliabilityScenario generate(int scenarioId) {
    final seed = scenarioSeed(scenarioId);
    final random = Random(seed);
    final campaign = ReliabilityCampaign
        .values[scenarioId % ReliabilityCampaign.values.length];
    final variants = switch (campaign) {
      ReliabilityCampaign.alarmTransaction => _alarmVariants,
      ReliabilityCampaign.journeyIdentity => _matchingVariants,
      ReliabilityCampaign.stopQualification => _stopVariants,
      ReliabilityCampaign.providerResilience => _providerVariants,
    };
    final campaignOrdinal = scenarioId ~/ ReliabilityCampaign.values.length;
    final route = const ['S20', 'S22', 'IR55'][random.nextInt(3)];
    final destination = const [
      '8500207',
      '8500212',
      '8503000',
    ][random.nextInt(3)];
    final terminal = const ['8500218', '8500991', '8500992'][random.nextInt(3)];
    final minute = random.nextBool() ? '00' : '30';
    return ReliabilityScenario(
      id: scenarioId,
      seed: seed,
      campaign: campaign,
      variant: variants[campaignOrdinal % variants.length],
      noiseJourneys: 3 + random.nextInt(18),
      delayMinutes: 1 + random.nextInt(180),
      tripId: 'trip-${random.nextInt(1000000)}',
      originalTripId: 'ch:1:sjyid:${random.nextInt(1000000)}',
      route: route,
      startDate: '202608${20 + random.nextInt(9)}',
      startTime: '${6 + random.nextInt(14)}:$minute:00',
      direction: terminal,
      destinationStop: destination,
      orderedStops: ['8500001', destination, terminal],
    );
  }

  List<String> alarmOperations(ReliabilityScenario scenario) {
    final random = Random(scenario.seed ^ 0x5f3759df);
    final count = 4 + random.nextInt(46);
    const operations = <String>[
      'replace_success',
      'schedule_failure',
      'promotion_failure',
      'ambiguous_promotion',
      'cancel_success',
      'cancel_failure',
    ];
    return List<String>.generate(
      count,
      (_) => operations[random.nextInt(operations.length)],
      growable: false,
    );
  }

  List<String> completionPermutation(ReliabilityScenario scenario) =>
      scenario.seed.isEven
      ? const ['start-A', 'start-B', 'complete-A', 'complete-B']
      : const ['start-A', 'start-B', 'complete-B', 'complete-A'];
}

const _alarmVariants = <String>[
  'initial_success',
  'replacement_success',
  'schedule_failure',
  'promotion_failure',
  'ambiguous_promotion',
  'unresolved_schedule',
  'cancel',
  'cancel_failure',
  'overlap_stale_completion',
  'stop_inflight',
  'alarmkit_failure_truth',
];
const _matchingVariants = <String>[
  'exact_identity',
  'same_line_collision',
  'adjacent_service',
  'opposite_direction',
  'delayed_previous',
  'tempting_wrong_eta',
  'missing_trip_id',
  'extreme_delay',
  'wrong_then_correct',
  'disappear_recover',
];
const _stopVariants = <String>[
  'valid_downstream',
  'origin_rejection',
  'no_previous_call',
  'skipped_stop',
  'missing_arrival',
  'departure_only',
  'duplicate_stop',
  'unordered_sequence',
  'normalized_id_variant',
  'missing_stop_id',
  'missing_stop_sequence',
  'absurd_delay',
];
const _providerVariants = <String>[
  'stationboard_success',
  'stationboard_empty',
  'stationboard_malformed_json',
  'stationboard_unexpected_type',
  'stationboard_missing_board',
  'stationboard_missing_stop',
  'stationboard_missing_arrival',
  'stationboard_departure_only',
  'stationboard_malformed_prognosis',
  'stationboard_early_prognosis',
  'stationboard_delayed_prognosis',
  'stationboard_duplicate_services',
  'stationboard_collision',
  'gtfs_missing_descriptor',
  'gtfs_missing_trip_id',
  'gtfs_missing_start_date',
  'gtfs_missing_start_time',
  'gtfs_missing_stop_id',
  'gtfs_missing_arrival',
  'gtfs_departure_only',
  'gtfs_duplicate_trip_updates',
  'gtfs_duplicate_stop_updates',
  'gtfs_non_increasing_sequence',
  'gtfs_missing_stop_sequence',
  'gtfs_skipped_stop',
  'gtfs_absurd_delay',
  'gtfs_empty_feed',
  'gtfs_conflicting_entities',
  'ojp_malformed_xml',
  'ojp_missing_journey_ref',
  'ojp_missing_operating_day',
  'ojp_missing_destination',
  'ojp_ambiguous_exact_records',
  'ojp_direction_disagreement',
  'ojp_missing_previous_call',
  'realtime_disappearance_recovery',
  'provider_failure_recovery',
  'provider_reordered_responses',
];

class ReliabilityEventRecorder {
  final List<String> _events = [];

  void add(String event) => _events.add(event);

  List<String> get events => List<String>.unmodifiable(_events);

  String get formatted => [
    for (var index = 0; index < _events.length; index++)
      '${(index + 1).toString().padLeft(2, '0')} ${_events[index]}',
  ].join('\n');
}

class ReliabilityCoverage {
  final Map<String, int> _counts = {};

  void hit(String bucket, [int amount = 1]) {
    _counts[bucket] = (_counts[bucket] ?? 0) + amount;
  }

  int operator [](String bucket) => _counts[bucket] ?? 0;

  Map<String, int> get counts => Map<String, int>.unmodifiable(_counts);

  String get summary {
    final keys = _counts.keys.toList()..sort();
    return keys.map((key) => '$key=${_counts[key]}').join(', ');
  }
}

class ReliabilityViolation implements Exception {
  const ReliabilityViolation(this.invariant, this.message);

  final String invariant;
  final String message;

  @override
  String toString() => '$invariant: $message';
}

class ReliabilityInvariantChecker {
  const ReliabilityInvariantChecker();

  void require(bool condition, String invariant, String message) {
    if (!condition) throw ReliabilityViolation(invariant, message);
  }

  void protectedAlarmSurvives(
    ConfirmedAlarm<String>? previous,
    ConfirmedAlarm<String>? current,
  ) {
    require(
      previous != null && identical(previous, current),
      'I1 PROTECTED ALARM SURVIVAL / I3 FAILED REPLACEMENT PRESERVES PREVIOUS',
      'failed replacement did not retain the exact previous confirmation',
    );
  }

  void alarmKitFailureIsTruthful(AlarmArmResult<String> result) {
    require(
      !result.succeeded && result.confirmed == null,
      'I9 ALARMKIT FAILURE TRUTH',
      'definitive AlarmKit failure produced successful confirmation',
    );
  }

  void journeyIsolation({
    required TripCandidate? refreshed,
    required String expectedTripId,
    required DateTime expectedEta,
  }) {
    require(
      refreshed?.tripId == expectedTripId,
      'I4 JOURNEY ISOLATION',
      'refresh selected ${refreshed?.tripId} instead of $expectedTripId',
    );
    require(
      refreshed!.etaLocal.difference(expectedEta).inSeconds.abs() <= 1,
      'I5 STOP/ARRIVAL ISOLATION',
      'refresh attached ETA ${refreshed.etaLocal.toIso8601String()} instead of ${expectedEta.toIso8601String()}',
    );
  }
}

class ReliabilityFailure {
  const ReliabilityFailure({
    required this.masterSeed,
    required this.scenario,
    required this.invariant,
    required this.message,
    required this.events,
  });

  final int masterSeed;
  final ReliabilityScenario scenario;
  final String invariant;
  final String message;
  final List<String> events;

  String get affectedPath => switch (scenario.campaign) {
    ReliabilityCampaign.alarmTransaction =>
      'AlarmTransactionCoordinator.arm/stop reconciliation',
    ReliabilityCampaign.journeyIdentity =>
      'TransportService.refreshCandidateEta exact identity join',
    ReliabilityCampaign.stopQualification =>
      'TransportService._qualifiedDownstreamArrivals/findCandidates',
    ReliabilityCampaign.providerResilience =>
      'TransportService provider parsing/fallback or OjpStopEventClient parser',
  };

  String get diagnostic =>
      '''
TREEP RELIABILITY FAILURE

Master seed: $masterSeed
Scenario: ${scenario.id}
Scenario seed: ${scenario.seed}
Campaign: ${scenario.campaign.name}
Variant: ${scenario.variant}
Invariant: $invariant
Likely affected path: $affectedPath
Noise journeys: ${scenario.noiseJourneys}
Delay minutes: ${scenario.delayMinutes}
Active journey: tripId=${scenario.tripId} originalTripId=${scenario.originalTripId} route=${scenario.route} startDate=${scenario.startDate} startTime=${scenario.startTime}
Direction: ${scenario.direction}
Destination: ${scenario.destinationStop}
Ordered stops: ${scenario.orderedStops.join(' > ')}

Expected/actual state: $message

Events:
${[for (var index = 0; index < events.length; index++) '${(index + 1).toString().padLeft(2, '0')} ${events[index]}'].join('\n')}

Rerun: flutter test test/reliability/seeded_reliability_harness_test.dart --dart-define=TREEP_RELIABILITY_SEED=$masterSeed --dart-define=TREEP_RELIABILITY_SCENARIO_ID=${scenario.id}
''';
}

class ReliabilityRunReport {
  const ReliabilityRunReport({
    required this.masterSeed,
    required this.executed,
    required this.coverage,
    required this.failures,
    required this.elapsed,
  });

  final int masterSeed;
  final int executed;
  final ReliabilityCoverage coverage;
  final List<ReliabilityFailure> failures;
  final Duration elapsed;

  String get summary =>
      'TREEP RELIABILITY seed=$masterSeed scenarios=$executed violations=${failures.length} runtimeMs=${elapsed.inMilliseconds}\n${coverage.summary}';
}

class SeededReliabilityHarness {
  SeededReliabilityHarness({this.masterSeed = defaultReliabilitySeed})
    : generator = ReliabilityScenarioGenerator(masterSeed: masterSeed);

  final int masterSeed;
  final ReliabilityScenarioGenerator generator;
  final _checker = const ReliabilityInvariantChecker();

  Future<ReliabilityRunReport> run({
    required int scenarioCount,
    int? scenarioId,
  }) async {
    final stopwatch = Stopwatch()..start();
    final coverage = ReliabilityCoverage();
    final failures = <ReliabilityFailure>[];
    final ids = scenarioId == null
        ? Iterable<int>.generate(scenarioCount)
        : <int>[scenarioId];

    for (final id in ids) {
      final scenario = generator.generate(id);
      final recorder = ReliabilityEventRecorder()
        ..add('generated ${scenario.campaign.name}/${scenario.variant}');
      coverage
        ..hit('scenarios_executed')
        ..hit('${scenario.campaign.name}_scenarios');
      try {
        switch (scenario.campaign) {
          case ReliabilityCampaign.alarmTransaction:
            await _runAlarm(scenario, recorder, coverage);
          case ReliabilityCampaign.journeyIdentity:
            await _runJourney(scenario, recorder, coverage);
          case ReliabilityCampaign.stopQualification:
            _runStops(scenario, recorder, coverage);
          case ReliabilityCampaign.providerResilience:
            await _runProvider(scenario, recorder, coverage);
        }
      } on ReliabilityViolation catch (failure) {
        coverage.hit('invariant_violations');
        recorder.add('ERROR ${failure.invariant}: ${failure.message}');
        failures.add(
          ReliabilityFailure(
            masterSeed: masterSeed,
            scenario: scenario,
            invariant: failure.invariant,
            message: failure.message,
            events: recorder.events,
          ),
        );
      } catch (error) {
        coverage.hit('invariant_violations');
        recorder.add('ERROR unexpected harness/production exception: $error');
        failures.add(
          ReliabilityFailure(
            masterSeed: masterSeed,
            scenario: scenario,
            invariant: 'UNEXPECTED EXCEPTION',
            message: error.toString(),
            events: recorder.events,
          ),
        );
      }
    }

    stopwatch.stop();
    return ReliabilityRunReport(
      masterSeed: masterSeed,
      executed: scenarioId == null ? scenarioCount : 1,
      coverage: coverage,
      failures: List<ReliabilityFailure>.unmodifiable(failures),
      elapsed: stopwatch.elapsed,
    );
  }

  Future<void> _runAlarm(
    ReliabilityScenario scenario,
    ReliabilityEventRecorder recorder,
    ReliabilityCoverage coverage,
  ) async {
    coverage.hit('alarm_${scenario.variant}');
    await _runAlarmSequence(scenario, recorder, coverage);
    final notifications = _HarnessNotificationGateway(recorder);
    final native = _HarnessNativeAlarmGateway(recorder);
    final coordinator = AlarmTransactionCoordinator<String>(
      native: native,
      notifications: notifications,
      nativeSchedulingEnabled: true,
      trace: recorder.add,
    );

    Future<AlarmArmResult<String>> arm(String selection, int id) =>
        coordinator.arm(
          selection: selection,
          plan: _alarmPlan(id),
          requestPermissions: true,
        );

    if (scenario.variant == 'initial_success') {
      final result = await arm('A', 100);
      _checker.require(
        result.succeeded && coordinator.confirmed?.selection == 'A',
        'I2 STABLE SINGLE CURRENT ALARM',
        'initial arm did not produce one stable current alarm',
      );
      return;
    }

    if (scenario.variant == 'alarmkit_failure_truth') {
      native.failNextSchedule = true;
      final result = await arm('A', 100);
      _checker.alarmKitFailureIsTruthful(result);
      _checker.require(
        notifications.activeIds.isEmpty,
        'I9 ALARMKIT FAILURE TRUTH',
        'failed AlarmKit transaction leaked notification artifacts',
      );
      return;
    }

    final initial = await arm('A', 100);
    _checker.require(
      initial.succeeded,
      'I2 STABLE SINGLE CURRENT ALARM',
      'scenario setup could not confirm alarm A',
    );
    final previous = coordinator.confirmed;

    switch (scenario.variant) {
      case 'replacement_success':
        coverage.hit('alarm_replacement_attempts');
        final replacement = await arm('B', 200);
        _checker.require(
          replacement.succeeded && coordinator.confirmed?.selection == 'B',
          'I2 STABLE SINGLE CURRENT ALARM',
          'successful replacement did not commit B',
        );
        _checker.require(
          native.active.length == 1,
          'I2 STABLE SINGLE CURRENT ALARM',
          'reconciled replacement left ${native.active.length} stable native alarms',
        );
      case 'schedule_failure':
        coverage
          ..hit('alarm_replacement_attempts')
          ..hit('alarm_schedule_failures')
          ..hit('alarm_definitive_failures');
        native.failNextSchedule = true;
        final replacement = await arm('B', 200);
        _checker.require(
          !replacement.succeeded,
          'I3 FAILED REPLACEMENT PRESERVES PREVIOUS',
          'definitive schedule failure unexpectedly succeeded',
        );
        _checker.protectedAlarmSurvives(previous, coordinator.confirmed);
      case 'promotion_failure':
        coverage
          ..hit('alarm_replacement_attempts')
          ..hit('alarm_promotion_failures')
          ..hit('alarm_definitive_failures');
        native.failNextPromotion = true;
        final replacement = await arm('B', 200);
        _checker.require(
          !replacement.succeeded,
          'I3 FAILED REPLACEMENT PRESERVES PREVIOUS',
          'promotion failure unexpectedly succeeded',
        );
        _checker.protectedAlarmSurvives(previous, coordinator.confirmed);
      case 'ambiguous_promotion':
        coverage
          ..hit('alarm_replacement_attempts')
          ..hit('alarm_ambiguous_outcomes');
        native.ambiguousNextPromotion = true;
        final replacement = await arm('B', 200);
        _checker.require(
          !replacement.succeeded && !replacement.transactionUnverified,
          'I3 FAILED REPLACEMENT PRESERVES PREVIOUS',
          'reconcilable ambiguous promotion was not safely rejected',
        );
        _checker.protectedAlarmSurvives(previous, coordinator.confirmed);
      case 'unresolved_schedule':
        coverage
          ..hit('alarm_replacement_attempts')
          ..hit('alarm_ambiguous_outcomes')
          ..hit('alarm_unresolved_cases');
        native.unresolvedNextSchedule = true;
        final replacement = await arm('B', 200);
        _checker.require(
          !replacement.succeeded && replacement.transactionUnverified,
          'I1 PROTECTED ALARM SURVIVAL',
          'unresolved schedule was not reported conservatively',
        );
        _checker.protectedAlarmSurvives(previous, coordinator.confirmed);
      case 'cancel':
        coverage.hit('alarm_cancellations');
        final stopped = await coordinator.stop();
        _checker.require(
          stopped.succeeded && coordinator.confirmed == null,
          'I2 STABLE SINGLE CURRENT ALARM',
          'confirmed cancellation left a current alarm',
        );
      case 'cancel_failure':
        coverage
          ..hit('alarm_cancellations')
          ..hit('alarm_cancel_failures');
        native.failCancellation = true;
        final stopped = await coordinator.stop();
        _checker.require(
          !stopped.succeeded &&
              coordinator.confirmed?.selection == previous?.selection &&
              coordinator.confirmed?.nativeAlarm?.id ==
                  previous?.nativeAlarm?.id,
          'I1 PROTECTED ALARM SURVIVAL',
          'failed cancellation hid the possibly-live alarm',
        );
      case 'overlap_stale_completion':
        coverage
          ..hit('alarm_replacement_attempts', 2)
          ..hit('alarm_stale_completions')
          ..hit('order_race_permutations');
        final gate = Completer<NotificationScheduleResult>();
        notifications.scheduleGate = gate;
        final older = arm('B', 200);
        await Future<void>.delayed(Duration.zero);
        final newer = await arm('C', 300);
        gate.complete(
          const NotificationScheduleResult(succeeded: true, ids: [200]),
        );
        final stale = await older;
        _checker.require(
          newer.succeeded &&
              !stale.succeeded &&
              coordinator.confirmed?.selection == 'C',
          'I10 STALE OPERATION ISOLATION',
          'late B completion overwrote or prevented committed C',
        );
      case 'stop_inflight':
        coverage
          ..hit('alarm_replacement_attempts')
          ..hit('alarm_cancellations')
          ..hit('cancel_replacement_interleavings')
          ..hit('order_race_permutations');
        final gate = Completer<void>();
        native.scheduleGate = gate;
        final replacement = arm('B', 200);
        await Future<void>.delayed(Duration.zero);
        final stopping = coordinator.stop();
        gate.complete();
        await replacement;
        final stopped = await stopping;
        _checker.require(
          stopped.succeeded &&
              coordinator.confirmed == null &&
              native.active.isEmpty,
          'I10 STALE OPERATION ISOLATION',
          'stop during in-flight replacement left stable protection behind',
        );
      default:
        throw StateError('unknown alarm variant ${scenario.variant}');
    }
  }

  Future<void> _runAlarmSequence(
    ReliabilityScenario scenario,
    ReliabilityEventRecorder recorder,
    ReliabilityCoverage coverage,
  ) async {
    final notifications = _HarnessNotificationGateway(recorder);
    final native = _HarnessNativeAlarmGateway(recorder);
    final coordinator = AlarmTransactionCoordinator<String>(
      native: native,
      notifications: notifications,
      nativeSchedulingEnabled: true,
      trace: recorder.add,
    );
    var nextId = 1000 + scenario.id * 100;
    var selectionOrdinal = 0;

    Future<AlarmArmResult<String>> arm() {
      selectionOrdinal++;
      nextId++;
      return coordinator.arm(
        selection: 'SEQ-$selectionOrdinal',
        plan: _alarmPlan(nextId),
        requestPermissions: true,
      );
    }

    final initial = await arm();
    coverage
      ..hit('alarm_sequences')
      ..hit('alarm_state_transitions');
    _checker.require(
      initial.succeeded && coordinator.confirmed != null,
      'I2 STABLE SINGLE CURRENT ALARM',
      'sequence setup failed to establish a current alarm',
    );

    final operations = generator.alarmOperations(scenario);
    recorder.add('alarm sequence operations=${operations.join('>')}');
    for (final operation in operations) {
      coverage.hit('alarm_state_transitions');
      if (coordinator.confirmed == null) {
        final result = await arm();
        coverage.hit('alarm_rearms_after_cancel');
        _checker.require(
          result.succeeded && coordinator.confirmed != null,
          'I2 STABLE SINGLE CURRENT ALARM',
          're-arm after cancellation did not establish protection',
        );
        continue;
      }

      final previousSelection = coordinator.confirmed!.selection;
      switch (operation) {
        case 'replace_success':
          coverage.hit('alarm_replacement_attempts');
          final result = await arm();
          _checker.require(
            result.succeeded &&
                coordinator.confirmed != null &&
                coordinator.confirmed!.selection != previousSelection,
            'I2 STABLE SINGLE CURRENT ALARM',
            'successful sequence replacement did not commit the new selection',
          );
        case 'schedule_failure':
          coverage
            ..hit('alarm_replacement_attempts')
            ..hit('alarm_schedule_failures')
            ..hit('alarm_definitive_failures');
          native.failNextSchedule = true;
          final result = await arm();
          _checker.require(
            !result.succeeded &&
                coordinator.confirmed?.selection == previousSelection,
            'I3 FAILED REPLACEMENT PRESERVES PREVIOUS',
            'sequence schedule failure did not preserve the prior selection',
          );
        case 'promotion_failure':
          coverage
            ..hit('alarm_replacement_attempts')
            ..hit('alarm_promotion_failures')
            ..hit('alarm_definitive_failures');
          native.failNextPromotion = true;
          final result = await arm();
          _checker.require(
            !result.succeeded &&
                coordinator.confirmed?.selection == previousSelection,
            'I3 FAILED REPLACEMENT PRESERVES PREVIOUS',
            'sequence promotion failure did not preserve the prior selection',
          );
        case 'ambiguous_promotion':
          coverage
            ..hit('alarm_replacement_attempts')
            ..hit('alarm_ambiguous_outcomes');
          native.ambiguousNextPromotion = true;
          final result = await arm();
          _checker.require(
            !result.succeeded &&
                coordinator.confirmed?.selection == previousSelection,
            'I1 PROTECTED ALARM SURVIVAL',
            'ambiguous promotion did not conservatively preserve the prior selection',
          );
        case 'cancel_success':
          coverage.hit('alarm_cancellations');
          final result = await coordinator.stop();
          _checker.require(
            result.succeeded && coordinator.confirmed == null,
            'I2 STABLE SINGLE CURRENT ALARM',
            'successful sequence cancellation retained a current alarm',
          );
        case 'cancel_failure':
          coverage
            ..hit('alarm_cancellations')
            ..hit('alarm_cancel_failures');
          native.failCancellation = true;
          final result = await coordinator.stop();
          native.failCancellation = false;
          _checker.require(
            !result.succeeded &&
                coordinator.confirmed?.selection == previousSelection,
            'I1 PROTECTED ALARM SURVIVAL',
            'failed sequence cancellation hid the current alarm',
          );
        default:
          throw StateError('unknown alarm sequence operation $operation');
      }
    }
  }

  Future<void> _runJourney(
    ReliabilityScenario scenario,
    ReliabilityEventRecorder recorder,
    ReliabilityCoverage coverage,
  ) async {
    coverage
      ..hit('matching_${scenario.variant}')
      ..hit('journey_collision_cases');
    final base = _scenarioTime(scenario);
    final activeTrip = scenario.tripId;
    final activeStart = scenario.startTime;
    final effectiveDelay = scenario.variant == 'extreme_delay'
        ? 12 * 60 + scenario.delayMinutes
        : scenario.delayMinutes;
    final expectedEta = base.add(Duration(minutes: effectiveDelay));
    final entities = <FeedEntity>[];

    for (var index = 0; index < scenario.noiseJourneys; index++) {
      final isAdjacent = index < 2;
      entities.add(
        _journeyEntity(
          tripId: 'noise-$index',
          startTime: isAdjacent
              ? activeStart
              : '${10 + (index ~/ 2)}:${index.isEven ? '15' : '45'}:00',
          eta: index == 0
              ? expectedEta.subtract(const Duration(seconds: 15))
              : base.add(Duration(minutes: index + 2)),
          terminal: index.isEven ? '8500991' : '8500992',
          route: scenario.route,
          startDate: index == 1 ? '20260819' : scenario.startDate,
          destinationStop: scenario.destinationStop,
        ),
      );
    }
    coverage
      ..hit('journey_same_line_collisions')
      ..hit('journey_adjacent_service_collisions')
      ..hit('journey_opposite_direction_collisions')
      ..hit('journey_noise_entities', scenario.noiseJourneys);
    if (scenario.variant == 'delayed_previous') {
      coverage.hit('journey_delayed_previous');
    }
    if (scenario.variant == 'tempting_wrong_eta') {
      coverage.hit('journey_wrong_identity_tempting_eta');
    }
    if (scenario.variant == 'missing_trip_id') {
      coverage.hit('journey_missing_identity');
    }
    if (scenario.variant == 'extreme_delay') {
      coverage.hit('journey_large_eta_changes');
    }

    final shouldMatch =
        scenario.variant != 'tempting_wrong_eta' &&
        scenario.variant != 'missing_trip_id';
    final feedTripId = switch (scenario.variant) {
      'tempting_wrong_eta' => 'wrong-trip',
      'missing_trip_id' => '',
      _ => activeTrip,
    };
    entities.add(
      _journeyEntity(
        tripId: feedTripId,
        startTime: activeStart,
        eta: expectedEta,
        terminal: scenario.variant == 'opposite_direction'
            ? '8500992'
            : scenario.direction,
        route: scenario.route,
        startDate: scenario.startDate,
        destinationStop: scenario.destinationStop,
      ),
    );
    entities.shuffle(Random(scenario.seed ^ 0x13579bdf));
    recorder.add(
      'injected active=$activeTrip feedTrip=$feedTripId competitors=${scenario.noiseJourneys} eta=${expectedEta.toIso8601String()}',
    );

    final candidate = _journeyCandidate(
      tripId: activeTrip,
      startTime: activeStart,
      eta: base,
      originalTripId: scenario.originalTripId,
      route: scenario.route,
      startDate: scenario.startDate,
      destinationStop: scenario.destinationStop,
      direction: scenario.direction,
    );
    Future<TripCandidate?> refresh(List<FeedEntity> feedEntities) =>
        _HarnessFeedTransportService(
          FeedMessage(entity: feedEntities),
        ).refreshCandidateEta(candidate);

    if (scenario.variant == 'wrong_then_correct') {
      coverage
        ..hit('journey_wrong_identity_tempting_eta')
        ..hit('realtime_recovery_sequences');
      final wrong = await refresh([
        _journeyEntity(
          tripId: 'wrong-trip',
          startTime: activeStart,
          eta: expectedEta,
          terminal: scenario.direction,
          route: scenario.route,
          startDate: scenario.startDate,
          destinationStop: scenario.destinationStop,
        ),
      ]);
      _checker.require(
        wrong == null,
        'I4 JOURNEY ISOLATION / I8 NO FALSE PROVIDER MATCH',
        'wrong identity mutated the active journey before recovery',
      );
      coverage.hit('provider_reordered_or_stale_cases');
    }

    if (scenario.variant == 'disappear_recover') {
      coverage.hit('realtime_recovery_sequences');
      final missing = await refresh(const []);
      _checker.require(
        missing == null,
        'I4 JOURNEY ISOLATION',
        'empty realtime feed fabricated an active-journey mutation',
      );
    }

    final refreshed = await refresh(entities);
    recorder.add('refresh result=${refreshed?.tripId ?? 'null'}');

    if (!shouldMatch) {
      _checker.require(
        refreshed == null,
        'I4 JOURNEY ISOLATION / I8 NO FALSE PROVIDER MATCH',
        '${scenario.variant} produced a fabricated exact refresh',
      );
      return;
    }
    _checker.journeyIsolation(
      refreshed: refreshed,
      expectedTripId: activeTrip,
      expectedEta: expectedEta,
    );
  }

  void _runStops(
    ReliabilityScenario scenario,
    ReliabilityEventRecorder recorder,
    ReliabilityCoverage coverage,
  ) {
    coverage
      ..hit('stop_${scenario.variant}')
      ..hit('stop_arrival_scenarios');
    const destination = '8500212';
    const prior = '8500207';
    const middle = '8500208';
    final base = _scenarioTime(scenario);
    List<TripUpdate_StopTimeUpdate> stops;
    var expectedMatch = false;

    switch (scenario.variant) {
      case 'valid_downstream':
        coverage.hit('stop_downstream_valid');
        expectedMatch = true;
        stops = [
          _stopUpdate(1, prior, base, departure: true),
          _stopUpdate(2, destination, base.add(const Duration(minutes: 10))),
        ];
      case 'origin_rejection':
        coverage.hit('stop_origin_rejection_cases');
        stops = [
          _stopUpdate(1, destination, base, departure: true),
          _stopUpdate(2, middle, base.add(const Duration(minutes: 10))),
        ];
      case 'no_previous_call':
        stops = [
          _stopUpdate(4, destination, base.add(const Duration(minutes: 10))),
          _stopUpdate(5, middle, base.add(const Duration(minutes: 20))),
        ];
      case 'skipped_stop':
        stops = [
          _stopUpdate(1, prior, base, departure: true, skipped: true),
          _stopUpdate(2, destination, base.add(const Duration(minutes: 10))),
        ];
      case 'missing_arrival':
        coverage.hit('stop_missing_arrival_cases');
        stops = [
          _stopUpdate(1, prior, base, departure: true),
          TripUpdate_StopTimeUpdate(stopSequence: 2, stopId: destination),
        ];
      case 'departure_only':
        coverage.hit('stop_departure_only_cases');
        stops = [
          _stopUpdate(1, prior, base, departure: true),
          _stopUpdate(
            2,
            destination,
            base.add(const Duration(minutes: 10)),
            departure: true,
          ),
        ];
      case 'duplicate_stop':
        coverage.hit('stop_duplicate');
        expectedMatch = true;
        stops = [
          _stopUpdate(1, destination, base, departure: true),
          _stopUpdate(2, middle, base.add(const Duration(minutes: 10))),
          _stopUpdate(3, destination, base.add(const Duration(minutes: 20))),
        ];
      case 'unordered_sequence':
        coverage.hit('stop_unordered');
        stops = [
          _stopUpdate(2, prior, base, departure: true),
          _stopUpdate(1, destination, base.add(const Duration(minutes: 10))),
        ];
      case 'normalized_id_variant':
        coverage.hit('stop_id_normalization');
        expectedMatch = true;
        stops = [
          _stopUpdate(1, prior, base, departure: true),
          _stopUpdate(
            2,
            'platform:8500212:0:1',
            base.add(const Duration(minutes: 10)),
          ),
        ];
      case 'missing_stop_id':
        stops = [
          _stopUpdate(1, prior, base, departure: true),
          TripUpdate_StopTimeUpdate(
            stopSequence: 2,
            arrival: _stopEvent(base.add(const Duration(minutes: 10))),
          ),
        ];
      case 'missing_stop_sequence':
        expectedMatch = true;
        stops = [
          _stopUpdate(1, prior, base, departure: true),
          TripUpdate_StopTimeUpdate(
            stopId: destination,
            arrival: _stopEvent(base.add(const Duration(minutes: 10))),
          ),
        ];
      case 'absurd_delay':
        coverage.hit('stop_absurd_delay_cases');
        expectedMatch = true;
        stops = [
          _stopUpdate(1, prior, base, departure: true),
          _stopUpdate(2, destination, base.add(const Duration(days: 3))),
        ];
      default:
        throw StateError('unknown stop variant ${scenario.variant}');
    }

    final service = TransportService(trace: recorder.add);
    final candidates = service.findCandidates(
      FeedMessage(
        entity: [
          FeedEntity(
            id: 'stop-scenario',
            tripUpdate: TripUpdate(
              trip: TripDescriptor(
                tripId: 'stop-trip',
                routeId: 'S22',
                startDate: '20260829',
                startTime: '10:00:00',
              ),
              stopTimeUpdate: stops,
            ),
          ),
        ],
      ),
      'S22',
      destination,
      requireDestinationMatch: true,
    );
    recorder.add('qualified candidates=${candidates.length}');
    _checker.require(
      expectedMatch ? candidates.length == 1 : candidates.isEmpty,
      expectedMatch
          ? 'I6 DOWNSTREAM DESTINATION'
          : 'I7 ORIGIN REJECTION / I5 STOP/ARRIVAL ISOLATION',
      '${scenario.variant} expectedMatch=$expectedMatch candidates=${candidates.length}',
    );
  }

  Future<void> _runProvider(
    ReliabilityScenario scenario,
    ReliabilityEventRecorder recorder,
    ReliabilityCoverage coverage,
  ) async {
    coverage
      ..hit('provider_failure_scenarios')
      ..hit('provider_${scenario.variant}');
    if (scenario.variant != 'stationboard_success') {
      coverage.hit('provider_failure_malformed_cases');
    }
    if (scenario.variant.startsWith('stationboard_')) {
      coverage.hit('provider_stationboard_malformed_degraded');
      await _runStationboardProvider(scenario, recorder, coverage);
      return;
    }
    if (scenario.variant.startsWith('gtfs_')) {
      coverage.hit('provider_gtfs_malformed_degraded');
      _runGtfsProvider(scenario, recorder);
      return;
    }
    if (scenario.variant.startsWith('ojp_')) {
      coverage.hit('provider_ojp_malformed_degraded');
      _runOjpProvider(scenario, recorder, coverage);
      return;
    }
    await _runProviderSequence(scenario, recorder, coverage);
  }

  Future<void> _runStationboardProvider(
    ReliabilityScenario scenario,
    ReliabilityEventRecorder recorder,
    ReliabilityCoverage coverage,
  ) async {
    final scheduled = DateTime.now().add(const Duration(hours: 1));
    final valid = _stationboardItem(scheduled, name: 'S22');
    late http.Response response;
    var expectedCount = 0;
    switch (scenario.variant) {
      case 'stationboard_success':
        response = _jsonResponse({
          'stationboard': [valid],
        });
        expectedCount = 1;
      case 'stationboard_empty':
        response = _jsonResponse({'stationboard': const []});
      case 'stationboard_malformed_json':
        response = http.Response('{malformed', 200);
      case 'stationboard_unexpected_type':
        response = _jsonResponse(const ['unexpected']);
      case 'stationboard_missing_board':
        response = _jsonResponse(const {'message': 'missing'});
      case 'stationboard_missing_stop':
        response = _jsonResponse({
          'stationboard': [Map<String, dynamic>.from(valid)..remove('stop')],
        });
      case 'stationboard_missing_arrival':
        final item = _copyStationboard(valid);
        (item['stop'] as Map<String, dynamic>).remove('arrivalTimestamp');
        response = _jsonResponse({
          'stationboard': [item],
        });
      case 'stationboard_departure_only':
        final item = _copyStationboard(valid);
        final stop = item['stop'] as Map<String, dynamic>;
        stop['departureTimestamp'] = stop.remove('arrivalTimestamp');
        response = _jsonResponse({
          'stationboard': [item],
        });
        expectedCount = 1;
      case 'stationboard_malformed_prognosis':
        final item = _copyStationboard(valid);
        (item['stop'] as Map<String, dynamic>)['prognosis'] = 'invalid';
        response = _jsonResponse({
          'stationboard': [item],
        });
        expectedCount = 1;
      case 'stationboard_early_prognosis':
        final item = _copyStationboard(valid);
        (item['stop'] as Map<String, dynamic>)['prognosis'] = {
          'arrival': scheduled
              .subtract(const Duration(hours: 8))
              .toIso8601String(),
        };
        response = _jsonResponse({
          'stationboard': [item],
        });
        expectedCount = 1;
      case 'stationboard_delayed_prognosis':
        final item = _copyStationboard(valid);
        (item['stop'] as Map<String, dynamic>)['prognosis'] = {
          'arrival': scheduled.add(const Duration(days: 3)).toIso8601String(),
        };
        response = _jsonResponse({
          'stationboard': [item],
        });
        expectedCount = 1;
      case 'stationboard_duplicate_services':
        response = _jsonResponse({
          'stationboard': [valid, valid],
        });
        expectedCount = 1;
      case 'stationboard_collision':
        coverage.hit('provider_conflicting_ambiguous');
        response = _jsonResponse({
          'stationboard': [valid, _stationboardItem(scheduled, name: 'S20')],
        });
        expectedCount = 1;
      default:
        throw StateError('unknown stationboard variant ${scenario.variant}');
    }
    final service = _stationboardService(recorder, (_) async => response);
    final arrivals = await _fallback(service);
    recorder.add('stationboard candidates=${arrivals.length}');
    _checker.require(
      arrivals.length == expectedCount,
      'I8 NO FALSE PROVIDER MATCH',
      '${scenario.variant} expected=$expectedCount actual=${arrivals.length}',
    );
  }

  void _runGtfsProvider(
    ReliabilityScenario scenario,
    ReliabilityEventRecorder recorder,
  ) {
    final base = _scenarioTime(scenario);
    final validStops = <TripUpdate_StopTimeUpdate>[
      _stopUpdate(1, '8500207', base, departure: true),
      _stopUpdate(2, '8500212', base.add(const Duration(minutes: 10))),
    ];
    TripDescriptor descriptor({
      String tripId = 'gtfs-active',
      String startDate = '20260829',
      String startTime = '10:00:00',
    }) => TripDescriptor(
      tripId: tripId,
      routeId: 'S22',
      startDate: startDate,
      startTime: startTime,
    );
    FeedEntity entity(
      TripDescriptor? trip,
      List<TripUpdate_StopTimeUpdate> stops,
    ) => FeedEntity(
      id: 'gtfs-${scenario.id}',
      tripUpdate: TripUpdate(trip: trip, stopTimeUpdate: stops),
    );

    var entities = <FeedEntity>[];
    var maximumCandidates = 0;
    switch (scenario.variant) {
      case 'gtfs_missing_descriptor':
        entities = [entity(null, validStops)];
      case 'gtfs_missing_trip_id':
        entities = [entity(descriptor(tripId: ''), validStops)];
        maximumCandidates = 1;
      case 'gtfs_missing_start_date':
        entities = [entity(descriptor(startDate: ''), validStops)];
        maximumCandidates = 1;
      case 'gtfs_missing_start_time':
        entities = [entity(descriptor(startTime: ''), validStops)];
        maximumCandidates = 1;
      case 'gtfs_missing_stop_id':
        entities = [
          entity(descriptor(), [
            validStops.first,
            TripUpdate_StopTimeUpdate(
              stopSequence: 2,
              arrival: _stopEvent(base),
            ),
          ]),
        ];
      case 'gtfs_missing_arrival':
        entities = [
          entity(descriptor(), [
            validStops.first,
            TripUpdate_StopTimeUpdate(stopSequence: 2, stopId: '8500212'),
          ]),
        ];
      case 'gtfs_departure_only':
        entities = [
          entity(descriptor(), [
            validStops.first,
            _stopUpdate(2, '8500212', base, departure: true),
          ]),
        ];
      case 'gtfs_duplicate_trip_updates':
        final duplicate = entity(descriptor(), validStops);
        entities = [duplicate, duplicate];
        maximumCandidates = 2;
      case 'gtfs_duplicate_stop_updates':
        entities = [
          entity(descriptor(), [...validStops, validStops.last]),
        ];
        maximumCandidates = 1;
      case 'gtfs_non_increasing_sequence':
        entities = [
          entity(descriptor(), [
            _stopUpdate(2, '8500207', base, departure: true),
            _stopUpdate(1, '8500212', base),
          ]),
        ];
      case 'gtfs_missing_stop_sequence':
        entities = [
          entity(descriptor(), [
            validStops.first,
            TripUpdate_StopTimeUpdate(
              stopId: '8500212',
              arrival: _stopEvent(base),
            ),
          ]),
        ];
        maximumCandidates = 1;
      case 'gtfs_skipped_stop':
        entities = [
          entity(descriptor(), [
            validStops.first,
            _stopUpdate(2, '8500212', base, skipped: true),
          ]),
        ];
      case 'gtfs_absurd_delay':
        entities = [
          entity(descriptor(), [
            validStops.first,
            _stopUpdate(2, '8500212', base.add(const Duration(days: 30))),
          ]),
        ];
        maximumCandidates = 1;
      case 'gtfs_empty_feed':
        entities = const [];
      case 'gtfs_conflicting_entities':
        entities = [
          entity(descriptor(), validStops),
          entity(descriptor(tripId: 'other-trip'), validStops),
        ];
        maximumCandidates = 2;
      default:
        throw StateError('unknown GTFS variant ${scenario.variant}');
    }
    final candidates = TransportService(trace: recorder.add).findCandidates(
      FeedMessage(entity: entities),
      'S22',
      '8500212',
      requireDestinationMatch: true,
    );
    recorder.add('gtfs candidates=${candidates.length}');
    _checker.require(
      candidates.length <= maximumCandidates,
      'I5 STOP/ARRIVAL ISOLATION / I8 NO FALSE PROVIDER MATCH',
      '${scenario.variant} maximum=$maximumCandidates actual=${candidates.length}',
    );
  }

  void _runOjpProvider(
    ReliabilityScenario scenario,
    ReliabilityEventRecorder recorder,
    ReliabilityCoverage coverage,
  ) {
    if (scenario.variant == 'ojp_malformed_xml') {
      var rejected = false;
      try {
        OjpStopEventClient.parseStopEventRecords('<OJP><broken>');
      } catch (_) {
        rejected = true;
      }
      _checker.require(
        rejected,
        'I8 NO FALSE PROVIDER MATCH',
        'malformed OJP XML was accepted',
      );
      return;
    }
    final records = OjpStopEventClient.parseStopEventRecords(
      _ojpXml(scenario.variant),
    );
    recorder.add('ojp records=${records.length}');
    if (scenario.variant == 'ojp_missing_journey_ref' ||
        scenario.variant == 'ojp_missing_operating_day') {
      _checker.require(
        records.isEmpty,
        'I8 NO FALSE PROVIDER MATCH',
        '${scenario.variant} was not rejected at the OJP parser boundary',
      );
      return;
    }
    if (scenario.variant == 'ojp_ambiguous_exact_records' ||
        scenario.variant == 'ojp_direction_disagreement') {
      coverage.hit('provider_conflicting_ambiguous');
      _checker.require(
        records.length == 2,
        'I8 NO FALSE PROVIDER MATCH',
        'ambiguous OJP fixture did not preserve both records for rejection',
      );
      return;
    }
    _checker.require(
      records.length == 1,
      'I8 NO FALSE PROVIDER MATCH',
      '${scenario.variant} parser count=${records.length}',
    );
    final record = records.single;
    final expectedEmpty = switch (scenario.variant) {
      'ojp_missing_journey_ref' => record.journeyRef.isEmpty,
      'ojp_missing_operating_day' => record.operatingDayRef.isEmpty,
      'ojp_missing_destination' => record.destinationText.isEmpty,
      'ojp_missing_previous_call' => !record.hasPreviousServicedCall,
      _ => true,
    };
    _checker.require(
      expectedEmpty,
      'I8 NO FALSE PROVIDER MATCH',
      '${scenario.variant} did not retain the expected missing/unsafe field',
    );
  }

  Future<void> _runProviderSequence(
    ReliabilityScenario scenario,
    ReliabilityEventRecorder recorder,
    ReliabilityCoverage coverage,
  ) async {
    coverage.hit('provider_disappearance_recovery');
    final scheduled = DateTime.now().add(const Duration(hours: 1));
    final validResponse = _jsonResponse({
      'stationboard': [_stationboardItem(scheduled, name: 'S22')],
    });
    if (scenario.variant == 'provider_reordered_responses') {
      coverage
        ..hit('provider_reordered_responses')
        ..hit('provider_reordered_or_stale_cases');
      final firstGate = Completer<http.Response>();
      final secondGate = Completer<http.Response>();
      var call = 0;
      final service = _stationboardService(
        recorder,
        (_) => call++ == 0 ? firstGate.future : secondGate.future,
      );
      final first = _fallback(service);
      final second = _fallback(service);
      secondGate.complete(validResponse);
      final secondResult = await second;
      firstGate.complete(_jsonResponse({'stationboard': const []}));
      final firstResult = await first;
      _checker.require(
        secondResult.length == 1 && firstResult.isEmpty,
        'I8 NO FALSE PROVIDER MATCH',
        'reordered provider responses were attached to the wrong request',
      );
      return;
    }
    final responses = scenario.variant == 'provider_failure_recovery'
        ? <http.Response>[http.Response('unavailable', 503), validResponse]
        : <http.Response>[
            _jsonResponse({'stationboard': const []}),
            _jsonResponse({'stationboard': const []}),
            validResponse,
          ];
    var index = 0;
    final service = _stationboardService(
      recorder,
      (_) async => responses[index++],
    );
    final expected = scenario.variant == 'provider_failure_recovery'
        ? <int>[0, 1]
        : <int>[0, 0, 1];
    for (final count in expected) {
      final result = await _fallback(service);
      _checker.require(
        result.length == count,
        'I8 NO FALSE PROVIDER MATCH',
        '${scenario.variant} expected=$count actual=${result.length}',
      );
    }
  }

  TransportService _stationboardService(
    ReliabilityEventRecorder recorder,
    Future<http.Response> Function(Uri uri) response,
  ) => TransportService(
    ojpApiKeyProvider: () => '',
    trace: recorder.add,
    httpGet: (uri, {headers}) => response(uri),
  );

  Future<List<TripCandidate>> _fallback(TransportService service) =>
      service.fallbackArrivalsAtDestination(
        trainQuery: 'S22',
        destStopIdCanons: const ['8500212'],
        resolveDestinationName: false,
      );
}

AlarmNotificationPlan _alarmPlan(int id) => AlarmNotificationPlan(
  baseId: id,
  firstFire: DateTime(2030, 1, 1, 12),
  count: 1,
  interval: const Duration(seconds: 45),
  title: 'TREEP ALARM',
  body: 'Seeded reliability scenario',
);

class _HarnessNotificationGateway implements AlarmNotificationGateway {
  _HarnessNotificationGateway(this.recorder);

  final ReliabilityEventRecorder recorder;
  Completer<NotificationScheduleResult>? scheduleGate;
  final Set<int> activeIds = {};

  @override
  Future<AlarmOperationResult> requestPermissions() async =>
      const AlarmOperationResult.success();

  @override
  Future<NotificationScheduleResult> schedule(
    AlarmNotificationPlan plan,
  ) async {
    recorder.add('notification schedule ${plan.baseId}');
    final gate = scheduleGate;
    scheduleGate = null;
    final result = gate == null
        ? NotificationScheduleResult(succeeded: true, ids: [plan.baseId])
        : await gate.future;
    activeIds.addAll(result.ids);
    return result;
  }

  @override
  Future<NotificationCancelResult> cancelIds(List<int> ids) async {
    recorder.add('notification cancel ${ids.join(',')}');
    activeIds.removeAll(ids);
    return const NotificationCancelResult(remainingIds: []);
  }
}

class _HarnessNativeAlarmGateway implements NativeAlarmGateway {
  _HarnessNativeAlarmGateway(this.recorder);

  final ReliabilityEventRecorder recorder;
  final Map<String, NativeAlarmRecord> active = {};
  int schedules = 0;
  NativeAlarmRecord? prepared;
  NativeAlarmRecord? committed;
  NativeAlarmRecord? retiring;
  bool failNextSchedule = false;
  bool failNextPromotion = false;
  bool ambiguousNextPromotion = false;
  bool unresolvedNextSchedule = false;
  bool failCancellation = false;
  Completer<void>? scheduleGate;

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
    final number = ++schedules;
    recorder.add('native schedule native-$number');
    final gate = scheduleGate;
    scheduleGate = null;
    if (gate != null) await gate.future;
    if (failNextSchedule) {
      failNextSchedule = false;
      return const NativeAlarmScheduleResult(
        accepted: false,
        confirmed: false,
        backend: NativeAlarmBackend.alarmKit,
        failure: 'seeded definitive schedule failure',
      );
    }
    final record = NativeAlarmRecord(
      id: 'native-$number',
      requestedFireTime: fireAt,
      scheduledFireTime: fireAt,
      state: unresolvedNextSchedule
          ? NativeAlarmState.unknown
          : NativeAlarmState.scheduled,
      backend: NativeAlarmBackend.alarmKit,
      sessionId: 'seeded-session',
      revision: number,
    );
    active[record.id] = record;
    prepared = record;
    if (unresolvedNextSchedule) {
      unresolvedNextSchedule = false;
      return NativeAlarmScheduleResult(
        accepted: false,
        confirmed: false,
        backend: NativeAlarmBackend.alarmKit,
        alarm: record,
        unresolved: true,
        failure: 'seeded unresolved schedule',
      );
    }
    return NativeAlarmScheduleResult(
      accepted: true,
      confirmed: true,
      backend: NativeAlarmBackend.alarmKit,
      alarm: record,
    );
  }

  @override
  Future<AlarmOperationResult> promoteSession(NativeAlarmRecord alarm) async {
    recorder.add('native promote ${alarm.id}');
    if (failNextPromotion) {
      failNextPromotion = false;
      return const AlarmOperationResult.failure('seeded promotion failure');
    }
    if (ambiguousNextPromotion) {
      ambiguousNextPromotion = false;
      return const AlarmOperationResult.ambiguous('seeded lost response');
    }
    final old = committed;
    committed = alarm;
    prepared = null;
    retiring = old;
    return const AlarmOperationResult.success();
  }

  @override
  Future<NativeAlarmSessionSnapshot> sessionSnapshot() async {
    final current = committed;
    return NativeAlarmSessionSnapshot(
      reconciliationAvailable: true,
      lifecycleHealthy: true,
      sessionExists: current != null,
      isProtected: current?.isConfirmed == true,
      protectionStatus: current?.isConfirmed == true
          ? NativeAlarmProtectionStatus.protected
          : NativeAlarmProtectionStatus.unverified,
      sessionId: current?.sessionId,
      revision: current?.revision,
      alarmId: current?.id,
      requestedFireTime: current?.requestedFireTime,
      state: current?.state ?? NativeAlarmState.unknown,
      preparedSessionId: prepared?.sessionId,
      preparedRevision: prepared?.revision,
      preparedAlarmId: prepared?.id,
    );
  }

  @override
  Future<NativeAlarmQueryResult> alarms() async =>
      NativeAlarmQueryResult(alarms: active.values.toList());

  @override
  Future<AlarmOperationResult> cancel(NativeAlarmRecord alarm) async {
    recorder.add('native cancel ${alarm.id}');
    if (failCancellation) {
      return const AlarmOperationResult.failure('seeded cancellation failure');
    }
    active.remove(alarm.id);
    if (prepared?.id == alarm.id) prepared = null;
    if (committed?.id == alarm.id) committed = null;
    if (retiring?.id == alarm.id) retiring = null;
    return const AlarmOperationResult.success();
  }

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

class _HarnessFeedTransportService extends TransportService {
  _HarnessFeedTransportService(this.feed);

  final FeedMessage feed;

  @override
  Future<FeedMessage> fetchGtfsRtFeed() async => feed;
}

FeedEntity _journeyEntity({
  required String tripId,
  required String startTime,
  required DateTime eta,
  required String terminal,
  required String route,
  required String startDate,
  required String destinationStop,
}) => FeedEntity(
  id: 'entity-$tripId-$startTime',
  tripUpdate: TripUpdate(
    trip: TripDescriptor(
      tripId: tripId,
      routeId: route,
      startDate: startDate,
      startTime: startTime,
    ),
    stopTimeUpdate: [
      _stopUpdate(
        1,
        '8500207',
        eta.subtract(const Duration(minutes: 10)),
        departure: true,
      ),
      _stopUpdate(2, destinationStop, eta),
      _stopUpdate(3, terminal, eta.add(const Duration(minutes: 10))),
    ],
  ),
);

TripCandidate _journeyCandidate({
  required String tripId,
  required String startTime,
  required DateTime eta,
  required String originalTripId,
  required String route,
  required String startDate,
  required String destinationStop,
  required String direction,
}) => TripCandidate(
  tripId: tripId,
  originalTripId: originalTripId,
  routeId: route,
  startDate: startDate,
  startTime: startTime,
  stopId: destinationStop,
  etaLocal: eta,
  delaySeconds: 0,
  displayTrain: route,
  vehicleLabel: 'Train',
  destinationMatched: true,
  upcomingStops: const [],
  terminalStopId: direction,
  terminalStopIdCanon: direction,
);

TripUpdate_StopTimeUpdate _stopUpdate(
  int sequence,
  String stopId,
  DateTime time, {
  bool departure = false,
  bool skipped = false,
}) {
  final seconds = time.toUtc().millisecondsSinceEpoch ~/ 1000;
  final event = TripUpdate_StopTimeEvent.fromJson('{"2":"$seconds"}');
  return TripUpdate_StopTimeUpdate(
    stopSequence: sequence,
    stopId: stopId,
    arrival: departure ? null : event,
    departure: departure ? event : null,
    scheduleRelationship: skipped
        ? TripUpdate_StopTimeUpdate_ScheduleRelationship.SKIPPED
        : null,
  );
}

TripUpdate_StopTimeEvent _stopEvent(DateTime time) {
  final seconds = time.toUtc().millisecondsSinceEpoch ~/ 1000;
  return TripUpdate_StopTimeEvent.fromJson('{"2":"$seconds"}');
}

DateTime _scenarioTime(ReliabilityScenario scenario) =>
    DateTime.utc(2030, 1, 1).add(Duration(minutes: scenario.id % 100000));

Map<String, dynamic> _copyStationboard(Map<String, dynamic> source) =>
    jsonDecode(jsonEncode(source)) as Map<String, dynamic>;

String _ojpXml(String variant) {
  String record({
    String journey = 'ch:1:sjyid:active',
    String day = '2026-08-29',
    String destination = 'Oensingen',
    bool previous = true,
  }) =>
      '''
  <StopEventResult><StopEvent>
    ${previous ? '<PreviousCall><CallAtStop><NotServicedStop>false</NotServicedStop></CallAtStop></PreviousCall>' : ''}
    <ThisCall><CallAtStop>
      <siri:StopPointRef>ch:1:sloid:212</siri:StopPointRef>
      <StopPointName><Text>Oensingen</Text></StopPointName>
      <ServiceArrival><TimetabledTime>2026-08-29T16:40:00Z</TimetabledTime></ServiceArrival>
    </CallAtStop></ThisCall>
    <Service>
      ${day.isEmpty ? '' : '<OperatingDayRef>$day</OperatingDayRef>'}
      ${journey.isEmpty ? '' : '<JourneyRef>$journey</JourneyRef>'}
      <PublishedServiceName><Text>S22</Text></PublishedServiceName>
      ${destination.isEmpty ? '' : '<DestinationText><Text>$destination</Text></DestinationText>'}
    </Service>
  </StopEvent></StopEventResult>''';

  final records = switch (variant) {
    'ojp_missing_journey_ref' => record(journey: ''),
    'ojp_missing_operating_day' => record(day: ''),
    'ojp_missing_destination' => record(destination: ''),
    'ojp_missing_previous_call' => record(previous: false),
    'ojp_ambiguous_exact_records' => '${record()}${record()}',
    'ojp_direction_disagreement' =>
      '${record(destination: 'Oensingen')}${record(destination: 'Solothurn')}',
    _ => throw StateError('unknown OJP variant $variant'),
  };
  return '''
<OJP xmlns="http://www.vdv.de/ojp" xmlns:siri="http://www.siri.org.uk/siri">
$records
</OJP>''';
}

Map<String, dynamic> _stationboardItem(
  DateTime scheduled, {
  required String name,
}) {
  final parts = name.trim().split(RegExp(r'\s+'));
  return {
    'name': name,
    'category': name.isEmpty ? '' : parts.first,
    'number': name.isEmpty || parts.length < 2 ? '' : parts[1],
    'to': 'Solothurn',
    'stop': {
      'arrivalTimestamp': scheduled.toUtc().millisecondsSinceEpoch ~/ 1000,
      'station': {'id': '8500212', 'name': 'Oensingen'},
      'prognosis': const <String, Object?>{},
    },
  };
}

http.Response _jsonResponse(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
