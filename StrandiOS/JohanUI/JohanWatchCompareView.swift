#if os(iOS)
import HealthKit
import SwiftUI
import WhoopProtocol

/// Reads the last nights of strap data from the store and the Apple Watch's own samples from HealthKit,
/// and runs `JohanWatchCompare` over each night.
///
/// Watch samples only: NOOP writes its own heart rate and sleep back into Health, so anything this app
/// authored is dropped, and of the rest only samples recorded on an Apple Watch count. Uses the read access
/// the Health connection already holds (heart rate, HRV, sleep, blood oxygen); when the screen finds none, its
/// hint re-runs that connection's own request rather than asking for anything new.
@MainActor
final class JohanWatchCompareModel: ObservableObject {
    @Published private(set) var nights: [JohanWatchCompare.Night] = []
    @Published private(set) var summary = JohanWatchCompare.Summary()
    @Published private(set) var loaded = false
    /// Why no night has both devices; nil once one does.
    @Published private(set) var gap: JohanWatchCompare.WatchDataGap?

    static let nightCount = 14
    private let store = HKHealthStore()

    func load(repo: Repository) async {
        let now = Date()
        let from = now.addingTimeInterval(-Double(Self.nightCount + 2) * 86_400)
        async let hrRaw = samples(HKQuantityType.quantityType(forIdentifier: .heartRate), from: from, to: now)
        async let hrvRaw = samples(HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
                                   from: from, to: now)
        async let sleepRaw = samples(HKCategoryType.categoryType(forIdentifier: .sleepAnalysis), from: from, to: now)
        async let spo2Raw = samples(HKQuantityType.quantityType(forIdentifier: .oxygenSaturation), from: from, to: now)
        let (hrAll, hrvAll, sleepAll, spo2All) = await (hrRaw, hrvRaw, sleepRaw, spo2Raw)

        // Counted before the Watch filter, so an empty screen can say which step emptied it.
        var tally = JohanWatchCompare.SourceTally(
            heartRate: Self.count(hrAll), hrv: Self.count(hrvAll),
            spo2: Self.count(spo2All), sleep: Self.count(sleepAll))
        tally.droppedSources = JohanWatchCompare.distinctSources(
            (hrAll + hrvAll + spo2All + sleepAll).lazy.filter { !Self.isOwn($0) && !Self.isWatch($0) }.map(Self.label))

        let watchHR = Self.heartRate(hrAll.filter(Self.isWatch))
        let watchHRV = Self.hrv(hrvAll.filter(Self.isWatch))
        let watchAsleep = Self.asleep(sleepAll.filter(Self.isWatch))
        let watchSpO2 = Self.spo2(spo2All.filter(Self.isWatch))

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
        gap = JohanWatchCompare.diagnose(tally, nightsBoth: summary.nightsBoth)
        loaded = true
    }

    // MARK: HealthKit

    /// Written by this app: NOOP's own heart rate and sleep write-backs.
    nonisolated private static func isOwn(_ sample: HKSample) -> Bool {
        sample.sourceRevision.source == HKSource.default()
    }

    /// Recorded on an Apple Watch and not written by this app.
    nonisolated private static func isWatch(_ sample: HKSample) -> Bool {
        if isOwn(sample) { return false }
        if let product = sample.sourceRevision.productType, product.hasPrefix("Watch") { return true }
        return sample.device?.model == "Watch"
    }

    nonisolated private static func label(_ sample: HKSample) -> String {
        JohanWatchCompare.sourceLabel(name: sample.sourceRevision.source.name,
                                      productType: sample.sourceRevision.productType,
                                      deviceModel: sample.device?.model)
    }

    nonisolated private static func count(_ samples: [HKSample]) -> JohanWatchCompare.SampleCount {
        var c = JohanWatchCompare.SampleCount(total: samples.count)
        for s in samples where !isOwn(s) {
            c.foreign += 1
            if isWatch(s) { c.watch += 1 }
        }
        return c
    }

