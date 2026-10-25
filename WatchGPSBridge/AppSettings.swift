import Foundation

/// User-facing preferences persisted on the phone and pushed to the Watch.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let allowedIntervals: [GPSRecordInterval] = GPSRecordInterval.allCases

    @Published var recordInterval: GPSRecordInterval {
        didSet {
            guard isReady else { return }
            UserDefaults.standard.set(recordInterval.rawValue, forKey: PersistenceKey.recordInterval)
            PhoneSessionManager.shared.pushSettingsToWatch()
        }
    }

    @Published var quietHours: QuietHoursSchedule {
        didSet {
            guard isReady else { return }
            persistQuietHours()
            PhoneSessionManager.shared.pushSettingsToWatch()
        }
    }

    private var isReady = false

    private enum PersistenceKey {
        static let recordInterval = "watchgpsbridge.recordIntervalSeconds"
        static let quietHours = "watchgpsbridge.quietHours"
    }

    private init() {
        let raw = UserDefaults.standard.integer(forKey: PersistenceKey.recordInterval)
        recordInterval = GPSRecordInterval(rawValue: raw) ?? .one
        quietHours = Self.loadQuietHours()
        isReady = true
    }

    /// Interval the Watch should use right now (active vs quiet hours).
    var effectiveRecordIntervalSeconds: Int {
        quietHours.effectiveIntervalSeconds(base: recordInterval.rawValue)
    }

    var isInQuietHours: Bool {
        quietHours.contains(Date())
    }

    var quietStartDate: Date {
        get { QuietHoursSchedule.date(fromMinutes: quietHours.startMinutes) }
        set {
            var next = quietHours
            next.startMinutes = QuietHoursSchedule.minutes(from: newValue)
            quietHours = next
        }
    }

    var quietEndDate: Date {
        get { QuietHoursSchedule.date(fromMinutes: quietHours.endMinutes) }
        set {
            var next = quietHours
            next.endMinutes = QuietHoursSchedule.minutes(from: newValue)
            quietHours = next
        }
    }

    private func persistQuietHours() {
        if let data = try? JSONEncoder().encode(quietHours) {
            UserDefaults.standard.set(data, forKey: PersistenceKey.quietHours)
        }
    }

    private static func loadQuietHours() -> QuietHoursSchedule {
        guard let data = UserDefaults.standard.data(forKey: PersistenceKey.quietHours),
              let decoded = try? JSONDecoder().decode(QuietHoursSchedule.self, from: data)
        else {
            return .default
        }
        return decoded
    }
}
