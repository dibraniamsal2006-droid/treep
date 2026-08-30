import ActivityKit
import SwiftUI
import WidgetKit

private let treepGreen = Color(red: 0.333, green: 0.839, blue: 0.545)
private let treepMuted = Color(red: 0.537, green: 0.576, blue: 0.557)

@main
struct TreepLiveActivityBundle: WidgetBundle {
  var body: some Widget {
    TreepJourneyLiveActivity()
  }
}

struct TreepJourneyLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TreepJourneyActivityAttributes.self) { context in
      TreepLockScreenView(context: context)
        .activityBackgroundTint(Color.black.opacity(0.92))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          TreepTimeRing(
            state: context.state,
            diameter: 32
          )
          .frame(maxWidth: 36, maxHeight: 36)
          .padding(.leading, 2)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.alarmTime, style: .timer)
            .font(.system(.title2, design: .rounded, weight: .bold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(width: 78, alignment: .trailing)
            .frame(width: 82, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(context.state.lineLabel)
                .font(.caption.weight(.bold))
                .foregroundStyle(treepGreen)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
              Spacer(minLength: 8)
              VStack(alignment: .trailing, spacing: 0) {
                Text("Arrival")
                  .font(.caption2)
                  .foregroundStyle(treepMuted)
                Text(context.state.arrivalTime, style: .time)
                  .font(.caption.weight(.semibold))
                  .monospacedDigit()
              }
              .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            Text(context.state.destinationLabel)
              .font(.headline.weight(.semibold))
              .lineLimit(1)
              .minimumScaleFactor(0.68)
              .layoutPriority(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 2)
          .padding(.top, 2)
        }
      } compactLeading: {
        TreepTimeRing(
          state: context.state,
          diameter: 19
        )
      } compactTrailing: {
        Text(context.state.alarmTime, style: .timer)
          .font(.caption2.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .foregroundStyle(treepGreen)
          .frame(width: 44, alignment: .trailing)
      } minimal: {
        TreepTimeRing(
          state: context.state,
          diameter: 19
        )
      }
      .keylineTint(treepGreen)
    }
  }
}

private struct TreepLockScreenView: View {
  let context: ActivityViewContext<TreepJourneyActivityAttributes>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 16) {
        TreepLockScreenTimeRing(state: context.state)
        Spacer(minLength: 0)
      }
      .frame(height: 44)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(context.state.lineLabel)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(treepGreen)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
          Text(context.state.destinationLabel)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.68)
            .layoutPriority(1)
        }
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Text("Arrival")
            .font(.caption)
            .foregroundStyle(treepMuted)
          Text(context.state.arrivalTime, style: .time)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
        }
      }
    }
    .padding(.trailing, 148)
    .overlay(alignment: .trailing) {
      if context.isStale {
        Text("Alarm now")
          .font(.system(size: 36, weight: .bold, design: .rounded))
          .lineLimit(1)
          .minimumScaleFactor(0.72)
          .frame(width: 140, alignment: .trailing)
      } else {
        Text(context.state.alarmTime, style: .timer)
          .font(.system(size: 39, weight: .bold, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.72)
          .frame(width: 140, alignment: .trailing)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}

private struct TreepLockScreenTimeRing: View {
  let state: TreepJourneyActivityAttributes.ContentState

  private var interval: ClosedRange<Date> {
    state.referenceTime...state.alarmTime
  }

  var body: some View {
    ProgressView(timerInterval: interval, countsDown: true) {
      EmptyView()
    } currentValueLabel: {
      EmptyView()
    }
      .progressViewStyle(.circular)
      .controlSize(.large)
      .tint(treepGreen)
      .frame(width: 36, height: 36)
      .contentShape(Circle())
      .accessibilityLabel("Time until Treep alarm")
  }
}

private struct TreepTimeRing: View {
  let state: TreepJourneyActivityAttributes.ContentState
  let diameter: CGFloat

  private var interval: ClosedRange<Date> {
    state.referenceTime...state.alarmTime
  }

  var body: some View {
    ProgressView(timerInterval: interval, countsDown: true) {
      EmptyView()
    } currentValueLabel: {
      EmptyView()
    }
      .progressViewStyle(.circular)
      .tint(treepGreen)
      .scaleEffect(diameter / 23)
    .frame(width: diameter, height: diameter)
    .contentShape(Circle())
    .accessibilityLabel("Time until Treep alarm")
  }
}
