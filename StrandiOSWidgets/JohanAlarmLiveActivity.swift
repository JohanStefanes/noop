import WidgetKit
import SwiftUI
import AlarmKit
import StrandDesign

/// Lock Screen and Dynamic Island for a JohanUI alarm while it is snoozed. The ringing alert itself is
/// drawn by the system; AlarmKit needs this presentation for the countdown between Snooze and the next ring.
@available(iOS 26.0, *)
struct JohanAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<JohanAlarmMetadata>.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "alarm.fill")
                    .font(.title2)
                    .foregroundStyle(context.attributes.tintColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.metadata?.label ?? context.attributes.metadata?.alarmWord ?? "Alarm")
                        .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                    status(context.state.mode, context.attributes.metadata)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Spacer()
                remaining(context.state.mode)
                    .font(.system(.title2, design: .rounded).monospacedDigit())
                    .foregroundStyle(context.attributes.tintColor)
            }
            .padding()
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { status(context.state.mode, context.attributes.metadata) } icon: { Image(systemName: "alarm.fill") }
                        .font(.subheadline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    remaining(context.state.mode)
                        .font(.system(.subheadline, design: .rounded).monospacedDigit())
                }
            } compactLeading: {
                Image(systemName: "zzz").foregroundStyle(context.attributes.tintColor)
            } compactTrailing: {
                remaining(context.state.mode).monospacedDigit().frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "alarm.fill").foregroundStyle(context.attributes.tintColor)
            }
        }
    }

    private func status(_ mode: AlarmPresentationState.Mode, _ words: JohanAlarmMetadata?) -> Text {
        switch mode {
        case .countdown: return Text(verbatim: words?.snoozingWord ?? "Snoozing")
        case .paused: return Text(verbatim: words?.pausedWord ?? "Paused")
        default: return Text(verbatim: words?.alarmWord ?? "Alarm")
        }
    }

    /// Time left until the snoozed alarm rings again, counting down on its own; nothing while it rings.
    @ViewBuilder
    private func remaining(_ mode: AlarmPresentationState.Mode) -> some View {
        if case .countdown(let c) = mode {
            Text(timerInterval: Date()...max(Date(), c.fireDate), countsDown: true)
        }
    }
}
