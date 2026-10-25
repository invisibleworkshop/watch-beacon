import Foundation

/// Encode / decode GPS tracks as GPX 1.1 track files.
public enum GPXCodec {
    public static let fileExtension = "gpx"

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func encode(
        points: [GPSPoint],
        name: String = "精確定位",
        createdAt: Date = Date()
    ) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="精確定位" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(escape(name))</name>
            <time>\(isoFormatter.string(from: createdAt))</time>
          </metadata>
          <trk>
            <name>\(escape(name))</name>
            <trkseg>

        """
        for point in points {
            xml += "      <trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\">\n"
            xml += "        <ele>\(point.altitude)</ele>\n"
            xml += "        <time>\(isoFormatter.string(from: point.timestamp))</time>\n"
            if point.horizontalAccuracy >= 0 {
                // Non-standard but useful; ignored by most readers.
                xml += "        <extensions><horizontalAccuracy>\(point.horizontalAccuracy)</horizontalAccuracy></extensions>\n"
            }
            xml += "      </trkpt>\n"
        }
        xml += """
            </trkseg>
          </trk>
        </gpx>

        """
        return xml
    }

    public static func encodeData(points: [GPSPoint], name: String = "精確定位", createdAt: Date = Date()) -> Data {
        Data(encode(points: points, name: name, createdAt: createdAt).utf8)
    }

    public static func decode(data: Data) throws -> [GPSPoint] {
        guard let xml = String(data: data, encoding: .utf8) else {
            throw GPXError.invalidEncoding
        }
        return try decode(xml: xml)
    }

    public static func decode(xml: String) throws -> [GPSPoint] {
        let pattern = #"<trkpt\s+lat="([^"]+)"\s+lon="([^"]+)"\s*>(.*?)</trkpt>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            throw GPXError.parseFailed
        }
        let ns = xml as NSString
        let matches = regex.matches(in: xml, options: [], range: NSRange(location: 0, length: ns.length))
        var points: [GPSPoint] = []
        for match in matches {
            guard match.numberOfRanges >= 4,
                  let lat = Double(ns.substring(with: match.range(at: 1))),
                  let lon = Double(ns.substring(with: match.range(at: 2)))
            else { continue }
            let body = ns.substring(with: match.range(at: 3))
            let ele = firstDouble(in: body, tag: "ele") ?? 0
            let timeText = firstTag(in: body, tag: "time")
            let timestamp = timeText.flatMap { isoFormatter.date(from: $0) } ?? Date()
            let accuracy = firstDouble(in: body, tag: "horizontalAccuracy") ?? -1
            points.append(
                GPSPoint(
                    latitude: lat,
                    longitude: lon,
                    altitude: ele,
                    horizontalAccuracy: accuracy,
                    verticalAccuracy: -1,
                    speed: -1,
                    course: -1,
                    timestamp: timestamp
                )
            )
        }
        return points.sorted { $0.timestamp < $1.timestamp }
    }

    /// Convert geotag JSON chunk ↔ GPX.
    public static func gpxData(from chunk: TrackChunkFile, name: String = "精確定位") -> Data {
        encodeData(points: chunk.points, name: name, createdAt: chunk.createdAt)
    }

    public static func trackChunk(fromGPX data: Data, createdAt: Date = Date()) throws -> TrackChunkFile {
        let points = try decode(data: data)
        return TrackChunkFile(createdAt: createdAt, points: points)
    }

    private static func firstTag(in body: String, tag: String) -> String? {
        let pattern = "<\(tag)>([^<]*)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: body, options: [], range: NSRange(location: 0, length: (body as NSString).length)),
              match.numberOfRanges >= 2
        else { return nil }
        return (body as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstDouble(in body: String, tag: String) -> Double? {
        firstTag(in: body, tag: tag).flatMap(Double.init)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

public enum GPXError: Error {
    case invalidEncoding
    case parseFailed
}
