#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

/// Read model behind "Schlaf-Coach". Sleep need, debt and the night itself come from the owners the
/// Sleep tab already uses: `SleepModel.debtNeedMin` (personalised, age-floored need), `SleepDebt`
/// (ledger + debt series), `SleepView.mainNightGroup` / `decodeSegments` (main night and hypnogram),
/// `WindDownNudge` (the wearer's configured wake time) and `CircadianEngine` (body-clock window).
@MainActor
final class JohanSleepCoachModel: ObservableObject {

    struct Recommendation: Equatable {
        /// Minutes since midnight, 0..<1440.
        var bedtimeMinutes: Int
        var wakeMinutes: Int
        var needMin: Double
        var paybackMin: Double
        var targetSleepMin: Double
        /// Nights of real sleep data behind the ledger; 0 means the 8 h default need is used.
        var nightsUsed: Int
    }

    struct Night {
        var start: Date
        var end: Date
        var intervals: [SleepInterval]
        var stages: Stages
    }

    struct BodyClock: Equatable {
        var idealBedHour: Double
        var idealWakeHour: Double
        var note: String
    }

    @Published private(set) var recommendation: Recommendation?
    @Published private(set) var debt: SleepDebtLedger?
    @Published private(set) var debtTrend: [(day: String, value: Double)] = []
    @Published private(set) var night: Night?
    @Published private(set) var loaded = false

    /// Most extra sleep the coach asks for on top of the need, whatever the debt (a sane nightly cap).
    static let maxPaybackMin: Double = 90

    func load(repo: Repository, circadian: CircadianEngine.PhaseEstimate?) async {
        let days = repo.days
        let series = days.map { (day: $0.day, totalSleepMin: $0.totalSleepMin) }
        let needMin = SleepModel.debtNeedMin(days: days)
        let ledger = SleepDebt.ledger(series: series, needHours: needMin / 60)
        debt = ledger
        debtTrend = Array(SleepDebt.debtSeries(series: series, needHours: needMin / 60).suffix(SleepDebt.defaultWindowNights))

        // Tomorrow's wake time as the wearer configured it (per-weekday overrides included).
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let wake = WindDownNudge.wakeMinutes(forWeekday: cal.component(.weekday, from: tomorrow))

        let payback = min(ledger.magnitudeMin, Self.maxPaybackMin)
        let target = ledger.needMin + payback
        let bed = ((wake - Int(target.rounded())) % 1440 + 1440) % 1440
        recommendation = Recommendation(bedtimeMinutes: bed, wakeMinutes: wake, needMin: ledger.needMin,
                                        paybackMin: payback, targetSleepMin: target,
                                        nightsUsed: ledger.nightCount)

        // Last night: the same main-night resolver the Sleep tab hero uses.
        let habitual = await repo.habitualMidsleepSec()
        let windowStart = Int(Date().addingTimeInterval(-36 * 3600).timeIntervalSince1970)
        let candidates = repo.sleeps.filter { $0.endTs > windowStart }
        let group = SleepView.mainNightGroup(candidates, habitualMidsleepSec: habitual)
        night = Self.buildNight(group)
        loaded = true
    }

    private static func buildNight(_ group: [CachedSleepSession]) -> Night? {
        guard let first = group.first, let last = group.last else { return nil }
        let origin = first.effectiveStartTs
        var intervals: [SleepInterval] = []
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        for s in group {
            guard let decoded = SleepView.decodeSegments(s.stagesJSON, sessionStart: max(origin, s.effectiveStartTs)) else { continue }
            // decodeSegments is relative to the session start it was given; re-base onto the night origin.
            let shift = TimeInterval(max(origin, s.effectiveStartTs) - origin)
            intervals += decoded.intervals.map {
                SleepInterval(stage: $0.stage, start: $0.start + shift, end: $0.end + shift)
            }
            stages.awake += decoded.stages.awake; stages.light += decoded.stages.light
            stages.deep += decoded.stages.deep; stages.rem += decoded.stages.rem
        }
        guard intervals.count >= 2 else { return nil }
        return Night(start: Date(timeIntervalSince1970: TimeInterval(origin)),
                     end: Date(timeIntervalSince1970: TimeInterval(last.endTs)),
                     intervals: intervals, stages: stages)
    }

    /// Body-clock sleep window for `durationMin`, from the engine's own estimate. nil while the rhythm is
    /// unreadable (the engine says so itself) so the screen never invents a window.
    static func bodyClock(_ estimate: CircadianEngine.PhaseEstimate?, durationMin: Double) -> BodyClock? {
        guard let estimate, estimate.confidence != .unreadable,
              let w = CircadianEngine.idealSleepWindow(tempMinHour: estimate.tempMinHour,
                                                       durationHours: durationMin / 60) else { return nil }
        let off = Int(estimate.offsetVsScheduleMinutes.rounded())
        let note: String
        if off > 20 { note = String(localized: "Your body clock runs about \(String(off)) min later than your schedule.") }
        else if off < -20 { note = String(localized: "Your body clock runs about \(String(-off)) min earlier than your schedule.") }
        else { note = String(localized: "Your body clock matches your schedule.") }
        return BodyClock(idealBedHour: w.bedHour, idealWakeHour: w.wakeHour, note: note)
    }
}
#endif
