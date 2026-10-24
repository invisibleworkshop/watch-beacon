import ActivityKit
import Foundation

/// Shared by the iPhone app and the Live Activity widget extension (Dynamic Island / Lock Screen).
struct TrackingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var pointCount: Int
        var lastAccuracy: Double?
        var isStale: Bool
        var statusText: String
        var lastFixAt: Date?
    }

    var startedAt: Date
}
