#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

/// Read model behind "Schlaf-Coach". Sleep need, debt and the night itself come from the owners the
/// Sleep tab already uses: `SleepModel.debtNeedMin` (personalised, age-floored need), `SleepDebt`
/// (ledger + debt series), `SleepModel.build` (the newest night, its hypnogram, the per-stage typicals and
/// the consistency series, fed exactly as the Sleep tab feeds it so no figure can differ from that tab),
/// `Repository.hrBuckets` (the night's one-minute heart rate), `WindDownNudge` (the wearer's configured
/// wake time) and `CircadianEngine` (body-clock window).
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

    struct BodyClock: Equatable {
        var idealBedHour: Double
        var idealWakeHour: Double
        var note: String
    }

    @Published private(set) var recommendation: Recommendation?
    @Published private(set) var debt: SleepDebtLedger?
    @Published private(set) var debtTrend: [(day: String, value: Double)] = []
    /// The Sleep tab's own model; nil until there is a night to show.
    @Published private(set) var sleep: SleepModel?
    /// One-minute heart-rate buckets across `sleep.night`, the same load the Sleep tab's HR chart uses.
    @Published private(set) var nightHR: [HRBucket] = []
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

        // The next wake time as the wearer configured it (per-weekday overrides included): this morning's
        // while it is still ahead (opened after midnight), otherwise tomorrow's.
        let cal = Calendar.current
        let now = Date()
        let nowMin = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let todayWake = WindDownNudge.wakeMinutes(forWeekday: cal.component(.weekday, from: now))
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
        let wake = nowMin < todayWake
            ? todayWake
            : WindDownNudge.wakeMinutes(forWeekday: cal.component(.weekday, from: tomorrow))

        let payback = min(ledger.magnitudeMin, Self.maxPaybackMin)
        let target = ledger.needMin + payback
        let bed = ((wake - Int(target.rounded())) % 1440 + 1440) % 1440
        recommendation = Recommendation(bedtimeMinutes: bed, wakeMinutes: wake, needMin: ledger.needMin,
                                        paybackMin: payback, targetSleepMin: target,
                                        nightsUsed: ledger.nightCount)

        // The night, its typicals and consistency: the Sleep tab's builder over the same inputs it loads.
        let sessions = await repo.allSleepSessions()
        let model = SleepModel.build(SleepModelInputs(
            days: days,
            sleeps: repo.sleeps,
            allSessions: sessions,
            importedSleep: repo.importedSleep,
            habitualMidsleepSec: await repo.habitualMidsleepSec(),
            motionByStart: await repo.sessionMotions(sessions: sessions)))
        var hr: [HRBucket] = []
        if let model, !model.isStubNight {
            hr = await repo.hrBuckets(from: model.night.session.startTs, to: model.night.session.endTs,
                                      bucketSeconds: 60)
        }
        // Published together so the chart never pairs one night's trace with another night's stages.
        sleep = model
        nightHR = hr
        loaded = true
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
