import XCTest
@testable import Runner

@MainActor
final class RunnerTests: XCTestCase {
  private let fireTime = Date(timeIntervalSince1970: 2_000_000_000)

  func testFirstCommittedSessionIsPersistedAndSurvivesRecreation() throws {
    let store = MemoryAlarmSessionStore()
    let coordinator = TreepAlarmSessionCoordinator(store: store)
    let alarmID = UUID()

    let prepared = try prepareConfirmed(
      coordinator,
      alarmID: alarmID,
      requestedFireTime: fireTime
    )
    XCTAssertNil(coordinator.envelope.current)
    try coordinator.promote(
      sessionID: prepared.sessionID,
      revision: prepared.revision,
      alarmID: alarmID
    )

    let recreated = TreepAlarmSessionCoordinator(store: store)
    XCTAssertEqual(recreated.envelope.current?.sessionID, prepared.sessionID)
    XCTAssertEqual(recreated.envelope.current?.revision, 1)
    XCTAssertEqual(recreated.envelope.current?.alarmID, alarmID)
    XCTAssertEqual(recreated.envelope.current?.protectionStatus, .unverified)
  }

  func testPreparedReplacementDoesNotReplaceCurrentUntilPromotion() throws {
    let coordinator = TreepAlarmSessionCoordinator(
      store: MemoryAlarmSessionStore()
    )
    let current = try commitFirst(coordinator)
    let replacement = try prepareConfirmed(
      coordinator,
      alarmID: UUID(),
      requestedFireTime: fireTime.addingTimeInterval(60)
    )

    XCTAssertEqual(coordinator.envelope.current, current)
    XCTAssertEqual(coordinator.envelope.prepared, replacement)

    let retired = try coordinator.promote(
      sessionID: replacement.sessionID,
      revision: replacement.revision,
      alarmID: replacement.alarmID
    )
    XCTAssertEqual(retired, current)
    XCTAssertEqual(coordinator.envelope.current, replacement)
    XCTAssertEqual(coordinator.envelope.retiring, current)
  }

  func testFailedConfirmationLeavesCurrentAndPreparedIntentUnchanged() throws {
    let coordinator = TreepAlarmSessionCoordinator(
      store: MemoryAlarmSessionStore()
    )
    let current = try commitFirst(coordinator)

    let intent = try coordinator.prepareIntent(
      alarmID: UUID(),
      requestedFireTime: fireTime
    )
    XCTAssertThrowsError(
      try coordinator.confirmPrepared(
        sessionID: intent.sessionID,
        revision: intent.revision,
        alarmID: intent.alarmID,
        nativeState: .paused
      )
    )
    XCTAssertEqual(coordinator.envelope.current, current)
    XCTAssertEqual(coordinator.envelope.prepared, intent)
  }

  func testProtectedStateClassification() throws {
    for state in [
      TreepNativeAlarmState.scheduled,
      .countdown,
      .alerting,
    ] {
      let coordinator = TreepAlarmSessionCoordinator(
        store: MemoryAlarmSessionStore()
      )
      let current = try commitFirst(coordinator)
      try coordinator.reconcileCurrent(
        observations: [TreepAlarmObservation(alarmID: current.alarmID, state: state)],
        now: fireTime.addingTimeInterval(-60)
      )
      XCTAssertTrue(coordinator.envelope.current?.isProtected == true)
      XCTAssertEqual(coordinator.envelope.current?.nativeState, state)
    }
  }

  func testPausedIsNotProtected() throws {
    let coordinator = TreepAlarmSessionCoordinator(
      store: MemoryAlarmSessionStore()
    )
    let current = try commitFirst(coordinator)
    try coordinator.reconcileCurrent(
      observations: [
        TreepAlarmObservation(alarmID: current.alarmID, state: .paused),
      ],
      now: fireTime.addingTimeInterval(-60)
    )

    XCTAssertFalse(coordinator.envelope.current?.isProtected == true)
    XCTAssertEqual(coordinator.envelope.current?.protectionStatus, .paused)
  }

  func testMissingBeforeFireIsProtectionLossNotCompletion() throws {
    let coordinator = TreepAlarmSessionCoordinator(
      store: MemoryAlarmSessionStore()
    )
    _ = try commitFirst(coordinator)
    try coordinator.reconcileCurrent(
      observations: [],
      now: fireTime.addingTimeInterval(-1)
    )

    XCTAssertNotNil(coordinator.envelope.current)
    XCTAssertFalse(coordinator.envelope.current?.isProtected == true)
    XCTAssertEqual(
      coordinator.envelope.current?.protectionStatus,
      .missingBeforeFire
    )
  }

