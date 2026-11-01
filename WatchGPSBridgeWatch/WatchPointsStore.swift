import Foundation

/// Durable outbound GPS queue on the Watch. Points stay on disk until delivery is confirmed.
@MainActor
final class WatchPointsStore {
    static let shared = WatchPointsStore()

    static let uploadBatchSize = 60

    private(set) var points: [GPSPoint] = []
    private var inFlightIDs: Set<UUID> = []

    var pendingCount: Int { points.count }

    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("WatchGPSBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("pending-points.json")
        load()
    }

    func enqueue(_ batch: [GPSPoint]) {
        guard !batch.isEmpty else { return }
        var known = Set(points.map(\.id))
        for point in batch where !known.contains(point.id) {
            known.insert(point.id)
            points.append(point)
        }
        persist()
    }

    /// Oldest points not already handed to WatchConnectivity.
    func nextBatch(limit: Int = WatchPointsStore.uploadBatchSize) -> [GPSPoint] {
        guard limit > 0 else { return [] }
        var batch: [GPSPoint] = []
        batch.reserveCapacity(min(limit, points.count))
        for point in points where !inFlightIDs.contains(point.id) {
            batch.append(point)
            if batch.count >= limit { break }
        }
        return batch
    }

    func markInFlight(_ batch: [GPSPoint]) {
        for point in batch {
            inFlightIDs.insert(point.id)
        }
    }

    func clearInFlight(_ batch: [GPSPoint]) {
        for point in batch {
            inFlightIDs.remove(point.id)
        }
    }

    func clearAllInFlight() {
        inFlightIDs.removeAll()
    }

    var inFlightCount: Int { inFlightIDs.count }

    func markDelivered(_ batch: [GPSPoint]) {
        guard !batch.isEmpty else { return }
        let ids = Set(batch.map(\.id))
        points.removeAll { ids.contains($0.id) }
        inFlightIDs.subtract(ids)
        persist()
    }

    func markDelivered(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        points.removeAll { ids.contains($0.id) }
        inFlightIDs.subtract(ids)
        persist()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try decoder.decode(Storage.self, from: data)
            points = decoded.points.sorted { $0.timestamp < $1.timestamp }
            inFlightIDs.removeAll()
        } catch {
            points = []
        }
    }

    private func persist() {
        let storage = Storage(points: points)
        do {
            let data = try encoder.encode(storage)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let temp = fileURL.appendingPathExtension("tmp")
                try data.write(to: temp, options: .atomic)
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            try? encoder.encode(storage).write(to: fileURL, options: .atomic)
        }
    }

    private struct Storage: Codable {
        var points: [GPSPoint]
    }
}
