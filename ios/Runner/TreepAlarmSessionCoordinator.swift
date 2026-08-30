import Foundation

enum TreepNativeAlarmState: String, Codable {
  case scheduled, countdown, paused, alerting, missing, unknown

  var isProtected: Bool {
    switch self {
    case .scheduled, .countdown, .alerting: return true
    case .paused, .missing, .unknown: return false
    }
  }
}

enum TreepAlarmProtectionStatus: String, Codable {
  case protected, paused, missingBeforeFire, missingAfterFire, unverified
}

enum TreepAlarmSchedulingStatus: String, Codable {
  case intent, confirmed, unverified
}

enum TreepAlarmLifecycleHealth: String {
  case healthy, corrupt
}

struct TreepAlarmObservation: Equatable {
  let alarmID: UUID
  let state: TreepNativeAlarmState
}

struct TreepPersistedAlarm: Codable, Equatable {
  let sessionID: UUID
  let revision: Int
  let alarmID: UUID
  let requestedFireTime: Date
  var nativeState: TreepNativeAlarmState
  var protectionStatus: TreepAlarmProtectionStatus
  var schedulingStatus: TreepAlarmSchedulingStatus

  var isProtected: Bool {
    schedulingStatus == .confirmed &&
      protectionStatus == .protected &&
      nativeState.isProtected
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID, revision, alarmID, requestedFireTime
    case nativeState, protectionStatus, schedulingStatus
  }

  init(
    sessionID: UUID,
    revision: Int,
    alarmID: UUID,
    requestedFireTime: Date,
    nativeState: TreepNativeAlarmState,
    protectionStatus: TreepAlarmProtectionStatus,
    schedulingStatus: TreepAlarmSchedulingStatus
  ) {
    self.sessionID = sessionID
    self.revision = revision
    self.alarmID = alarmID
    self.requestedFireTime = requestedFireTime
    self.nativeState = nativeState
    self.protectionStatus = protectionStatus
    self.schedulingStatus = schedulingStatus
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try values.decode(UUID.self, forKey: .sessionID)
    revision = try values.decode(Int.self, forKey: .revision)
    alarmID = try values.decode(UUID.self, forKey: .alarmID)
    requestedFireTime = try values.decode(Date.self, forKey: .requestedFireTime)
    nativeState = try values.decode(TreepNativeAlarmState.self, forKey: .nativeState)
    protectionStatus = try values.decode(
      TreepAlarmProtectionStatus.self,
      forKey: .protectionStatus
    )
    // PATCH 4.2 records predate this field and represented confirmed alarms.
    schedulingStatus = try values.decodeIfPresent(
      TreepAlarmSchedulingStatus.self,
      forKey: .schedulingStatus
    ) ?? .confirmed
  }
}

struct TreepAlarmSessionEnvelope: Codable, Equatable {
  var current: TreepPersistedAlarm?
  var prepared: TreepPersistedAlarm?
  var retiring: TreepPersistedAlarm?

  static let empty = TreepAlarmSessionEnvelope(
    current: nil,
    prepared: nil,
    retiring: nil
  )

  var hasDistinctAlarmIDs: Bool {
    let ids = [current?.alarmID, prepared?.alarmID, retiring?.alarmID]
      .compactMap { $0 }
    return Set(ids).count == ids.count
  }
}

protocol TreepAlarmSessionStoring {
  func load() throws -> TreepAlarmSessionEnvelope?
  func save(_ envelope: TreepAlarmSessionEnvelope) throws
}

final class TreepAlarmSessionUserDefaultsStore: TreepAlarmSessionStoring {
  private let defaults: UserDefaults
  private let key: String
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    defaults: UserDefaults = .standard,
    key: String = "treep.nativeAlarmSession.v1"
  ) {
    self.defaults = defaults
    self.key = key
  }

  func load() throws -> TreepAlarmSessionEnvelope? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try decoder.decode(TreepAlarmSessionEnvelope.self, from: data)
  }

  func save(_ envelope: TreepAlarmSessionEnvelope) throws {
    if envelope == .empty {
      defaults.removeObject(forKey: key)
    } else {
      defaults.set(try encoder.encode(envelope), forKey: key)
    }
    // Alarm UUID ownership must reach the preferences daemon before
    // AlarmManager.schedule is invoked. A false result aborts scheduling.
    guard defaults.synchronize() else {
      throw TreepAlarmSessionStoreError.synchronizationFailed
    }
  }
}

