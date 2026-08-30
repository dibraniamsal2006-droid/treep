import 'package:flutter_test/flutter_test.dart';

import 'seeded_reliability_harness.dart';

const _masterSeed = int.fromEnvironment(
  'TREEP_RELIABILITY_SEED',
  defaultValue: defaultReliabilitySeed,
);
const _scenarioCount = int.fromEnvironment(
  'TREEP_RELIABILITY_SCENARIOS',
  defaultValue: 100,
);
const _scenarioId = int.fromEnvironment(
  'TREEP_RELIABILITY_SCENARIO_ID',
  defaultValue: -1,
);

void main() {
  group('seeded reliability harness self-tests', () {
    test('same master seed and scenario ID create the same scenario', () {
      const first = ReliabilityScenarioGenerator(masterSeed: 42);
      const second = ReliabilityScenarioGenerator(masterSeed: 42);

      expect(first.generate(91).signature, second.generate(91).signature);
    });

    test('different master seeds create a different scenario seed', () {
      const first = ReliabilityScenarioGenerator(masterSeed: 42);
      const second = ReliabilityScenarioGenerator(masterSeed: 43);

      expect(first.generate(91).seed, isNot(second.generate(91).seed));
    });

    test('failure diagnostic contains exact seed and scenario ID', () {
      const scenario = ReliabilityScenario(
        id: 17,
        seed: 1234,
        campaign: ReliabilityCampaign.journeyIdentity,
        variant: 'same_line_collision',
        noiseJourneys: 4,
        delayMinutes: 12,
        tripId: 'active-trip',
        originalTripId: 'ch:1:sjyid:active',
        route: 'S22',
        startDate: '20260829',
        startTime: '10:00:00',
        direction: '8500991',
        destinationStop: '8500212',
        orderedStops: ['8500207', '8500212', '8500991'],
      );
      const failure = ReliabilityFailure(
        masterSeed: 830291,
        scenario: scenario,
        invariant: 'I4 JOURNEY ISOLATION',
        message: 'deliberate diagnostic fixture',
        events: ['generated', 'failed'],
      );

      expect(failure.diagnostic, contains('Master seed: 830291'));
      expect(failure.diagnostic, contains('Scenario: 17'));
      expect(failure.diagnostic, contains('Scenario seed: 1234'));
      expect(failure.diagnostic, contains('TREEP_RELIABILITY_SCENARIO_ID=17'));
    });

    test('event ordering is stable', () {
      final recorder = ReliabilityEventRecorder()
        ..add('generated')
        ..add('injected')
        ..add('checked');

      expect(recorder.formatted, '01 generated\n02 injected\n03 checked');
    });

    test('coverage counters increment exactly', () {
      final coverage = ReliabilityCoverage()
        ..hit('alarm')
        ..hit('alarm')
        ..hit('matching', 3);

      expect(coverage['alarm'], 2);
      expect(coverage['matching'], 3);
      expect(coverage['missing'], 0);
    });

    test('invariant checker catches a deliberately invalid result', () {
      const checker = ReliabilityInvariantChecker();

      expect(
        () => checker.require(
          false,
          'SELF TEST',
          'deliberately invalid synthetic result',
        ),
        throwsA(isA<ReliabilityViolation>()),
      );
    });

    test('same seed generates an identical alarm operation sequence', () {
      const generator = ReliabilityScenarioGenerator(masterSeed: 830291);
      final scenario = generator.generate(44);

      expect(
        generator.alarmOperations(scenario),
        generator.alarmOperations(generator.generate(44)),
      );
      expect(
        generator.alarmOperations(scenario).length,
        inInclusiveRange(4, 49),
      );
    });

    test('ordered completion permutation is reproducible', () {
      const generator = ReliabilityScenarioGenerator(masterSeed: 830291);

      expect(
        generator.completionPermutation(generator.generate(88)),
        generator.completionPermutation(generator.generate(88)),
      );
    });

    test('state-transition counter and exact replay are stable', () async {
      final first = await SeededReliabilityHarness(
        masterSeed: 830291,
      ).run(scenarioCount: 100, scenarioId: 44);
      final second = await SeededReliabilityHarness(
        masterSeed: 830291,
      ).run(scenarioCount: 1, scenarioId: 44);

      expect(first.executed, 1);
      expect(first.failures, isEmpty);
      expect(
        first.coverage['alarm_state_transitions'],
        second.coverage['alarm_state_transitions'],
      );
    });
  });

  test('seeded reliability development campaign', () async {
    final harness = SeededReliabilityHarness(masterSeed: _masterSeed);
    final report = await harness.run(
      scenarioCount: _scenarioCount,
      scenarioId: _scenarioId < 0 ? null : _scenarioId,
    );

    // One compact line on success; full ordered diagnostics on failure.
    // ignore: avoid_print
    print(report.summary);
    expect(
      report.failures,
      isEmpty,
      reason: report.failures.map((failure) => failure.diagnostic).join('\n'),
    );
    expect(report.coverage['invariant_violations'], 0);
  });
}
