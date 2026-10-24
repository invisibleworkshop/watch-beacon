import Foundation

/// Shared entry for Shortcuts / Live Activity / onOpenURL — independent of which UIWindowScene is active.
enum URLRouter {
    @MainActor
    static func handle(_ url: URL) {
        guard url.scheme == BridgeKeys.urlScheme else { return }
        let session = PhoneSessionManager.shared
        let host = (url.host ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch host {
        case "start", "open":
            Task { await session.wakeWatchAndStartTracking() }
        case "ensure", "maintain", "check":
            Task {
                _ = await session.prepareForWatchConnectivity()
                await session.ensureTrackingHealthy()
            }
        case "stop":
            session.stopTrackingOnWatch()
        case "status":
            Task { await session.pingWatch() }
        default:
            Task { await session.wakeWatchAndStartTracking() }
        }
    }
}
