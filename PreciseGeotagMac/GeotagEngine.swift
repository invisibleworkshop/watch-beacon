import Foundation
import ImageIO
import UniformTypeIdentifiers

struct FixedOffsetTZ: Hashable, Identifiable {
    let id: String
    let label: String
    let secondsFromGMT: Int

    var timeZone: TimeZone { TimeZone(secondsFromGMT: secondsFromGMT)! }

    var exifOffset: String {
        let sign = secondsFromGMT >= 0 ? "+" : "-"
        let absSec = abs(secondsFromGMT)
        let h = absSec / 3600
        let m = (absSec % 3600) / 60
        if m == 0 { return String(format: "%@%02d:00", sign, h) }
        return String(format: "%@%02d:%02d", sign, h, m)
    }

    static let common: [FixedOffsetTZ] = [
        .init(id: "0", label: "GMT+0 / UTC", secondsFromGMT: 0),
        .init(id: "7", label: "GMT+7（曼谷等）", secondsFromGMT: 7 * 3600),
        .init(id: "8", label: "GMT+8（台北／新加坡等）", secondsFromGMT: 8 * 3600),
        .init(id: "9", label: "GMT+9（東京／首爾等）", secondsFromGMT: 9 * 3600),
        .init(id: "10", label: "GMT+10", secondsFromGMT: 10 * 3600),
        .init(id: "-5", label: "GMT-5", secondsFromGMT: -5 * 3600),
        .init(id: "-7", label: "GMT-7", secondsFromGMT: -7 * 3600),
        .init(id: "-8", label: "GMT-8", secondsFromGMT: -8 * 3600),
    ]

    static func parse(_ text: String) throws -> FixedOffsetTZ {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "UTC", with: "GMT")
            .replacingOccurrences(of: " ", with: "")
        let pattern = #"^(?:GMT)?([+-]?)(\d{1,2})(?::?(\d{2}))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              match.numberOfRanges >= 3
        else {
            throw GeotagError.message("無法解析時區：\(text)（例：GMT+8）")
        }
        let ns = raw as NSString
        let sign = ns.substring(with: match.range(at: 1)) == "-" ? -1 : 1
        let hours = Int(ns.substring(with: match.range(at: 2))) ?? 0
        let minutes = match.range(at: 3).location != NSNotFound
            ? Int(ns.substring(with: match.range(at: 3))) ?? 0
            : 0
        let seconds = sign * (hours * 3600 + minutes * 60)
        return FixedOffsetTZ(id: "custom-\(seconds)", label: "GMT\(sign >= 0 ? "+" : "")\(hours)\(minutes > 0 ? String(format: ":%02d", minutes) : "")", secondsFromGMT: seconds)
    }
}

enum GeotagMode: String, CaseIterable, Identifiable {
    case retag
    case convert
    var id: String { rawValue }
    var title: String {
        switch self {
        case .retag: return "保持牆上時間，改套目標時區"
        case .convert: return "同一瞬間換算到目標時區"
        }
    }
}

struct TrackPointLite: Equatable {
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var horizontalAccuracy: Double
}

enum GeotagError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let s) = self { return s }
        return nil
    }
}

enum GeotagEngine {
    static let photoExtensions: Set<String> = ["jpg", "jpeg", "tif", "tiff", "heic", "heif"]

