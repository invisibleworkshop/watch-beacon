import Foundation

/// On-disk JSON schema for each rotated track file (shared contract with Mac tools).
public struct TrackChunkFile: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let pointsPerFile = 10_000

    public let schemaVersion: Int
    public let source: String
    public let chunkIndex: Int
    public let startedAt: Date
    public let closedAt: Date?
    public let points: [GPSPoint]

    public init(
        schemaVersion: Int = TrackChunkFile.currentSchemaVersion,
        source: String = "apple-watch",
        chunkIndex: Int,
        startedAt: Date,
        closedAt: Date? = nil,
        points: [GPSPoint]
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.chunkIndex = chunkIndex
        self.startedAt = startedAt
        self.closedAt = closedAt
        self.points = points
    }
}

public enum StorageKeys {
    /// Must match Xcode iCloud container id / entitlements.
    public static let iCloudContainer = "iCloud.com.watchgpsbridge.app"
    public static let tracksFolderName = "WatchGPSTracks"
}
