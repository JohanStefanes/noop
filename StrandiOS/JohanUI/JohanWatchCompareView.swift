#if os(iOS)
import HealthKit
import SwiftUI
import WhoopProtocol

/// Reads the last nights of strap data from the store and the Apple Watch's own samples from HealthKit,
/// and runs `JohanWatchCompare` over each night.
///
/// Watch samples only: NOOP writes its own heart rate and sleep back into Health, so anything this app
/// authored is dropped, and of the rest only samples recorded on an Apple Watch count. Uses the read access
/// the Health connection already holds (heart rate, HRV, sleep, blood oxygen), so it asks for nothing new.
@MainActor
final class JohanWatchCompareModel: ObservableObject {
    @Published private(set) var nights: [JohanWatchCompare.Night] = []
    @Published private(set) var summary = JohanWatchCompare.Summary()
    @Published private(set) var loaded = false

    static let nightCount = 14
    private let store = HKHealthStore()

    func load(repo: Repository) async {
        let now = Date()
        let from = now.addingTimeInterval(-Double(Self.nightCount + 2) * 86_400)
        async let hr = watchHR(from: from, to: now)
        async let hrv = watchHRV(from: from, to: now)
        async let asleep = watchAsleep(from: from, to: now)
        async let spo2 = watchSpO2(from: from, to: now)
        let (watchHR, watchHRV, watchAsleep, watchSpO2) = await (hr, hrv, asleep, spo2)

        let windows = JohanWatchCompare.windows(
            count: Self.nightCount, now: now, watchAsleep: watchAsleep,
            strapSleeps: repo.sleeps.map { (start: $0.effectiveStartTs, end: $0.endTs) },
            calendar: .current)
        var out: [JohanWatchCompare.Night] = []
        for w in windows {
            // A night at 1 Hz is ~30k HR rows and as many beats; the limits only guard a runaway window.
            let strapHR = await repo.hrSamples(from: w.start, to: w.end, limit: 80_000)
            let strapRR = await repo.rrIntervals(from: w.start, to: w.end, limit: 120_000)
            // The strap keeps about a week of these seconds, so older nights simply have none.
            let strapSpO2 = await repo.v18AuxByte82(from: w.start, to: w.end)
                .map { (ts: $0.ts, pct: Double($0.value)) }
            let night = await Task.detached(priority: .userInitiated) {
                JohanWatchCompare.compare(night: w.night, source: w.source, start: w.start, end: w.end,
                                          strapHR: strapHR, strapRR: strapRR,
                                          watchHR: watchHR, watchHRV: watchHRV,
                                          strapSpO2: strapSpO2, watchSpO2: watchSpO2)
            }.value
            out.append(night)
        }
        nights = out
        summary = JohanWatchCompare.summarize(out)
        loaded = true
    }

    // MARK: HealthKit

    /// Recorded on an Apple Watch and not written by this app.
    nonisolated private static func isWatch(_ sample: HKSample) -> Bool {
        if sample.sourceRevision.source == HKSource.default() { return false }
        if let product = sample.sourceRevision.productType, product.hasPrefix("Watch") { return true }
        return sample.device?.model == "Watch"
    }