    static func loadTracks(from directory: URL) throws -> [TrackPointLite] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let trackFiles = files.filter {
            let e = $0.pathExtension.lowercased()
            return e == "gpx" || e == "json"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !trackFiles.isEmpty else {
            throw GeotagError.message("在 \(directory.path) 找不到 .gpx／.json 軌跡檔")
        }

        var points: [TrackPointLite] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for url in trackFiles {
            let data = try Data(contentsOf: url)
            let gps: [GPSPoint]
            if url.pathExtension.lowercased() == "gpx" {
                gps = try GPXCodec.decode(data: data)
            } else {
                gps = try decoder.decode(TrackChunkFile.self, from: data).points
            }
            for p in gps {
                points.append(
                    TrackPointLite(
                        timestamp: p.timestamp,
                        latitude: p.latitude,
                        longitude: p.longitude,
                        altitude: p.altitude,
                        horizontalAccuracy: p.horizontalAccuracy
                    )
                )
            }
        }

        points.sort { $0.timestamp < $1.timestamp }
        var deduped: [TrackPointLite] = []
        for p in points {
            if let last = deduped.last, last.timestamp == p.timestamp {
                if p.horizontalAccuracy >= 0,
                   last.horizontalAccuracy < 0 || p.horizontalAccuracy < last.horizontalAccuracy {
                    deduped[deduped.count - 1] = p
                }
                continue
            }
            deduped.append(p)
        }
        return deduped
    }

    static func iterPhotos(in directory: URL, recursive: Bool) -> [URL] {
        var results: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        for case let url as URL in enumerator {
            if photoExtensions.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    static func processPhotos(
        tracksDir: URL,
        photosDir: URL,
        sourceTZ: FixedOffsetTZ,
        targetTZ: FixedOffsetTZ,
        mode: GeotagMode,
        maxDeltaSeconds: Int,
        recursive: Bool,
        write: Bool,
        requireGPS: Bool,
        log: (String) -> Void
    ) throws -> (matched: Int, skipped: Int, failed: Int) {
        let tracks = try loadTracks(from: tracksDir)
        log("已載入 \(tracks.count) 個軌跡點")
        let photos = iterPhotos(in: photosDir, recursive: recursive)
        log("找到 \(photos.count) 張照片")

        var matched = 0
        var skipped = 0
        var failed = 0
        let maxDelta = TimeInterval(maxDeltaSeconds)

        for photo in photos {
            do {
                guard let wall = readWallClock(from: photo) else {
                    log("略過（無 EXIF 時間）：\(photo.lastPathComponent)")
                    skipped += 1
                    continue
                }
                let corrected = correctTime(wall: wall, source: sourceTZ, target: targetTZ, mode: mode)
                let utc = wallClockToUTC(wall: wall, source: sourceTZ, target: targetTZ, mode: mode)

                let nearest = nearestPoint(in: tracks, whenUTC: utc, maxDelta: maxDelta)
                if requireGPS, nearest == nil {
                    log("略過（無對應 GPS）：\(photo.lastPathComponent)")
                    skipped += 1
                    continue
                }

                if write {
                    try writeExif(
                        to: photo,
                        localDate: corrected,
                        targetTZ: targetTZ,
                        point: nearest?.point
                    )
                    if let nearest {
                        log("已寫入 \(photo.lastPathComponent)（Δ \(Int(nearest.delta))s）")
                    } else {
                        log("已寫入時間 \(photo.lastPathComponent)（無 GPS）")
                    }
                } else {
                    if let nearest {
                        log("預覽 \(photo.lastPathComponent) → \(String(format: "%.5f,%.5f", nearest.point.latitude, nearest.point.longitude)) Δ\(Int(nearest.delta))s")
                    } else {
                        log("預覽 \(photo.lastPathComponent)（僅時區）")
                    }
                }
                matched += 1
            } catch {
                failed += 1
                log("失敗 \(photo.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return (matched, skipped, failed)
    }

    private static func correctTime(
        wall: DateComponents,
        source: FixedOffsetTZ,
        target: FixedOffsetTZ,
        mode: GeotagMode
    ) -> DateComponents {
        // Return wall-clock components to write into EXIF (local numbers).
        switch mode {
        case .retag:
            return wall
        case .convert:
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = source.timeZone
            guard let absolute = cal.date(from: wall) else { return wall }
            cal.timeZone = target.timeZone
            return cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: absolute)
        }
    }

    private static func wallClockToUTC(
        wall: DateComponents,
        source: FixedOffsetTZ,
        target: FixedOffsetTZ,
        mode: GeotagMode
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        switch mode {
        case .retag:
            cal.timeZone = target.timeZone
        case .convert:
            cal.timeZone = source.timeZone
        }
        return cal.date(from: wall) ?? Date()
    }

    private static func nearestPoint(
        in points: [TrackPointLite],
        whenUTC: Date,
        maxDelta: TimeInterval
    ) -> (point: TrackPointLite, delta: TimeInterval)? {
        guard !points.isEmpty else { return nil }
        let timestamps = points.map(\.timestamp)
        let idx = timestamps.firstIndex { $0 >= whenUTC } ?? timestamps.count
        var candidates: [TrackPointLite] = []
        if idx < points.count { candidates.append(points[idx]) }
        if idx > 0 { candidates.append(points[idx - 1]) }
        guard let best = candidates.min(by: { abs($0.timestamp.timeIntervalSince(whenUTC)) < abs($1.timestamp.timeIntervalSince(whenUTC)) }) else {
            return nil
        }
        let delta = abs(best.timestamp.timeIntervalSince(whenUTC))
        guard delta <= maxDelta else { return nil }
        return (best, delta)
    }

    private static func readWallClock(from url: URL) -> DateComponents? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        guard let raw else { return nil }
        return parseExifDate(raw)
    }

    private static func parseExifDate(_ text: String) -> DateComponents? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(secondsFromGMT: 0)!
                return cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            }
        }
        return nil
    }

