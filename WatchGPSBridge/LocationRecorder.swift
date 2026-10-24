import Foundation

/// Continuously records Watch GPS into rotating JSON files on iCloud Drive
/// (one new file every ``TrackChunkFile.pointsPerFile`` points) so a Mac can process them later.
@MainActor
final class LocationRecorder: ObservableObject {
    static let shared = LocationRecorder()

    static var pointsPerFile: Int { TrackChunkFile.pointsPerFile }

    @Published private(set) var recentPoints: [GPSPoint] = []
    @Published private(set) var currentFilePointCount = 0
    @Published private(set) var completedFileCount = 0
    @Published private(set) var totalPointsRecorded: Int = 0
    @Published private(set) var currentFileName: String?
    @Published private(set) var storageDescription = "尚未就緒"
    @Published private(set) var isUsingiCloud = false
    @Published var lastError: String?

    private var currentBatch: [GPSPoint] = []
    private var tracksDirectory: URL?
    private var currentFileURL: URL?
    private var currentFileCreatedAt = Date()
    private var iCloudRetryAttempts = 0

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private enum PersistenceKey {
        static let activeFileName = "watchgpsbridge.activeTrackFileName"
        static let totalPoints = "watchgpsbridge.totalPointsRecorded"
    }

    var points: [GPSPoint] { recentPoints }

    private init() {
        resolveStorageDirectory()
        if !resumeOpenFileIfPossible() {
            startNewFile()
        }
        recalculateTotalsFromDisk()
        if !isUsingiCloud {
            scheduleiCloudRetry()
        }
    }

    func prepareStorage() {
        let wasLocal = !isUsingiCloud
        let oldURL = currentFileURL
        let hadOnlyEmptyLocal = wasLocal && currentBatch.isEmpty
        resolveStorageDirectory()
        if wasLocal, isUsingiCloud, let oldURL {
            if !currentBatch.isEmpty {
                persistCurrentFile()
            }
            try? FileManager.default.removeItem(at: oldURL)
            // Cold start often resolves iCloud late — pick up the open track there.
            if hadOnlyEmptyLocal || currentBatch.isEmpty {
                currentFileURL = nil
                currentFileName = nil
                if !resumeOpenFileIfPossible() {
                    startNewFile()
                }
            }
        } else if currentFileURL == nil {
            if !resumeOpenFileIfPossible() {
                startNewFile()
            }
        }
        recalculateTotalsFromDisk()
    }

    func append(_ batch: [GPSPoint]) {
        guard !batch.isEmpty else { return }
        if tracksDirectory == nil {
            prepareStorage()
        }

        var knownIDs = Set(currentBatch.map(\.id)).union(Set(recentPoints.map(\.id)))

        for point in batch {
            // WatchConnectivity can deliver the same batch twice (message + context/userInfo).
            if knownIDs.contains(point.id) { continue }
            if let last = currentBatch.last,
               abs(point.timestamp.timeIntervalSince(last.timestamp)) < 0.05,
               abs(point.latitude - last.latitude) < 1e-7,
               abs(point.longitude - last.longitude) < 1e-7 {
                continue
            }
            knownIDs.insert(point.id)

            currentBatch.append(point)
            totalPointsRecorded += 1
            currentFilePointCount = currentBatch.count
            recentPoints.append(point)
            if recentPoints.count > 40 {
                recentPoints.removeFirst(recentPoints.count - 40)
            }

            if currentBatch.count >= Self.pointsPerFile {
                rotateFile()
            } else {
                persistCurrentFile()
            }
        }
        UserDefaults.standard.set(totalPointsRecorded, forKey: PersistenceKey.totalPoints)
    }

    /// Clears only the on-screen buffer. Completed iCloud track files are kept.
    func clearRecentBuffer() {
        recentPoints.removeAll()
    }

    func clear() {
        clearRecentBuffer()
    }

