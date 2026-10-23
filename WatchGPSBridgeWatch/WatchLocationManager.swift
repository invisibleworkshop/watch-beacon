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
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    self?.flushPending(force: false)
                }
            }
        }
    }

    private func flushPending(force: Bool) {
        guard !pendingPoints.isEmpty else { return }
        guard force || pendingPoints.count >= 3 else { return }
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
            for location in locations {
                // Skip clearly invalid / coarse cellular-only fixes when possible.
                guard location.horizontalAccuracy >= 0 else { continue }

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
                pendingPoints.append(point)
            }
            flushPending(force: false)
            publishStatus()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
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
