import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct TreepJourneyActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
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
  }

  let activityID: String
}
