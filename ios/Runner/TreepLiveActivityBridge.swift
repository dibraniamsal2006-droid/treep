import ActivityKit
import Flutter
import Foundation

@available(iOS 16.2, *)
private struct TreepLiveActivityPayload {
  let journeyID: String
  let lineLabel: String
  let destinationLabel: String
  let directionLabel: String
  let referenceTime: Date
  let alarmTime: Date
  let arrivalTime: Date
  let phase: String
  let alarmID: String?
  let alarmSessionID: String?
  let alarmRevision: Int?

  init(arguments: Any?) throws {
    guard let values = arguments as? [String: Any] else {
      throw TreepLiveActivityError.invalidArguments
    }
    journeyID = try Self.requiredString("journeyId", in: values)
    lineLabel = try Self.requiredString("lineLabel", in: values)
    destinationLabel = try Self.requiredString("destinationLabel", in: values)
    directionLabel = (values["directionLabel"] as? String)?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ) ?? ""
    referenceTime = try Self.requiredDate("referenceTimeMs", in: values)
    alarmTime = try Self.requiredDate("alarmTimeMs", in: values)
    arrivalTime = try Self.requiredDate("arrivalTimeMs", in: values)
    phase = (values["phase"] as? String)?.nonEmpty ?? "tracking"
    alarmID = (values["alarmId"] as? String)?.nonEmpty
    alarmSessionID = (values["alarmSessionId"] as? String)?.nonEmpty
    alarmRevision = (values["alarmRevision"] as? NSNumber)?.intValue

    guard alarmTime > referenceTime, arrivalTime >= alarmTime else {
      throw TreepLiveActivityError.invalidTimeline
    }
  }

  var contentState: TreepJourneyActivityAttributes.ContentState {
    TreepJourneyActivityAttributes.ContentState(
      journeyID: journeyID,
      lineLabel: lineLabel,
      destinationLabel: destinationLabel,
      directionLabel: directionLabel,
      referenceTime: referenceTime,
      alarmTime: alarmTime,
      arrivalTime: arrivalTime,
      phase: phase,
      alarmID: alarmID,
      alarmSessionID: alarmSessionID,
      alarmRevision: alarmRevision
    )
  }

  private static func requiredString(
    _ key: String,
    in values: [String: Any]
  ) throws -> String {
    guard let value = (values[key] as? String)?.nonEmpty else {
      throw TreepLiveActivityError.missingField(key)
    }
    return value
  }

  private static func requiredDate(
    _ key: String,
    in values: [String: Any]
  ) throws -> Date {
    guard let milliseconds = values[key] as? NSNumber else {
      throw TreepLiveActivityError.missingField(key)
    }
    return Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
  }
}

private enum TreepLiveActivityError: LocalizedError {
  case invalidArguments
  case missingField(String)
  case invalidTimeline

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      return "Invalid Live Activity arguments"
    case .missingField(let field):
      return "Missing Live Activity field: \(field)"
    case .invalidTimeline:
      return "Live Activity timestamps are not ordered"
    }
  }
}

private extension String {
  var nonEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}

enum TreepLiveActivityBridge {
  static func configure(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "treep/live_activity",
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      guard #available(iOS 16.2, *) else {
        result(unsupportedResponse())
        return
      }
      Task { @MainActor in
        switch call.method {
        case "capabilities":
          result(capabilitiesResponse())
        case "startOrUpdate":
          result(await startOrUpdate(arguments: call.arguments))
        case "end":
          result(await end(arguments: call.arguments))
        case "snapshot":
          result(snapshotResponse())
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  private static func unsupportedResponse() -> [String: Any] {
    [
      "supported": false,
      "enabled": false,
      "succeeded": false,
      "failure": "Live Activities require iOS 16.2 or later",
    ]
  }

  @available(iOS 16.2, *)
  @MainActor
  private static func capabilitiesResponse() -> [String: Any] {
    [
      "supported": true,
      "enabled": ActivityAuthorizationInfo().areActivitiesEnabled,
      "succeeded": true,
    ]
  }

  @available(iOS 16.2, *)
  @MainActor
  private static func startOrUpdate(arguments: Any?) async -> [String: Any] {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      return [
        "supported": true,
        "enabled": false,
        "succeeded": false,
        "failure": "Live Activities are disabled",
      ]
    }

    do {
      let payload = try TreepLiveActivityPayload(arguments: arguments)
      let content = ActivityContent(
        state: payload.contentState,
        staleDate: payload.alarmTime
      )
      let activities = Activity<TreepJourneyActivityAttributes>.activities
      if let current = activities.first {
        await current.update(content)
        for duplicate in activities.dropFirst() {
          await duplicate.end(nil, dismissalPolicy: .immediate)
        }
        return operationResponse(activity: current, action: "updated")
      }

      let attributes = TreepJourneyActivityAttributes(
        activityID: UUID().uuidString
      )
      let activity = try Activity.request(
        attributes: attributes,
        content: content,
        pushType: nil
      )
      return operationResponse(activity: activity, action: "started")
    } catch {
      return [
        "supported": true,
        "enabled": true,
        "succeeded": false,
        "failure": error.localizedDescription,
      ]
    }
  }

  @available(iOS 16.2, *)
  @MainActor
  private static func end(arguments: Any?) async -> [String: Any] {
    let requestedID = (arguments as? [String: Any])?["activityId"] as? String
    let activities = Activity<TreepJourneyActivityAttributes>.activities
    let selected = requestedID?.nonEmpty == nil
      ? activities
      : activities.filter { $0.id == requestedID }
    for activity in selected {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
    return [
      "supported": true,
      "enabled": ActivityAuthorizationInfo().areActivitiesEnabled,
      "succeeded": true,
      "endedCount": selected.count,
    ]
  }

  @available(iOS 16.2, *)
  @MainActor
  private static func snapshotResponse() -> [String: Any] {
    let activities = Activity<TreepJourneyActivityAttributes>.activities
    return [
      "supported": true,
      "enabled": ActivityAuthorizationInfo().areActivitiesEnabled,
      "succeeded": true,
      "activities": activities.map {
        [
          "activityId": $0.id,
          "journeyId": $0.content.state.journeyID,
          "phase": $0.content.state.phase,
          "alarmTimeMs":
            $0.content.state.alarmTime.timeIntervalSince1970 * 1000,
        ]
      },
    ]
  }

  @available(iOS 16.2, *)
  private static func operationResponse(
    activity: Activity<TreepJourneyActivityAttributes>,
    action: String
  ) -> [String: Any] {
    [
      "supported": true,
      "enabled": true,
      "succeeded": true,
      "activityId": activity.id,
      "action": action,
    ]
  }
}
