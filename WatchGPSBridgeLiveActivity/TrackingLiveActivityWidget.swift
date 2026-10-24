import ActivityKit
import SwiftUI
import WidgetKit

struct TrackingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrackingActivityAttributes.self) { context in
            lockScreenView(state: context.state, startedAt: context.attributes.startedAt)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("精確定位", systemImage: "location.fill")
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.pointCount)")
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .contentTransition(.numericText())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.statusText)
                        .font(.caption)
                        .foregroundStyle(context.state.isStale ? .orange : .secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if let accuracy = context.state.lastAccuracy {
                            Text(String(format: "精度 ±%.0f m", accuracy))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let fix = context.state.lastFixAt {
                            Text(fix, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isStale ? "location.slash.fill" : "location.fill")
                    .foregroundStyle(context.state.isStale ? .orange : .green)
            } compactTrailing: {
                Text("\(context.state.pointCount)")
                    .font(.caption.monospacedDigit())
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.7)
            } minimal: {
                Image(systemName: context.state.isStale ? "location.slash.fill" : "location.fill")
                    .foregroundStyle(context.state.isStale ? .orange : .green)
            }
        }
    }

    @ViewBuilder
    private func lockScreenView(
        state: TrackingActivityAttributes.ContentState,
        startedAt: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("精確定位", systemImage: "location.fill")
                    .font(.headline)
                Spacer()
                Text(state.statusText)
                    .font(.subheadline)
                    .foregroundStyle(state.isStale ? .orange : .secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\(state.pointCount)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("點")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let accuracy = state.lastAccuracy {
                        Text(String(format: "±%.0f m", accuracy))
                            .font(.caption.monospacedDigit())
                    }
                    Text(startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .activityBackgroundTint(Color.black.opacity(0.35))
    }
}

@main
struct WatchGPSBridgeWidgetBundle: WidgetBundle {
    var body: some Widget {
        TrackingLiveActivityWidget()
    }
}
