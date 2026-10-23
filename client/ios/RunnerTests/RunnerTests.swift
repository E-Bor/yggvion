import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
  private var directory: URL!
  private var store: TrackingStore!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    store = TrackingStore(directory: directory)
    _ = try store.publish(TrackingState(taskId: "task", title: "Задача", deviceId: "device",
      plannedMs: 1800000, elapsedMs: 0, updatedAtMs: 1000, running: true,
      sessionIds: ["first"], accent: 0xff9cb9ff), acknowledged: [])
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  func testPauseResumeStopSurviveProcessRecreation() throws {
    let first = try store.read()
    XCTAssertTrue(try store.perform("pause", taskId: "task", revision: first.revision, at: 601000))
    store = TrackingStore(directory: directory)
    var current = try store.read()
    XCTAssertFalse(current.state!.running)
    XCTAssertEqual(current.state!.elapsed(at: 1801000), 600000)
    XCTAssertTrue(try store.perform("resume", taskId: "task", revision: current.revision, at: 1801000))
    current = try store.read()
    XCTAssertTrue(current.state!.running)
    XCTAssertNotNil(current.pending.last!.newSessionId)
    XCTAssertTrue(try store.perform("stop", taskId: "task", revision: current.revision, at: 2701000))
    current = try store.read()
    XCTAssertNil(current.state)
    XCTAssertEqual(current.pending.map { $0.atMs }, [601000, 1801000, 2701000])
    XCTAssertEqual(current.pending.last!.sessionIds, [current.pending[1].newSessionId!])
  }

  func testStaleSnapshotAndRepeatedButtonsCannotOverwritePause() throws {
    let first = try store.read()
    XCTAssertTrue(try store.perform("pause", taskId: "task", revision: first.revision, at: 601000))
    XCTAssertFalse(try store.perform("pause", taskId: "task", revision: first.revision, at: 901000))
    XCTAssertFalse(try store.publish(first.state, acknowledged: []))
    let paused = try store.read()
    XCTAssertFalse(paused.state!.running)
    XCTAssertEqual(paused.pending.count, 1)
    XCTAssertTrue(try store.publish(paused.state, acknowledged: paused.pending.map { $0.id }))
    XCTAssertTrue(try store.read().pending.isEmpty)
  }

  func testWrongTaskAndUnknownActionDoNothing() throws {
    let first = try store.read()
    XCTAssertFalse(try store.perform("stop", taskId: "other", revision: first.revision, at: 2000))
    XCTAssertFalse(try store.perform("delete", taskId: "task", revision: first.revision, at: 2000))
    XCTAssertEqual(try store.read().revision, first.revision)
    XCTAssertTrue(try store.read().pending.isEmpty)
  }

  func testPrivateQueueExcludedFromSystemBackup() throws {
    XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    // Simulator's host filesystem does not implement iOS Data Protection.
    #if !targetEnvironment(simulator)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path)
    XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
    #endif
  }
}