enum TreepAlarmSessionStoreError: LocalizedError {
  case synchronizationFailed

  var errorDescription: String? {
    "Native alarm session persistence could not be synchronized"
  }
}

enum TreepAlarmSessionError: LocalizedError {
  case corruptPersistence, duplicateAlarmIdentity, preparedAlarmExists
  case unprotectedPreparedState, preparedAlarmMismatch, staleRevision
  case cancellationIdentityMismatch

  var errorDescription: String? {
    switch self {
    case .corruptPersistence:
      return "Native alarm session persistence is corrupt or unavailable"
    case .duplicateAlarmIdentity:
      return "Native alarm session contains duplicate alarm identities"
    case .preparedAlarmExists:
      return "Another native alarm is already being prepared"
    case .unprotectedPreparedState:
      return "Prepared native alarm is not in a protected state"
    case .preparedAlarmMismatch:
      return "Prepared native alarm identity does not match"
    case .staleRevision:
      return "Native alarm session revision is stale"
    case .cancellationIdentityMismatch:
      return "Native alarm cancellation identity does not match the committed session"
    }
  }
}

struct TreepAlarmStartupPlan {
  let preparedToCancel: TreepPersistedAlarm?
  let retiringToCancel: TreepPersistedAlarm?
}

@MainActor
final class TreepAlarmSessionCoordinator {
  private let store: TreepAlarmSessionStoring
  private(set) var envelope: TreepAlarmSessionEnvelope
  private(set) var lifecycleHealth: TreepAlarmLifecycleHealth

  init(store: TreepAlarmSessionStoring) {
    self.store = store
    let loaded: TreepAlarmSessionEnvelope
    do {
      loaded = try store.load() ?? .empty
    } catch {
      // Never overwrite an undecodable record: AlarmKit may still contain
      // alarms whose ownership cannot be reconstructed without its UUIDs.
      envelope = .empty
      lifecycleHealth = .corrupt
      return
    }
    envelope = Self.unverified(loaded)
    guard loaded.hasDistinctAlarmIDs else {
      lifecycleHealth = .corrupt
      return
    }
    lifecycleHealth = .healthy
    do {
      try store.save(envelope)
    } catch {
      // Retain the decoded identities in memory, but prohibit mutations when
      // their conservative unverified state could not be made durable.
      lifecycleHealth = .corrupt
    }
  }

  func prepareIntent(
    alarmID: UUID,
    requestedFireTime: Date
  ) throws -> TreepPersistedAlarm {
    try requireHealthyEnvelope()
    guard envelope.prepared == nil else {
      throw TreepAlarmSessionError.preparedAlarmExists
    }
    guard envelope.current?.alarmID != alarmID,
      envelope.retiring?.alarmID != alarmID
    else {
      throw TreepAlarmSessionError.duplicateAlarmIdentity
    }

    let sessionID = envelope.current?.sessionID ?? UUID()
    let highestRevision = [
      envelope.current?.revision,
      envelope.retiring?.revision,
    ].compactMap { $0 }.max() ?? 0
    let prepared = TreepPersistedAlarm(
      sessionID: sessionID,
      revision: highestRevision + 1,
      alarmID: alarmID,
      requestedFireTime: requestedFireTime,
      nativeState: .unknown,
      protectionStatus: .unverified,
      schedulingStatus: .intent
    )
    var next = envelope
    next.prepared = prepared
    try persist(next)
    return prepared
  }

  func confirmPrepared(
    sessionID: UUID,
    revision: Int,
    alarmID: UUID,
    nativeState: TreepNativeAlarmState
  ) throws -> TreepPersistedAlarm {
    try requireHealthyEnvelope()
    guard nativeState.isProtected else {
      throw TreepAlarmSessionError.unprotectedPreparedState
    }
    var prepared = try matchingPrepared(
      sessionID: sessionID,
      revision: revision,
      alarmID: alarmID
    )
    prepared.nativeState = nativeState
    prepared.protectionStatus = .protected
    prepared.schedulingStatus = .confirmed
    var next = envelope
    next.prepared = prepared
    try persist(next)
    return prepared
  }

