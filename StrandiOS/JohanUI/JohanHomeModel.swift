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
        /// Nights already banked toward the recovery baseline (0..<Baselines.minNightsSeed) while it is
        /// forming, nil once recovery is available.
        var calibrationNights: Int?
        var hrv = Vital()
        var restingHR = Vital()
        var resp = Vital()
        /// Measured SpO₂ first; the strap's unverified candidate only when none is stored and the
        /// Experimental display of it is on (the same rule the original Today follows).
        var spo2: Double?
        var spo2IsEstimate = false
        /// Skin temperature as stored (°C): the absolute night mean and/or its deviation from baseline.
        var skinTempAbsC: Double?
        var skinTempDevC: Double?
        /// The day each of these two belongs to, when it is not the shown day's own: carried from an earlier
        /// night (within `Baselines.vitalCarryDays`), or, past that, only remembered so the tile can say how
        /// old the last one is while showing no number.
        var spo2Day: String?
        var skinTempDay: String?
        var targetBand: ClosedRange<Int>?
        /// The day's calories and their source (`JohanCalories`: imported Apple Health first, else NOOP's estimate).
        var calories: JohanCalories.Reading?
        /// What shaped the recovery score, from the engine's own scoring (`ChargeBreakdownWiring`, the
        /// same call the original Today and Coupled sheets make). nil while the night cannot honestly
        /// score (no usable HRV baseline, or no HRV / resting HR).
        var drivers: [ChargeDriver]?
        var confidence: ScoreConfidence?
    }

    /// The weekly long-term figures (latest stored point of each), nil until the engine has written one.
    struct Healthspan: Equatable {
        var bodyAge: Double?
        var vitality: Double?
        var fitnessAge: Double?
        var vo2max: Double?
        var isEmpty: Bool { bodyAge == nil && vitality == nil && fitnessAge == nil && vo2max == nil }
    }

    /// One day's three ring values for the week strip and the month calendar.
    struct DayRings: Equatable {
        var recovery: Double?
        var sleepPct: Double?
        var strain21: Double?
        var isEmpty: Bool { recovery == nil && sleepPct == nil && strain21 == nil }
    }

    /// 0 = today, 1 = yesterday, ...
    @Published var dayOffset = 0
    /// Ring values by day key, from the stored daily rows and the sleep-performance series. Today's entry is
    /// overlaid with the open snapshot (live Effort) by `rings(for:)`, so the strip and the hero agree.
    @Published private(set) var dayRings: [String: DayRings] = [:]
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var loaded = false
    /// The newest heart-rate sample already stored for today, so the live card has an honest number to
    /// show (dimmed, with its age) during the seconds the strap takes to start streaming.
    @Published private(set) var lastStoredHR: HRSample?
    @Published private(set) var healthspan = Healthspan()
    /// SpO₂ candidate by day ("spo2_candidate" series), the fallback behind `Snapshot.spo2`.
    private var spo2CandidateByDay: [String: Double] = [:]
    /// Imported Apple Health active energy by day, the first choice behind `Snapshot.calories`.
    private var importedKcalByDay: [String: Double] = [:]

    let calibrationLength = Baselines.minNightsSeed

    func canGoBack(repo: Repository) -> Bool {
        guard let earliest = repo.freshness.earliestDay else { return false }
        return dayKey(offset: dayOffset + 1) >= earliest
    }

    /// The furthest day back that has data (its offset), or 0 when nothing is stored yet.
    func maxOffset(repo: Repository) -> Int {
        guard let earliest = repo.freshness.earliestDay,
              let date = Self.keyParser.date(from: earliest) else { return 0 }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date),
                                                   to: Calendar.current.startOfDay(for: dayDate(offset: 0))).day ?? 0
        return max(0, days)
    }

    /// The rings for one day. Today reads the open snapshot when it is today's, so a strip cell never shows
    /// an older Effort than the hero above it.
    func rings(for key: String) -> DayRings {
        if key == snapshot.dayKey, snapshot.isToday {
            return DayRings(recovery: snapshot.recovery, sleepPct: snapshot.sleepPct, strain21: snapshot.strain21)
        }
        return dayRings[key] ?? DayRings()
    }

    func loadRings(repo: Repository) async {
        let sleep = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        var out: [String: DayRings] = [:]
        for d in repo.days {
            out[d.day, default: DayRings()].recovery = d.recovery
            out[d.day, default: DayRings()].strain21 = d.strain.map { UnitFormatter.effortValue($0, scale: .whoop) }
        }
        for p in sleep { out[p.day, default: DayRings()].sleepPct = p.value }
        if out != dayRings { dayRings = out }
    }

    /// Body Age, Vitality, Fitness Age and VO₂max: the latest weekly point of each, as Health shows them.
    func loadHealthspan(repo: Repository) async {
        async let body = repo.exploreSeries(key: "body_age", source: "my-whoop")
        async let vitality = repo.exploreSeries(key: "vitality", source: "my-whoop")
        async let fitness = repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        async let vo2 = repo.exploreSeries(key: "vo2max_est", source: "my-whoop")
        let next = Healthspan(bodyAge: await body.last?.value, vitality: await vitality.last?.value,
                              fitnessAge: await fitness.last?.value, vo2max: await vo2.last?.value)
        if next != healthspan { healthspan = next }
    }

    static let keyParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

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

        importedKcalByDay = JohanCalories.importedByDay(await repo.appleDailyRows(days: offset + 2))
        let sleepSeries = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        let sleepPct = sleepSeries.last(where: { $0.day == key })?.value
        if PuffinExperiment.spo2CandidateDisplayEnabled {
            let candidates = await repo.exploreSeries(key: "spo2_candidate", source: "my-whoop")
            spo2CandidateByDay = Dictionary(candidates.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        } else {
            spo2CandidateByDay = [:]
        }

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
            s.calibrationNights = min(n, calibrationLength - 1)
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
        // SpO₂ and skin temperature are sparse (imported or banked per night), so today carries the freshest
        // prior value of each field, as the original Today does; a past day shows only its own.
        let spo2Row = isToday ? Repository.lastSpo2Day(days: repo.days, todayKey: key) : nil
        let skinRow = isToday ? Repository.lastSkinTempReadingDay(days: repo.days, todayKey: key) : nil
        // A carried value older than the respiratory carry window is not shown as a number: a months-old
        // import read as last night's is the "Respiratory 15.6 a fortnight later" bug in another tile.
        let cutoff = Baselines.cutoffKey(todayKey: key)
        if let measured = row?.spo2Pct {
            s.spo2 = measured
        } else if let carried = spo2Row, let pct = carried.spo2Pct {
            s.spo2Day = carried.day
            if carried.day >= cutoff { s.spo2 = pct }
        } else if let candidate = spo2CandidateByDay[key] {
            s.spo2 = candidate
            s.spo2IsEstimate = true
        }
        let skinSource = [row, skinRow].compactMap { $0 }.first { $0.skinTempC != nil || $0.skinTempDevC != nil }
        if let skinSource, skinSource.day != key { s.skinTempDay = skinSource.day }
        if let skinSource, skinSource.day >= cutoff {
            s.skinTempAbsC = skinSource.skinTempC
            s.skinTempDevC = skinSource.skinTempDevC
        }
        s.targetBand = CoupledView.optimalStrainRange(recovery: row?.recovery)
        s.calories = JohanCalories.reading(imported: importedKcalByDay[key], onDevice: row?.activeKcalEst)
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
