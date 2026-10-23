import Foundation

/// A single high-accuracy GPS sample originating from Apple Watch.
public struct GPSPoint: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    public let horizontalAccuracy: Double
    public let verticalAccuracy: Double
    public let speed: Double
    public let course: Double
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        speed: Double,
        course: Double,
        timestamp: Date
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.course = course
        self.timestamp = timestamp
    }

    /// Prefer samples with horizontal accuracy better than this (meters).
    public var isPreciseEnough: Bool {
        horizontalAccuracy >= 0 && horizontalAccuracy <= 15
    }
}

public enum BridgeCommand: String, Codable, Sendable {
    case startTracking
    case stopTracking
    case ping
    case requestStatus
}

public struct BridgeEnvelope: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case command
        case points
        case status
        case ack
    }

    public let kind: Kind
    public let command: BridgeCommand?
    public let points: [GPSPoint]?
    public let status: WatchStatus?
    public let sentAt: Date

    public init(
        kind: Kind,
        command: BridgeCommand? = nil,
        points: [GPSPoint]? = nil,
        status: WatchStatus? = nil,
        sentAt: Date = Date()
    ) {
        self.kind = kind
        self.command = command
        self.points = points
        self.status = status
        self.sentAt = sentAt
    }
}

public struct WatchStatus: Codable, Sendable, Equatable {
    public var isTracking: Bool
    public var authorization: String
    public var lastFixAt: Date?
    public var lastAccuracy: Double?
    public var workoutActive: Bool
    public var watchReachableNote: String?

    public init(
        isTracking: Bool = false,
        authorization: String = "unknown",
        lastFixAt: Date? = nil,
        lastAccuracy: Double? = nil,
        workoutActive: Bool = false,
        watchReachableNote: String? = nil
    ) {
        self.isTracking = isTracking
        self.authorization = authorization
        self.lastFixAt = lastFixAt
        self.lastAccuracy = lastAccuracy
        self.workoutActive = workoutActive
        self.watchReachableNote = watchReachableNote
    }
}

public enum BridgeKeys {
    public static let payload = "payload"
    public static let urlScheme = "watchgpsbridge"
    public static let appGroupSuite = "group.com.watchgpsbridge.app"
}
