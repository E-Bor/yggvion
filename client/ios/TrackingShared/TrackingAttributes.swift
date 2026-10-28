import ActivityKit
import Foundation

struct TrackingAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var title: String
    var plannedSeconds: Double
    var elapsedSeconds: Double
    var updatedAt: Date
    var running: Bool
    var accent: UInt32
    var revision: String
    var labels: [String: String]? = nil

    func label(_ key: String, _ fallback: String) -> String { labels?[key] ?? fallback }

    var clockStart: Date { updatedAt.addingTimeInterval(-elapsedSeconds) }
    var progressEnd: Date { clockStart.addingTimeInterval(max(1, plannedSeconds)) }
  }

  let taskId: String
}
