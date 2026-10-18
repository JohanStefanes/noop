import Foundation

/// When the bedtime "no live link" reminder should fire, as a dead man's switch.
///
/// iOS never relaunches an app the wearer swiped away in the app switcher, so a closed NOOP cannot say that
/// it is closed. Instead the app keeps one pending local notification and, every time live heart rate
/// arrives from the strap, pushes it `graceMinutes` further out. While the link is live it never comes due;
/// once heart rate stops arriving (the app was closed, the strap is charging or out of range) nothing pushes
/// it any more and it fires.
///
/// It may only fire inside the evening part of the overnight capture window: from `firstDelayMinutes` after
/// the window opens (the stream needs a moment to arm) until `spanMinutes` after it opens, so it reaches the
/// wearer before sleep, never in the middle of it.
/// No UI here: `StrandTests` compiles this file directly.
enum JohanLiveLinkPlan {

    /// How long live heart rate may be absent before the reminder fires.
    static let graceMinutes = 20
    /// How long after the window opens the first reminder may fire.
    static let firstDelayMinutes = 15
    /// How long after the window opens reminders stop for that night.
    static let spanMinutes = 4 * 60

    /// The fire date for a reminder planned at `now`: the first evening window whose latest allowed moment is
    /// still at least `graceMinutes` away, at the later of its first allowed moment and `now + grace`.
    ///
    /// `nightStartMinutes` is the capture window's opening minute of the day (`ContinuousHrvSchedule.nightWindow`).
    static func fireDate(now: Date, nightStartMinutes: Int, calendar: Calendar = .current) -> Date? {
        let start = min(max(nightStartMinutes, 0), 24 * 60 - 1)
        let today = calendar.startOfDay(for: now)
        let pushed = now.addingTimeInterval(TimeInterval(graceMinutes * 60))
        for dayOffset in -1...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today),
                  let open = calendar.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: day)
            else { continue }
            let first = open.addingTimeInterval(TimeInterval(firstDelayMinutes * 60))
            let last = open.addingTimeInterval(TimeInterval(spanMinutes * 60))
            let fire = max(first, pushed)
            if fire <= last { return fire }
        }
        return nil
    }
}
