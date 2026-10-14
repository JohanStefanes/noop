#if os(iOS)
import Foundation
import StrandAnalytics
import WhoopStore
import WhoopProtocol

/// Read model behind the JohanUI Home screen. All numbers come from existing owners:
/// `Repository.days` / `Repository.today` (stored daily rows), `Repository.chargeBaselines` (personal
/// baselines), `RecoveryScorer.calibrationNights` (calibration state), `StrainScorer` (live Effort) and
/// `CoupledView.optimalStrainRange` (recovery to target strain band). Nothing is re-derived here.
@MainActor
final class JohanHomeModel: ObservableObject {

    /// One vital with its personal baseline (nil while that baseline is still learning).
    struct Vital: Equatable {
        var value: Double?
        var baseline: Double?
        var delta: Double? {
            guard let value, let baseline else { return nil }
            return value - baseline
        }
    }

    struct Snapshot: Equatable {
        var dayKey = ""
        var isToday = true
        var recovery: Double?
        var sleepPct: Double?
        /// Effort on WHOOP-style 0-21 axis (display conversion of the stored 0-100 value).
        var strain21: Double?
        /// 1...Baselines.minNightsSeed while the baselines are forming, nil once recovery is available.
        var calibrationDay: Int?
        var hrv = Vital()
        var restingHR = Vital()
        var resp = Vital()
        var targetBand: ClosedRange<Int>?
        /// What shaped the recovery score, from the engine's own scoring (`ChargeBreakdownWiring`, the
        /// same call the original Today and Coupled sheets make). nil while the night cannot honestly
        /// score (no usable HRV baseline, or no HRV / resting HR).
        var drivers: [ChargeDriver]?
        var confidence: ScoreConfidence?
    }

    /// 0 = today, 1 = yesterday, ...
    @Published var dayOffset = 0
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var loaded = false
    /// The newest heart-rate sample already stored for today, so the live card has an honest number to
    /// show (dimmed, with its age) during the seconds the strap takes to start streaming.
    @Published private(set) var lastStoredHR: HRSample?

    let calibrationLength = Baselines.minNightsSeed

    func canGoBack(repo: Repository) -> Bool {
        guard let earliest = repo.freshness.earliestDay else { return false }
        return dayKey(offset: dayOffset + 1) >= earliest
    }

    func dayKey(offset: Int) -> String {
        let day = Repository.logicalDay(Date())
        let shifted = Calendar.current.date(byAdding: .day, value: -offset, to: day) ?? day
        return Repository.localDayKey(shifted)
    }

    func dayDate(offset: Int) -> Date {
        let day = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -offset, to: day) ?? day
    }

    func load(repo: Repository, profile: ProfileStore) async {
        let offset = dayOffset
        let key = dayKey(offset: offset)
        let isToday = offset == 0
        let row: DailyMetric? = isToday
            ? (repo.today ?? repo.days.last(where: { $0.day == key }))
            : repo.days.last(where: { $0.day == key })

        // Calibration: the same helper the classic and liquid Today use.
        let baselines = repo.chargeBaselines
        let calNights: Int? = isToday
            ? RecoveryScorer.calibrationNights(nightlyHrv: baselines?.hrvHistory.values ?? [],
                                               dayKeys: baselines?.hrvHistory.dayKeys ?? [],
                                               hasRecovery: row?.recovery != nil)
            : nil

        // Stored Effort first, so the screen is never blank while the HR pass runs.
        let strainStored = row?.strain
        publish(row: row, key: key, isToday: isToday, calNights: calNights, baselines: baselines,
                sleepPct: snapshot.dayKey == key ? snapshot.sleepPct : nil, effort: strainStored, repo: repo)

        let sleepSeries = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        let sleepPct = sleepSeries.last(where: { $0.day == key })?.value

        var effort = strainStored
        if isToday {
            let start = Int(Calendar.current.startOfDay(for: Repository.logicalDay(Date())).timeIntervalSince1970)
            let now = Int(Date().timeIntervalSince1970)
            // Whole-window read with an explicit limit (a day banks ~18k HR rows), as the liquid Today does.
            let hr = await repo.hrSamples(from: start, to: now, limit: 200_000)
            if let last = hr.last(where: { (30...220).contains($0.bpm) }), last != lastStoredHR { lastStoredHR = last }
            let maxHR = profile.effortHRmax
            let restHR = row?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
            let method = PuffinExperiment.effortMethod
            let sex = profile.sex
            let live = await Task.detached(priority: .utility) {
                StrainScorer.strain(hr, maxHR: maxHR, restingHR: restHR, method: method, sex: sex)
            }.value
            effort = StrainScorer.effectiveEffort(live: live, stored: row?.strain)
        }
        // The day may have been changed while awaiting.
        guard offset == dayOffset else { return }
        publish(row: row, key: key, isToday: isToday, calNights: calNights, baselines: baselines,
                sleepPct: sleepPct, effort: effort, repo: repo)
        loaded = true
    }

    private func publish(row: DailyMetric?, key: String, isToday: Bool, calNights: Int?,
                         baselines: ChargeBaselines.Resolved?, sleepPct: Double?, effort: Double?,
                         repo: Repository) {
        var s = Snapshot()
        s.dayKey = key
        s.isToday = isToday
        s.recovery = row?.recovery
        s.sleepPct = sleepPct
        s.strain21 = effort.map { UnitFormatter.effortValue($0, scale: .whoop) }
        if row?.recovery == nil, let n = calNights {
            s.calibrationDay = min(n + 1, calibrationLength)
        }
        // Vitals: the day's own value; today falls back to the freshest prior night (same carry the liquid
        // Today uses). Deltas only on today, and only against a baseline the engine considers usable.
        let hrvRow = isToday ? Repository.lastHrvDay(days: repo.days, todayKey: key) : nil
        let rhrRow = isToday ? Repository.lastRestingHrDay(days: repo.days, todayKey: key) : nil
        let respRow = isToday ? Repository.lastRespDay(days: repo.days, todayKey: key) : nil
        s.hrv = Vital(value: row?.avgHrv ?? hrvRow?.avgHrv,
                      baseline: isToday ? usable(baselines?.hrv) : nil)
        s.restingHR = Vital(value: (row?.restingHr ?? rhrRow?.restingHr).map(Double.init),
                            baseline: isToday ? usable(baselines?.restingHR) : nil)
        s.resp = Vital(value: row?.respRateBpm ?? respRow?.respRateBpm,
                       baseline: isToday ? usable(baselines?.resp) : nil)
        s.targetBand = CoupledView.optimalStrainRange(recovery: row?.recovery)
        // The Sleep row scores against the same sleep figure the Schlaf dial on this screen shows.
        if let row, row.recovery != nil, let baselines,
           let breakdown = ChargeBreakdownWiring.breakdown(baselines: baselines, row: row, sleepPerfPercent: sleepPct) {
            s.drivers = breakdown.drivers
            s.confidence = breakdown.confidence
        }
        if s != snapshot { snapshot = s }
    }

    private func usable(_ state: BaselineState?) -> Double? {
        guard let state, state.usable else { return nil }
        return state.baseline
    }
}
#endif
