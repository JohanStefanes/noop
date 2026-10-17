import Foundation
import StrandAnalytics
import WhoopProtocol

/// The pure half of "MG vs Watch": one night of strap data set against the Apple Watch's own readings.
///
/// The same comparison as `Tools/mg_vs_watch.py`, run on the phone so no backup or Health export has to
/// leave it. Strap HRV comes from `HRVAnalyzer`, so the strap figures are the ones the app itself scores.
/// No HealthKit or UI here: `StrandTests` compiles this file directly.
enum JohanWatchCompare {

    /// One Watch HRV reading. HealthKit's HRV is SDNN over a reading of about a minute.
    struct HRVReading: Equatable {
        var start: Int
        var end: Int
        var sdnnMs: Double
    }

    /// Strap SDNN and Watch SDNN over one Watch reading's window, ms.
    struct HRVPair: Equatable {
        var strap: Double
        var watch: Double
    }

    /// Where a night's window came from, best first.
    enum WindowSource: String, Equatable {
        /// The Watch's own asleep span.
        case watch
        /// The strap's sleep session.
        case strap
        /// 23:00 to 07:00 local, when neither recorded the night.
        case fixed
    }

    struct Night: Equatable {
        /// The evening the night starts on.
        var night: Date
        var source: WindowSource
        var start: Int
        var end: Int

        // Strap on its own.
        var strapHRCount = 0
        /// Fraction of the window's minutes holding at least one strap HR sample.
        var coverage = 0.0
        var gapCount = 0
        var longestGapSec = 0
        var rrCount = 0
        var rrClean = 0
        var rmssd: Double?
        var sdnn: Double?

        // Against the Watch.
        var watchHRCount = 0
        var hrPairs = 0
        /// Strap minus Watch, bpm.
        var hrBias: Double?
        var hrMAE: Double?
        var watchHRVCount = 0
        /// Strap and Watch SDNN over the same window.
        var hrvPairs: [HRVPair] = []

        // SpO₂: the strap's unvalidated `spo2_candidate_82` against the Watch's own readings, each as its
        // mean over the window. Two night means, not paired samples: the strap byte is duty-cycled and the
        // Watch reads a few times a night, so their moments rarely meet.
        var strapSpO2Count = 0
        var strapSpO2: Double?
        var watchSpO2Count = 0
        var watchSpO2: Double?

        var hrvBias: Double? { Self.mean(hrvPairs.map { $0.strap - $0.watch }) }
        var hrvMAE: Double? { Self.mean(hrvPairs.map { abs($0.strap - $0.watch) }) }
        var hasWatch: Bool { watchHRCount > 0 || watchHRVCount > 0 }
        var hasStrap: Bool { strapHRCount > 0 || rrCount > 0 }

        static func mean(_ xs: [Double]) -> Double? {
            xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
        }
    }

    /// One SpO₂ reading, percent. Strap candidates outside this band are the byte's off-window zeros or noise,
    /// the same in-band rule `AnalyticsEngine.nightlySpo2CandidateMean` applies.
    static let spo2Band = 70.0...100.0

    /// A gap in strap HR longer than this counts.
    static let gapSec = 300
    /// A Watch HR sample pairs with the strap's median within this many seconds either side.
    static let pairSec = 30
    /// Clean strap beats a Watch HRV window needs before its SDNN is compared. Above `HRVAnalyzer.minBeats`
    /// because one minute is short: twenty beats would be a third of it.
    static let hrvMinBeats = 30

    // MARK: Nights

