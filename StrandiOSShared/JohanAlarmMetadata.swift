#if os(iOS)
import AlarmKit

/// What a JohanUI alarm carries into its system alert and its snooze Live Activity. Shared by the app,
/// which schedules the alarm, and the widget extension, which draws the snooze countdown.
///
/// The words travel already translated: the widget extension ships no string catalog, so text it looks
/// up itself would always be English.
@available(iOS 26.0, *)
struct JohanAlarmMetadata: AlarmMetadata {
    /// The alarm's label, or nil for an unnamed alarm.
    var label: String?
    /// "Alarm", shown when there is no label.
    var alarmWord: String
    /// "Snoozing", while the snooze counts down.
    var snoozingWord: String
    /// "Paused".
    var pausedWord: String
}
#endif