  func testReconciliationIgnoresUnrelatedAlarm() throws {
    let coordinator = TreepAlarmSessionCoordinator(
      store: MemoryAlarmSessionStore()
    )
    _ = try commitFirst(coordinator)
    try coordinator.reconcileCurrent(
      observations: [
        TreepAlarmObservation(alarmID: UUID(), state: .alerting),
      ],
      now: fireTime.addingTimeInterval(-1)
    )

    XCTAssertEqual(
      coordinator.envelope.current?.protectionStatus,
      .missingBeforeFire
    )
  }

  func testStaleRevisionCannotReplaceCurrent() throws {
    let sessionID = UUID()
    let current = persisted(
      sessionID: sessionID,
      revision: 2,
      alarmID: UUID()
    )
    let stale = persisted(
      sessionID: sessionID,
      revision: 1,
      alarmID: UUID()
    )
    let store = MemoryAlarmSessionStore(
      envelope: TreepAlarmSessionEnvelope(
        current: current,
        prepared: stale,
        retiring: nil
      )
    )
    let coordinator = TreepAlarmSessionCoordinator(store: store)

    XCTAssertThrowsError(
      try coordinator.promote(
        sessionID: stale.sessionID,
        revision: stale.revision,
        alarmID: stale.alarmID
      )
    )
    XCTAssertEqual(coordinator.envelope.current?.revision, 2)
    XCTAssertEqual(coordinator.envelope.current?.alarmID, current.alarmID)
  }

  func testCancellationClearsOnlyMatchingCommittedSession() throws {
    let coordinator = TreepAlarmSessionCoordinator(
      store: MemoryAlarmSessionStore()
    )
    let current = try commitFirst(coordinator)

    XCTAssertThrowsError(
      try coordinator.recordCancellation(
        sessionID: current.sessionID,
        revision: current.revision - 1,
        alarmID: current.alarmID
      )
    )
    XCTAssertEqual(coordinator.envelope.current, current)

    try coordinator.recordCancellation(
      sessionID: current.sessionID,
      revision: current.revision,
      alarmID: current.alarmID
    )
    XCTAssertNil(coordinator.envelope.current)
  }

  func testPreparedIntentIsPersistedBeforeNativeConfirmation() throws {
    let store = MemoryAlarmSessionStore()
    let coordinator = TreepAlarmSessionCoordinator(store: store)
    let alarmID = UUID()

    let intent = try coordinator.prepareIntent(
      alarmID: alarmID,
      requestedFireTime: fireTime
    )

    XCTAssertEqual(store.envelope?.prepared, intent)
    XCTAssertEqual(intent.schedulingStatus, .intent)
    XCTAssertEqual(intent.nativeState, .unknown)
    XCTAssertFalse(intent.isProtected)
  }

  func testMissingPreparedIntentIsClearedDuringStartupReconciliation() throws {
    let coordinator = TreepAlarmSessionCoordinator(
      store: MemoryAlarmSessionStore()
    )
    _ = try coordinator.prepareIntent(
      alarmID: UUID(),
      requestedFireTime: fireTime
    )

    let plan = try coordinator.reconcileStartup(
      observations: [],
      now: fireTime.addingTimeInterval(-60)
    )

    XCTAssertNil(plan.preparedToCancel)
    XCTAssertNil(coordinator.envelope.prepared)
  }

  func testPreparedIdentitySurvivesRecreationWhenQueryIsUnavailable() throws {
    let store = MemoryAlarmSessionStore()
    let coordinator = TreepAlarmSessionCoordinator(store: store)
    let intent = try coordinator.prepareIntent(
      alarmID: UUID(),
      requestedFireTime: fireTime
    )

    let recreated = TreepAlarmSessionCoordinator(store: store)
    try recreated.markAllUnverified()

    XCTAssertEqual(recreated.envelope.prepared?.alarmID, intent.alarmID)
    XCTAssertEqual(recreated.envelope.prepared?.schedulingStatus, .unverified)
  }

