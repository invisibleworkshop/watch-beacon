import CoreLocation
import Foundation
import HealthKit

/// Runs high-accuracy outdoor GPS on Apple Watch and keeps the session alive with a workout.
@MainActor
final class WatchLocationManager: NSObject, ObservableObject {
    @Published private(set) var isTracking = false
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastPoint: GPSPoint?
    @Published private(set) var workoutActive = false
    @Published var lastError: String?

    private let locationManager = CLLocationManager()
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var pendingPoints: [GPSPoint] = []
    private var flushTask: Task<Void, Never>?
    /// Keep at most one sample per this many seconds (from phone settings).
    private(set) var recordIntervalSeconds: TimeInterval = 1
    private var lastAcceptedAt: Date?

    var onPointsBatch: (([GPSPoint]) -> Void)?
    var onStatusChange: ((WatchStatus) -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = true
        authorizationStatus = locationManager.authorizationStatus
        let raw = UserDefaults.standard.integer(forKey: "watchgpsbridge.recordIntervalSeconds")
        if let interval = GPSRecordInterval(rawValue: raw) {
            recordIntervalSeconds = TimeInterval(interval.rawValue)
        }
    }

    func setRecordIntervalSeconds(_ seconds: Int) {
        let clamped = GPSRecordInterval(rawValue: seconds)?.rawValue ?? 1
        recordIntervalSeconds = TimeInterval(clamped)
        UserDefaults.standard.set(clamped, forKey: "watchgpsbridge.recordIntervalSeconds")
    }

    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
        // Always / background is granted via Info.plist + Settings after When In Use.
        locationManager.requestAlwaysAuthorization()

        let types: Set<HKSampleType> = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: types, read: types) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.lastError = error.localizedDescription
                }
                self?.publishStatus()
            }
        }
    }

    func startTracking() {
        requestAuthorization()
        guard !isTracking else {
            publishStatus()
            return
        }

        startWorkoutSession()
        locationManager.startUpdatingLocation()
        isTracking = true
        scheduleFlushLoop()
        publishStatus()
    }

    func stopTracking() {
        isTracking = false
        locationManager.stopUpdatingLocation()
        flushPending(force: true)
        flushTask?.cancel()
        flushTask = nil
        endWorkoutSession()
        publishStatus()
    }

    func currentStatus() -> WatchStatus {
        WatchStatus(
            isTracking: isTracking,
            authorization: authorizationLabel(authorizationStatus),
            lastFixAt: lastPoint?.timestamp,
            lastAccuracy: lastPoint?.horizontalAccuracy,
            workoutActive: workoutActive
        )
    }

    private func publishStatus() {
        onStatusChange?(currentStatus())
    }

    private func authorizationLabel(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "whenInUse"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private func scheduleFlushLoop() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                let nanos = UInt64(max(1, self?.recordIntervalSeconds ?? 1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                await MainActor.run {
                    self?.flushPending(force: true)
                }
            }
        }
    }

    private func flushPending(force: Bool) {
        guard !pendingPoints.isEmpty else { return }
        guard force || pendingPoints.count >= 1 else { return }
        let batch = pendingPoints
        pendingPoints.removeAll(keepingCapacity: true)
        onPointsBatch?(batch)
    }

    private func startWorkoutSession() {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .walking
        configuration.locationType = .outdoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            workoutSession = session
            workoutBuilder = builder
            session.startActivity(with: Date())
            builder.beginCollection(withStart: Date()) { [weak self] _, error in
                Task { @MainActor in
                    if let error {
                        self?.lastError = error.localizedDescription
                    }
                    self?.workoutActive = true
                    self?.publishStatus()
                }
            }
        } catch {
            lastError = error.localizedDescription
            workoutActive = false
            publishStatus()
        }
    }

    private func endWorkoutSession() {
        workoutSession?.end()
        workoutBuilder?.endCollection(withEnd: Date()) { [weak self] _, _ in
            self?.workoutBuilder?.finishWorkout { _, _ in }
        }
        workoutSession = nil
        workoutBuilder = nil
        workoutActive = false
    }
}

extension WatchLocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            publishStatus()
            if isTracking,
               manager.authorizationStatus == .authorizedAlways
                || manager.authorizationStatus == .authorizedWhenInUse {
                locationManager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            var didAccept = false
            for location in locations {
                // Skip clearly invalid / coarse cellular-only fixes when possible.
                guard location.horizontalAccuracy >= 0 else { continue }

                if let lastAcceptedAt,
                   location.timestamp.timeIntervalSince(lastAcceptedAt) < recordIntervalSeconds {
                    continue
                }

                let point = GPSPoint(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    altitude: location.altitude,
                    horizontalAccuracy: location.horizontalAccuracy,
                    verticalAccuracy: location.verticalAccuracy,
                    speed: location.speed,
                    course: location.course,
                    timestamp: location.timestamp
                )
                lastPoint = point
                lastAcceptedAt = location.timestamp
                pendingPoints.append(point)
                didAccept = true
            }
            // Successful fixes mean prior "location unknown" noise is stale.
            if didAccept {
                lastError = nil
                flushPending(force: true)
            }
            publishStatus()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            // kCLErrorDomain 0 = locationUnknown: GPS still acquiring; not a real failure.
            // Common outdoors while first fix comes in — points may already be flowing to iPhone.
            if let clError = error as? CLError, clError.code == .locationUnknown {
                if lastPoint == nil, lastError == nil {
                    lastError = "正在取得 GPS…"
                }
                return
            }
            lastError = error.localizedDescription
            publishStatus()
        }
    }
}

extension WatchLocationManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            workoutActive = (toState == .running)
            publishStatus()
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            lastError = error.localizedDescription
            workoutActive = false
            publishStatus()
        }
    }
}

extension WatchLocationManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {}

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
