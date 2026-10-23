import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

private extension TrackingAttributes.ContentState {
  var color: Color {
    Color(red: Double((accent >> 16) & 255) / 255,
          green: Double((accent >> 8) & 255) / 255,
          blue: Double(accent & 255) / 255)
  }

  func duration(_ seconds: Double) -> String {
    let minutes = Int(max(0, seconds) / 60)
    return minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
  }
}

private struct TrackingClock: View {
  let state: TrackingAttributes.ContentState
  var body: some View {
    Group {
      if state.running {
        // A finite interval and an explicit width are essential in WidgetKit:
        // fixedSize() on an unbounded timer can produce infinite render bounds.
        Text(timerInterval: state.clockStart...state.updatedAt.addingTimeInterval(8 * 3600),
             countsDown: false)
      } else {
        let seconds = Int(max(0, state.elapsedSeconds))
        Text(seconds >= 3600
          ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
          : String(format: "%d:%02d", seconds / 60, seconds % 60))
      }
    }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
  }
}

private struct TrackingControls: View {
  let context: ActivityViewContext<TrackingAttributes>
  var body: some View {
    if #available(iOS 17.0, *) {
      HStack(spacing: 8) {
        Button(intent: TrackingIntent(taskId: context.attributes.taskId,
          revision: context.state.revision, action: context.state.running ? "pause" : "resume")) {
          Image(systemName: context.state.running ? "pause.fill" : "play.fill")
            .font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
            .foregroundStyle(Color(red: 0.06, green: 0.08, blue: 0.11))
            .background(context.state.color, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(context.state.running ? "Приостановить таймер" : "Продолжить таймер")
        Button(intent: TrackingIntent(taskId: context.attributes.taskId,
          revision: context.state.revision, action: "stop")) {
          Image(systemName: "stop.fill").font(.system(size: 13, weight: .semibold))
            .frame(width: 44, height: 44).foregroundStyle(.white.opacity(0.85))
            .background(.white.opacity(0.09), in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel("Остановить и убрать таймер")
      }
    }
  }
}

private struct TrackingCard: View {
  let context: ActivityViewContext<TrackingAttributes>
  var body: some View {
    let state = context.state
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 5) {
            Image(systemName: state.running ? "timer" : "pause.circle")
            Text(state.running ? "YGGVION · В РАБОТЕ" : "YGGVION · ПАУЗА")
              .tracking(1.2)
          }.font(.system(size: 10, weight: .semibold)).foregroundStyle(state.color)
          Text(state.title).font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white).lineLimit(2)
        }
        Spacer(minLength: 0)
        TrackingControls(context: context)
      }
      VStack(spacing: 6) {
        if state.running && state.plannedSeconds > 0 {
          ProgressView(timerInterval: state.clockStart...state.progressEnd, countsDown: false)
            .labelsHidden().progressViewStyle(.linear).frame(height: 4).tint(state.color)
        } else {
          ProgressView(value: min(1, state.elapsedSeconds / max(1, state.plannedSeconds)))
            .progressViewStyle(.linear).frame(height: 4).tint(state.color)
        }
        HStack(spacing: 4) {
          TrackingClock(state: state).frame(width: 76, alignment: .leading)
            .foregroundStyle(.white.opacity(0.9))
          Text("/ \(state.duration(state.plannedSeconds))")
            .foregroundStyle(.white.opacity(0.5))
          Spacer()
          Text("ФАКТ / ПЛАН").font(.system(size: 9, weight: .medium)).tracking(1)
            .foregroundStyle(.white.opacity(0.45))
        }.font(.system(size: 12, weight: .medium))
      }
    }.padding(16)
  }
}

@main
struct TrackingWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TrackingAttributes.self) { context in
      TrackingCard(context: context)
        .environment(\.colorScheme, .dark)
        .activityBackgroundTint(Color(red: 0.075, green: 0.085, blue: 0.11))
        .activitySystemActionForegroundColor(context.state.color)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label("Yggvion", systemImage: "timer").font(.caption.weight(.semibold))
            .foregroundStyle(context.state.color)
        }
        DynamicIslandExpandedRegion(.trailing) {
          TrackingClock(state: context.state).font(.headline)
            .frame(width: 100, alignment: .trailing)
            .foregroundStyle(context.state.color)
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(context.state.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                .foregroundStyle(.white)
              Text("План · \(context.state.duration(context.state.plannedSeconds))")
                .font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 8)
            TrackingControls(context: context)
          }.padding(.top, 4).environment(\.colorScheme, .dark)
        }
      } compactLeading: {
        Image(systemName: context.state.running ? "timer" : "pause.fill")
          .foregroundStyle(context.state.color)
      } compactTrailing: {
        TrackingClock(state: context.state).font(.caption2).frame(maxWidth: 62)
          .foregroundStyle(context.state.color)
      } minimal: {
        Image(systemName: context.state.running ? "timer" : "pause.fill")
          .foregroundStyle(context.state.color)
      }.keylineTint(context.state.color)
    }
  }
}
