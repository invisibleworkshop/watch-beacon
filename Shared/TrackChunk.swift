import Foundation

/// On-disk JSON schema for each rotated track file (shared contract with Mac tools).
public struct TrackChunkFile: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let pointsPerFile = 10_000

    public let schemaVersion: Int
    public let pointsPerFile: Int
    public let createdAt: Date
    public let pointCount: Int
    public let points: [GPSPoint]

    public init(
        schemaVersion: Int = TrackChunkFile.currentSchemaVersion,
        pointsPerFile: Int = TrackChunkFile.pointsPerFile,
        createdAt: Date = Date(),
        points: [GPSPoint]
    ) {
        self.schemaVersion = schemaVersion
        self.pointsPerFile = pointsPerFile
        self.createdAt = createdAt
        self.pointCount = points.count
        self.points = points
    }
}

public enum StorageKeys {
    /// Must match Xcode iCloud container id / entitlements.
    public static let iCloudContainer = "iCloud.com.watchgpsbridge.app"
    public static let tracksFolderName = "Tracks"
}
