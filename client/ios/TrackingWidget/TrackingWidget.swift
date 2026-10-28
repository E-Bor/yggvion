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
    return minutes >= 60
      ? "\(minutes / 60) \(label("hour", "ч")) \(minutes % 60) \(label("minute", "мин"))"
      : "\(minutes) \(label("minute", "мин"))"
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
        .accessibilityLabel(context.state.running
          ? context.state.label("pause", "Пауза") : context.state.label("resume", "Продолжить"))
        Button(intent: TrackingIntent(taskId: context.attributes.taskId,
          revision: context.state.revision, action: "stop")) {
          Image(systemName: "stop.fill").font(.system(size: 13, weight: .semibold))
            .frame(width: 44, height: 44).foregroundStyle(.white.opacity(0.85))
            .background(.white.opacity(0.09), in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(context.state.label("stop", "Остановить"))
      }
    }
  }
}

private struct TrackingProgress: View {
  let state: TrackingAttributes.ContentState
  // Same rose used by the calendar's tracked-time stripe in the dark theme.
  private let overtime = Color(red: 223.0 / 255, green: 166.0 / 255, blue: 186.0 / 255)
  private let steps = 64

  private func interval(_ index: Int) -> ClosedRange<Date> {
    let start = state.plannedSeconds / (1 - Double(index) / Double(steps))
    let end = index + 1 == steps ? start + 10 * 365 * 86400
      : state.plannedSeconds / (1 - Double(index + 1) / Double(steps))
    return state.clockStart.addingTimeInterval(start)...state.clockStart.addingTimeInterval(end)
  }

  var body: some View {
    Group {
      if state.running && state.plannedSeconds > 0 {
        ZStack {
          ProgressView(timerInterval: state.clockStart...state.progressEnd, countsDown: false)
            .labelsHidden().tint(state.color)
          // ActivityKit can suspend our process. System-driven date progress
          // views keep the reciprocal plan/elapsed curve moving without an app
          // timer or push. Small contiguous intervals approximate it within one
          // bar segment (1/64); paused state uses the exact ratio below.
          HStack(spacing: 0) {
            ForEach(0..<steps, id: \.self) { index in
              overtime.mask(
                ProgressView(timerInterval: interval(index), countsDown: false)
                  .labelsHidden().tint(.white)
                  .scaleEffect(x: 1, y: 3)
                  .frame(height: 4).clipped()
                  .background(.black).compositingGroup()
                  .contrast(100).luminanceToAlpha()
              )
            }
          }.environment(\.layoutDirection, .rightToLeft)
        }
      } else {
        GeometryReader { geometry in
          let elapsed = max(0, state.elapsedSeconds)
          let plan = max(0, state.plannedSeconds)
          let denominator = max(1, max(elapsed, plan))
          HStack(spacing: 0) {
            state.color.frame(width: geometry.size.width * min(elapsed, plan) / denominator)
            overtime.frame(width: geometry.size.width * max(0, elapsed - plan) / denominator)
            Spacer(minLength: 0)
          }.background(.white.opacity(0.12))
        }
      }
    }.frame(height: 4).clipShape(Capsule()).accessibilityLabel(state.label("progress", "Факт относительно плана"))
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
            Text("YGGVION · \(state.running ? state.label("running", "В работе") : state.label("pause", "Пауза"))")
              .tracking(1.2)
          }.font(.system(size: 10, weight: .semibold)).foregroundStyle(state.color)
          Text(state.title).font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white).lineLimit(2)
        }
        Spacer(minLength: 0)
        TrackingControls(context: context)
      }
      VStack(spacing: 6) {
        TrackingProgress(state: state)
        HStack(spacing: 4) {
          TrackingClock(state: state).frame(width: 76, alignment: .leading)
            .foregroundStyle(.white.opacity(0.9))
          Text("/ \(state.duration(state.plannedSeconds))")
            .foregroundStyle(.white.opacity(0.5))
          Spacer()
          Text("\(state.label("actual", "Факт")) / \(state.label("planned", "План"))")
            .font(.system(size: 9, weight: .medium)).tracking(1).lineLimit(1).minimumScaleFactor(0.7)
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
              Text("\(context.state.label("planned", "План")) · \(context.state.duration(context.state.plannedSeconds))")
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
