import AlarmKit
import AVFoundation
import Flutter
import SwiftUI
import UIKit

@available(iOS 26.0, *)
private struct TreepAlarmMetadata: AlarmMetadata {
  let requestedFireTime: Date
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var alarmPlayer: AVAudioPlayer?
  private var pendingLegacyAlarmID: UUID?
  private var pendingLegacyWorkItem: DispatchWorkItem?
  private lazy var alarmSessionCoordinator = TreepAlarmSessionCoordinator(
    store: TreepAlarmSessionUserDefaultsStore()
  )
  private var alarmUpdatesTask: Task<Void, Never>?
  private var alarmLifecycleStartupTask: Task<Void, Never>?

  private func ensureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(
        .playback,
        mode: .default,
        options: [.mixWithOthers, .duckOthers, .allowAirPlay, .allowBluetooth]
      )
      try session.setActive(true)
    } catch {
      print("[alarm] legacy audio session failed: \(error)")
    }
  }

  private func loadAlarmPlayerIfNeeded(loop: Bool) {
    if alarmPlayer != nil { return }
    guard let url = Bundle.main.url(forResource: "alarm", withExtension: "wav") else {
      return
    }
    do {
      ensureAudioSession()
      let player = try AVAudioPlayer(contentsOf: url)
      player.volume = 1.0
      player.numberOfLoops = loop ? -1 : 0
      player.prepareToPlay()
      alarmPlayer = player
    } catch {
      alarmPlayer = nil
      print("[alarm] legacy player failed: \(error)")
    }
  }

  private func startLegacyAlarm(loop: Bool) {
    loadAlarmPlayerIfNeeded(loop: loop)
    ensureAudioSession()
    alarmPlayer?.numberOfLoops = loop ? -1 : 0
    alarmPlayer?.currentTime = 0
    alarmPlayer?.play()
  }

  private func stopLegacyAlarm() {
    pendingLegacyWorkItem?.cancel()
    pendingLegacyWorkItem = nil
    pendingLegacyAlarmID = nil
    alarmPlayer?.stop()
    alarmPlayer = nil
  }

  private func operation(_ succeeded: Bool, failure: String? = nil) -> [String: Any] {
    var response: [String: Any] = ["succeeded": succeeded]
    if let failure {
      response["failure"] = failure
    }
    return response
  }

  @available(iOS 26.0, *)
  private func authorizationName(
    _ state: AlarmManager.AuthorizationState
  ) -> String {
    switch state {
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .authorized: return "authorized"
    @unknown default: return "unknown"
    }
  }

  @available(iOS 26.0, *)
  private func stateName(_ state: Alarm.State) -> String {
    switch state {
    case .scheduled: return "scheduled"
    case .countdown: return "countdown"
    case .paused: return "paused"
    case .alerting: return "alerting"
    @unknown default: return "unknown"
    }
  }

  @available(iOS 26.0, *)
  private func sessionState(_ state: Alarm.State) -> TreepNativeAlarmState {
    switch state {
    case .scheduled: return .scheduled
    case .countdown: return .countdown
    case .paused: return .paused
    case .alerting: return .alerting
    @unknown default: return .unknown
    }
  }

  @available(iOS 26.0, *)
  @MainActor
  private func observations(_ alarms: [Alarm]) -> [TreepAlarmObservation] {
    alarms.map {
      TreepAlarmObservation(
        alarmID: $0.id,
        state: sessionState($0.state)
      )
    }
  }

  @available(iOS 26.0, *)
  @MainActor
  @discardableResult
  private func reconcileSession(with alarms: [Alarm]) -> Bool {
    do {
      try alarmSessionCoordinator.reconcileCurrent(
        observations: observations(alarms),
        now: Date()
      )
      return true
    } catch {
      print("[alarm] native session reconciliation persistence failed: \(error)")
      return false
    }
  }

  @available(iOS 26.0, *)
  @MainActor
  private func cancelLifecycleAlarm(_ persisted: TreepPersistedAlarm) {
    guard alarmSessionCoordinator.envelope.current?.alarmID != persisted.alarmID else {
      print(
        "[alarm] lifecycle cleanup refused current id=\(persisted.alarmID.uuidString)"
      )
      return
    }
    do {
      try alarmSessionCoordinator.validateCancellation(
        sessionID: persisted.sessionID,
        revision: persisted.revision,
        alarmID: persisted.alarmID
      )
      do {
        try AlarmManager.shared.cancel(id: persisted.alarmID)
      } catch {
        let stillExists = try AlarmManager.shared.alarms.contains {
          $0.id == persisted.alarmID
        }
        if stillExists { throw error }
      }
      try alarmSessionCoordinator.recordCancellation(
        sessionID: persisted.sessionID,
        revision: persisted.revision,
        alarmID: persisted.alarmID
      )
    } catch {
      print(
        "[alarm] lifecycle cleanup failed id=\(persisted.alarmID.uuidString): \(error)"
      )
    }
  }

  @available(iOS 26.0, *)
  @MainActor
  private func resolveFailedPreparedSchedule(
    _ prepared: TreepPersistedAlarm
  ) -> Bool {
    do {
      var exists = try AlarmManager.shared.alarms.contains {
        $0.id == prepared.alarmID
      }
      if exists {
        do {
          try AlarmManager.shared.cancel(id: prepared.alarmID)
        } catch {
          print(
            "[alarm] prepared rollback cancel failed id=\(prepared.alarmID.uuidString): \(error)"
          )
        }
        exists = try AlarmManager.shared.alarms.contains {
          $0.id == prepared.alarmID
        }
      }
      if exists {
        try alarmSessionCoordinator.markPreparedUnverified(
          sessionID: prepared.sessionID,
          revision: prepared.revision,
          alarmID: prepared.alarmID
        )
        return true
      }
      try alarmSessionCoordinator.clearPreparedIfMissing(
        sessionID: prepared.sessionID,
        revision: prepared.revision,
        alarmID: prepared.alarmID
      )
      return false
    } catch {
      do {
        try alarmSessionCoordinator.markPreparedUnverified(
          sessionID: prepared.sessionID,
          revision: prepared.revision,
          alarmID: prepared.alarmID
        )
      } catch let persistenceError {
        print(
          "[alarm] prepared ownership remains persisted but could not be marked unverified: \(persistenceError)"
        )
      }
      print(
        "[alarm] prepared schedule outcome unresolved id=\(prepared.alarmID.uuidString): \(error)"
      )
      return true
    }
  }

  @available(iOS 26.0, *)
  @MainActor
  private func runAlarmLifecycleStartup() {
    do {
      let alarms = try AlarmManager.shared.alarms
      let plan = try alarmSessionCoordinator.reconcileStartup(
        observations: observations(alarms),
        now: Date()
      )
      for persisted in [plan.preparedToCancel, plan.retiringToCancel]
        .compactMap({ $0 })
      {
        cancelLifecycleAlarm(persisted)
      }
    } catch {
      do {
        try alarmSessionCoordinator.markAllUnverified()
      } catch {
        // Corrupt persistence is deliberately left untouched. Unknown or
        // pre-PATCH alarms returned by AlarmKit are never adopted or deleted.
      }
      print("[alarm] native session startup reconciliation failed: \(error)")
    }
  }

  @available(iOS 26.0, *)
  @MainActor
  private func startAlarmLifecycle() {
    guard alarmLifecycleStartupTask == nil else { return }
    let startup = Task { @MainActor [weak self] in
      guard let self else { return }
      self.runAlarmLifecycleStartup()
    }
    alarmLifecycleStartupTask = startup
    alarmUpdatesTask = Task { @MainActor [weak self] in
      await startup.value
      for await alarms in AlarmManager.shared.alarmUpdates {
        guard let self else { return }
        self.reconcileSession(with: alarms)
      }
    }
  }

  @available(iOS 26.0, *)
  private func fireTime(_ alarm: Alarm) -> Date? {
    guard let schedule = alarm.schedule else { return nil }
    switch schedule {
    case .fixed(let date): return date
    case .relative: return nil
    @unknown default: return nil
    }
  }

  @available(iOS 26.0, *)
  private func alarmMap(
    _ alarm: Alarm,
    requestedFireTime: Date? = nil,
    persisted: TreepPersistedAlarm? = nil
  ) -> [String: Any] {
    var response: [String: Any] = [
      "id": alarm.id.uuidString,
      "backend": "alarmkit",
      "state": stateName(alarm.state),
    ]
    let scheduled = fireTime(alarm)
    if let requestedFireTime {
      response["requestedFireTimeMs"] = requestedFireTime.timeIntervalSince1970 * 1000
    } else if let scheduled {
      response["requestedFireTimeMs"] = scheduled.timeIntervalSince1970 * 1000
    }
    if let scheduled {
      response["scheduledFireTimeMs"] = scheduled.timeIntervalSince1970 * 1000
    }
    if let persisted {
      response["sessionId"] = persisted.sessionID.uuidString
      response["revision"] = persisted.revision
    }
    return response
  }

  @available(iOS 26.0, *)
  private func unresolvedAlarmMap(
    _ persisted: TreepPersistedAlarm
  ) -> [String: Any] {
    [
      "id": persisted.alarmID.uuidString,
      "backend": "alarmkit",
      "state": "unknown",
      "requestedFireTimeMs":
        persisted.requestedFireTime.timeIntervalSince1970 * 1000,
      "sessionId": persisted.sessionID.uuidString,
      "revision": persisted.revision,
    ]
  }

  @available(iOS 26.0, *)
  private func failedScheduleMap(
    prepared: TreepPersistedAlarm,
    unresolved: Bool,
    failure: String
  ) -> [String: Any] {
    var response: [String: Any] = [
      "accepted": false,
      "confirmed": false,
      "backend": "alarmkit",
      "unresolved": unresolved,
      "failure": failure,
    ]
    if unresolved {
      response["alarm"] = unresolvedAlarmMap(prepared)
    }
    return response
  }

  private func scheduleLegacy(fireTime: Date) -> [String: Any] {
    pendingLegacyWorkItem?.cancel()
    let id = UUID()
    let work = DispatchWorkItem { [weak self] in
      self?.startLegacyAlarm(loop: true)
    }
    pendingLegacyAlarmID = id
    pendingLegacyWorkItem = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + max(0, fireTime.timeIntervalSinceNow),
      execute: work
    )
    return [
      "accepted": true,
      "confirmed": false,
      "backend": "legacy",
      "alarm": [
        "id": id.uuidString,
        "backend": "legacy",
        "state": "bestEffort",
        "requestedFireTimeMs": fireTime.timeIntervalSince1970 * 1000,
        "scheduledFireTimeMs": fireTime.timeIntervalSince1970 * 1000,
      ],
    ]
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if #available(iOS 26.0, *) {
      startAlarmLifecycle()
    }

    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(
      name: "treep/alarm",
      binaryMessenger: controller.binaryMessenger
    )
    TreepLiveActivityBridge.configure(
      binaryMessenger: controller.binaryMessenger
    )

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(["succeeded": false, "failure": "App delegate unavailable"])
        return
      }
      switch call.method {
      case "capabilities":
        if #available(iOS 26.0, *) {
          result(["alarmKitSupported": true, "backend": "alarmkit"])
        } else {
          result(["alarmKitSupported": false, "backend": "legacy"])
        }

      case "authorizationState":
        if #available(iOS 26.0, *) {
          result([
            "authorization": self.authorizationName(
              AlarmManager.shared.authorizationState
            )
          ])
        } else {
          result(["authorization": "unsupported"])
        }

      case "requestAuthorization":
        guard #available(iOS 26.0, *) else {
          result(["authorization": "unsupported"])
          return
        }
        Task { @MainActor in
          do {
            let state = try await AlarmManager.shared.requestAuthorization()
            result(["authorization": self.authorizationName(state)])
          } catch {
            result([
              "authorization": "unknown",
              "failure": error.localizedDescription,
            ])
          }
        }

      case "schedule":
        guard
          let arguments = call.arguments as? [String: Any],
          let fireTimeMs = arguments["fireTimeMs"] as? NSNumber
        else {
          result([
            "accepted": false,
            "confirmed": false,
            "backend": "unavailable",
            "failure": "Missing fireTimeMs",
          ])
          return
        }
        let fireTime = Date(
          timeIntervalSince1970: fireTimeMs.doubleValue / 1000
        )
        guard #available(iOS 26.0, *) else {
          result(self.scheduleLegacy(fireTime: fireTime))
          return
        }
        Task { @MainActor in
          await self.alarmLifecycleStartupTask?.value
          let id = UUID()
          let preparedIntent: TreepPersistedAlarm
          do {
            preparedIntent = try self.alarmSessionCoordinator.prepareIntent(
              alarmID: id,
              requestedFireTime: fireTime
            )
          } catch {
            result([
              "accepted": false,
              "confirmed": false,
              "backend": "alarmkit",
              "failure": error.localizedDescription,
            ])
            return
          }
          do {
            let alert: AlarmPresentation.Alert
            if #available(iOS 26.1, *) {
              alert = AlarmPresentation.Alert(
                title: LocalizedStringResource("TREEP ALARM")
              )
            } else {
              let stopButton = AlarmButton(
                text: LocalizedStringResource("Stop"),
                textColor: .white,
                systemImageName: "stop.fill"
              )
              alert = AlarmPresentation.Alert(
                title: LocalizedStringResource("TREEP ALARM"),
                stopButton: stopButton
              )
            }
            let presentation = AlarmPresentation(alert: alert)
            let attributes = AlarmAttributes(
              presentation: presentation,
              metadata: TreepAlarmMetadata(requestedFireTime: fireTime),
              tintColor: .green
            )
            let configuration = AlarmManager.AlarmConfiguration.alarm(
              schedule: .fixed(fireTime),
              attributes: attributes,
              sound: .default
            )
            let alarm = try await AlarmManager.shared.schedule(
              id: id,
              configuration: configuration
            )
            let prepared: TreepPersistedAlarm
            do {
              prepared = try self.alarmSessionCoordinator.confirmPrepared(
                sessionID: preparedIntent.sessionID,
                revision: preparedIntent.revision,
                alarmID: preparedIntent.alarmID,
                nativeState: self.sessionState(alarm.state)
              )
            } catch {
              let unresolved = self.resolveFailedPreparedSchedule(preparedIntent)
              result(
                self.failedScheduleMap(
                  prepared: preparedIntent,
                  unresolved: unresolved,
                  failure: error.localizedDescription
                )
              )
              return
            }
            result([
              "accepted": true,
              "confirmed": self.sessionState(alarm.state).isProtected,
              "backend": "alarmkit",
              "alarm": self.alarmMap(
                alarm,
                requestedFireTime: fireTime,
                persisted: prepared
              ),
            ])
          } catch {
            let unresolved = self.resolveFailedPreparedSchedule(preparedIntent)
            result(
              self.failedScheduleMap(
                prepared: preparedIntent,
                unresolved: unresolved,
                failure: error.localizedDescription
              )
            )
          }
        }

      case "promoteSession":
        guard #available(iOS 26.0, *) else {
          result(self.operation(false, failure: "AlarmKit unavailable"))
          return
        }
        guard
          let arguments = call.arguments as? [String: Any],
          let rawSessionID = arguments["sessionId"] as? String,
          let sessionID = UUID(uuidString: rawSessionID),
          let revision = arguments["revision"] as? NSNumber,
          let rawAlarmID = arguments["alarmId"] as? String,
          let alarmID = UUID(uuidString: rawAlarmID)
        else {
          result(self.operation(false, failure: "Invalid native session identity"))
          return
        }
        Task { @MainActor in
          do {
            try self.alarmSessionCoordinator.promote(
              sessionID: sessionID,
              revision: revision.intValue,
              alarmID: alarmID
            )
            if let retiring = self.alarmSessionCoordinator.retiringAlarm {
              self.cancelLifecycleAlarm(retiring)
            }
            result(self.operation(true))
          } catch {
            result(self.operation(false, failure: error.localizedDescription))
          }
        }

      case "sessionSnapshot":
        guard #available(iOS 26.0, *) else {
          result([
            "sessionExists": false,
            "protected": false,
            "protectionStatus": "unverified",
          ])
          return
        }
        Task { @MainActor in
          await self.alarmLifecycleStartupTask?.value
          var reconciliationAvailable = true
          do {
            let alarms = try AlarmManager.shared.alarms
            reconciliationAvailable = self.reconcileSession(with: alarms)
          } catch {
            reconciliationAvailable = false
            try? self.alarmSessionCoordinator.markAllUnverified()
          }
          result(
            self.alarmSessionCoordinator.snapshotMap(
              reconciliationAvailable: reconciliationAvailable
            )
          )
        }

      case "alarms":
        guard #available(iOS 26.0, *) else {
          result(["alarms": [], "backend": "legacy"])
          return
        }
        Task { @MainActor in
          do {
            let alarms = try AlarmManager.shared.alarms
            self.reconcileSession(with: alarms)
            result([
              "alarms": alarms.map {
                self.alarmMap(
                  $0,
                  persisted: self.alarmSessionCoordinator.persistedAlarm(
                    alarmID: $0.id
                  )
                )
              },
              "backend": "alarmkit",
            ])
          } catch {
            try? self.alarmSessionCoordinator.markAllUnverified()
            result(
              FlutterError(
                code: "alarm_query_failed",
                message: error.localizedDescription,
                details: nil
              )
            )
          }
        }

      case "cancel":
        guard #available(iOS 26.0, *) else {
          result(self.operation(false, failure: "AlarmKit unavailable"))
          return
        }
        guard
          let arguments = call.arguments as? [String: Any],
          let rawID = arguments["alarmId"] as? String,
          let id = UUID(uuidString: rawID)
        else {
          result(self.operation(false, failure: "Invalid alarmId"))
          return
        }
        let rawSessionID = arguments["sessionId"] as? String
        let sessionID = rawSessionID.flatMap(UUID.init(uuidString:))
        let revision = (arguments["revision"] as? NSNumber)?.intValue
        Task { @MainActor in
          do {
            try self.alarmSessionCoordinator.validateCancellation(
              sessionID: sessionID,
              revision: revision,
              alarmID: id
            )
            do {
              try AlarmManager.shared.cancel(id: id)
            } catch {
              let stillExists = try AlarmManager.shared.alarms.contains { $0.id == id }
              if stillExists { throw error }
            }
            try self.alarmSessionCoordinator.recordCancellation(
              sessionID: sessionID,
              revision: revision,
              alarmID: id
            )
            result(self.operation(true))
          } catch {
            result(self.operation(false, failure: error.localizedDescription))
          }
        }

      case "stopAlerting":
        guard #available(iOS 26.0, *) else {
          result(self.operation(false, failure: "AlarmKit unavailable"))
          return
        }
        guard
          let arguments = call.arguments as? [String: Any],
          let rawID = arguments["alarmId"] as? String,
          let id = UUID(uuidString: rawID)
        else {
          result(self.operation(false, failure: "Invalid alarmId"))
          return
        }
        let rawSessionID = arguments["sessionId"] as? String
        let sessionID = rawSessionID.flatMap(UUID.init(uuidString:))
        let revision = (arguments["revision"] as? NSNumber)?.intValue
        Task { @MainActor in
          do {
            try self.alarmSessionCoordinator.validateCancellation(
              sessionID: sessionID,
              revision: revision,
              alarmID: id
            )
            let alarm = try AlarmManager.shared.alarms.first { $0.id == id }
            if alarm?.state == .alerting {
              try AlarmManager.shared.stop(id: id)
            }
            result(self.operation(true))
          } catch {
            result(self.operation(false, failure: error.localizedDescription))
          }
        }

      case "startNow":
        let arguments = call.arguments as? [String: Any]
        self.startLegacyAlarm(loop: arguments?["loop"] as? Bool ?? true)
        result(self.operation(true))

      case "stopLegacy":
        self.stopLegacyAlarm()
        result(self.operation(true))

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )
  }
}