    /// The evening a moment belongs to: anything before noon is the previous day's night.
    static func nightOf(_ ts: Int, calendar: Calendar) -> Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts - 12 * 3600)))
    }

    /// The `count` most recent nights that began at least twelve hours before `now`, oldest first, each with
    /// its window: the Watch's asleep span, else the longest strap sleep session, else 23:00 to 07:00.
    static func windows(count: Int, now: Date, watchAsleep: [(start: Int, end: Int)],
                        strapSleeps: [(start: Int, end: Int)],
                        calendar: Calendar) -> [(night: Date, source: WindowSource, start: Int, end: Int)] {
        var watch: [Date: (Int, Int)] = [:]
        for s in watchAsleep {
            let n = nightOf(s.start, calendar: calendar)
            let cur = watch[n] ?? (s.start, s.end)
            watch[n] = (min(cur.0, s.start), max(cur.1, s.end))
        }
        var strap: [Date: (Int, Int)] = [:]
        for s in strapSleeps {
            let n = nightOf(s.start, calendar: calendar)
            if let cur = strap[n], cur.1 - cur.0 >= s.end - s.start { continue }
            strap[n] = (s.start, s.end)
        }
        let last = nightOf(Int(now.timeIntervalSince1970) - 12 * 3600, calendar: calendar)
        return (0..<max(count, 0)).reversed().compactMap { back in
            guard let n = calendar.date(byAdding: .day, value: -back, to: last) else { return nil }
            if let w = watch[n] { return (n, .watch, w.0, w.1) }
            if let s = strap[n] { return (n, .strap, s.0, s.1) }
            guard let eleven = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: n) else { return nil }
            let start = Int(eleven.timeIntervalSince1970)
            return (n, .fixed, start, start + 8 * 3600)
        }
    }

    // MARK: One night

    /// Compare one night. Every input may hold samples outside `start..<end`; they are ignored. `strapRR`
    /// must already be the store's scored read (one transport, suspect beats dropped).
    static func compare(night: Date, source: WindowSource, start: Int, end: Int,
                        strapHR: [HRSample], strapRR: [RRInterval],
                        watchHR: [HRSample], watchHRV: [HRVReading],
                        strapSpO2: [(ts: Int, pct: Double)] = [],
                        watchSpO2: [(ts: Int, pct: Double)] = []) -> Night {
        var out = Night(night: night, source: source, start: start, end: end)
        let hr = strapHR.filter { $0.ts >= start && $0.ts < end }.sorted { $0.ts < $1.ts }
        let rr = strapRR.filter { $0.ts >= start && $0.ts < end }

        out.strapHRCount = hr.count
        let minutes = max(1, (end - start) / 60)
        out.coverage = min(1, Double(Set(hr.map { ($0.ts - start) / 60 }).count) / Double(minutes))
        let points = [start] + hr.map(\.ts) + [end]
        let gaps = zip(points, points.dropFirst()).map { $1 - $0 }.filter { $0 > gapSec }
        out.gapCount = gaps.count
        out.longestGapSec = gaps.max() ?? 0

        let hrv = HRVAnalyzer.analyze(rr)
        out.rrCount = rr.count
        out.rrClean = hrv.nClean
        out.rmssd = hrv.rmssd
        out.sdnn = hrv.sdnn

        // HR: each Watch sample against the median of the strap within `pairSec`, found by binary search.
        let ts = hr.map(\.ts)
        var diffs: [Double] = []
        let watchInNight = watchHR.filter { $0.ts >= start && $0.ts < end }
        out.watchHRCount = watchInNight.count
        for w in watchInNight {
            var i = lowerBound(ts, w.ts - pairSec)
            var near: [Int] = []
            while i < hr.count, hr[i].ts <= w.ts + pairSec { near.append(hr[i].bpm); i += 1 }
            guard !near.isEmpty else { continue }
            diffs.append(median(near) - Double(w.bpm))
        }
        out.hrPairs = diffs.count
        out.hrBias = Night.mean(diffs)
        out.hrMAE = Night.mean(diffs.map(abs))

        // HRV: strap SDNN over each Watch reading's own window.
        let readings = watchHRV.filter { $0.start >= start && $0.start < end }
        out.watchHRVCount = readings.count
        for r in readings {
            let seg = HRVAnalyzer.analyze(rr, windowStart: r.start, windowEnd: r.end)
            guard seg.nClean >= hrvMinBeats, let s = seg.sdnn else { continue }
            out.hrvPairs.append(HRVPair(strap: s, watch: r.sdnnMs))
        }

        let strapO2 = strapSpO2.filter { $0.ts >= start && $0.ts < end && spo2Band.contains($0.pct) }.map(\.pct)
        let watchO2 = watchSpO2.filter { $0.ts >= start && $0.ts < end && spo2Band.contains($0.pct) }.map(\.pct)
        out.strapSpO2Count = strapO2.count
        out.strapSpO2 = Night.mean(strapO2)
        out.watchSpO2Count = watchO2.count
        out.watchSpO2 = Night.mean(watchO2)
        return out
    }

    // MARK: Summary

    struct Summary: Equatable {
        var nights = 0
        var nightsBoth = 0
        var meanCoverage: Double?
        var hrPairs = 0
        var hrBias: Double?
        var hrMAE: Double?
        var hrvPairs = 0
        var hrvBias: Double?
        var hrvMAE: Double?
        /// Nights where both the strap candidate and the Watch read SpO₂.
        var spo2Nights = 0
        var spo2Bias: Double?
        var spo2MAE: Double?
        /// Pearson r of the night means, from `minSpO2NightsForR` nights on.
        var spo2R: Double?
        /// Highest minus lowest Watch night mean: without spread, r says nothing about tracking.
        var spo2WatchSpread: Double?
    }

    /// Fewer nights than this give no correlation: two points always lie on a line.
    static let minSpO2NightsForR = 5

    /// Pooled over every pair, so a night with many readings weighs more than one with few.
    static func summarize(_ nights: [Night]) -> Summary {
        var s = Summary()
        s.nights = nights.count
        let both = nights.filter { $0.hasWatch && $0.hasStrap }
        s.nightsBoth = both.count
        s.meanCoverage = Night.mean(nights.filter(\.hasStrap).map(\.coverage))
        s.hrPairs = both.reduce(0) { $0 + $1.hrPairs }
        if s.hrPairs > 0 {
            s.hrBias = both.reduce(0) { $0 + ($1.hrBias ?? 0) * Double($1.hrPairs) } / Double(s.hrPairs)
            s.hrMAE = both.reduce(0) { $0 + ($1.hrMAE ?? 0) * Double($1.hrPairs) } / Double(s.hrPairs)
        }
        let pairs = both.flatMap(\.hrvPairs)
        s.hrvPairs = pairs.count
        s.hrvBias = Night.mean(pairs.map { $0.strap - $0.watch })
        s.hrvMAE = Night.mean(pairs.map { abs($0.strap - $0.watch) })

        let o2 = nights.compactMap { n -> (Double, Double)? in
            guard let a = n.strapSpO2, let b = n.watchSpO2 else { return nil }
            return (a, b)
        }
        s.spo2Nights = o2.count
        s.spo2Bias = Night.mean(o2.map { $0.0 - $0.1 })
        s.spo2MAE = Night.mean(o2.map { abs($0.0 - $0.1) })
        if let lo = o2.map(\.1).min(), let hi = o2.map(\.1).max() { s.spo2WatchSpread = hi - lo }
        if o2.count >= minSpO2NightsForR { s.spo2R = pearson(o2) }
        return s
    }

    /// nil when either side does not vary (r is undefined there).
    static func pearson(_ xy: [(Double, Double)]) -> Double? {
        guard xy.count >= 2 else { return nil }
        let n = Double(xy.count)
        let mx = xy.reduce(0) { $0 + $1.0 } / n, my = xy.reduce(0) { $0 + $1.1 } / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in xy {
            sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx); syy += (y - my) * (y - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    // MARK: Why no night has both

    /// What one Health sample type returned over the loaded range, at each step of the Watch filter.
    struct SampleCount: Equatable {
        /// Everything the query returned, NOOP's own write-backs included.
        var total = 0
        /// Written by any source other than NOOP. HealthKit always returns an app's own samples, even with
        /// read access denied, so only these say anything about read access.
        var foreign = 0
        /// Recorded on an Apple Watch: what the comparison uses.
        var watch = 0
    }

    /// The four Health types the comparison reads, counted over the whole loaded range.
    struct SourceTally: Equatable {
        var heartRate = SampleCount()
        var hrv = SampleCount()
        var spo2 = SampleCount()
        var sleep = SampleCount()
        /// Distinct labels of the foreign samples the Watch filter dropped, from `sourceLabel`.
        var droppedSources: [String] = []

        var all: [SampleCount] { [heartRate, hrv, spo2, sleep] }
    }

    /// Why the screen has no night with both devices, as far as the counts can attribute it.
    enum WatchDataGap: Equatable {
        /// Health returned no sample from any other source for any of the four types. A denied read looks
        /// exactly like this, since HealthKit answers it with an empty result rather than an error; so does
        /// a Health database with nothing in it, which is why the screen says "probably".
        case noReadAccess
        /// Other sources wrote samples, but none was recorded on an Apple Watch.
        case noWatchSamples(sources: [String])
        /// Watch samples exist, but none falls in a night the strap also recorded.
        case noOverlap
    }

    /// nil once at least one night has both devices: the screen then has nothing to explain.
    static func diagnose(_ tally: SourceTally, nightsBoth: Int) -> WatchDataGap? {
        guard nightsBoth == 0 else { return nil }
        if tally.all.allSatisfy({ $0.foreign == 0 }) { return .noReadAccess }
        if tally.all.allSatisfy({ $0.watch == 0 }) { return .noWatchSamples(sources: tally.droppedSources) }
        return .noOverlap
    }

    /// Most dropped-source labels the screen lists; the rest only matter in a count.
    static let maxDroppedSources = 8

    /// "Name · product · model" for one sample's source, without the parts HealthKit left empty, so the
    /// Watch filter's inputs (`productType` prefix "Watch", or device model "Watch") can be checked by eye.
    static func sourceLabel(name: String, productType: String?, deviceModel: String?) -> String {
        var parts = [name.trimmingCharacters(in: .whitespaces)]
        for p in [productType, deviceModel] {
            if let p = p?.trimmingCharacters(in: .whitespaces), !p.isEmpty, !parts.contains(p) { parts.append(p) }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Distinct labels in first-seen order, capped at `maxDroppedSources`.
    static func distinctSources(_ labels: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for l in labels where !l.isEmpty && seen.insert(l).inserted {
            out.append(l)
            if out.count == maxDroppedSources { break }
        }
        return out
    }

    // MARK: Helpers

    private static func lowerBound(_ xs: [Int], _ x: Int) -> Int {
        var lo = 0, hi = xs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if xs[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func median(_ xs: [Int]) -> Double {
        let s = xs.sorted()
        return s.count % 2 == 1 ? Double(s[s.count / 2]) : Double(s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
