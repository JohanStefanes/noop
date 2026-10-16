#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore
import WhoopProtocol

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
    /// How much of `sleep.night` carries beat-to-beat data, from the same scored R-R read the night's HRV
    /// uses; nil without a night.
    @Published private(set) var coverage: JohanNightCoverage.Summary?
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

        recommendation = Self.recommendation(ledger: ledger, goal: JohanSleepGoal.current)

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
        var nightCoverage: JohanNightCoverage.Summary?
        if let model, !model.isStubNight {
            hr = await repo.hrBuckets(from: model.night.session.startTs, to: model.night.session.endTs,
                                      bucketSeconds: 60)
            let start = model.night.session.effectiveStartTs
            let end = model.night.session.endTs
            let beats = await repo.rrIntervals(from: start, to: end, limit: 200_000)
            let samples = await repo.hrSamples(from: start, to: end, limit: 80_000)
            nightCoverage = await Task.detached(priority: .userInitiated) {
                JohanNightCoverage.summarize(
                    start: start, end: end, beatTimestamps: beats.map(\.ts),
                    liveBeats: beats.filter { Self.isLive($0.srcChannel) }.count,
                    heartRateTimestamps: samples.map(\.ts))
            }.value
        }
        // Published together so the chart never pairs one night's trace with another night's stages.
        sleep = model
        nightHR = hr
        coverage = nightCoverage
        loaded = true
    }

    /// Re-plans tonight for another goal without reloading the night.
    func apply(goal: JohanSleepGoal) {
        guard let debt else { return }
        recommendation = Self.recommendation(ledger: debt, goal: goal)
    }

    /// Tonight's plan from the sleep ledger: the next configured wake time (this morning's while it is still
    /// ahead, otherwise tomorrow's) minus the goal's share of need plus capped payback. Home's "Tonight" card
    /// calls this too, so the two bedtimes can never differ.
    static func recommendation(ledger: SleepDebtLedger, goal: JohanSleepGoal, now: Date = Date()) -> Recommendation {
        let cal = Calendar.current
        let nowMin = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let todayWake = WindDownNudge.wakeMinutes(forWeekday: cal.component(.weekday, from: now))
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
        let wake = nowMin < todayWake
            ? todayWake
            : WindDownNudge.wakeMinutes(forWeekday: cal.component(.weekday, from: tomorrow))

        let payback = min(ledger.magnitudeMin, maxPaybackMin)
        let target = (ledger.needMin + payback) * goal.fraction
        let bed = ((wake - Int(target.rounded())) % 1440 + 1440) % 1440
        return Recommendation(bedtimeMinutes: bed, wakeMinutes: wake, needMin: ledger.needMin,
                              paybackMin: payback, targetSleepMin: target, nightsUsed: ledger.nightCount)
    }

    /// The ledger the Sleep tab plans with, from the stored nights alone (no session reads), for Home.
    static func ledger(days: [DailyMetric]) -> SleepDebtLedger {
        let series = days.map { (day: $0.day, totalSleepMin: $0.totalSleepMin) }
        return SleepDebt.ledger(series: series, needHours: SleepModel.debtNeedMin(days: days) / 60)
    }

    /// Beats that came over the live Bluetooth stream rather than the strap's banked history.
    nonisolated static func isLive(_ channel: RRSourceChannel?) -> Bool {
        switch channel {
        case .whoop5Standard?, .whoop4Realtime?, .whoop4Standard?: return true
        default: return false
        }
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

#if os(iOS)
/// How much of tonight's sleep goal to plan for, in WHOOP's three steps: all of it, most of it, or enough to
/// get by. One stored choice shared by the Sleep tab and Home.
enum JohanSleepGoal: String, CaseIterable, Identifiable {
    case peak, perform, getBy

    static let storageKey = "johanSleepGoal"
    static var current: JohanSleepGoal {
        JohanSleepGoal(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .peak
    }

    var id: String { rawValue }

    var fraction: Double {
        switch self {
        case .peak: return 1.0
        case .perform: return 0.85
        case .getBy: return 0.70
        }
    }

    var title: String {
        switch self {
        case .peak: return String(localized: "Peak")
        case .perform: return String(localized: "Perform")
        case .getBy: return String(localized: "Get by")
        }
    }
}
#endif
