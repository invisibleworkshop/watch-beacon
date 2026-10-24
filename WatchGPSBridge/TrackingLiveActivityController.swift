import ActivityKit
import Foundation

/// Starts / updates / ends the Dynamic Island + Lock Screen Live Activity while tracking.
@MainActor
final class TrackingLiveActivityController {
    static let shared = TrackingLiveActivityController()

    private var activity: Activity<TrackingActivityAttributes>?

    /// Snapshot of an orphan Live Activity left over after process death (Shortcuts cold start).
    struct OrphanSnapshot {
        var pointCount: Int
        var lastAccuracy: Double?
        var isStale: Bool
        var statusText: String
        var lastFixAt: Date?
        var startedAt: Date
    }

    private init() {
        // Adopt any activity that survived process death — same activity ID, not a second app.
        activity = Activity<TrackingActivityAttributes>.activities.first
    }

    var orphanSnapshot: OrphanSnapshot? {
        guard let activity else { return nil }
        let state = activity.content.state
        return OrphanSnapshot(
            pointCount: state.pointCount,
            lastAccuracy: state.lastAccuracy,
            isStale: state.isStale,
            statusText: state.statusText,
            lastFixAt: state.lastFixAt,
            startedAt: activity.attributes.startedAt
        )
    }

    func startOrUpdate(
        pointCount: Int,
        lastAccuracy: Double?,
        isStale: Bool,
        lastFixAt: Date?
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let state = TrackingActivityAttributes.ContentState(
            pointCount: pointCount,
            lastAccuracy: lastAccuracy,
            isStale: isStale,
            statusText: isStale ? "訊號中斷" : "定位中",
            lastFixAt: lastFixAt
        )

        if activity == nil {
            activity = Activity<TrackingActivityAttributes>.activities.first
        }

        if let activity {
            Task {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
            return
        }

        let attributes = TrackingActivityAttributes(startedAt: Date())
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            // Live Activities can be disabled in Settings; ignore quietly.
        }
    }

    func end() {
        let activities = Activity<TrackingActivityAttributes>.activities
        let finalState = TrackingActivityAttributes.ContentState(
            pointCount: LocationRecorder.shared.totalPointsRecorded,
            lastAccuracy: PhoneSessionManager.shared.watchStatus.lastAccuracy,
            isStale: false,
            statusText: "已停止",
            lastFixAt: PhoneSessionManager.shared.lastReceivedAt
        )
        activity = nil
        Task {
            for item in activities {
                await item.end(
                    ActivityContent(state: finalState, staleDate: nil),
                    dismissalPolicy: .immediate
                )
            }
        }
    }
}