  func markPreparedUnverified(
    sessionID: UUID,
    revision: Int,
    alarmID: UUID
  ) throws {
    try requireHealthyEnvelope()
    var prepared = try matchingPrepared(
      sessionID: sessionID,
      revision: revision,
      alarmID: alarmID
    )
    prepared.nativeState = .unknown
    prepared.protectionStatus = .unverified
    prepared.schedulingStatus = .unverified
    var next = envelope
    next.prepared = prepared
    try persist(next)
  }

  func clearPreparedIfMissing(
    sessionID: UUID,
    revision: Int,
    alarmID: UUID
  ) throws {
    try requireHealthyEnvelope()
    _ = try matchingPrepared(
      sessionID: sessionID,
      revision: revision,
      alarmID: alarmID
    )
    var next = envelope
    next.prepared = nil
    try persist(next)
  }

  @discardableResult
  func promote(
    sessionID: UUID,
    revision: Int,
    alarmID: UUID
  ) throws -> TreepPersistedAlarm? {
    try requireHealthyEnvelope()
    if let current = envelope.current,
      current.sessionID == sessionID,
      current.revision == revision,
      current.alarmID == alarmID
    {
      return envelope.retiring
    }

    let prepared = try matchingPrepared(
      sessionID: sessionID,
      revision: revision,
      alarmID: alarmID
    )
    guard prepared.schedulingStatus == .confirmed, prepared.isProtected else {
      throw TreepAlarmSessionError.unprotectedPreparedState
    }
    if let current = envelope.current, revision <= current.revision {
      throw TreepAlarmSessionError.staleRevision
    }

    var next = envelope
    let previous = next.current
    next.current = prepared
    next.prepared = nil
    if let previous { next.retiring = previous }
    try persist(next)
    return previous
  }

  func reconcileCurrent(
    observations: [TreepAlarmObservation],
    now: Date
  ) throws {
    try requireHealthyEnvelope()
    guard var current = envelope.current else { return }
    Self.applyObservation(
      to: &current,
      observation: observations.first { $0.alarmID == current.alarmID },
      now: now
    )
    var next = envelope
    next.current = current
    try persist(next)
  }

  func reconcileStartup(
    observations: [TreepAlarmObservation],
    now: Date
  ) throws -> TreepAlarmStartupPlan {
    try requireHealthyEnvelope()
    var next = envelope
    if var current = next.current {
      Self.applyObservation(
        to: &current,
        observation: observations.first { $0.alarmID == current.alarmID },
        now: now
      )
      next.current = current
    }

    var preparedToCancel: TreepPersistedAlarm?
    if var prepared = next.prepared {
      if let observation = observations.first(where: {
        $0.alarmID == prepared.alarmID
      }) {
        Self.applyObservation(to: &prepared, observation: observation, now: now)
        prepared.schedulingStatus = prepared.nativeState.isProtected
          ? .confirmed
          : .unverified
        next.prepared = prepared
        preparedToCancel = prepared
      } else {
        next.prepared = nil
      }
    }

    var retiringToCancel: TreepPersistedAlarm?
    if var retiring = next.retiring {
      if let observation = observations.first(where: {
        $0.alarmID == retiring.alarmID
      }) {
        Self.applyObservation(to: &retiring, observation: observation, now: now)
        next.retiring = retiring
        retiringToCancel = retiring
      } else {
        next.retiring = nil
      }
    }

    try persist(next)
    return TreepAlarmStartupPlan(
      preparedToCancel: preparedToCancel,
      retiringToCancel: retiringToCancel
    )
  }

  func markAllUnverified() throws {
    try requireHealthyEnvelope()
    var next = envelope
    next.current = next.current.map(Self.markedUnverified)
    next.prepared = next.prepared.map(Self.markedUnverified)
    next.retiring = next.retiring.map(Self.markedUnverified)
    try persist(next)
  }

  func validateCancellation(
    sessionID: UUID?,
    revision: Int?,
    alarmID: UUID
  ) throws {
    try requireHealthyEnvelope()
    let matching = [envelope.current, envelope.prepared, envelope.retiring]
      .compactMap { $0 }
      .first { $0.alarmID == alarmID }
    guard let matching else { return }
    guard matching.sessionID == sessionID, matching.revision == revision else {
      throw TreepAlarmSessionError.cancellationIdentityMismatch
    }
  }

