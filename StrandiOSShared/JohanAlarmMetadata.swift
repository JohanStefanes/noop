#if os(iOS)
import AlarmKit

/// What a JohanUI alarm carries into its system alert and its snooze Live Activity. Shared by the app,
/// which schedules the alarm, and the widget extension, which draws the snooze countdown.
@available(iOS 26.0, *)
struct JohanAlarmMetadata: AlarmMetadata {
    /// The alarm's label, or nil for an unnamed alarm.
    var label: String?
}
#endif
