import Foundation

struct TrackingState: Codable, Equatable {
  var taskId: String
  var title: String
  var deviceId: String
  var plannedMs: Int64
  var elapsedMs: Int64
  var updatedAtMs: Int64
  var running: Bool
  var sessionIds: [String]
  var accent: UInt32

  func elapsed(at time: Int64) -> Int64 {
    max(0, elapsedMs) + (running ? max(0, time - updatedAtMs) : 0)
  }
}

struct TrackingCommand: Codable {
  let id: String
  let taskId: String
  let deviceId: String
  let action: String
  let atMs: Int64
  let sessionIds: [String]
  let newSessionId: String?
}

struct TrackingEnvelope: Codable {
  var state: TrackingState?
  var pending: [TrackingCommand] = []
  var revision = UUID().uuidString
}

/// Used only in the app process (LiveActivityIntent runs there too). Callers
/// serialize access on the main actor. No shared App Group or credentials.
final class TrackingStore {
  let file: URL

  init(directory: URL) { file = directory.appendingPathComponent("tracking.json") }

  func read() throws -> TrackingEnvelope {
    guard FileManager.default.fileExists(atPath: file.path) else {
      return TrackingEnvelope()
    }
    return try JSONDecoder().decode(TrackingEnvelope.self, from: Data(contentsOf: file))
  }

  func write(_ value: TrackingEnvelope) throws {
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var excluded = directory
    var resources = URLResourceValues()
    resources.isExcludedFromBackup = true
    try excluded.setResourceValues(resources)
    let data = try JSONEncoder().encode(value)
    #if os(iOS)
    try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
    try data.write(to: file, options: .atomic)
    #endif
  }

  @discardableResult
  func publish(_ state: TrackingState?, acknowledged: [String]) throws -> Bool {
    var current = try read()
    let ids = Set(acknowledged)
    current.pending.removeAll { ids.contains($0.id) }
    // Flutter must first commit every interaction made on the lock screen.
    guard current.pending.isEmpty else { try write(current); return false }
    current.state = state
    current.revision = UUID().uuidString
    try write(current)
    return true
  }

  @discardableResult
  func perform(_ action: String, taskId: String, revision: String, at: Int64) throws -> Bool {
    var current = try read()
    guard var state = current.state, state.taskId == taskId,
          current.revision == revision,
          ["pause", "resume", "stop"].contains(action),
          (action != "resume" || !state.running),
          (action != "pause" || state.running) else { return false }
    guard current.pending.count < 1024 else {
      throw NSError(domain: "YggvionTracking", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Откройте Yggvion, чтобы сохранить учёт времени."])
    }
    let time = max(state.updatedAtMs, at)
    let newSession = action == "resume" ? UUID().uuidString.lowercased() : nil
    current.pending.append(TrackingCommand(
      id: UUID().uuidString, taskId: taskId, deviceId: state.deviceId,
      action: action, atMs: time, sessionIds: state.sessionIds, newSessionId: newSession))
    state.elapsedMs = state.elapsed(at: time)
    state.updatedAtMs = time
    state.running = action == "resume"
    state.sessionIds = newSession.map { [$0] } ?? []
    current.state = action == "stop" ? nil : state
    current.revision = UUID().uuidString
    // Persist first: process termination cannot lose a pause or create a gap.
    try write(current)
    return true
  }
}
