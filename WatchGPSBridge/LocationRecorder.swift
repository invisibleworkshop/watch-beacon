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
    private var iCloudRetryAttempts = 0

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    var points: [GPSPoint] { recentPoints }

    private init() {
        resolveStorageDirectory()
        startNewFile()
        if !isUsingiCloud {
            scheduleiCloudRetry()
        }
    }

    func prepareStorage() {
        let wasLocal = !isUsingiCloud
        let oldURL = currentFileURL
        resolveStorageDirectory()
        if wasLocal, isUsingiCloud, let oldURL {
            persistCurrentFile()
            try? FileManager.default.removeItem(at: oldURL)
        } else if currentFileURL == nil {
            startNewFile()
        }
        refreshCompletedFileCount()
    }

    func append(_ batch: [GPSPoint]) {
        guard !batch.isEmpty else { return }
        if tracksDirectory == nil {
            prepareStorage()
        }

        for point in batch {
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
            storageDescription = "iCloud Drive → 腕上定位 → Documents → Tracks"
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

    private func startNewFile() {
        guard let tracksDirectory else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "track-\(stamp)-part\(String(format: "%04d", completedFileCount + 1)).json"
        let url = tracksDirectory.appendingPathComponent(name)
        currentFileURL = url
        currentFileName = name
        currentBatch = []
        currentFilePointCount = 0
        persistCurrentFile()
    }

    private func rotateFile() {
        persistCurrentFile()
        completedFileCount += 1
        startNewFile()
        refreshCompletedFileCount()
    }

    private func persistCurrentFile() {
        guard let currentFileURL else { return }
        let document = TrackChunkFile(createdAt: Date(), points: currentBatch)
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

    private func refreshCompletedFileCount() {
        guard let tracksDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: tracksDirectory,
                includingPropertiesForKeys: nil
              )
        else { return }
        let trackFiles = files.filter { $0.pathExtension.lowercased() == "json" }
        completedFileCount = trackFiles.filter { $0.lastPathComponent != currentFileName }.count
    }
}
