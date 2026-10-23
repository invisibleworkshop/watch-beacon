import SwiftUI

@main
struct WatchGPSBridgeWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) var appDelegate
    @StateObject private var locationManager = WatchLocationManager()
    @StateObject private var sessionManager = WatchSessionManager.shared

    var body: some Scene {
        WindowGroup {
            WatchContentView(location: locationManager, session: sessionManager)
                .onAppear {
                    sessionManager.bind(locationManager: locationManager)
                }
        }
    }
}
