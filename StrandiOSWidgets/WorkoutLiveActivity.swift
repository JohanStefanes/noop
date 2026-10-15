import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Lock Screen and Dynamic Island for a running workout: the clock, heart rate and strain so far.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: context.attributes.symbol)
                        .foregroundStyle(StrandPalette.accent)
                    Text(context.attributes.sport)
                        .font(.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text(context.state.status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(context.state.isPaused ? StrandPalette.textSecondary : StrandPalette.accent)
                }
                HStack(alignment: .firstTextBaseline) {
                    clock(context.state)
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(context.state.isPaused ? StrandPalette.textSecondary : StrandPalette.textPrimary)
                    Spacer()
                    metric(context.state.bpm.map(String.init) ?? "–", context.attributes.bpmWord)
                    metric(context.state.strain, context.attributes.strainWord)
                        .padding(.leading, 14)
                }
            }
            .padding()
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { clock(context.state) } icon: { Image(systemName: context.attributes.symbol) }
                        .font(.system(.subheadline, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.bpm.map(String.init) ?? "–") \(context.attributes.bpmWord) · \(context.state.strain)")
                        .font(.system(.subheadline, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: context.attributes.symbol).foregroundStyle(StrandPalette.accent)
            } compactTrailing: {
                clock(context.state).monospacedDigit().frame(maxWidth: 56)
            } minimal: {
                Image(systemName: context.attributes.symbol).foregroundStyle(StrandPalette.accent)
            }
        }
    }

    /// Counts up on its own while running; frozen at the elapsed time while paused.
    @ViewBuilder
    private func clock(_ state: WorkoutActivityAttributes.ContentState) -> some View {
        if let start = state.clockStart {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
        } else {
            Text(Duration.seconds(state.pausedElapsed).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1))))
        }
    }

    private func metric(_ value: String, _ unit: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
            Text(unit).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}