    /// Every sample in the range, unfiltered. A denied read returns an empty list here, not an error.
    private func samples(_ type: HKSampleType?, from: Date, to: Date) async -> [HKSample] {
        guard let type, HKHealthStore.isHealthDataAvailable() else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return await withCheckedContinuation { (cont: CheckedContinuation<[HKSample], Never>) in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [sort]) { _, samples, _ in
                cont.resume(returning: samples ?? [])
            }
            store.execute(query)
        }
    }

    private static func heartRate(_ samples: [HKSample]) -> [HRSample] {
        let unit = HKUnit.count().unitDivided(by: .minute())
        return samples.compactMap { s in
            guard let q = s as? HKQuantitySample else { return nil }
            let bpm = q.quantity.doubleValue(for: unit)
            guard bpm.isFinite, bpm >= 25, bpm <= 240 else { return nil }
            return HRSample(ts: Int(q.startDate.timeIntervalSince1970), bpm: Int(bpm.rounded()))
        }
    }

    private static func hrv(_ samples: [HKSample]) -> [JohanWatchCompare.HRVReading] {
        let ms = HKUnit.secondUnit(with: .milli)
        return samples.compactMap { s in
            guard let q = s as? HKQuantitySample else { return nil }
            let v = q.quantity.doubleValue(for: ms)
            guard v.isFinite, v > 0 else { return nil }
            return .init(start: Int(q.startDate.timeIntervalSince1970),
                         end: Int(q.endDate.timeIntervalSince1970), sdnnMs: v)
        }
    }

    /// Blood oxygen readings, percent (HealthKit stores 0…1).
    private static func spo2(_ samples: [HKSample]) -> [(ts: Int, pct: Double)] {
        samples.compactMap { s in
            guard let q = s as? HKQuantitySample else { return nil }
            let pct = q.quantity.doubleValue(for: .percent()) * 100
            guard pct.isFinite else { return nil }
            return (ts: Int(q.startDate.timeIntervalSince1970), pct: pct)
        }
    }

    private static func asleep(_ samples: [HKSample]) -> [(start: Int, end: Int)] {
        let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        return samples.compactMap { s in
            guard let c = s as? HKCategorySample, asleep.contains(c.value) else { return nil }
            return (Int(c.startDate.timeIntervalSince1970), Int(c.endDate.timeIntervalSince1970))
        }
    }
}

