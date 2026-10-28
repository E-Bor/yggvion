import ActivityKit
import Flutter
import UIKit

@MainActor
final class TrackingActivityCoordinator {
  static let shared = TrackingActivityCoordinator()
  var actionsChanged: (() -> Void)?

  private var store: TrackingStore {
    get throws {
      let directory = try FileManager.default.url(for: .applicationSupportDirectory,
        in: .userDomainMask, appropriateFor: nil, create: true)
      return TrackingStore(directory: directory.appendingPathComponent("Tracking"))
    }
  }

  func pending() throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.read().pending))
  }

  func publish(_ arguments: Any?) async throws -> Bool {
    struct Update: Decodable {
      var state: TrackingState?
      var acknowledged: [String]
    }
    guard let args = arguments as? [String: Any] else {
      throw CocoaError(.coderInvalidValue)
    }
    let update = try JSONDecoder().decode(Update.self,
      from: JSONSerialization.data(withJSONObject: args))
    let accepted = try store.publish(update.state, acknowledged: update.acknowledged)
    try await synchronize(canStart: UIApplication.shared.applicationState == .active)
    return accepted
  }

  func perform(_ action: String, taskId: String, revision: String) async throws {
    let changed = try store.perform(action, taskId: taskId, revision: revision,
      at: Int64(Date().timeIntervalSince1970 * 1000))
    if changed {
      try await synchronize(canStart: true)
      actionsChanged?()
    }
  }

  func clear() async throws {
    try store.write(TrackingEnvelope())
    try await synchronize(canStart: false)
  }

  private func synchronize(canStart: Bool) async throws {
    let current = try store.read()
    for activity in Activity<TrackingAttributes>.activities
      where activity.attributes.taskId != current.state?.taskId ||
        activity.activityState == .ended || activity.activityState == .dismissed {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
    guard let state = current.state else { return }
    let content = ActivityContent(state: TrackingAttributes.ContentState(
      title: state.title, plannedSeconds: Double(max(0, state.plannedMs)) / 1000,
      elapsedSeconds: Double(max(0, state.elapsedMs)) / 1000,
      updatedAt: Date(timeIntervalSince1970: Double(state.updatedAtMs) / 1000),
      running: state.running, accent: state.accent, revision: current.revision, labels: state.labels),
      staleDate: nil)
    if let activity = Activity<TrackingAttributes>.activities.first(where: {
      $0.attributes.taskId == state.taskId &&
        ($0.activityState == .active || $0.activityState == .stale)
    }) {
      await activity.update(content)
    } else if canStart && state.running && ActivityAuthorizationInfo().areActivitiesEnabled {
      _ = try Activity.request(attributes: TrackingAttributes(taskId: state.taskId),
        content: content, pushType: nil)
    }
    // An intent can arrive while ActivityKit suspends update/end. Reconcile
    // again so an old Flutter update cannot overwrite the latest pause/stop.
    if try store.read().revision != current.revision {
      try await synchronize(canStart: canStart)
    }
  }
}

@MainActor
final class TrackingChannel {
  let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.yggvion/tracking", binaryMessenger: messenger)
    TrackingActivityCoordinator.shared.actionsChanged = { [weak self] in
      self?.channel.invokeMethod("actionsChanged", arguments: nil)
    }
    channel.setMethodCallHandler { call, result in
      Task { @MainActor in
        do {
          let coordinator = TrackingActivityCoordinator.shared
          switch call.method {
          case "pending": result(try coordinator.pending())
          case "publish": result(try await coordinator.publish(call.arguments))
          case "clear": try await coordinator.clear(); result(nil)
          default: result(FlutterMethodNotImplemented)
          }
        } catch {
          result(FlutterError(code: "tracking_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }
}
