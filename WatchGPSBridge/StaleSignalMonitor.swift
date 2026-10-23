import Foundation

/// Watches for missing GPS heartbeats while tracking is expected.
@MainActor
final class StaleSignalMonitor: ObservableObject {
    @Published private(set) var isStale = false
    @Published private(set) var secondsSinceLastSignal: TimeInterval?

    /// How long without Watch GPS before we alert (seconds).
    var staleThreshold: TimeInterval = 60

    private var timer: Timer?
    private weak var session: PhoneSessionManager?
    private let notifications = NotificationManager.shared
    private var didNotifyForCurrentGap = false

    func start(session: PhoneSessionManager) {
        self.session = session
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluate()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isStale = false
        secondsSinceLastSignal = nil
        didNotifyForCurrentGap = false
    }

    private func evaluate() {
        guard let session, session.isExpectingTracking else {
            isStale = false
            secondsSinceLastSignal = nil
            didNotifyForCurrentGap = false
            return
        }

        let reference = session.lastReceivedAt ?? .distantPast
        let elapsed = Date().timeIntervalSince(reference)
        secondsSinceLastSignal = elapsed

        let stale = elapsed >= staleThreshold
        isStale = stale

        if stale {
            if !didNotifyForCurrentGap {
                didNotifyForCurrentGap = true
                notifications.notifyStaleSignal(secondsWithoutData: elapsed)
            }
        } else {
            didNotifyForCurrentGap = false
        }
    }
}
