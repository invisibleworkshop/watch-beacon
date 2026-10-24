import Foundation
import HealthKit
import WatchConnectivity

/// Receives GPS from the Watch companion and can wake the Watch app via HealthKit.
/// Intentionally NOT an NSObject subclass — combining NSObject + ObservableObject breaks SwiftUI updates
/// (Live Activity can keep rising while the Shortcuts-opened window stays frozen).
@MainActor
final class PhoneSessionManager: ObservableObject {
    static let shared = PhoneSessionManager()

    @Published private(set) var isWatchPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false
    /// True once we have proof the companion exists (system flag, reachability, or any WC payload).
    @Published private(set) var hasWatchCompanion = false
    @Published private(set) var watchStatus = WatchStatus()
    @Published private(set) var lastReceivedAt: Date?
    @Published private(set) var isExpectingTracking = false
    /// When the phone began expecting Watch GPS (used so we don't treat "no points yet" as stale).
    @Published private(set) var expectingSince: Date?
    @Published var lastError: String?
    /// One-line “what’s happening now” for the UI while connecting / waiting for GPS.
    @Published private(set) var progress: ConnectionProgress = .idle
    /// Bumped on each connectivity / points refresh so SwiftUI windows always redraw.
    @Published private(set) var uiEpoch: UInt64 = 0

    fileprivate let session: WCSession?
    private let healthStore = HKHealthStore()
    private let recorder = LocationRecorder.shared
    private let wcBridge = PhoneWCSessionBridge()

    var onPointsReceived: (([GPSPoint]) -> Void)?

    private enum PersistenceKey {
        static let expecting = "watchgpsbridge.expectingTracking"
        static let expectingSince = "watchgpsbridge.expectingSince"
        static let lastReceivedAt = "watchgpsbridge.lastReceivedAt"
    }

    private init() {
        if WCSession.isSupported() {
            session = WCSession.default
        } else {
            session = nil
        }
        wcBridge.owner = self
        restoreExpectation()
        session?.delegate = wcBridge
        session?.activate()
        reconcileAfterLaunch()
    }

    /// Shortcuts may open a second UI scene while an existing session keeps updating Live Activity.
    private func reconcileAfterLaunch() {
        recorder.prepareStorage()
        if isExpectingTracking {
            refreshLiveActivity(isStale: false)
            progress = lastReceivedAt == nil ? .waitingForFirstFix : .receiving
        } else if TrackingLiveActivityController.shared.orphanSnapshot != nil {
            TrackingLiveActivityController.shared.end()
            progress = .idle
        }
        bumpUI()
    }

    enum ConnectionProgress: Equatable {
        case idle
        case activatingConnectivity
        case requestingHealthPermission
        case wakingWatch
        case startingWatchTracking
        case waitingForFirstFix
        case receiving
        case staleRewaking
        case failed(String)

        var line: String {
            switch self {
            case .idle:
                return "待命"
            case .activatingConnectivity:
                return "正在啟用 WatchConnectivity…"
            case .requestingHealthPermission:
                return "正在請求健康／運動權限…"
            case .wakingWatch:
                return "正在喚醒手錶 App…"
            case .startingWatchTracking:
                return "已喚醒，正在請手錶開始定位…"
            case .waitingForFirstFix:
                return "等待手錶第一筆 GPS（戶外通常數秒～十幾秒）…"
            case .receiving:
                return "記錄中，持續接收手錶點位"
            case .staleRewaking:
                return "訊號中斷，正在重新喚醒手錶…"
            case .failed(let message):
                return message
            }
        }

        var isBusy: Bool {
            switch self {
            case .idle, .receiving, .failed:
                return false
            default:
                return true
            }
        }
    }

    enum EnsureTrackingResult {
        case idle
        case healthy
        case rewoke(success: Bool)
    }

    func ensureTrackingHealthy(staleThreshold: TimeInterval = 60) async -> EnsureTrackingResult {
        guard isExpectingTracking else {
            setProgress(.idle)
            return .idle
        }

        _ = await prepareForWatchConnectivity()
        refreshLiveActivity(isStale: false)

        let reference = lastReceivedAt ?? expectingSince ?? .distantPast
        let elapsed = Date().timeIntervalSince(reference)
        if elapsed < staleThreshold {
            await pingWatch()
            setProgress(lastReceivedAt == nil ? .waitingForFirstFix : .receiving)
            return .healthy
        }

        setProgress(.staleRewaking)
        let ok = await wakeWatchAndStartTracking(notifyOnFailure: true)
        return .rewoke(success: ok)
    }