    private func samples(_ type: HKSampleType, from: Date, to: Date) async -> [HKSample] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return await withCheckedContinuation { (cont: CheckedContinuation<[HKSample], Never>) in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [sort]) { _, samples, _ in
                cont.resume(returning: (samples ?? []).filter(Self.isWatch))
            }
            store.execute(query)
        }
    }

    private func watchHR(from: Date, to: Date) async -> [HRSample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }
        let unit = HKUnit.count().unitDivided(by: .minute())
        return await samples(type, from: from, to: to).compactMap { s in
            guard let q = s as? HKQuantitySample else { return nil }
            let bpm = q.quantity.doubleValue(for: unit)
            guard bpm.isFinite, bpm >= 25, bpm <= 240 else { return nil }
            return HRSample(ts: Int(q.startDate.timeIntervalSince1970), bpm: Int(bpm.rounded()))
        }
    }

    private func watchHRV(from: Date, to: Date) async -> [JohanWatchCompare.HRVReading] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return [] }
        let ms = HKUnit.secondUnit(with: .milli)
        return await samples(type, from: from, to: to).compactMap { s in
            guard let q = s as? HKQuantitySample else { return nil }
            let v = q.quantity.doubleValue(for: ms)
            guard v.isFinite, v > 0 else { return nil }
            return .init(start: Int(q.startDate.timeIntervalSince1970),
                         end: Int(q.endDate.timeIntervalSince1970), sdnnMs: v)
        }
    }

    /// Blood oxygen readings, percent (HealthKit stores 0…1).
    private func watchSpO2(from: Date, to: Date) async -> [(ts: Int, pct: Double)] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) else { return [] }
        return await samples(type, from: from, to: to).compactMap { s in
            guard let q = s as? HKQuantitySample else { return nil }
            let pct = q.quantity.doubleValue(for: .percent()) * 100
            guard pct.isFinite else { return nil }
            return (ts: Int(q.startDate.timeIntervalSince1970), pct: pct)
        }
    }

    private func watchAsleep(from: Date, to: Date) async -> [(start: Int, end: Int)] {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        return await samples(type, from: from, to: to).compactMap { s in
            guard let c = s as? HKCategorySample, asleep.contains(c.value) else { return nil }
            return (Int(c.startDate.timeIntervalSince1970), Int(c.endDate.timeIntervalSince1970))
        }
    }
}

