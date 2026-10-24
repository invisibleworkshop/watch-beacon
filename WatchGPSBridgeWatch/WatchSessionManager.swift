import Foundation
import WatchConnectivity

/// Sends GPS batches and status from Watch to iPhone; accepts start/stop commands.
@MainActor
final class WatchSessionManager: NSObject, ObservableObject {
    static let shared = WatchSessionManager()

    @Published private(set) var isReachable = false
    @Published private(set) var lastSentAt: Date?
    @Published var lastError: String?

    private let session: WCSession?
    private(set) var locationManager: WatchLocationManager?

    private override init() {
        if WCSession.isSupported() {
            session = WCSession.default
        } else {
            session = nil
        }
        super.init()
        activateIfNeeded()
    }

    func activateIfNeeded() {
        session?.delegate = self
        session?.activate()
    }

    /// Used when iPhone wakes the Watch before SwiftUI has created the view model.
    func ensureLocationManager() -> WatchLocationManager {
        if let locationManager {
            return locationManager
        }
        let manager = WatchLocationManager()
        bind(locationManager: manager)
        return manager
    }

    func bind(locationManager: WatchLocationManager) {
        self.locationManager = locationManager
        locationManager.onPointsBatch = { [weak self] points in
            self?.sendPoints(points)
        }
        locationManager.onStatusChange = { [weak self] status in
            self?.sendStatus(status)
        }
    }

    func sendPoints(_ points: [GPSPoint]) {
        guard !points.isEmpty else { return }
        let envelope = BridgeEnvelope(kind: .points, points: points)
        transmit(envelope, preferRealtime: true)
    }

    func sendStatus(_ status: WatchStatus) {
        let envelope = BridgeEnvelope(kind: .status, status: status)
        transmit(envelope, preferRealtime: false)
    }

    func sendAck(command: BridgeCommand) {
        let envelope = BridgeEnvelope(kind: .ack, command: command)
        transmit(envelope, preferRealtime: true)
    }

    private func transmit(_ envelope: BridgeEnvelope, preferRealtime: Bool) {
        guard let session, session.activationState == .activated else {
            lastError = "WatchConnectivity 尚未啟用"
            return
        }

        do {
            let data = try JSONEncoder().encode(envelope)
            let payload: [String: Any] = [BridgeKeys.payload: data]

            // Important: do NOT also updateApplicationContext with the same points payload.
            // Phone receives both sendMessage and applicationContext → duplicate recordings.
            if preferRealtime, session.isReachable {
                session.sendMessage(payload, replyHandler: { [weak self] _ in
                    Task { @MainActor in
                        self?.lastSentAt = Date()
                    }
                }, errorHandler: { [weak self] error in
                    Task { @MainActor in
                        self?.lastError = error.localizedDescription
                        self?.session?.transferUserInfo(payload)
                        self?.lastSentAt = Date()
                    }
                })
            } else if envelope.kind == .points {
                session.transferUserInfo(payload)
                lastSentAt = Date()
            } else {
                session.transferUserInfo(payload)
                try? session.updateApplicationContext(payload)
                lastSentAt = Date()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handleIncoming(_ payload: [String: Any]) {
        guard let data = payload[BridgeKeys.payload] as? Data,
              let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: data),
              envelope.kind == .command,
              let command = envelope.command
        else { return }

        if let seconds = envelope.recordIntervalSeconds {
            locationManager?.setRecordIntervalSeconds(seconds)
        }

        switch command {
        case .startTracking:
            locationManager?.startTracking()
            sendAck(command: .startTracking)
        case .stopTracking:
            locationManager?.stopTracking()
            sendAck(command: .stopTracking)
        case .updateSettings:
            sendAck(command: .updateSettings)
        case .ping, .requestStatus:
            if let status = locationManager?.currentStatus() {
                sendStatus(status)
            }
            sendAck(command: command)
        }
    }
}

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            isReachable = session.isReachable
            if let error {
                lastError = error.localizedDescription
            }
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