    @discardableResult
    func wakeWatchAndStartTracking(notifyOnFailure: Bool = true) async -> Bool {
        isExpectingTracking = true
        if expectingSince == nil {
            expectingSince = Date()
        }
        persistExpectation()
        lastError = nil
        var wakeSucceeded = true

        _ = await prepareForWatchConnectivity()

        setProgress(.requestingHealthPermission)
        do {
            try await requestHealthAuthorization()
            setProgress(.wakingWatch)
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .walking
            configuration.locationType = .outdoor
            try await healthStore.startWatchApp(toHandle: configuration)
        } catch {
            wakeSucceeded = false
            let message = "無法喚醒手錶：\(error.localizedDescription)"
            lastError = message
            setProgress(.failed(message))
            if notifyOnFailure {
                NotificationManager.shared.notifyWatchWakeFailed(message: message)
            }
        }

        if wakeSucceeded {
            setProgress(.startingWatchTracking)
        }
        sendCommand(.startTracking)
        sendCommand(.requestStatus)
        refreshLiveActivity(isStale: false)
        if wakeSucceeded {
            setProgress(lastReceivedAt == nil ? .waitingForFirstFix : .receiving)
        }
        bumpUI()
        return wakeSucceeded
    }

    func noteStaleRewaking() {
        setProgress(.staleRewaking)
    }

    private func setProgress(_ value: ConnectionProgress) {
        progress = value
        bumpUI()
    }

    /// Called when the (single) UI becomes active — including Shortcuts「打開 App」.
    /// Prefer that over「打開 URL」, which is what spawned a second window on this app.
    func handleSceneBecameActive() async {
        _ = await prepareForWatchConnectivity()
        if isExpectingTracking {
            // Opening the app is enough to keep phone-side recording healthy.
            _ = await ensureTrackingHealthy()
        }
        bumpUI()
    }