  func testPreparedNativeAlarmRemainsTrackedWhenCleanupFails() throws {
    let coordinator = TreepAlarmSessionCoordinator(
      store: MemoryAlarmSessionStore()
    )
    let intent = try coordinator.prepareIntent(
      alarmID: UUID(),
      requestedFireTime: fireTime
    )

    let plan = try coordinator.reconcileStartup(
      observations: [
        TreepAlarmObservation(alarmID: intent.alarmID, state: .scheduled),
      ],
      now: fireTime.addingTimeInterval(-60)
    )

    XCTAssertEqual(plan.preparedToCancel?.alarmID, intent.alarmID)
    XCTAssertEqual(coordinator.envelope.prepared?.alarmID, intent.alarmID)
  }

  func testRepeatedIdenticalPromotionIsIdempotent() throws {
    let coordinator = TreepAlarmSessionCoordinator(
      store: MemoryAlarmSessionStore()
    )
    let prepared = try prepareConfirmed(
      coordinator,
      alarmID: UUID(),
      requestedFireTime: fireTime
    )
    try coordinator.promote(
      sessionID: prepared.sessionID,
      revision: prepared.revision,
      alarmID: prepared.alarmID
    )

    XCTAssertNoThrow(
      try coordinator.promote(
        sessionID: prepared.sessionID,
        revision: prepared.revision,
        alarmID: prepared.alarmID
      )
    )
    XCTAssertEqual(coordinator.envelope.current, prepared)
  }

  func testCorruptLoadIsNotOverwrittenAsEmpty() {
    let store = ThrowingAlarmSessionStore()
    let coordinator = TreepAlarmSessionCoordinator(store: store)

    XCTAssertEqual(coordinator.lifecycleHealth, .corrupt)
    XCTAssertEqual(store.saveCount, 0)
    XCTAssertThrowsError(
      try coordinator.prepareIntent(
        alarmID: UUID(),
        requestedFireTime: fireTime
      )
    )
  }

  func testDuplicateSlotIdentityIsNonDestructiveCorruptState() {
    let alarm = persisted(sessionID: UUID(), revision: 1, alarmID: UUID())
    let original = TreepAlarmSessionEnvelope(
      current: alarm,
      prepared: alarm,
      retiring: nil
    )
    let store = MemoryAlarmSessionStore(envelope: original)
    let coordinator = TreepAlarmSessionCoordinator(store: store)

    XCTAssertEqual(coordinator.lifecycleHealth, .corrupt)
    XCTAssertEqual(store.envelope, original)
    XCTAssertThrowsError(
      try coordinator.reconcileStartup(
        observations: [
          TreepAlarmObservation(alarmID: alarm.alarmID, state: .scheduled),
        ],
        now: fireTime
      )
    )
  }

  func testRetiringCleanupPlanCannotTargetCurrent() throws {
    let coordinator = TreepAlarmSessionCoordinator(
      store: MemoryAlarmSessionStore()
    )
    let old = try commitFirst(coordinator)
    let replacement = try prepareConfirmed(
      coordinator,
      alarmID: UUID(),
      requestedFireTime: fireTime.addingTimeInterval(60)
    )
    try coordinator.promote(
      sessionID: replacement.sessionID,
      revision: replacement.revision,
      alarmID: replacement.alarmID
    )

    let plan = try coordinator.reconcileStartup(
      observations: [
        TreepAlarmObservation(alarmID: old.alarmID, state: .scheduled),
        TreepAlarmObservation(alarmID: replacement.alarmID, state: .scheduled),
      ],
      now: fireTime.addingTimeInterval(-60)
    )

    XCTAssertEqual(plan.retiringToCancel?.alarmID, old.alarmID)
    XCTAssertNotEqual(
      plan.retiringToCancel?.alarmID,
      coordinator.envelope.current?.alarmID
    )
  }

