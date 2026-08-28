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
    requestedFireTime: Date? = nil
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

    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(
      name: "treep/alarm",
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
          do {
            let id = UUID()
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
            result([
              "accepted": true,
              "confirmed": alarm.state == .scheduled,
              "backend": "alarmkit",
              "alarm": self.alarmMap(
                alarm,
                requestedFireTime: fireTime
              ),
            ])
          } catch {
            result([
              "accepted": false,
              "confirmed": false,
              "backend": "alarmkit",
              "failure": error.localizedDescription,
            ])
          }
        }

      case "alarms":
        guard #available(iOS 26.0, *) else {
          result(["alarms": [], "backend": "legacy"])
          return
        }
        do {
          let alarms = try AlarmManager.shared.alarms
          result([
            "alarms": alarms.map { self.alarmMap($0) },
            "backend": "alarmkit",
          ])
        } catch {
          result(
            FlutterError(
              code: "alarm_query_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
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
        do {
          try AlarmManager.shared.cancel(id: id)
          result(self.operation(true))
        } catch {
          do {
            let stillExists = try AlarmManager.shared.alarms.contains { $0.id == id }
            result(
              stillExists
                ? self.operation(false, failure: error.localizedDescription)
                : self.operation(true)
            )
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
        do {
          let alarm = try AlarmManager.shared.alarms.first { $0.id == id }
          if alarm?.state == .alerting {
            try AlarmManager.shared.stop(id: id)
          }
          result(self.operation(true))
        } catch {
          result(self.operation(false, failure: error.localizedDescription))
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
