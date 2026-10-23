import SwiftUI

@main
struct WatchGPSBridgeApp: App {
    @ObservedObject private var session = PhoneSessionManager.shared
    @ObservedObject private var recorder = LocationRecorder.shared
    @StateObject private var monitor = StaleSignalMonitor()
    @ObservedObject private var notifications = NotificationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .environmentObject(recorder)
                .environmentObject(monitor)
                .environmentObject(notifications)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .task {
                    // Cold-start from Shortcuts / URL should still attempt wake.
                    if ProcessInfo.processInfo.arguments.contains("-startTracking") {
                        await session.wakeWatchAndStartTracking()
                    }
                }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == BridgeKeys.urlScheme else { return }
        let host = (url.host ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch host {
        case "start", "open":
            Task { await session.wakeWatchAndStartTracking() }
        case "stop":
            session.stopTrackingOnWatch()
        case "status":
            session.pingWatch()
        default:
            Task { await session.wakeWatchAndStartTracking() }
        }
    }
}
