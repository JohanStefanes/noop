#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

/// "Schlaf-Coach": tonight's bedtime from sleep need + sleep debt (+ body clock), last night (heart rate,
/// hypnogram, stages against the wearer's typical), sleep consistency and the sleep-debt trend.
struct JohanSleepCoachView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @StateObject private var coach = JohanSleepCoachModel()

    var body: some View {
        JohanScreen(title: String(localized: "Sleep")) {
            if let rec = coach.recommendation {
                bedtimeCard(rec).johanStagger(0)
            } else {
                JohanPlaceholderCard(height: 200)
                JohanPlaceholderCard(height: 180)
            }
            if coach.loaded {
                nightCard.johanStagger(1)
                if let sleep = coach.sleep, sleep.consistency.latest != nil {
                    consistencyCard(sleep).johanStagger(2)
                }
                debtCard.johanStagger(3)
            }
        }
        .task { await coach.load(repo: repo, circadian: model.circadianPhase) }
        .onReceive(repo.$days.dropFirst()) { _ in
            Task { await coach.load(repo: repo, circadian: model.circadianPhase) }
        }
    }

    // MARK: Bedtime

    private func bedtimeCard(_ rec: JohanSleepCoachModel.Recommendation) -> some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                JohanOverline(String(localized: "Recommended bedtime tonight"))
                Text(clock(rec.bedtimeMinutes))
                    .johanNumberFont(56).foregroundStyle(JohanTheme.sleepViolet)
                bedtimeStats(rec)
                Text(explanation(rec)).font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                if let clockWindow = JohanSleepCoachModel.bodyClock(model.circadianPhase, durationMin: rec.targetSleepMin) {
                    Divider().overlay(JohanTheme.cardBorder)
                    JohanOverline(String(localized: "Body clock"))
                    Text(String(localized: "Ideal window \(hourText(clockWindow.idealBedHour)) to \(hourText(clockWindow.idealWakeHour)). \(clockWindow.note)"))
                        .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                }
                NavigationLink {
                    SmartAlarmView()
                        .background(JohanTheme.background.ignoresSafeArea())
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Adjust wake time & reminder", systemImage: "alarm")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(JohanTheme.sleepViolet)
                }
            }
        }
    }

    private func explanation(_ rec: JohanSleepCoachModel.Recommendation) -> String {
        if rec.nightsUsed == 0 {
            return String(localized: "No sleep data yet: the recommendation uses the default need of \(hm(rec.needMin)) and your wake time. It gets more precise once nights are recorded.")
        }
        let nights = String(rec.nightsUsed)
        if rec.paybackMin >= 1 {
            return String(localized: "Wake time minus sleep need (\(hm(rec.needMin))) plus \(hm(rec.paybackMin)) to pay down your sleep debt, based on \(nights) nights.")
        }
        return String(localized: "Wake time minus sleep need (\(hm(rec.needMin))), based on \(nights) nights.")
    }

    private func bedtimeStats(_ rec: JohanSleepCoachModel.Recommendation) -> some View {
        var items = [(String(localized: "Wake-up"), clock(rec.wakeMinutes)), (String(localized: "Target"), hm(rec.targetSleepMin)), (String(localized: "Need"), hm(rec.needMin))]
        if rec.paybackMin >= 1 { items.append((String(localized: "Debt"), "+" + hm(rec.paybackMin))) }
        return statsLayout(items)
    }

    /// One row when it fits, otherwise a two-column grid, otherwise one column (largest text sizes), so no
    /// value is ever truncated or wrapped mid-value.
    private func statsLayout(_ items: [(String, String)]) -> some View {
        let pairs = stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { ForEach(items, id: \.0) { stat($0.0, $0.1) } }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                ForEach(pairs, id: \.first!.0) { pair in
                    GridRow { ForEach(pair, id: \.0) { stat($0.0, $0.1) } }
                }
            }
            VStack(alignment: .leading, spacing: 10) { ForEach(items, id: \.0) { stat($0.0, $0.1) } }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(.caption2)).foregroundStyle(JohanTheme.textSecondary)
            Text(value).johanNumberFont(17).lineLimit(1)
        }
    }

    // MARK: Last night

    private var nightCard: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                if let sleep = coach.sleep, !sleep.isStubNight {
                    let night = sleep.night
                    JohanOverline(isRecent(night) ? String(localized: "Last night") : night.spanLabel)
                    Text(String(localized: "\(night.onsetText) – \(night.wakeText) · \(hm(night.stages.asleep)) asleep"))
                        .font(.system(.subheadline, weight: .semibold))
                    heartRate(sleep)
                    Hypnogram(intervals: sleep.intervals, height: 130, showsStageAxis: true,
                              showsHover: false, nightStart: night.onsetDate, showsTimeAxis: true, filled: true)
                        .johanRevealLeftToRight()
                    stagesVsTypical(sleep)
                } else {
                    JohanOverline(String(localized: "Last night"))
                    Text("No night recorded yet. Wear the strap overnight and your sleep will show up here.")
                        .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                }
            }
        }
    }

    /// Woken from today, so "Last night" is true; an older newest night is named by its own date instead.
    private func isRecent(_ night: Night) -> Bool {
        Calendar.current.isDateInToday(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
    }

    // MARK: Night heart rate

    @ViewBuilder
    private func heartRate(_ sleep: SleepModel) -> some View {
        let start = TimeInterval(sleep.night.session.effectiveStartTs)
        let bpms = coach.nightHR.filter { TimeInterval($0.ts) >= start }.map(\.bpm)
        if bpms.count >= 2, let low = bpms.min() {
            let intervals = sleep.intervals.sorted { $0.start < $1.start }
            let origin = intervals.first?.start ?? 0
            let span = max(1, (intervals.map(\.end).max() ?? 1) - origin)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Heart rate").font(.system(.caption, weight: .semibold)).foregroundStyle(JohanTheme.textSecondary)
                    Spacer()
                    Text(String(localized: "Lowest \(String(Int(low.rounded()))) bpm"))
                        .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                }
                SleepHRChart(nightHR: coach.nightHR, intervals: intervals, origin: origin, span: span,
                             night: sleep.night, selectedStage: nil, timeFormatter: Self.timeFormatter)
                    .frame(height: 96)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    // MARK: Stages vs typical

    /// Deep, REM and light against the wearer's own per-stage means (`SleepModel.typical*Min`, the figures
    /// the Sleep tab's "Stages vs typical" card reads).
    private func stagesVsTypical(_ sleep: SleepModel) -> some View {
        let s = sleep.night.stages
        return VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(JohanTheme.cardBorder)
            stageRow(String(localized: "Deep"), last: s.deep, typical: sleep.typicalDeepMin, stage: .deep, index: 0)
            stageRow("REM", last: s.rem, typical: sleep.typicalRemMin, stage: .rem, index: 1)
            stageRow(String(localized: "Light"), last: s.light, typical: sleep.typicalLightMin, stage: .light, index: 2)
            HStack {
                Text("Awake").font(.system(.subheadline)).foregroundStyle(JohanTheme.textSecondary)
                Spacer()
                Text(hm(s.awake)).johanNumberFont(15).foregroundStyle(JohanTheme.textSecondary)
            }
            if sleep.typicalDeepMin != nil {
                Text("The line marks your typical night.").font(.system(.caption2)).foregroundStyle(JohanTheme.textTertiary)
            }
        }
    }

    private func stageRow(_ label: String, last: Double, typical: Double?, stage: SleepStage, index: Int) -> some View {
        let color = StrandPalette.sleepStageColor(stage)
        let scale = max(1, max(last, typical ?? 0) * 1.15)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(label).font(.system(.subheadline, weight: .semibold))
                Spacer()
                Text(hm(last)).johanNumberFont(15)
                if let typical, typical > 0 {
                    let diff = last - typical
                    Text((diff >= 0 ? "+" : "−") + hm(abs(diff)))
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(abs(diff) < 5 ? JohanTheme.textSecondary
                                         : diff > 0 ? JohanTheme.recoveryGreen : JohanTheme.recoveryYellow)
                        .frame(minWidth: 56, alignment: .trailing)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(JohanTheme.track)
                    Capsule().fill(color).frame(width: max(4, w * CGFloat(min(1, last / scale))))
                        .johanRevealLeftToRight()
                    if let typical, typical > 0 {
                        Rectangle().fill(JohanTheme.textPrimary)
                            .frame(width: 2, height: 14)
                            .position(x: w * CGFloat(min(1, typical / scale)), y: 4)
                    }
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(typical.map { String(localized: "\(label): \(hm(last)), typical \(hm($0))") }
                            ?? String(localized: "\(label): \(hm(last))"))
    }

    // MARK: Consistency

    /// The Sleep tab's consistency metric (`SleepModel.consistency`): how steady bed and wake times are.
    private func consistencyCard(_ sleep: SleepModel) -> some View {
        let c = sleep.consistency
        let latest = c.latest ?? 0
        return JohanCard {
            VStack(alignment: .leading, spacing: 10) {
                JohanOverline(String(localized: "Sleep consistency"))
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(latest.rounded()))%")
                        .johanNumberFont(34)
                        .foregroundStyle(JohanTheme.recoveryColor(latest))
                    Spacer()
                    Text(consistencyCaption(c)).font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                }
                let tail = Array(c.series.suffix(30))
                if tail.count >= 2 {
                    JohanSparkline(values: tail, color: JohanTheme.sleepViolet, height: 40)
                }
                Text("How regular your bed and wake times are. Steady times make sleep more restorative.")
                    .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
            }
        }
    }

    private func consistencyCaption(_ c: SleepModel.Metric) -> String {
        if let carried = SleepModel.carriedMetricCaption(latestDay: c.latestDay, latest: c.latest) { return carried }
        guard let latest = c.latest, let typical = c.typical else { return "" }
        let diff = Int((latest - typical).rounded())
        let sign = diff >= 0 ? "+" : "−", magnitude = String(abs(diff)), suffix = "%"
        return String(localized: "\(sign)\(magnitude)\(suffix) vs typical")
    }

    // MARK: Debt trend

    private var debtCard: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 10) {
                JohanOverline(String(localized: "Sleep debt"))
                if let ledger = coach.debt, ledger.nightCount > 0 {
                    let inDebt = ledger.isDebt && ledger.magnitudeMin >= SleepDebt.onTargetBandMin
                    HStack(alignment: .firstTextBaseline) {
                        Text(inDebt ? hm(ledger.magnitudeMin) : String(localized: "Balanced"))
                            .johanNumberFont(26)
                            .foregroundStyle(inDebt ? JohanTheme.recoveryYellow : JohanTheme.recoveryGreen)
                        Spacer()
                        Text(String(localized: "last \(String(ledger.nightCount)) nights")).font(.system(.caption))
                            .foregroundStyle(JohanTheme.textSecondary)
                    }
                    if coach.debtTrend.count >= 2 {
                        JohanGrowBars(bars: coach.debtTrend.map { .init(dayKey: $0.day, value: $0.value) },
                                      color: JohanTheme.sleepViolet, formatValue: hm)
                            .frame(height: 120)
                    }
                } else {
                    Text("Sleep debt is calculated from the last two weeks of nights and appears after the first recorded night.")
                        .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                }
            }
        }
    }

    // MARK: Formatting

    private func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    private func hourText(_ hour: Double) -> String {
        let m = Int((hour * 60).rounded()) % 1440
        return clock((m + 1440) % 1440)
    }

    private func hm(_ minutes: Double) -> String {
        let t = max(0, Int(minutes.rounded()))
        let h = String(t / 60), m = String(t % 60)
        return t >= 60 ? String(localized: "\(h) h \(m) min") : String(localized: "\(m) min")
    }

    private func timeText(_ d: Date) -> String {
        d.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale))
    }
}
#endif
