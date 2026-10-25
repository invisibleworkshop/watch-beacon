import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: PhoneSessionManager
    @EnvironmentObject private var recorder: LocationRecorder
    @EnvironmentObject private var monitor: StaleSignalMonitor
    @EnvironmentObject private var notifications: NotificationManager
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero
                    statusSection
                    .id(session.uiEpoch) // force redraw when WC/points update (Shortcuts window was freezing)
                    settingsSection
                    recentPoints
                    bufferClear
                    shortcutsHint
                }
                .padding(20)
            }
            .background(PageBackground())
            .navigationTitle("精確定位")
            .task {
                await notifications.requestAuthorization()
                _ = await session.prepareForWatchConnectivity()
                monitor.start(session: session)
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("精確定位")
                .font(.system(size: 40, weight: .bold, design: .serif))
                .foregroundStyle(Color("BrandInk"))
            Text("由手錶送出精確 GPS，手機負責記錄與靈動島狀態；約 1 分鐘沒訊號會喚醒手錶，連續約 5 分鐘仍無訊息才通知。")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("設定")
                .font(.headline)
            Text("GPS 記錄間隔（活躍時段）")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("GPS 記錄間隔", selection: $settings.recordInterval) {
                ForEach(AppSettings.allowedIntervals) { interval in
                    Text(interval.label).tag(interval)
                }
            }
            .pickerStyle(.segmented)
            Text("手錶依此間隔保留點位並傳回手機。變更後會同步到手錶。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("啟用非活躍時段", isOn: Binding(
                get: { settings.quietHours.isEnabled },
                set: { enabled in
                    var next = settings.quietHours
                    next.isEnabled = enabled
                    settings.quietHours = next
                }
            ))

            if settings.quietHours.isEnabled {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("開始")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DatePicker(
                            "開始",
                            selection: Binding(
                                get: { settings.quietStartDate },
                                set: { settings.quietStartDate = $0 }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("結束")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DatePicker(
                            "結束",
                            selection: Binding(
                                get: { settings.quietEndDate },
                                set: { settings.quietEndDate = $0 }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                    }
                }
                Text("非活躍時段（預設 \(QuietHoursSchedule.default.startLabel)–\(QuietHoursSchedule.default.endLabel)）改為每 \(settings.quietHours.intervalSeconds) 秒定位一次。可跨午夜。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            statusRow(
                title: "目前生效間隔",
                value: settings.isInQuietHours
                    ? "每 \(settings.effectiveRecordIntervalSeconds) 秒（非活躍）"
                    : "每 \(settings.effectiveRecordIntervalSeconds) 秒（活躍）",
                ok: true
            )

            if monitor.isStale {
                statusRow(
                    title: "喚醒嘗試",
                    value: "\(monitor.rewakeAttemptsInCurrentGap) / 5",
                    ok: monitor.rewakeAttemptsInCurrentGap < 5
                )
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("連線狀態")
                .font(.headline)

            progressLine

            statusRow(
                title: "手錶 Companion",
                value: watchCompanionLabel,
                ok: session.isReachable || session.isWatchAppInstalled
            )
            statusRow(
                title: "即時可達",
                value: session.isReachable ? "是" : "否（仍可背景傳輸）",
                ok: session.isReachable
            )
            statusRow(
                title: "手機記錄",
                value: session.isExpectingTracking ? "開啟中" : "已停止",
                ok: session.isExpectingTracking
            )
            statusRow(
                title: "Watch 定位中",
                value: watchTrackingLabel,
                ok: session.watchStatus.isTracking && session.hasFreshPoints
            )
            statusRow(
                title: "最後訊號",
                value: lastSignalLabel,
                ok: session.hasFreshPoints
            )

            if monitor.isStale {
                Text(
                    monitor.isAttemptingRewake
                        ? "訊號逾時，正在喚醒手錶（每分鐘一次）…"
                        : "訊號逾時：每分鐘自動喚醒；連續 5 次仍無訊息才通知。"
                )
                .font(.subheadline)
                .foregroundStyle(Color("AlertClay"))
            }

            if let error = session.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color("AlertClay"))
            }

            trackingControls

            storageSection
        }
    }

    private var trackingControls: some View {
        VStack(spacing: 12) {
            Button {
                Task { await session.wakeWatchAndStartTracking() }
            } label: {
                Text("開始手機記錄（喚醒手錶）")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(session.isExpectingTracking)

            HStack(spacing: 12) {
                Button("停止") {
                    session.stopTrackingOnWatch()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!session.isExpectingTracking)

                Button("重新查詢") {
                    Task { await session.pingWatch() }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.top, 4)
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

    private var progressLine: some View {
        HStack(alignment: .top, spacing: 8) {
            if session.progress.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: progressSymbol)
                    .foregroundStyle(progressColor)
            }
            Text(session.progress.line)
                .font(.subheadline)
                .foregroundStyle(progressColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(progressColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var progressSymbol: String {
        switch session.progress {
        case .idle: return "pause.circle"
        case .receiving: return "antenna.radiowaves.left.and.right"
        case .expectingNoSignal, .failed: return "exclamationmark.triangle.fill"
        default: return "ellipsis.circle"
        }
    }

    private var progressColor: Color {
        switch session.progress {
        case .failed, .expectingNoSignal: return Color("AlertClay")
        case .receiving: return Color("BrandInk")
        case .idle: return .secondary
        default: return Color("BrandInk")
        }
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

    private var watchCompanionLabel: String {
        if session.isReachable {
            return "即時可通訊"
        }
        if session.isWatchAppInstalled {
            return "已安裝（未即時可達）"
        }
        if !session.isWatchPaired {
            return "未配對手錶"
        }
        if let contact = session.lastCompanionContactAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "zh_TW")
            formatter.unitsStyle = .short
            let ago = formatter.localizedString(for: contact, relativeTo: Date())
            return "系統回報未安裝（上次通訊 \(ago)）"
        }
        return "系統回報未安裝／無法通訊"
    }

    private var watchTrackingLabel: String {
        if session.watchStatus.isTracking, session.hasFreshPoints {
            return "是（有近期點位）"
        }
        if session.watchStatus.isTracking {
            return "手錶回報是（但點位已過期）"
        }
        return "否"
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

    private var bufferClear: some View {
        Button("清除畫面緩衝（不刪 iCloud 檔）", role: .destructive) {
            recorder.clearRecentBuffer()
        }
        .font(.footnote)
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
            Text("記錄以手機為準。定時維持請用「打開 App → 精確定位」（與方圓記帳相同），不要用「打開 URL」——自訂 URL 在本 App（有靈動島）容易開出第二個視窗。每次打開若正在記錄會自動檢查／重喚醒手錶。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("可選 URL（容易開雙窗，不建議給自動化）：")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("watchgpsbridge://start  /  ensure  /  stop")
                .font(.system(.caption, design: .monospaced))
            Text("Mac 處理")
                .font(.headline)
                .padding(.top, 8)
            Text("軌跡以 GPX 寫入 iCloud。Mac 用「精確定位 Geotag」App（scheme PreciseGeotagMac）選軌跡／照片目錄與時區寫入 GPS，並可 GPX ⇄ 舊 JSON 互轉。")
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
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 14)
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.85))
            .background(
                Color("BrandInk").opacity(
                    !isEnabled ? 0.35 : (configuration.isPressed ? 0.8 : 1)
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 12)
            .foregroundStyle(Color("BrandInk").opacity(isEnabled ? 1 : 0.4))
            .background(
                Color.white.opacity(
                    !isEnabled ? 0.4 : (configuration.isPressed ? 0.5 : 0.75)
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
