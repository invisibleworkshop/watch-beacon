import Foundation
import WatchConnectivity

/// Sends GPS batches and status from Watch to iPhone; accepts start/stop commands.
/// GPS points are persisted locally and drained in batches so ~1h offline (e.g. 5s interval) survives.
@MainActor
final class WatchSessionManager: NSObject, ObservableObject {
    static let shared = WatchSessionManager()

    @Published private(set) var isReachable = false
    @Published private(set) var lastSentAt: Date?
    @Published private(set) var pendingUploadCount = 0
    @Published var lastError: String?

    private let session: WCSession?
    private let pointsStore = WatchPointsStore.shared
    private(set) var locationManager: WatchLocationManager?

    /// Cap parallel WC point transfers so the system queue is not flooded (~720 tiny transfers).
    private let maxOutstandingPointTransfers = 4
    /// If didFinish never arrives (phone crash / WC wedge), unlock and retry.
    private let transferStallTimeout: TimeInterval = 90
    private var outstandingPointTransfers = 0
    private var inFlightStartedAt: Date?
    private var isDraining = false
    private var needsRedrain = false
    private var drainTimer: Timer?

    private override init() {
        if WCSession.isSupported() {
            session = WCSession.default
        } else {
            session = nil
        }
        super.init()
        pendingUploadCount = pointsStore.pendingCount
        activateIfNeeded()
        startDrainTimerIfNeeded()
    }

    func activateIfNeeded() {
        session?.delegate = self
        session?.activate()
    }

