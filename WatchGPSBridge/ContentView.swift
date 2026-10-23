import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: PhoneSessionManager
    @EnvironmentObject private var recorder: LocationRecorder
    @EnvironmentObject private var monitor: StaleSignalMonitor
    @EnvironmentObject private var notifications: NotificationManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero
                    statusSection
                    controls
                    recentPoints
                    shortcutsHint
                }
                .padding(20)
            }
            .background(PageBackground())
            .navigationTitle("腕上定位")
            .task {
                await notifications.requestAuthorization()
                monitor.start(session: session)
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("腕上定位")
                .font(.system(size: 40, weight: .bold, design: .serif))
                .foregroundStyle(Color("BrandInk"))
            Text("由 Apple Watch 送出精確 GPS，iPhone 負責記錄與斷線提醒。捷徑只需打開本 App。")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("連線狀態")
                .font(.headline)

            statusRow(
                title: "Watch App",
                value: session.isWatchAppInstalled ? "已安裝" : "未安裝",
                ok: session.isWatchAppInstalled
            )
            statusRow(
                title: "即時可達",
                value: session.isReachable ? "是" : "否（仍可背景傳輸）",
                ok: session.isReachable
            )
            statusRow(
                title: "Watch 定位中",
                value: session.watchStatus.isTracking ? "是" : "否",
                ok: session.watchStatus.isTracking
            )
            statusRow(
                title: "最後訊號",
                value: lastSignalLabel,
                ok: !monitor.isStale
            )

            if monitor.isStale {
                Text("訊號逾時：請檢查 Apple Watch 佩戴、電量與定位權限。")
                    .font(.subheadline)
                    .foregroundStyle(Color("AlertClay"))
            }

            if let error = session.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color("AlertClay"))
            }

            storageSection
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("儲存")
                .font(.headline)
            statusRow(
                title: "位置",
                value: recorder.isUsingiCloud ? "iCloud" : "本機暫存",
                ok: recorder.isUsingiCloud
            )
            Text(recorder.storageDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            statusRow(
                title: "目前檔案",
                value: "\(recorder.currentFilePointCount) / \(LocationRecorder.pointsPerFile)",
                ok: true
            )
            if let name = recorder.currentFileName {
                Text(name)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            statusRow(
                title: "已完成檔案",
                value: "\(recorder.completedFileCount)",
                ok: true
            )
            statusRow(
                title: "累計點位",
                value: "\(recorder.totalPointsRecorded)",
                ok: true
            )
            if let error = recorder.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color("AlertClay"))
            }
        }
        .padding(.top, 8)
    }

    private var lastSignalLabel: String {
        if let date = session.lastReceivedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "zh_TW")
            formatter.unitsStyle = .short
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return "尚未收到"
    }

    private func statusRow(title: String, value: String, ok: Bool) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(ok ? Color("BrandInk") : Color("AlertClay"))
        }
        .font(.subheadline)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                Task { await session.wakeWatchAndStartTracking() }
            } label: {
                Text("喚醒 Watch 並開始記錄")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())

            HStack(spacing: 12) {
                Button("停止") {
                    session.stopTrackingOnWatch()
                }
                .buttonStyle(SecondaryButtonStyle())

                Button("重新查詢") {
                    session.pingWatch()
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Button("清除畫面緩衝（不刪 iCloud 檔）", role: .destructive) {
                recorder.clearRecentBuffer()
            }
            .font(.footnote)
        }
    }

    private var recentPoints: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近點位")
                    .font(.headline)
                Spacer()
                Text("緩衝 \(recorder.recentPoints.count)")
                    .foregroundStyle(.secondary)
            }

            if recorder.recentPoints.isEmpty {
                Text("尚未收到 Watch GPS。按下上方按鈕，或用捷徑打開本 App。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recorder.recentPoints.suffix(8).reversed()) { point in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.5f, %.5f  ·  ±%.1fm", point.latitude, point.longitude, point.horizontalAccuracy))
                            .font(.system(.caption, design: .monospaced))
                        Text(point.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var shortcutsHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("捷徑設定")
                .font(.headline)
            Text("在「捷徑」建立自動化：於指定時間「打開 App → 腕上定位」，或執行 App Intent「開始 Watch GPS 記錄」。本 App 會嘗試喚醒 Watch Companion。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("URL Scheme：watchgpsbridge://start")
                .font(.system(.caption, design: .monospaced))
            Text("Mac 處理")
                .font(.headline)
                .padding(.top, 8)
            Text("軌跡同步到 iCloud 後，在 Mac 執行 python tools/geotag_app.py：選軌跡／照片目錄與時區，修正 EXIF 時間後寫入 GPS。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 24)
    }
}

private struct PageBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.93, green: 0.96, blue: 0.94),
                Color(red: 0.86, green: 0.91, blue: 0.88),
                Color(red: 0.78, green: 0.86, blue: 0.90)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(Color("BrandInk").opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 12)
            .foregroundStyle(Color("BrandInk"))
            .background(Color.white.opacity(configuration.isPressed ? 0.5 : 0.75))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
