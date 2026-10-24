import Foundation

/// Watches for missing GPS heartbeats while tracking is expected.
/// Rewakes the Watch every minute; notifies only after 5 attempts (~5 minutes) with no signal.
@MainActor
final class StaleSignalMonitor: ObservableObject {
    @Published private(set) var isStale = false
    @Published private(set) var secondsSinceLastSignal: TimeInterval?
    @Published private(set) var isAttemptingRewake = false
    @Published private(set) var rewakeAttemptsInCurrentGap = 0

    /// Start rewake attempts after this many seconds without a point.
    var staleThreshold: TimeInterval = 60
    /// Minimum gap between automatic rewake attempts.
    var rewakeCooldown: TimeInterval = 60
    /// Notify only after this many rewake attempts without recovering a signal.
    var notifyAfterRewakeAttempts: Int = 5

    private var timer: Timer?
    private weak var session: PhoneSessionManager?
    private let notifications = NotificationManager.shared
    private var didNotifyForCurrentGap = false
    private var lastRewakeAttemptAt: Date?
    private var isRewakeInFlight = false

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
        resetGapState()
        isStale = false
        secondsSinceLastSignal = nil
    }

    private func resetGapState() {
        isAttemptingRewake = false
        didNotifyForCurrentGap = false
        lastRewakeAttemptAt = nil
        isRewakeInFlight = false
        rewakeAttemptsInCurrentGap = 0
    }

    private func evaluate() {
        guard let session, session.isExpectingTracking else {
            isStale = false
            secondsSinceLastSignal = nil
            resetGapState()
            return
        }

        let reference = session.lastReceivedAt ?? session.expectingSince ?? Date()
        let elapsed = Date().timeIntervalSince(reference)
        secondsSinceLastSignal = elapsed

        let stale = elapsed >= staleThreshold
        isStale = stale

        if stale {
            session.refreshLiveActivity(isStale: true)
            let cooledDown = lastRewakeAttemptAt.map { Date().timeIntervalSince($0) >= rewakeCooldown } ?? true
            if !isRewakeInFlight, cooledDown {
                Task { await attemptAutoRewakeIfNeeded(elapsed: elapsed) }
            }
        } else {
            resetGapState()
        }
    }

    private func attemptAutoRewakeIfNeeded(elapsed: TimeInterval) async {
        guard let session, !isRewakeInFlight else { return }

        isRewakeInFlight = true
        isAttemptingRewake = true
        lastRewakeAttemptAt = Date()
        rewakeAttemptsInCurrentGap += 1
        let attempt = rewakeAttemptsInCurrentGap
        defer {
            isRewakeInFlight = false
            isAttemptingRewake = false
        }

        // Quiet rewake — no notification until 5 failed minutes.
        session.noteStaleRewaking()
        _ = await session.wakeWatchAndStartTracking(notifyOnFailure: false)

        if attempt >= notifyAfterRewakeAttempts, !didNotifyForCurrentGap {
            didNotifyForCurrentGap = true
            let message = session.lastError
                ?? String(
                    format: "已約 %.0f 分鐘未收到手錶定位（已嘗試喚醒 %d 次）。請檢查手錶是否佩戴、電量與定位權限。",
                    elapsed / 60,
                    attempt
                )
            notifications.notifyStaleSignal(
                secondsWithoutData: elapsed,
                autoRewaking: false,
                detail: message
            )
        }
    }
}