    private func resolveStorageDirectory() {
        lastError = nil
        if let iCloudRoot = FileManager.default.url(
            forUbiquityContainerIdentifier: StorageKeys.iCloudContainer
        ) {
            let tracks = iCloudRoot
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(StorageKeys.tracksFolderName, isDirectory: true)
            ensureDirectory(tracks)
            tracksDirectory = tracks
            isUsingiCloud = true
            storageDescription = "iCloud Drive → 精確定位 → Documents → Tracks"
            return
        }

        let local = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(StorageKeys.tracksFolderName, isDirectory: true)
        ensureDirectory(local)
        tracksDirectory = local
        isUsingiCloud = false
        storageDescription = "本機 Documents/Tracks（等待 iCloud；請確認已登入並在 Xcode 啟用 iCloud）"
    }

    private func scheduleiCloudRetry() {
        guard iCloudRetryAttempts < 5 else { return }
        iCloudRetryAttempts += 1
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !isUsingiCloud else { return }
            prepareStorage()
            if !isUsingiCloud {
                scheduleiCloudRetry()
            }
        }
    }

    /// After Shortcuts / process death: continue the open track file instead of starting a blank "second instance".
    @discardableResult
    private func resumeOpenFileIfPossible() -> Bool {
        guard let tracksDirectory else { return false }

        let defaults = UserDefaults.standard
        if let savedName = defaults.string(forKey: PersistenceKey.activeFileName) {
            let url = tracksDirectory.appendingPathComponent(savedName)
            if FileManager.default.fileExists(atPath: url.path), loadFileForResume(url) {
                return true
            }
        }

        // Fallback: newest incomplete JSON in Tracks.
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tracksDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        let jsonFiles = files.filter { $0.pathExtension.lowercased() == "json" }
        let sorted = jsonFiles.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }

        for url in sorted {
            if loadFileForResume(url) {
                return true
            }
        }
        return false
    }

    private func loadFileForResume(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let document = try? decoder.decode(TrackChunkFile.self, from: data)
        else { return false }

        // Full files are finished; don't append more to them.
        guard document.points.count < Self.pointsPerFile else { return false }

        currentFileURL = url
        currentFileName = url.lastPathComponent
        currentFileCreatedAt = document.createdAt
        currentBatch = document.points
        currentFilePointCount = document.points.count
        recentPoints = Array(document.points.suffix(40))
        UserDefaults.standard.set(currentFileName, forKey: PersistenceKey.activeFileName)
        return true
    }

    private func recalculateTotalsFromDisk() {
        guard let tracksDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: tracksDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              )
        else { return }

        var total = 0
        var completed = 0
        for url in files where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let document = try? decoder.decode(TrackChunkFile.self, from: data)
            else { continue }
            total += document.points.count
            if url.lastPathComponent != currentFileName {
                completed += 1
            }
        }
        totalPointsRecorded = total
        completedFileCount = completed
        UserDefaults.standard.set(totalPointsRecorded, forKey: PersistenceKey.totalPoints)
    }

    private func startNewFile() {
        guard let tracksDirectory else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "track-\(stamp)-part\(String(format: "%04d", completedFileCount + 1)).json"
        let url = tracksDirectory.appendingPathComponent(name)
        currentFileURL = url
        currentFileName = name
        currentFileCreatedAt = Date()
        currentBatch = []
        currentFilePointCount = 0
        UserDefaults.standard.set(name, forKey: PersistenceKey.activeFileName)
        persistCurrentFile()
    }

    private func rotateFile() {
        persistCurrentFile()
        completedFileCount += 1
        startNewFile()
        recalculateTotalsFromDisk()
    }

    private func persistCurrentFile() {
        guard let currentFileURL else { return }
        let document = TrackChunkFile(createdAt: currentFileCreatedAt, points: currentBatch)
        do {
            let data = try encoder.encode(document)
            try data.write(to: currentFileURL, options: [.atomic])
        } catch {
            lastError = "寫入失敗：\(error.localizedDescription)"
        }
    }

    private func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
