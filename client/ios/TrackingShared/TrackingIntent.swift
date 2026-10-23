import AppIntents

@available(iOS 17.0, *)
struct TrackingIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Управление таймером Yggvion"
  static var openAppWhenRun = false
  static var isDiscoverable = false
  static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
  @available(iOS 26.0, *)
  static var supportedModes: IntentModes { .background }

  @Parameter(title: "Задача") var taskId: String
  @Parameter(title: "Состояние") var revision: String
  @Parameter(title: "Действие") var action: String

  init() {}
  init(taskId: String, revision: String, action: String) {
    self.taskId = taskId
    self.revision = revision
    self.action = action
  }

  func perform() async throws -> some IntentResult {
    // LiveActivityIntent is executed in Runner's process. The extension only
    // needs the declaration to encode the button; it never opens a second DB.
    #if !TRACKING_EXTENSION
    try await TrackingActivityCoordinator.shared.perform(
      action, taskId: taskId, revision: revision)
    #endif
    return .result()
  }
}