    private static func writeExif(
        to url: URL,
        localDate: DateComponents,
        targetTZ: FixedOffsetTZ,
        point: TrackPointLite?
    ) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let uti = CGImageSourceGetType(source)
        else {
            throw GeotagError.message("無法讀取影像")
        }

        let dateString = String(
            format: "%04d:%02d:%02d %02d:%02d:%02d",
            localDate.year ?? 0,
            localDate.month ?? 0,
            localDate.day ?? 0,
            localDate.hour ?? 0,
            localDate.minute ?? 0,
            localDate.second ?? 0
        )

        var exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: dateString,
            kCGImagePropertyExifDateTimeDigitized: dateString,
            kCGImagePropertyExifOffsetTimeOriginal: targetTZ.exifOffset,
            kCGImagePropertyExifOffsetTimeDigitized: targetTZ.exifOffset,
            kCGImagePropertyExifOffsetTime: targetTZ.exifOffset,
        ]
        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFDateTime: dateString,
        ]

        var gps: [CFString: Any] = [:]
        if let point {
            gps[kCGImagePropertyGPSLatitudeRef] = point.latitude >= 0 ? "N" : "S"
            gps[kCGImagePropertyGPSLatitude] = abs(point.latitude)
            gps[kCGImagePropertyGPSLongitudeRef] = point.longitude >= 0 ? "E" : "W"
            gps[kCGImagePropertyGPSLongitude] = abs(point.longitude)
            gps[kCGImagePropertyGPSAltitudeRef] = point.altitude >= 0 ? 0 : 1
            gps[kCGImagePropertyGPSAltitude] = abs(point.altitude)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy:MM:dd"
            gps[kCGImagePropertyGPSDateStamp] = formatter.string(from: point.timestamp)
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: 0)!
            let c = cal.dateComponents([.hour, .minute, .second], from: point.timestamp)
            gps[kCGImagePropertyGPSTimeStamp] = String(
                format: "%02d:%02d:%02d",
                c.hour ?? 0,
                c.minute ?? 0,
                c.second ?? 0
            )
        }

        var props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
        ]
        if !gps.isEmpty {
            props[kCGImagePropertyGPSDictionary] = gps
        }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, uti, 1, nil) else {
            throw GeotagError.message("無法建立寫入目標")
        }
        CGImageDestinationAddImageFromSource(dest, source, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmp)
            throw GeotagError.message("寫入 EXIF 失敗")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
