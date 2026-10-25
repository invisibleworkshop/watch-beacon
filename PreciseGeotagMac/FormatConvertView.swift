import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FormatConvertView: View {
    @State private var logText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GPX ⇄ Geotag JSON 互轉")
                .font(.title2.bold())
            Text("精確定位現在以 GPX 記錄；舊版軌跡為 geotag JSON（TrackChunk）。可在此雙向轉換單一檔案或整個資料夾。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("JSON → GPX（選檔）") { convertFiles(toGPX: true) }
                Button("GPX → JSON（選檔）") { convertFiles(toGPX: false) }
            }
            HStack(spacing: 12) {
                Button("資料夾：全部 JSON → GPX") { convertFolder(toGPX: true) }
                Button("資料夾：全部 GPX → JSON") { convertFolder(toGPX: false) }
            }

            Text("日誌")
                .font(.headline)
            ScrollView {
                Text(logText.isEmpty ? "尚無輸出" : logText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 220)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func convertFiles(toGPX: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = toGPX
            ? [.json]
            : [UTType(filenameExtension: "gpx")].compactMap { $0 }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            convertOne(url, toGPX: toGPX)
        }
    }

    private func convertFolder(toGPX: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let ext = toGPX ? "json" : "gpx"
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension.lowercased() == ext {
            convertOne(url, toGPX: toGPX)
        }
    }

    private func convertOne(_ url: URL, toGPX: Bool) {
        do {
            let data = try Data(contentsOf: url)
            if toGPX {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let chunk = try decoder.decode(TrackChunkFile.self, from: data)
                let out = url.deletingPathExtension().appendingPathExtension("gpx")
                try GPXCodec.gpxData(from: chunk, name: url.deletingPathExtension().lastPathComponent)
                    .write(to: out, options: .atomic)
                logText += "✓ \(url.lastPathComponent) → \(out.lastPathComponent)（\(chunk.points.count) 點）\n"
            } else {
                let chunk = try GPXCodec.trackChunk(fromGPX: data)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let out = url.deletingPathExtension().appendingPathExtension("json")
                try encoder.encode(chunk).write(to: out, options: .atomic)
                logText += "✓ \(url.lastPathComponent) → \(out.lastPathComponent)（\(chunk.points.count) 點）\n"
            }
        } catch {
            logText += "✗ \(url.lastPathComponent)：\(error.localizedDescription)\n"
        }
    }
}
