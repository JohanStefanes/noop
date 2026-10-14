#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

/// "Schlaf-Coach": tonight's bedtime from sleep need + sleep debt (+ body clock), last night's hypnogram
/// and the sleep-debt trend.
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
                debtCard.johanStagger(2)
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
                JohanOverline(String(localized: "Last night"))
                if let night = coach.night {
                    Text(String(localized: "\(timeText(night.start)) – \(timeText(night.end)) · \(hm(night.stages.asleep)) asleep"))
                        .font(.system(.subheadline, weight: .semibold))
                    Hypnogram(intervals: night.intervals, height: 130, showsStageAxis: true,
                              showsHover: false, nightStart: night.start, showsTimeAxis: true, filled: true)
                        .johanRevealLeftToRight()
                    statsLayout([(String(localized: "Deep"), hm(night.stages.deep)), ("REM", hm(night.stages.rem)),
                                 (String(localized: "Light"), hm(night.stages.light)), (String(localized: "Awake"), hm(night.stages.awake))])
                } else {
                    Text("No night recorded yet. Wear the strap overnight and your sleep will show up here.")
                        .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                }
            }
        }
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