    /// Call when Watch app becomes active (or after phone reboot recovery).
    func handleAppBecameActive() {
        activateIfNeeded()
        recoverStalledTransfersIfNeeded(force: false)
        drainOutboundPoints()
        startDrainTimerIfNeeded()
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
            self?.enqueuePoints(points)
        }
        locationManager.onStatusChange = { [weak self] status in
            self?.sendStatus(self?.enriched(status) ?? status)
        }
    }

    private func enriched(_ status: WatchStatus) -> WatchStatus {
        var next = status
        next.pendingUploadCount = pendingUploadCount
        return next
    }

    func enqueuePoints(_ points: [GPSPoint]) {
        guard !points.isEmpty else { return }
        pointsStore.enqueue(points)
        refreshPendingCount()
        startDrainTimerIfNeeded()
        drainOutboundPoints()
    }

    func sendStatus(_ status: WatchStatus) {
        let envelope = BridgeEnvelope(kind: .status, status: status)
        transmitControl(envelope, preferRealtime: false)
    }

    func sendAck(command: BridgeCommand) {
        let envelope = BridgeEnvelope(kind: .ack, command: command)
        transmitControl(envelope, preferRealtime: true)
    }

    private func refreshPendingCount() {
        let previous = pendingUploadCount
        pendingUploadCount = pointsStore.pendingCount
        // Tell the phone when catch-up starts/ends or moves by a full batch (avoid per-point chatter).
        if previous != pendingUploadCount, let locationManager {
            let crossedEmpty = (previous == 0) != (pendingUploadCount == 0)
            let bigStep = abs(previous - pendingUploadCount) >= WatchPointsStore.uploadBatchSize
            if crossedEmpty || bigStep {
                sendStatus(enriched(locationManager.currentStatus()))
            }
        }
        if pendingUploadCount == 0 {
            stopDrainTimer()
        } else {
            startDrainTimerIfNeeded()
        }
    }

    private func startDrainTimerIfNeeded() {
        guard pendingUploadCount > 0 || pointsStore.pendingCount > 0 else { return }
        guard drainTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recoverStalledTransfersIfNeeded(force: false)
                self?.drainOutboundPoints()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        drainTimer = timer
    }

    private func stopDrainTimer() {
        drainTimer?.invalidate()
        drainTimer = nil
    }

    /// Phone crash / reboot often leaves transferUserInfo without didFinish — unlock the queue.
    private func recoverStalledTransfersIfNeeded(force: Bool) {
        guard outstandingPointTransfers > 0 || pointsStore.inFlightCount > 0 else { return }
        let stalled: Bool
        if force {
            stalled = true
        } else if let started = inFlightStartedAt {
            stalled = Date().timeIntervalSince(started) >= transferStallTimeout
        } else {
            // In-flight bookkeeping without a start stamp (e.g. after partial state) — treat as stalled.
            stalled = pointsStore.inFlightCount > 0
        }
        guard stalled else { return }

        if let session {
            for transfer in session.outstandingUserInfoTransfers where isPointsPayload(transfer.userInfo) {
                transfer.cancel()
            }
        }
        pointsStore.clearAllInFlight()
        outstandingPointTransfers = 0
        inFlightStartedAt = nil
        lastError = nil
    }

    private func isPointsPayload(_ userInfo: [String: Any]) -> Bool {
        guard let data = userInfo[BridgeKeys.payload] as? Data,
              let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: data)
        else { return false }
        return envelope.kind == .points
    }

    private func drainOutboundPoints() {
        guard let session, session.activationState == .activated else { return }
        recoverStalledTransfersIfNeeded(force: false)

        if isDraining {
            needsRedrain = true
            return
        }
        isDraining = true
        defer {
            isDraining = false
            if needsRedrain {
                needsRedrain = false
                drainOutboundPoints()
            }
        }

        while outstandingPointTransfers < maxOutstandingPointTransfers {
            let batch = pointsStore.nextBatch()
            guard !batch.isEmpty else { break }
            // Always ship whatever is ready (incl. short remainders like 62→60+2).
            // Cap above prevents flooding WC after long offline catch-up.
            guard startPointsTransfer(batch, session: session) else { break }
        }
        refreshPendingCount()
    }

    @discardableResult
    private func startPointsTransfer(_ batch: [GPSPoint], session: WCSession) -> Bool {
        let envelope = BridgeEnvelope(kind: .points, points: batch)
        do {
            let data = try JSONEncoder().encode(envelope)
            let payload: [String: Any] = [BridgeKeys.payload: data]
            pointsStore.markInFlight(batch)
            outstandingPointTransfers += 1
            if inFlightStartedAt == nil {
                inFlightStartedAt = Date()
            }

            if session.isReachable {
                session.sendMessage(payload, replyHandler: { [weak self] _ in
                    Task { @MainActor in
                        self?.completePointsDelivery(batch, succeeded: true)
                    }
                }, errorHandler: { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        // Keep in-flight; background transfer still owns delivery confirmation.
                        if self.session != nil {
                            self.session?.transferUserInfo(payload)
                            self.lastError = nil
                        } else {
                            self.completePointsDelivery(batch, succeeded: false)
                        }
                    }
                })
            } else {
                session.transferUserInfo(payload)
            }
            return true
        } catch {
            lastError = error.localizedDescription
            pointsStore.clearInFlight(batch)
            outstandingPointTransfers = max(0, outstandingPointTransfers - 1)
            if outstandingPointTransfers == 0 {
                inFlightStartedAt = nil
            }
            return false
        }
    }

    private func completePointsDelivery(_ batch: [GPSPoint], succeeded: Bool) {
        if succeeded {
            pointsStore.markDelivered(batch)
            lastError = nil
            lastSentAt = Date()
        } else {
            pointsStore.clearInFlight(batch)
        }
        outstandingPointTransfers = max(0, outstandingPointTransfers - 1)
        if outstandingPointTransfers == 0 {
            inFlightStartedAt = nil
        } else {
            inFlightStartedAt = Date()
        }
        refreshPendingCount()
        drainOutboundPoints()
    }

    private func completePointsDelivery(fromUserInfo userInfo: [String: Any], succeeded: Bool) {
        // Status/ack also use transferUserInfo — ignore those completions here.
        guard let data = userInfo[BridgeKeys.payload] as? Data,
              let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: data),
              envelope.kind == .points,
              let batch = envelope.points, !batch.isEmpty
        else { return }
        completePointsDelivery(batch, succeeded: succeeded)
    }

    /// Status / ack — not buffered; safe to drop or replace when offline.
    private func transmitControl(_ envelope: BridgeEnvelope, preferRealtime: Bool) {
        guard let session, session.activationState == .activated else {
            lastError = "WatchConnectivity 尚未啟用"
            return
        }

        do {
            let data = try JSONEncoder().encode(envelope)
            let payload: [String: Any] = [BridgeKeys.payload: data]

            // Important: do NOT also updateApplicationContext with points payloads.
            if preferRealtime, session.isReachable {
                session.sendMessage(payload, replyHandler: { [weak self] _ in
                    Task { @MainActor in
                        self?.lastError = nil
                        self?.lastSentAt = Date()
                    }
                }, errorHandler: { [weak self] _ in
                    Task { @MainActor in
                        self?.session?.transferUserInfo(payload)
                        self?.lastError = nil
                        self?.lastSentAt = Date()
                    }
                })
            } else {
                session.transferUserInfo(payload)
                try? session.updateApplicationContext(payload)
                lastError = nil
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
        if let quietHours = envelope.quietHours {
            locationManager?.setQuietHours(quietHours)
        }

        switch command {
        case .startTracking:
            locationManager?.startTracking()
            sendAck(command: .startTracking)
            drainOutboundPoints()
        case .stopTracking:
            locationManager?.stopTracking()
            sendAck(command: .stopTracking)
        case .updateSettings:
            sendAck(command: .updateSettings)
        case .ping, .requestStatus:
            if let status = locationManager?.currentStatus() {
                sendStatus(enriched(status))
            }
            sendAck(command: command)
            recoverStalledTransfersIfNeeded(force: false)
            drainOutboundPoints()
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
            } else if activationState == .activated {
                lastError = nil
                drainOutboundPoints()
                startDrainTimerIfNeeded()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            isReachable = session.isReachable
            // Drain on any change — isReachable is often false even when transferUserInfo works.
            drainOutboundPoints()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?
    ) {
        Task { @MainActor in
            completePointsDelivery(fromUserInfo: userInfoTransfer.userInfo, succeeded: error == nil)
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
        // Reply first — delaying the handler makes the phone's sendMessage time out
        // and looks like "無法連線" even though the watch is awake.
        replyHandler(["ok": true])
        Task { @MainActor in
            handleIncoming(message)
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
