import SwiftUI

/// Same pattern as 方圓記帳 (LedgerApp): SwiftUI `@main` + `WindowGroup`.
/// Custom URL + UIKit SceneDelegate was causing Shortcuts to spawn a second window
/// while Live Activity kept updating the first.
@main
struct WatchGPSBridgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var monitor = StaleSignalMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(PhoneSessionManager.shared)
                .environmentObject(LocationRecorder.shared)
                .environmentObject(monitor)
                .environmentObject(NotificationManager.shared)
                .environmentObject(AppSettings.shared)
                .onOpenURL { url in
                    URLRouter.handle(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await PhoneSessionManager.shared.handleSceneBecameActive()
                    }
                }
        }
        .handlesExternalEvents(matching: Set(["*"]))
    }
}