/// "MG vs Watch": Phase 1 of the roadmap on the phone. How completely the strap recorded each night, and how
/// far its heart rate and HRV sit from the Apple Watch worn the same night.
struct JohanWatchCompareView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.johanReloadTick) private var reloadTick
    @StateObject private var model = JohanWatchCompareModel()

    var body: some View {
        JohanScreen(title: String(localized: "MG vs Watch")) {
            if !model.loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                summaryCard
                if model.summary.nightsBoth == 0 { emptyHint }
                spo2Card
                JohanOverline(String(localized: "Nights")).padding(.top, 8)
                ForEach(model.nights.reversed(), id: \.night) { nightCard($0) }
                Text("The Watch measures HRV as SDNN over about a minute, a few times a night. Each reading is compared with the strap's SDNN over the same minute, not with its overnight RMSSD.")
                    .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
            }
        }
        .task(id: reloadTick) { await model.load(repo: repo) }
        .onReceive(repo.$days.dropFirst()) { _ in Task { await model.load(repo: repo) } }
    }

    // MARK: Summary

    private var summaryCard: some View {
        let s = model.summary
        return JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(s.nightsBoth) of \(s.nights) nights with both")
                    .font(JohanTheme.Fonts.title).foregroundStyle(JohanTheme.textPrimary)
                JohanAdaptiveStack(spacing: 16) {
                    stat(String(localized: "Coverage"), percent(s.meanCoverage), note: String(localized: "strap, per night"))
                    stat(String(localized: "Heart rate"), signed(s.hrBias, unit: "bpm"),
                         note: String(localized: "\(s.hrPairs) pairs, ±\(number(s.hrMAE))"))
                    stat("HRV", signed(s.hrvBias, unit: "ms"),
                         note: String(localized: "\(s.hrvPairs) pairs, ±\(number(s.hrvMAE))"))
                }
                Text("Average difference, strap minus Watch. ± is the average size of the difference.")
                    .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
            }
        }
    }

    /// Whether the strap's SpO₂ candidate follows the Watch from night to night. The candidate is an
    /// unvalidated byte, so this card is evidence-gathering, and says so until enough varied nights exist.
    private var spo2Card: some View {
        let s = model.summary
        let need = JohanWatchCompare.minSpO2NightsForR
        return JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Blood oxygen (strap estimate)").font(JohanTheme.Fonts.title).foregroundStyle(JohanTheme.textPrimary)
                JohanAdaptiveStack(spacing: 16) {
                    stat(String(localized: "Nights"), "\(s.spo2Nights)", note: String(localized: "strap and Watch"))
                    stat(String(localized: "Difference"), signed(s.spo2Bias, unit: "%"),
                         note: String(localized: "±\(number(s.spo2MAE))"))
                    stat("r", s.spo2R.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "–",
                         note: String(localized: "Watch spread \(number(s.spo2WatchSpread)) %"))
                }
                Text(spo2Verdict(s, need: need))
                    .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The strap value is an unconfirmed reading of one byte the strap sends during sleep. It stays an estimate until it follows the Watch over many nights.")
                    .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func spo2Verdict(_ s: JohanWatchCompare.Summary, need: Int) -> String {
        if s.spo2Nights < need {
            return String(localized: "\(s.spo2Nights) of \(need) nights so far. Turn on Blood Oxygen on the Watch and wear both overnight.")
        }
        if (s.spo2WatchSpread ?? 0) < 2 {
            return String(localized: "Your Watch values barely change from night to night, so r cannot show yet whether the strap follows them. Only the difference says something so far.")
        }
        guard let r = s.spo2R else { return String(localized: "Not enough variation to compare yet.") }
        if r >= 0.7 { return String(localized: "The strap follows the Watch closely so far.") }
        if r >= 0.4 { return String(localized: "The strap follows the Watch only loosely so far.") }
        return String(localized: "The strap does not follow the Watch so far.")
    }

    private var emptyHint: some View {
        JohanCard {
            Text("No night with both devices yet. Wear the Apple Watch with sleep tracking on beside the strap, and the comparison fills in here each morning.")
                .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
        }
    }

    private func stat(_ title: String, _ value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
            Text(value).johanNumberFont(22).foregroundStyle(JohanTheme.textPrimary)
            Text(note).font(JohanTheme.Fonts.unit).foregroundStyle(JohanTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: One night

    private func nightCard(_ n: JohanWatchCompare.Night) -> some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(n.night.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(JohanTheme.Fonts.title).foregroundStyle(JohanTheme.textPrimary)
                    Spacer()
                    Text(windowLabel(n)).font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
                }
                if !n.hasStrap {
                    line("waveform.path.ecg", String(localized: "No strap data"), tint: JohanTheme.recoveryRed)
                } else {
                    line("waveform.path.ecg",
                         String(localized: "Strap \(percent(n.coverage)) covered, \(n.gapCount) gaps (longest \(n.longestGapSec / 60) min)"),
                         tint: n.coverage >= 0.9 ? JohanTheme.textSecondary : JohanTheme.recoveryYellow)
                    line("heart.text.square",
                         String(localized: "\(n.rrClean) of \(n.rrCount) beats clean, RMSSD \(number(n.rmssd)) ms"),
                         tint: JohanTheme.textSecondary)
                }
                if n.hasWatch {
                    line("applewatch",
                         String(localized: "Heart rate \(signed(n.hrBias, unit: "bpm")) (±\(number(n.hrMAE)), \(n.hrPairs) of \(n.watchHRCount))"),
                         tint: JohanTheme.strainBlue)
                    line("applewatch",
                         String(localized: "HRV \(signed(n.hrvBias, unit: "ms")) (±\(number(n.hrvMAE)), \(n.hrvPairs.count) of \(n.watchHRVCount))"),
                         tint: JohanTheme.sleepViolet)
                } else {
                    line("applewatch", String(localized: "No Watch data"), tint: JohanTheme.textTertiary)
                }
                if n.strapSpO2 != nil || n.watchSpO2 != nil {
                    line("drop.fill",
                         String(localized: "SpO₂ strap \(number(n.strapSpO2)) %, Watch \(number(n.watchSpO2)) % (\(n.watchSpO2Count) readings)"),
                         tint: JohanTheme.recoveryRed)
                }
            }
        }
    }

    private func line(_ icon: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(JohanTheme.Fonts.caption).foregroundStyle(tint).frame(width: 18)
                .accessibilityHidden(true)
            Text(text).font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func windowLabel(_ n: JohanWatchCompare.Night) -> String {
        let span = "\(Self.clock(n.start))–\(Self.clock(n.end))"
        switch n.source {
        case .watch: return String(localized: "\(span), Watch sleep")
        case .strap: return String(localized: "\(span), strap sleep")
        case .fixed: return span
        }
    }

    // MARK: Formatting

    private static func clock(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .omitted, time: .shortened)
    }

    private func number(_ v: Double?) -> String {
        v.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–"
    }

    private func signed(_ v: Double?, unit: String) -> String {
        guard let v else { return "–" }
        return v.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) + " " + unit
    }

    private func percent(_ v: Double?) -> String {
        v.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–"
    }
}
#endif