    @discardableResult
    func prepareForWatchConnectivity(timeout: TimeInterval = 12) async -> Bool {
        guard let session else { return false }
        if session.activationState != .activated {
            setProgress(.activatingConnectivity)
        }
        session.delegate = wcBridge
        if session.activationState == .notActivated {
            session.activate()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while session.activationState != .activated, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard session.activationState == .activated else {
            let message = "WatchConnectivity 尚未啟用（捷徑剛開啟時常見，請再試一次）"
            lastError = message
            setProgress(.failed(message))
            return false
        }

        refreshWatchConnectivityState()
        drainReceivedApplicationContext()
        bumpUI()
        return true
    }

    private func drainReceivedApplicationContext() {
        guard let session, session.activationState == .activated else { return }
        let context = session.receivedApplicationContext
        guard !context.isEmpty else { return }
        handleIncoming(context)
    }

    func stopTrackingOnWatch() {
        isExpectingTracking = false
        expectingSince = nil
        persistExpectation()
        sendCommand(.stopTracking)
        TrackingLiveActivityController.shared.end()
        setProgress(.idle)
    }

    func refreshLiveActivity(isStale: Bool) {
        guard isExpectingTracking else {
            TrackingLiveActivityController.shared.end()
            return
        }
        TrackingLiveActivityController.shared.startOrUpdate(
            pointCount: recorder.totalPointsRecorded,
            lastAccuracy: watchStatus.lastAccuracy,
            isStale: isStale,
            lastFixAt: lastReceivedAt
        )
    }

    func pingWatch() async {
        _ = await prepareForWatchConnectivity()
        sendCommand(.ping)
        sendCommand(.requestStatus)
        bumpUI()
    }

    func refreshWatchConnectivityState() {
        guard let session else {
            isWatchPaired = false
            isWatchAppInstalled = false
            isReachable = false
            bumpUI()
            return
        }
        guard session.activationState == .activated else { return }

        isWatchPaired = session.isPaired
        isReachable = session.isReachable
        let reportedInstalled = session.isPaired && session.isWatchAppInstalled
        isWatchAppInstalled = reportedInstalled
        if reportedInstalled || session.isReachable {
            hasWatchCompanion = true
        }
        bumpUI()
    }

    private func noteWatchCommunication() {
        hasWatchCompanion = true
        isWatchAppInstalled = true
        refreshWatchConnectivityState()
    }

    private func bumpUI() {
        uiEpoch &+= 1
    }

    private func restoreExpectation() {
        let defaults = UserDefaults.standard
        isExpectingTracking = defaults.bool(forKey: PersistenceKey.expecting)
        if let since = defaults.object(forKey: PersistenceKey.expectingSince) as? Date {
            expectingSince = since
        }
        if let last = defaults.object(forKey: PersistenceKey.lastReceivedAt) as? Date {
            lastReceivedAt = last
        }
    }

    private func persistExpectation() {
        let defaults = UserDefaults.standard
        defaults.set(isExpectingTracking, forKey: PersistenceKey.expecting)
        defaults.set(expectingSince, forKey: PersistenceKey.expectingSince)
        defaults.set(lastReceivedAt, forKey: PersistenceKey.lastReceivedAt)
    }

    private func requestHealthAuthorization() async throws {
        let types: Set<HKSampleType> = [HKObjectType.workoutType()]
        try await healthStore.requestAuthorization(toShare: types, read: types)
    }

    func pushSettingsToWatch() {
        sendCommand(.updateSettings)
    }

    fileprivate func sendCommand(_ command: BridgeCommand) {
        guard let session, session.activationState == .activated else {
            lastError = "WatchConnectivity 尚未啟用"
            bumpUI()
            return
        }

        let envelope = BridgeEnvelope(
            kind: .command,
            command: command,
            recordIntervalSeconds: AppSettings.shared.recordInterval.rawValue
        )
        do {
            let data = try JSONEncoder().encode(envelope)
            let payload: [String: Any] = [BridgeKeys.payload: data]

            if session.isReachable {
                session.sendMessage(payload, replyHandler: { _ in }, errorHandler: { [weak self] error in
                    Task { @MainActor in
                        self?.lastError = error.localizedDescription
                        self?.session?.transferUserInfo(payload)
                        self?.bumpUI()
                    }
                })
            } else {
                session.transferUserInfo(payload)
                try? session.updateApplicationContext(payload)
            }
        } catch {
            lastError = error.localizedDescription
            bumpUI()
        }
    }

    fileprivate func handleIncoming(_ payload: [String: Any]) {
        guard let data = payload[BridgeKeys.payload] as? Data,
              let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: data)
        else { return }

        noteWatchCommunication()

        switch envelope.kind {
        case .points:
            guard isExpectingTracking else { return }
            guard let points = envelope.points, !points.isEmpty else { return }

            lastReceivedAt = Date()
            persistExpectation()
            recorder.append(points)
            onPointsReceived?(points)
            if let latest = points.last {
                var status = watchStatus
                status.isTracking = true
                status.lastFixAt = latest.timestamp
                status.lastAccuracy = latest.horizontalAccuracy
                watchStatus = status
            }
            refreshLiveActivity(isStale: false)
            setProgress(.receiving)
        case .status:
            if let status = envelope.status {
                watchStatus = status
                bumpUI()
            }
        case .ack, .command:
            break
        }
    }
}

/// WCSessionDelegate must be NSObject; keep it off the ObservableObject to preserve SwiftUI updates.
private final class PhoneWCSessionBridge: NSObject, WCSessionDelegate {
    weak var owner: PhoneSessionManager?

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            owner?.refreshWatchConnectivityState()
            owner?.drainReceivedApplicationContextFromBridge()
            if let error {
                owner?.lastError = error.localizedDescription
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            owner?.refreshWatchConnectivityState()
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            owner?.refreshWatchConnectivityState()
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            owner?.handleIncoming(message)
        }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            owner?.handleIncoming(message)
            replyHandler(["ok": true])
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            owner?.handleIncoming(userInfo)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            owner?.handleIncoming(applicationContext)
        }
    }
}

private extension PhoneSessionManager {
    func drainReceivedApplicationContextFromBridge() {
        drainReceivedApplicationContext()
    }
}
