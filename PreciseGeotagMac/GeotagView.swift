import AppKit
import SwiftUI

struct GeotagView: View {
    @State private var tracksDir: URL?
    @State private var photosDir: URL?
    @State private var sourceTZ = FixedOffsetTZ.common[2]
    @State private var targetTZ = FixedOffsetTZ.common[3]
    @State private var customSource = ""
    @State private var customTarget = ""
    @State private var mode: GeotagMode = .retag
    @State private var maxDelta = "300"
    @State private var recursive = true
    @State private var write = false
    @State private var requireGPS = true
    @State private var logText = ""
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("精確定位 · 照片 Geotag")
                .font(.title2.bold())
            Text("選擇 GPX／舊 JSON 軌跡與照片目錄，修正 EXIF 時區並寫入 GPS。預設為預覽；勾選「實際寫入」才會改檔。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            pathRow(title: "軌跡目錄", url: tracksDir) { tracksDir = pickDirectory() }
            pathRow(title: "照片目錄", url: photosDir) { photosDir = pickDirectory() }

            GroupBox("照片時區") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("原時區")
                        Picker("", selection: $sourceTZ) {
                            ForEach(FixedOffsetTZ.common) { Text($0.label).tag($0) }
                        }
                        TextField("自訂 GMT+8", text: $customSource)
                            .frame(width: 100)
                    }
                    HStack {
                        Text("目標時區")
                        Picker("", selection: $targetTZ) {
                            ForEach(FixedOffsetTZ.common) { Text($0.label).tag($0) }
                        }
                        TextField("自訂 GMT+9", text: $customTarget)
                            .frame(width: 100)
                    }
                    Picker("模式", selection: $mode) {
                        ForEach(GeotagMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                }
                .padding(6)
            }

            HStack {
                Text("最大時間差（秒）")
                TextField("300", text: $maxDelta)
                    .frame(width: 80)
                Toggle("含子資料夾", isOn: $recursive)
                Toggle("必須對到 GPS", isOn: $requireGPS)
                Toggle("實際寫入", isOn: $write)
            }

            HStack {
                Button(isRunning ? "處理中…" : "開始") {
                    run()
                }
                .disabled(isRunning || tracksDir == nil || photosDir == nil)
                .keyboardShortcut(.defaultAction)
                Spacer()
            }

            Text("日誌")
                .font(.headline)
            ScrollView {
                Text(logText.isEmpty ? "尚無輸出" : logText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 180)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func pathRow(title: String, url: URL?, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .frame(width: 72, alignment: .leading)
            Text(url?.path ?? "尚未選擇")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(url == nil ? .secondary : .primary)
            Spacer()
            Button("選擇…", action: action)
        }
    }

    private func pickDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func resolvedTZ(custom: String, fallback: FixedOffsetTZ) -> FixedOffsetTZ {
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        return (try? FixedOffsetTZ.parse(trimmed)) ?? fallback
    }

    private func run() {
        guard let tracksDir, let photosDir else { return }
        isRunning = true
        logText = ""
        let source = resolvedTZ(custom: customSource, fallback: sourceTZ)
        let target = resolvedTZ(custom: customTarget, fallback: targetTZ)
        let delta = Int(maxDelta) ?? 300
        let doRecursive = recursive
        let doWrite = write
        let doRequireGPS = requireGPS
        let selectedMode = mode
        let tracks = tracksDir
        let photos = photosDir

        Task.detached(priority: .userInitiated) {
            do {
                let result = try GeotagEngine.processPhotos(
                    tracksDir: tracks,
                    photosDir: photos,
                    sourceTZ: source,
                    targetTZ: target,
                    mode: selectedMode,
                    maxDeltaSeconds: delta,
                    recursive: doRecursive,
                    write: doWrite,
                    requireGPS: doRequireGPS
                ) { line in
                    Task { @MainActor in
                        logText += line + "\n"
                    }
                }
                await MainActor.run {
                    logText += "\n完成：成功 \(result.matched)，略過 \(result.skipped)，失敗 \(result.failed)\n"
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    logText += "錯誤：\(error.localizedDescription)\n"
                    isRunning = false
                }
            }
        }
    }
}