  func testCurrentAndRetiringIdentitiesSurviveRecreation() throws {
    let store = MemoryAlarmSessionStore()
    let coordinator = TreepAlarmSessionCoordinator(store: store)
    let old = try commitFirst(coordinator)
    let replacement = try prepareConfirmed(
      coordinator,
      alarmID: UUID(),
      requestedFireTime: fireTime.addingTimeInterval(60)
    )
    try coordinator.promote(
      sessionID: replacement.sessionID,
      revision: replacement.revision,
      alarmID: replacement.alarmID
    )

    let recreated = TreepAlarmSessionCoordinator(store: store)
    let plan = try recreated.reconcileStartup(
      observations: [
        TreepAlarmObservation(alarmID: old.alarmID, state: .scheduled),
        TreepAlarmObservation(alarmID: replacement.alarmID, state: .scheduled),
      ],
      now: fireTime.addingTimeInterval(-60)
    )

    XCTAssertEqual(recreated.envelope.current?.alarmID, replacement.alarmID)
    XCTAssertEqual(recreated.envelope.retiring?.alarmID, old.alarmID)
    XCTAssertEqual(plan.retiringToCancel?.alarmID, old.alarmID)
    XCTAssertNotEqual(plan.retiringToCancel?.alarmID, replacement.alarmID)
  }

  func testRepeatedIdenticalReconciliationIsIdempotent() throws {
    let coordinator = TreepAlarmSessionCoordinator(
      store: MemoryAlarmSessionStore()
    )
    let current = try commitFirst(coordinator)
    let observations = [
      TreepAlarmObservation(alarmID: current.alarmID, state: .countdown),
    ]

    try coordinator.reconcileCurrent(
      observations: observations,
      now: fireTime.addingTimeInterval(-60)
    )
    let reconciled = coordinator.envelope
    try coordinator.reconcileCurrent(
      observations: observations,
      now: fireTime.addingTimeInterval(-60)
    )

    XCTAssertEqual(coordinator.envelope, reconciled)
  }

  func testStoppedAlertMissingAfterRecreationRemainsConservative() throws {
    let store = MemoryAlarmSessionStore()
    let coordinator = TreepAlarmSessionCoordinator(store: store)
    _ = try commitFirst(coordinator)

    let recreated = TreepAlarmSessionCoordinator(store: store)
    _ = try recreated.reconcileStartup(
      observations: [],
      now: fireTime.addingTimeInterval(1)
    )

    XCTAssertNotNil(recreated.envelope.current)
    XCTAssertEqual(
      recreated.envelope.current?.protectionStatus,
      .missingAfterFire
    )
    XCTAssertFalse(recreated.envelope.current?.isProtected == true)
  }

  private func commitFirst(
    _ coordinator: TreepAlarmSessionCoordinator
  ) throws -> TreepPersistedAlarm {
    let prepared = try prepareConfirmed(
      coordinator,
      alarmID: UUID(),
      requestedFireTime: fireTime
    )
    try coordinator.promote(
      sessionID: prepared.sessionID,
      revision: prepared.revision,
      alarmID: prepared.alarmID
    )
    return prepared
  }

  private func persisted(
    sessionID: UUID,
    revision: Int,
    alarmID: UUID
  ) -> TreepPersistedAlarm {
    TreepPersistedAlarm(
      sessionID: sessionID,
      revision: revision,
      alarmID: alarmID,
      requestedFireTime: fireTime,
      nativeState: .scheduled,
      protectionStatus: .protected,
      schedulingStatus: .confirmed
    )
  }

  private func prepareConfirmed(
    _ coordinator: TreepAlarmSessionCoordinator,
    alarmID: UUID,
    requestedFireTime: Date
  ) throws -> TreepPersistedAlarm {
    let intent = try coordinator.prepareIntent(
      alarmID: alarmID,
      requestedFireTime: requestedFireTime
    )
    return try coordinator.confirmPrepared(
      sessionID: intent.sessionID,
      revision: intent.revision,
      alarmID: intent.alarmID,
      nativeState: .scheduled
    )
  }
}

private final class MemoryAlarmSessionStore: TreepAlarmSessionStoring {
  private(set) var envelope: TreepAlarmSessionEnvelope?

  init(envelope: TreepAlarmSessionEnvelope? = nil) {
    self.envelope = envelope
  }

  func load() throws -> TreepAlarmSessionEnvelope? {
    envelope
  }

  func save(_ envelope: TreepAlarmSessionEnvelope) throws {
    self.envelope = envelope
  }
}

private final class ThrowingAlarmSessionStore: TreepAlarmSessionStoring {
  private(set) var saveCount = 0

  func load() throws -> TreepAlarmSessionEnvelope? {
    throw CocoaError(.coderReadCorrupt)
  }

  func save(_ envelope: TreepAlarmSessionEnvelope) throws {
    saveCount += 1
  }
}
