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
    case updateSettings
}

/// How often the Watch should keep / send a GPS sample (seconds) during active hours.
public enum GPSRecordInterval: Int, CaseIterable, Codable, Sendable, Identifiable {
    case one = 1
    case three = 3
    case five = 5
    case ten = 10

    public var id: Int { rawValue }

    public var label: String {
        "每 \(rawValue) 秒"
    }
}

/// Overnight (or same-day) window that uses a coarser GPS interval.
public struct QuietHoursSchedule: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Minutes from local midnight, 0...1439 (e.g. 21:00 → 1260).
    public var startMinutes: Int
    /// Minutes from local midnight; may be earlier than start for overnight windows.
    public var endMinutes: Int
    /// Sample interval while inside the window (default 60 = once per minute).
    public var intervalSeconds: Int

    public static let `default` = QuietHoursSchedule(
        isEnabled: true,
        startMinutes: 21 * 60,
        endMinutes: 7 * 60,
        intervalSeconds: 60
    )

    public init(
        isEnabled: Bool = true,
        startMinutes: Int = 21 * 60,
        endMinutes: Int = 7 * 60,
        intervalSeconds: Int = 60
    ) {
        self.isEnabled = isEnabled
        self.startMinutes = Self.clampMinutes(startMinutes)
        self.endMinutes = Self.clampMinutes(endMinutes)
        self.intervalSeconds = max(1, intervalSeconds)
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if startMinutes == endMinutes {
            return true
        }
        if startMinutes < endMinutes {
            return minutes >= startMinutes && minutes < endMinutes
        }
        // Overnight, e.g. 21:00 → 07:00
        return minutes >= startMinutes || minutes < endMinutes
    }

    public func effectiveIntervalSeconds(
        base: Int,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        guard contains(date, calendar: calendar) else { return max(1, base) }
        return max(1, intervalSeconds)
    }

    public var startLabel: String { Self.timeLabel(startMinutes) }
    public var endLabel: String { Self.timeLabel(endMinutes) }

    public static func timeLabel(_ minutes: Int) -> String {
        let m = clampMinutes(minutes)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    public static func clampMinutes(_ value: Int) -> Int {
        let wrapped = value % (24 * 60)
        return wrapped >= 0 ? wrapped : wrapped + 24 * 60
    }

    public static func minutes(from date: Date, calendar: Calendar = .current) -> Int {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    public static func date(fromMinutes minutes: Int, calendar: Calendar = .current, reference: Date = Date()) -> Date {
        let m = clampMinutes(minutes)
        var comps = calendar.dateComponents([.year, .month, .day], from: reference)
        comps.hour = m / 60
        comps.minute = m % 60
        comps.second = 0
        return calendar.date(from: comps) ?? reference
    }
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
    public let recordIntervalSeconds: Int?
    public let quietHours: QuietHoursSchedule?
    public let sentAt: Date

    public init(
        kind: Kind,
        command: BridgeCommand? = nil,
        points: [GPSPoint]? = nil,
        status: WatchStatus? = nil,
        recordIntervalSeconds: Int? = nil,
        quietHours: QuietHoursSchedule? = nil,
        sentAt: Date = Date()
    ) {
        self.kind = kind
        self.command = command
        self.points = points
        self.status = status
        self.recordIntervalSeconds = recordIntervalSeconds
        self.quietHours = quietHours
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
    public static let appGroupSuite = "group.com.invisibleworkshop.watchgpsbridge"
}
