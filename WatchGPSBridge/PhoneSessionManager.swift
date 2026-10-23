import Foundation
import HealthKit
import WatchConnectivity

/// Receives GPS from the Watch companion and can wake the Watch app via HealthKit.
@MainActor
final class PhoneSessionManager: NSObject, ObservableObject {
    static let shared = PhoneSessionManager()

    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false
    @Published private(set) var watchStatus = WatchStatus()
    @Published private(set) var lastReceivedAt: Date?
    @Published private(set) var isExpectingTracking = false
    @Published var lastError: String?

    private let session: WCSession?
    private let healthStore = HKHealthStore()
    private let recorder = LocationRecorder.shared

    var onPointsReceived: (([GPSPoint]) -> Void)?

    private override init() {
        if WCSession.isSupported() {
            session = WCSession.default
        } else {
            session = nil
        }
        super.init()
        session?.delegate = self
        session?.activate()
    }

    /// Opens the companion Watch app (works around Shortcuts not launching Watch apps).
    func wakeWatchAndStartTracking() async {
        isExpectingTracking = true
        lastError = nil

        do {
            try await requestHealthAuthorization()
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .walking
            configuration.locationType = .outdoor
            try await healthStore.startWatchApp(toHandle: configuration)
        } catch {
            let message = "無法喚醒 Apple Watch：\(error.localizedDescription)"
            lastError = message
            NotificationManager.shared.notifyWatchWakeFailed(message: message)
        }

        // Also send an explicit command in case the Watch app is already running.
        sendCommand(.startTracking)
        sendCommand(.requestStatus)
    }

    func stopTrackingOnWatch() {
        isExpectingTracking = false
        sendCommand(.stopTracking)
    }

    func pingWatch() {
        sendCommand(.ping)
        sendCommand(.requestStatus)
    }

    private func requestHealthAuthorization() async throws {
        let types: Set<HKSampleType> = [HKObjectType.workoutType()]
        try await healthStore.requestAuthorization(toShare: types, read: types)
    }

    private func sendCommand(_ command: BridgeCommand) {
        guard let session, session.activationState == .activated else {
            lastError = "WatchConnectivity 尚未啟用"
            return
        }

        let envelope = BridgeEnvelope(kind: .command, command: command)
        do {
            let data = try JSONEncoder().encode(envelope)
            let payload: [String: Any] = [BridgeKeys.payload: data]

            if session.isReachable {
                session.sendMessage(payload, replyHandler: { _ in }, errorHandler: { [weak self] error in
                    Task { @MainActor in
                        self?.lastError = error.localizedDescription
                        self?.session?.transferUserInfo(payload)
                    }
                })
            } else {
                session.transferUserInfo(payload)
                try? session.updateApplicationContext(payload)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handleIncoming(_ payload: [String: Any]) {
        guard let data = payload[BridgeKeys.payload] as? Data,
              let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: data)
        else { return }

        lastReceivedAt = Date()

        switch envelope.kind {
        case .points:
            if let points = envelope.points, !points.isEmpty {
                recorder.append(points)
                onPointsReceived?(points)
                if let latest = points.last {
                    var status = watchStatus
                    status.isTracking = true
                    status.lastFixAt = latest.timestamp
                    status.lastAccuracy = latest.horizontalAccuracy
                    watchStatus = status
                }
            }
        case .status:
            if let status = envelope.status {
                watchStatus = status
                if status.isTracking {
                    isExpectingTracking = true
                }
            }
        case .ack, .command:
            break
        }
    }
}

extension PhoneSessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            isWatchAppInstalled = session.isWatchAppInstalled
            isReachable = session.isReachable
            if let error {
                lastError = error.localizedDescription
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            isWatchAppInstalled = session.isWatchAppInstalled
            isReachable = session.isReachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            isReachable = session.isReachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            handleIncoming(message)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            handleIncoming(message)
            replyHandler(["ok": true])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            handleIncoming(userInfo)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            handleIncoming(applicationContext)
        }
    }
}
