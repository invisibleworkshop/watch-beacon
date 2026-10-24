import AppIntents

/// Starts the **phone** recording session and wakes the Watch so it can feed GPS to the phone.
struct StartWatchGPSTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "開始手機記錄"
    static var description = IntentDescription("啟動精確定位開始記錄；並喚醒手錶傳送 GPS。僅對手錶開 GPS 不會寫入。")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await PhoneSessionManager.shared.wakeWatchAndStartTracking()
        return .result(dialog: "手機精確定位已開始記錄。正在要求手錶傳送 GPS；若之後沒訊號會通知。")
    }
}

struct StopWatchGPSTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "停止手機記錄"
    static var description = IntentDescription("結束手機記錄，並請手錶停止定位。")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PhoneSessionManager.shared.stopTrackingOnWatch()
        return .result(dialog: "已停止手機記錄，並送出停止定位指令。")
    }
}

/// Hourly Shortcuts: keep the **phone** recording session alive (open app + monitor + record).
struct EnsureWatchGPSTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "檢查並維持手機記錄"
    static var description = IntentDescription("確保精確定位在手機端持續監視並記錄手錶訊號；未開始記錄則略過。訊號中斷時會重喚醒手錶。")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await PhoneSessionManager.shared.ensureTrackingHealthy() {
        case .idle:
            return .result(dialog: "手機尚未開始記錄，已略過。請先「開始手機記錄」；只對手錶開 GPS 不會寫入。")
        case .healthy:
            return .result(dialog: "手機精確定位正在記錄，手錶訊號正常。")
        case .rewoke(true):
            return .result(dialog: "手機已恢復記錄，並重新喚醒手錶以繼續傳送訊號。")
        case .rewoke(false):
            return .result(dialog: "手機已在記錄狀態，但無法喚醒手錶，請查看通知。")
        }
    }
}

struct WatchGPSBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWatchGPSTrackingIntent(),
            phrases: [
                "開始 \(.applicationName) 記錄",
                "用 \(.applicationName) 開始定位記錄"
            ],
            shortTitle: "開始記錄",
            systemImageName: "location.fill"
        )
        AppShortcut(
            intent: EnsureWatchGPSTrackingIntent(),
            phrases: [
                "檢查 \(.applicationName) 記錄",
                "維持 \(.applicationName) 記錄"
            ],
            shortTitle: "檢查維持",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: StopWatchGPSTrackingIntent(),
            phrases: [
                "停止 \(.applicationName) 記錄"
            ],
            shortTitle: "停止記錄",
            systemImageName: "stop.fill"
        )
    }
}