  func recordCancellation(
    sessionID: UUID?,
    revision: Int?,
    alarmID: UUID
  ) throws {
    try validateCancellation(
      sessionID: sessionID,
      revision: revision,
      alarmID: alarmID
    )
    var next = envelope
    if next.current?.alarmID == alarmID { next.current = nil }
    if next.prepared?.alarmID == alarmID { next.prepared = nil }
    if next.retiring?.alarmID == alarmID { next.retiring = nil }
    try persist(next)
  }

  func persistedAlarm(alarmID: UUID) -> TreepPersistedAlarm? {
    [envelope.current, envelope.prepared, envelope.retiring]
      .compactMap { $0 }
      .first { $0.alarmID == alarmID }
  }

  var retiringAlarm: TreepPersistedAlarm? {
    envelope.retiring
  }

  func snapshotMap(reconciliationAvailable: Bool) -> [String: Any] {
    var response: [String: Any] = [
      "sessionExists": envelope.current != nil,
      "protected": envelope.current?.isProtected == true,
      "protectionStatus": envelope.current?.protectionStatus.rawValue ??
        TreepAlarmProtectionStatus.unverified.rawValue,
      "reconciliationAvailable": reconciliationAvailable,
      "lifecycleHealth": lifecycleHealth.rawValue,
    ]
    if let current = envelope.current {
      response["sessionId"] = current.sessionID.uuidString
      response["revision"] = current.revision
      response["alarmId"] = current.alarmID.uuidString
      response["requestedFireTimeMs"] =
        current.requestedFireTime.timeIntervalSince1970 * 1000
      response["state"] = current.nativeState.rawValue
    }
    if let prepared = envelope.prepared {
      response["preparedSessionId"] = prepared.sessionID.uuidString
      response["preparedRevision"] = prepared.revision
      response["preparedAlarmId"] = prepared.alarmID.uuidString
      response["preparedSchedulingStatus"] = prepared.schedulingStatus.rawValue
    }
    return response
  }

  private func matchingPrepared(
    sessionID: UUID,
    revision: Int,
    alarmID: UUID
  ) throws -> TreepPersistedAlarm {
    guard let prepared = envelope.prepared,
      prepared.sessionID == sessionID,
      prepared.revision == revision,
      prepared.alarmID == alarmID
    else {
      throw TreepAlarmSessionError.preparedAlarmMismatch
    }
    return prepared
  }

  private func requireHealthyEnvelope() throws {
    guard lifecycleHealth == .healthy else {
      throw TreepAlarmSessionError.corruptPersistence
    }
    guard envelope.hasDistinctAlarmIDs else {
      lifecycleHealth = .corrupt
      throw TreepAlarmSessionError.duplicateAlarmIdentity
    }
  }

  private func persist(_ next: TreepAlarmSessionEnvelope) throws {
    guard next.hasDistinctAlarmIDs else {
      lifecycleHealth = .corrupt
      throw TreepAlarmSessionError.duplicateAlarmIdentity
    }
    try store.save(next)
    envelope = next
  }

  private static func applyObservation(
    to alarm: inout TreepPersistedAlarm,
    observation: TreepAlarmObservation?,
    now: Date
  ) {
    if let observation {
      alarm.nativeState = observation.state
      alarm.protectionStatus = switch observation.state {
      case .scheduled, .countdown, .alerting: .protected
      case .paused: .paused
      case .missing, .unknown: .unverified
      }
    } else {
      alarm.nativeState = .missing
      alarm.protectionStatus = now < alarm.requestedFireTime
        ? .missingBeforeFire
        : .missingAfterFire
    }
  }

  private static func markedUnverified(
    _ alarm: TreepPersistedAlarm
  ) -> TreepPersistedAlarm {
    var alarm = alarm
    alarm.nativeState = .unknown
    alarm.protectionStatus = .unverified
    if alarm.schedulingStatus != .confirmed {
      alarm.schedulingStatus = .unverified
    }
    return alarm
  }

  private static func unverified(
    _ envelope: TreepAlarmSessionEnvelope
  ) -> TreepAlarmSessionEnvelope {
    TreepAlarmSessionEnvelope(
      current: envelope.current.map(markedUnverified),
      prepared: envelope.prepared.map(markedUnverified),
      retiring: envelope.retiring.map(markedUnverified)
    )
  }
}
