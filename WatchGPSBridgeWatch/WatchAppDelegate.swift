import HealthKit
import WatchKit

/// Receives `startWatchApp` launches from iPhone and starts GPS tracking.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WatchSessionManager.shared.activateIfNeeded()
    }

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in
            let manager = WatchSessionManager.shared.ensureLocationManager()
            manager.startTracking()
        }
    }
}