/// "MG vs Watch": Phase 1 of the roadmap on the phone. How completely the strap recorded each night, and how
/// far its heart rate and HRV sit from the Apple Watch worn the same night.
///
/// Answer first: three coloured verdicts and a table of nights. Offsets, pair counts and the method sit
/// behind "Details" toggles, so the screen reads at a glance and still keeps every figure one tap away.
struct JohanWatchCompareView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var health: HealthKitBridge
    @Environment(\.johanReloadTick) private var reloadTick
    @StateObject private var model = JohanWatchCompareModel()
    @State private var openNights: Set<Date> = []
    @State private var summaryDetails = false
    @State private var spo2Details = false
    @State private var gapDetails = false
    @State private var methodDetails = false

    var body: some View {
        JohanScreen(title: String(localized: "MG vs Watch")) {
            if !model.loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                if let gap = model.gap { gapHint(gap) }
                summaryCard
                JohanOverline(String(localized: "Nights")).padding(.top, 8)
                nightsTable
                spo2Card
                methodNote
            }
        }
        .task(id: reloadTick) { await model.load(repo: repo) }
        .onReceive(repo.$days.dropFirst()) { _ in Task { await model.load(repo: repo) } }
    }

    // MARK: Summary

    private var summaryCard: some View {
        let s = model.summary
        return JohanCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(s.nightsBoth) of \(s.nights) nights with both")
                    .font(JohanTheme.Fonts.title).foregroundStyle(JohanTheme.textPrimary)
                verdictRow("heart.fill", String(localized: "Heart rate"), plusMinus(s.hrMAE, unit: "bpm"),
                           JohanWatchCompare.hrAgreement(s.hrMAE))
                verdictRow("waveform.path.ecg", "HRV", plusMinus(s.hrvMAE, unit: "ms"),
                           JohanWatchCompare.hrvAgreement(s.hrvMAE))
                verdictRow("dot.radiowaves.left.and.right", String(localized: "Coverage"), percent(s.meanCoverage),
                           JohanWatchCompare.coverageAgreement(s.meanCoverage))
                Text("± is how far the strap sits from the Watch on average.")
                    .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                detailsToggle($summaryDetails)
                if summaryDetails {
                    VStack(alignment: .leading, spacing: 6) {
                        line("heart.fill", String(localized: "Heart rate \(signed(s.hrBias, unit: "bpm")), \(s.hrPairs) pairs"),
                             tint: JohanTheme.strainBlue)
                        line("waveform.path.ecg", String(localized: "HRV \(signed(s.hrvBias, unit: "ms")), \(s.hrvPairs) pairs"),
                             tint: JohanTheme.sleepViolet)
                        Text("Average difference, strap minus Watch.")
                            .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func verdictRow(_ icon: String, _ title: String, _ value: String,
                            _ agreement: JohanWatchCompare.Agreement?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).font(.system(.subheadline)).foregroundStyle(tint(agreement))
                .frame(width: 22).accessibilityHidden(true)
            Text(title).font(.system(.subheadline)).foregroundStyle(JohanTheme.textSecondary)
            Spacer(minLength: 8)
            Text(value).johanNumberFont(20).foregroundStyle(JohanTheme.textPrimary)
            agreementPill(agreement)
        }
        .accessibilityElement(children: .combine)
    }

    private func agreementPill(_ a: JohanWatchCompare.Agreement?) -> some View {
        Text(agreementLabel(a))
            .font(JohanTheme.Fonts.unit).foregroundStyle(a == nil ? JohanTheme.textTertiary : tint(a))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(tint(a).opacity(a == nil ? 0 : 0.16)))
            .frame(minWidth: 64, alignment: .trailing)
    }

    // MARK: Nights

    private var nightsTable: some View {
        JohanCard(padding: 12) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    column(String(localized: "Pulse"))
                    column("HRV")
                    column(String(localized: "Coverage"))
                    Color.clear.frame(width: 14)
                }
                .font(JohanTheme.Fonts.unit).foregroundStyle(JohanTheme.textTertiary)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
                ForEach(Array(model.nights.reversed().enumerated()), id: \.element.night) { i, n in
                    if i > 0 { Divider().overlay(JohanTheme.cardBorder) }
                    nightRow(n)
                }
            }
        }
    }

    private func column(_ text: String) -> some View {
        Text(text).lineLimit(1).minimumScaleFactor(0.7).frame(width: 64, alignment: .trailing)
    }

    private func nightRow(_ n: JohanWatchCompare.Night) -> some View {
        let open = openNights.contains(n.night)
        let empty = !n.hasStrap && !n.hasWatch
        let coverage = n.hasStrap ? n.coverage : nil
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) {
                    if open { openNights.remove(n.night) } else { openNights.insert(n.night) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(n.night.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(empty ? JohanTheme.textTertiary : JohanTheme.textPrimary)
                    Spacer(minLength: 0)
                    cell(plusMinus(n.hrMAE, unit: nil), JohanWatchCompare.hrAgreement(n.hrMAE))
                    cell(plusMinus(n.hrvMAE, unit: nil), JohanWatchCompare.hrvAgreement(n.hrvMAE))
                    cell(percent(coverage), JohanWatchCompare.coverageAgreement(coverage))
                    Image(systemName: "chevron.down")
                        .font(.system(.caption2, weight: .semibold)).foregroundStyle(JohanTheme.textTertiary)
                        .rotationEffect(.degrees(open ? 180 : 0)).frame(width: 14)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(nightAccessibility(n, coverage: coverage))
            .accessibilityHint(String(localized: "Details"))
            if open { nightDetails(n).padding(.bottom, 10) }
        }
    }

    private func cell(_ value: String, _ a: JohanWatchCompare.Agreement?) -> some View {
        HStack(spacing: 4) {
            Circle().fill(a == nil ? Color.clear : tint(a)).frame(width: 6, height: 6)
            Text(value).johanNumberFont(15).foregroundStyle(a == nil ? JohanTheme.textTertiary : JohanTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 64, alignment: .trailing)
    }

    /// What the row leaves out: window, gaps, beats, offsets and SpO₂.
    private func nightDetails(_ n: JohanWatchCompare.Night) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            line("clock", windowLabel(n), tint: JohanTheme.textTertiary)
            if !n.hasStrap {
                line("waveform.path.ecg", String(localized: "No strap data"), tint: JohanTheme.recoveryRed)
            } else {
                line("waveform.path.ecg",
                     String(localized: "\(n.gapCount) gaps, longest \(n.longestGapSec / 60) min"),
                     tint: n.coverage >= 0.9 ? JohanTheme.textSecondary : JohanTheme.recoveryYellow)
                line("heart.text.square",
                     String(localized: "\(n.rrClean) of \(n.rrCount) beats clean, RMSSD \(number(n.rmssd)) ms"),
                     tint: JohanTheme.textSecondary)
            }
            if n.hasWatch {
                line("applewatch",
                     String(localized: "Heart rate \(signed(n.hrBias, unit: "bpm")) (\(n.hrPairs) of \(n.watchHRCount))"),
                     tint: JohanTheme.strainBlue)
                line("applewatch",
                     String(localized: "HRV \(signed(n.hrvBias, unit: "ms")) (\(n.hrvPairs.count) of \(n.watchHRVCount))"),
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
        .padding(.leading, 2)
    }

    private func nightAccessibility(_ n: JohanWatchCompare.Night, coverage: Double?) -> String {
        let date = n.night.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let parts = [date,
                     String(localized: "Heart rate") + " " + plusMinus(n.hrMAE, unit: "bpm"),
                     "HRV " + plusMinus(n.hrvMAE, unit: "ms"),
                     String(localized: "Coverage") + " " + percent(coverage)]
        return parts.joined(separator: ", ")
    }

    // MARK: SpO₂

    /// Whether the strap's SpO₂ candidate follows the Watch from night to night. The candidate is an
    /// unvalidated byte, so this card is evidence-gathering, and says so until enough varied nights exist.
    private var spo2Card: some View {
        let s = model.summary
        let need = JohanWatchCompare.minSpO2NightsForR
        return JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Blood oxygen (strap estimate)").font(JohanTheme.Fonts.title).foregroundStyle(JohanTheme.textPrimary)
                JohanAdaptiveStack(spacing: 16) {
                    stat(String(localized: "Nights"), "\(min(s.spo2Nights, need)) / \(need)")
                    stat(String(localized: "Difference"), plusMinus(s.spo2MAE, unit: "%"))
                }
                if s.spo2Nights < need {
                    ProgressView(value: Double(s.spo2Nights), total: Double(need)).tint(JohanTheme.recoveryRed)
                }
                Text(spo2Verdict(s, need: need))
                    .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                detailsToggle($spo2Details)
                if spo2Details {
                    VStack(alignment: .leading, spacing: 6) {
                        line("drop.fill", String(localized: "Difference \(signed(s.spo2Bias, unit: "%")), r \(s.spo2R.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "–")"),
                             tint: JohanTheme.recoveryRed)
                        line("applewatch", String(localized: "Watch spread \(number(s.spo2WatchSpread)) %"),
                             tint: JohanTheme.textTertiary)
                        Text("The strap value is an unconfirmed reading of one byte the strap sends during sleep. It stays an estimate until it follows the Watch over many nights.")
                            .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func spo2Verdict(_ s: JohanWatchCompare.Summary, need: Int) -> String {
        if s.spo2Nights < need {
            return String(localized: "Turn on Blood Oxygen on the Watch and wear both overnight.")
        }
        if (s.spo2WatchSpread ?? 0) < 2 {
            return String(localized: "Your Watch values barely change from night to night, so r cannot show yet whether the strap follows them. Only the difference says something so far.")
        }
        guard let r = s.spo2R else { return String(localized: "Not enough variation to compare yet.") }
        if r >= 0.7 { return String(localized: "The strap follows the Watch closely so far.") }
        if r >= 0.4 { return String(localized: "The strap follows the Watch only loosely so far.") }
        return String(localized: "The strap does not follow the Watch so far.")
    }

    // MARK: Why no night has both

    /// One line on what is missing and what to do; the reasoning behind it sits under "Details".
    private func gapHint(_ gap: JohanWatchCompare.WatchDataGap) -> some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(JohanTheme.recoveryYellow)
                        .accessibilityHidden(true)
                    Text(gapHeadline(gap)).font(JohanTheme.Fonts.title).foregroundStyle(JohanTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch gap {
                case .noReadAccess:
                    if health.auth == .entitlementMissing {
                        Text("Apple Health returned nothing from the Watch or any other source. This build is signed without Apple Health access, so it cannot read the Watch at all.")
                            .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Button {
                            Task {
                                await health.requestAuthorization()
                                await model.load(repo: repo)
                            }
                        } label: {
                            Label("Ask for Health access", systemImage: "heart.fill")
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(JohanTheme.background)
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Capsule().fill(JohanTheme.strainBlue))
                        }
                        .buttonStyle(JohanPressStyle())
                        detailsToggle($gapDetails)
                        if gapDetails {
                            gapText("Apple Health returned nothing from the Watch or any other source over the last \(JohanWatchCompareModel.nightCount) nights. NOOP probably has no read access: Health answers a denied read with an empty list, not an error.")
                            gapText("Turn it on in Settings → Health → Data Access & Devices → NOOP, and allow reading Heart Rate, Heart Rate Variability, Sleep and Blood Oxygen.")
                            Text("Health shows its sheet only for types not yet decided. If nothing appears, use Settings.")
                                .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .noWatchSamples(let sources):
                    detailsToggle($gapDetails)
                    if gapDetails {
                        gapText("Apple Health has heart rate, HRV, sleep or blood oxygen from other sources, but none recorded on an Apple Watch, so every night stays without the Watch.")
                        if !sources.isEmpty {
                            Text("Sources seen")
                                .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
                            ForEach(sources, id: \.self) { label in
                                line("applewatch", label, tint: JohanTheme.textTertiary)
                            }
                        }
                        Text("A sample counts as the Watch's when its product type starts with \"Watch\" or its device model is \"Watch\".")
                            .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .noOverlap:
                    gapText("No night with both devices yet. Wear the Apple Watch with sleep tracking on beside the strap, and the comparison fills in here each morning.")
                }
            }
        }
    }

    private func gapHeadline(_ gap: JohanWatchCompare.WatchDataGap) -> String {
        switch gap {
        case .noReadAccess: return String(localized: "NOOP can't read Apple Health")
        case .noWatchSamples: return String(localized: "No Apple Watch data in Health")
        case .noOverlap: return String(localized: "No shared night yet")
        }
    }

    private func gapText(_ text: LocalizedStringKey) -> some View {
        Text(text).font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Method

    private var methodNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { methodDetails.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("How it's compared")
                    Image(systemName: "chevron.down").rotationEffect(.degrees(methodDetails ? 180 : 0))
                }
                .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
            }
            .buttonStyle(.plain)
            if methodDetails {
                Text("The Watch measures HRV as SDNN over about a minute, a few times a night. Each reading is compared with the strap's SDNN over the same minute, not with its overnight RMSSD.")
                    .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4).padding(.top, 4)
    }

    // MARK: Pieces

    private func detailsToggle(_ isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy) { isOn.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(isOn.wrappedValue ? "Less" : "Details")
                Image(systemName: "chevron.down").rotationEffect(.degrees(isOn.wrappedValue ? 180 : 0))
            }
            .font(.system(.caption, weight: .semibold)).foregroundStyle(JohanTheme.strainBlue)
        }
        .buttonStyle(.plain)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
            Text(value).johanNumberFont(22).foregroundStyle(JohanTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ icon: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(JohanTheme.Fonts.caption).foregroundStyle(tint).frame(width: 18)
                .accessibilityHidden(true)
            Text(text).font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tint(_ a: JohanWatchCompare.Agreement?) -> Color {
        switch a {
        case .good: return JohanTheme.recoveryGreen
        case .fair: return JohanTheme.recoveryYellow
        case .poor: return JohanTheme.recoveryRed
        case nil: return JohanTheme.textTertiary
        }
    }

    private func agreementLabel(_ a: JohanWatchCompare.Agreement?) -> String {
        switch a {
        case .good: return String(localized: "Good")
        case .fair: return String(localized: "Fair")
        case .poor: return String(localized: "Poor")
        case nil: return "–"
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

    /// "±2.1 bpm", or "–" without a value.
    private func plusMinus(_ v: Double?, unit: String?) -> String {
        guard let v else { return "–" }
        let n = "±" + v.formatted(.number.precision(.fractionLength(1)))
        return unit.map { "\(n) \($0)" } ?? n
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
