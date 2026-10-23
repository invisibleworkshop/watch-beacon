import AppIntents

/// Exposed to the Shortcuts app so automations can start tracking without opening Watch directly.
struct StartWatchGPSTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "開始 Watch GPS 記錄"
    static var description = IntentDescription("打開腕上定位、喚醒 Apple Watch Companion，並開始接收精確 GPS。")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await PhoneSessionManager.shared.wakeWatchAndStartTracking()
        return .result(dialog: "已要求 Apple Watch 開始傳送精確 GPS。若後續沒有訊號，會收到通知。")
    }
}

struct StopWatchGPSTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "停止 Watch GPS 記錄"
    static var description = IntentDescription("停止 Apple Watch 定位並結束 iPhone 端的期待接收狀態。")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PhoneSessionManager.shared.stopTrackingOnWatch()
        return .result(dialog: "已送出停止定位指令。")
    }
}

struct WatchGPSBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWatchGPSTrackingIntent(),
            phrases: [
                "開始 \(.applicationName) 定位",
                "用 \(.applicationName) 記錄 Watch GPS"
            ],
            shortTitle: "開始記錄",
            systemImageName: "location.fill"
        )
        AppShortcut(
            intent: StopWatchGPSTrackingIntent(),
            phrases: [
                "停止 \(.applicationName) 定位"
            ],
            shortTitle: "停止記錄",
            systemImageName: "stop.fill"
        )
    }
}
