import Foundation

/// Persists GPS points received from Apple Watch onto the iPhone.
@MainActor
final class LocationRecorder: ObservableObject {
    static let shared = LocationRecorder()

    @Published private(set) var points: [GPSPoint] = []
    @Published private(set) var sessionStartedAt: Date?

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = folder.appendingPathComponent("watch-gps-track.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func beginSessionIfNeeded() {
        if sessionStartedAt == nil {
            sessionStartedAt = Date()
        }
    }

    func append(_ batch: [GPSPoint]) {
        beginSessionIfNeeded()
        points.append(contentsOf: batch)
        // Keep memory bounded for long outdoor sessions.
        if points.count > 50_000 {
            points.removeFirst(points.count - 50_000)
        }
        save()
    }

    func clear() {
        points.removeAll()
        sessionStartedAt = nil
        save()
    }

    func exportJSON() -> Data? {
        try? encoder.encode(points)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([GPSPoint].self, from: data)
        else { return }
        points = decoded
        sessionStartedAt = decoded.first?.timestamp
    }

    private func save() {
        guard let data = try? encoder.encode(points) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
