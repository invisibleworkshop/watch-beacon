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

    func notifyStaleSignal(secondsWithoutData: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Apple Watch GPS 中斷"
        content.body = String(
            format: "已超過 %.0f 秒未收到 Watch 精確定位。請檢查 Watch 是否佩戴、電量、定位權限，以及「腕上定位」App 是否仍在定位中。",
            secondsWithoutData
        )
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
        content.title = "無法喚醒 Apple Watch"
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
