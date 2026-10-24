import Foundation
import UserNotifications

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published private(set) var isAuthorized = false

    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
        } catch {
            isAuthorized = false
        }
    }

    func notifyStaleSignal(
        secondsWithoutData: TimeInterval,
        autoRewaking: Bool = false,
        detail: String? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = "手錶 GPS 中斷"
        if let detail {
            content.body = detail
        } else if autoRewaking {
            content.body = String(
                format: "已超過 %.0f 秒未收到定位，正在嘗試重新喚醒手錶上的「精確定位」。",
                secondsWithoutData
            )
        } else {
            content.body = String(
                format: "已超過 %.0f 秒未收到手錶精確定位。請檢查手錶是否佩戴、電量、定位權限，以及 App 是否仍在定位中。",
                secondsWithoutData
            )
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "watch-gps-stale-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    func notifyWatchWakeFailed(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "無法喚醒手錶"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "watch-wake-failed-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
