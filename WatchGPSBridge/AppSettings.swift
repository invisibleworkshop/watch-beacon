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

    private var isReady = false

    private enum PersistenceKey {
        static let recordInterval = "watchgpsbridge.recordIntervalSeconds"
    }

    private init() {
        let raw = UserDefaults.standard.integer(forKey: PersistenceKey.recordInterval)
        recordInterval = GPSRecordInterval(rawValue: raw) ?? .one
        isReady = true
    }
}
