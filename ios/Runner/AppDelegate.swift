import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var alarmPlayer: AVAudioPlayer?
  private var pendingArmWorkItem: DispatchWorkItem?

  private func ensureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      // .playback spielt auch im Silent Mode (best-effort; Volume muss trotzdem > 0 sein)
      try session.setCategory(
        .playback,
        mode: .default,
        options: [.mixWithOthers, .duckOthers, .allowAirPlay, .allowBluetooth]
      )
      try session.setActive(true)
    } catch {
      // ignore
    }
  }

  private func loadAlarmPlayerIfNeeded(loop: Bool) {
    if alarmPlayer != nil { return }

    guard let url = Bundle.main.url(forResource: "alarm", withExtension: "wav") else {
      return
    }

    do {
      ensureAudioSession()
      let p = try AVAudioPlayer(contentsOf: url)
      p.volume = 1.0
      p.numberOfLoops = loop ? -1 : 0
      p.prepareToPlay()
      alarmPlayer = p
    } catch {
      alarmPlayer = nil
    }
  }

  private func startAlarm(loop: Bool) {
    loadAlarmPlayerIfNeeded(loop: loop)
    ensureAudioSession()
    alarmPlayer?.numberOfLoops = loop ? -1 : 0
    alarmPlayer?.currentTime = 0
    alarmPlayer?.play()
  }

  private func stopAlarm() {
    pendingArmWorkItem?.cancel()
    pendingArmWorkItem = nil
    alarmPlayer?.stop()
    alarmPlayer = nil
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "treep/alarm", binaryMessenger: controller.binaryMessenger)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(false); return }

      switch call.method {
      case "startNow":
        let args = call.arguments as? [String: Any]
        let loop = (args?["loop"] as? Bool) ?? true
        self.startAlarm(loop: loop)
        result(true)

      case "stop":
        self.stopAlarm()
        result(true)

      case "arm":
        let args = call.arguments as? [String: Any]
        let secs = (args?["secondsFromNow"] as? Double) ?? 0.0
        let loop = (args?["loop"] as? Bool) ?? true

        self.pendingArmWorkItem?.cancel()
        self.pendingArmWorkItem = nil

        let delay = max(0.0, secs)
        let work = DispatchWorkItem { [weak self] in
          self?.startAlarm(loop: loop)
        }
        self.pendingArmWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        result(true)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
