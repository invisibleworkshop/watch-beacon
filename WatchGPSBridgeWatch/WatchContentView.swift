import SwiftUI

struct WatchContentView: View {
    @ObservedObject var location: WatchLocationManager
    @ObservedObject var session: WatchSessionManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(location.isTracking ? "定位中" : "待命")
                    .font(.headline)

                if let point = location.lastPoint {
                    Text(String(format: "%.5f, %.5f", point.latitude, point.longitude))
                        .font(.caption2)
                        .monospaced()
                    Text(String(format: "精度 ±%.1f m", point.horizontalAccuracy))
                        .font(.caption2)
                        .foregroundStyle(point.isPreciseEnough ? .green : .orange)
                } else {
                    Text("尚無 GPS 點位")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Label(
                    session.isReachable ? "已連線 iPhone" : "iPhone 未達",
                    systemImage: session.isReachable ? "iphone" : "iphone.slash"
                )
                .font(.caption2)

                if session.pendingUploadCount > 0 {
                    Text("待上傳 \(session.pendingUploadCount) 點")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if location.workoutActive {
                    Text("運動工作階段進行中（維持背景 GPS）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(location.isTracking ? "停止" : "開始") {
                        if location.isTracking {
                            location.stopTracking()
                        } else {
                            location.startTracking()
                        }
                    }
                    .tint(location.isTracking ? .red : .green)

                    Button("狀態") {
                        session.sendStatus(location.currentStatus())
                    }
                }

                if let error = location.lastError ?? session.lastError {
                    let acquiring = error.contains("正在取得 GPS")
                    // During catch-up, pending orange is the signal — don't alarm on soft residuals.
                    let soft = acquiring || session.pendingUploadCount > 0
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(soft ? Color.secondary : Color.red)
                }
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            location.requestAuthorization()
            session.bind(locationManager: location)
            session.handleAppBecameActive()
        }
    }
}
