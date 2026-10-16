#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

/// "Schlaf-Coach", in three sections: last night (summary, stages against the wearer's typical with every
/// phase, heart rate), tonight (bedtime from sleep need + sleep debt, body clock) and the trends (sleep
/// consistency, sleep debt). Every card names what it shows in a title and one plain sentence.
struct JohanSleepCoachView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.johanReloadTick) private var reloadTick
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @StateObject private var coach = JohanSleepCoachModel()
    @AppStorage(PuffinExperiment.keepRealtimeForDataKey) private var continuousHrv = false
    @State private var showsPhases = false
    /// The moment marked on the stage chart, in seconds after onset; a phase row sets it too.
    @State private var selectedTime: TimeInterval?
    /// The stage tapped in the stage rows: brought forward in the stage chart and the heart-rate chart.
    @State private var highlightedStage: SleepStage?
    @State private var showsNightDetails = false

    var body: some View {
        JohanScreen(title: String(localized: "Sleep")) {
            if coach.loaded {
                lastNightSection
                if let rec = coach.recommendation {
                    sectionTitle(String(localized: "Tonight"))
                    bedtimeCard(rec).johanStagger(3)
                }
                sectionTitle(String(localized: "Trends"))
                if let sleep = coach.sleep, sleep.consistency.latest != nil {
                    consistencyCard(sleep).johanStagger(4)
                }
                debtCard.johanStagger(5)
            } else {
                JohanPlaceholderCard(height: 160)
                JohanPlaceholderCard(height: 260)
                JohanPlaceholderCard(height: 180)
            }
        }
        .task(id: reloadTick) { await coach.load(repo: repo, circadian: model.circadianPhase) }
        .onReceive(repo.$days.dropFirst()) { _ in
            Task { await coach.load(repo: repo, circadian: model.circadianPhase) }
        }
    }

    // MARK: Layout

    /// Heading over a group of cards: what part of the night (or the day) the cards below are about.
    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(.title3, weight: .bold))
            .foregroundStyle(JohanTheme.textPrimary)
            .padding(.top, 10)
            .accessibilityAddTraits(.isHeader)
    }

    /// A card's own title and the one sentence that says what it shows.
    private func cardHeader(_ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(.headline)).foregroundStyle(JohanTheme.textPrimary)
            Text(caption).font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Tonight

    private func bedtimeCard(_ rec: JohanSleepCoachModel.Recommendation) -> some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 14) {
                cardHeader(String(localized: "Recommended bedtime"),
                           String(localized: "Go to bed at this time to wake up rested at \(clock(rec.wakeMinutes))."))
                Text(clock(rec.bedtimeMinutes))
                    .johanNumberFont(56).foregroundStyle(JohanTheme.sleepViolet)
                sleepSum(rec)
                Text(explanation(rec)).font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                if let clockWindow = JohanSleepCoachModel.bodyClock(model.circadianPhase, durationMin: rec.targetSleepMin) {
                    Divider().overlay(JohanTheme.cardBorder)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Body clock").font(.system(.subheadline, weight: .semibold))
                        Text(String(localized: "Ideal window \(hourText(clockWindow.idealBedHour)) to \(hourText(clockWindow.idealWakeHour)). \(clockWindow.note)"))
                            .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                    }
                }
                Divider().overlay(JohanTheme.cardBorder)
                NavigationLink {
                    SmartAlarmView()
                        .background(JohanTheme.background.ignoresSafeArea())
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        Label("Adjust wake time & reminder", systemImage: "alarm")
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold))
                    }
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(JohanTheme.sleepViolet)
                }
            }
        }
    }

    /// How the sleep time behind the bedtime is made up: need, plus debt to pay back, equals the target.
    @ViewBuilder
    private func sleepSum(_ rec: JohanSleepCoachModel.Recommendation) -> some View {
        let parts: [(String, String)] = rec.paybackMin >= 1
            ? [(String(localized: "Sleep need"), hm(rec.needMin)),
               (String(localized: "Pay back debt"), "+ " + hm(rec.paybackMin)),
               (String(localized: "Sleep goal"), "= " + hm(rec.targetSleepMin))]
            : [(String(localized: "Sleep need"), hm(rec.needMin)),
               (String(localized: "Sleep goal"), "= " + hm(rec.targetSleepMin))]
        statsLayout(parts)
    }

    private func explanation(_ rec: JohanSleepCoachModel.Recommendation) -> String {
        if rec.nightsUsed == 0 {
            return String(localized: "No sleep data yet: the recommendation uses the default need of \(hm(rec.needMin)) and your wake time. It gets more precise once nights are recorded.")
        }
        return String(localized: "Based on your last \(String(rec.nightsUsed)) nights.")
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

    @ViewBuilder
    private var lastNightSection: some View {
        if let sleep = coach.sleep, !sleep.isStubNight {
            let night = sleep.night
            sectionTitle(isRecent(night) ? String(localized: "Last night") : night.spanLabel)
            summaryCard(sleep).johanStagger(0)
            stagesCard(sleep).johanStagger(1)
            heartRateCard(sleep).johanStagger(2)
            coverageCard.johanStagger(2)
        } else {
            sectionTitle(String(localized: "Last night"))
            JohanCard {
                Text("No night recorded yet. Wear the strap overnight and your sleep will show up here.")
                    .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func summaryCard(_ sleep: SleepModel) -> some View {
        let night = sleep.night
        return Button {
            withAnimation(.snappy) { showsNightDetails.toggle() }
        } label: {
            JohanCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hm(night.stages.asleep)).johanNumberFont(44).foregroundStyle(JohanTheme.sleepViolet)
                            Text("Time asleep, without the minutes you were awake.")
                                .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down")
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(JohanTheme.textTertiary)
                            .rotationEffect(.degrees(showsNightDetails ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                    statsLayout([(String(localized: "Fell asleep"), night.onsetText),
                                 (String(localized: "Woke up"), night.wakeText)])
                    if showsNightDetails {
                        Divider().overlay(JohanTheme.cardBorder)
                        statsLayout([(String(localized: "In bed"), hm(night.timeInBed)),
                                     (String(localized: "Awake"), hm(night.stages.awake)),
                                     (String(localized: "Times awake"), String(Self.wakeUps(sleep.intervals)))])
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(JohanTheme.textPrimary)
            }
        }
        .buttonStyle(JohanPressStyle())
        .accessibilityHint(Text(showsNightDetails ? "Hides the details." : "Shows time in bed and how often you woke up."))
    }

    /// Awake phases between the first and the last stretch of sleep: waking up during the night, not the
    /// minutes before falling asleep or after the final wake.
    static func wakeUps(_ intervals: [SleepInterval]) -> Int {
        let phases = JohanSleepPhases.phases(intervals)
        guard let first = phases.firstIndex(where: { $0.stage != .awake }),
              let last = phases.lastIndex(where: { $0.stage != .awake }), first < last else { return 0 }
        return phases[first...last].filter { $0.stage == .awake }.count
    }

    private func stagesCard(_ sleep: SleepModel) -> some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 14) {
                cardHeader(String(localized: "Sleep stages"),
                           String(localized: "Which stage you were in through the night, and how long each lasted."))
                JohanHypnogram(intervals: sleep.intervals, nightStart: sleep.night.onsetDate,
                               nightEnd: Date(timeIntervalSince1970: TimeInterval(sleep.night.session.endTs)),
                               selectedTime: $selectedTime, highlightedStage: highlightedStage)
                stagesVsTypical(sleep)
                phaseList(sleep)
            }
        }
    }

    /// Woken from today, so "Last night" is true; an older newest night is named by its own date instead.
    private func isRecent(_ night: Night) -> Bool {
        Calendar.current.isDateInToday(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
    }

    // MARK: Night recording

    /// How much of the night carries beat-to-beat data, where it is missing, and the two settings states
    /// that most often leave it thin: overnight capture switched off, another app pulling the strap.
    @ViewBuilder
    private var coverageCard: some View {
        if let c = coach.coverage, c.nightMinutes > 0 {
            JohanCard {
                VStack(alignment: .leading, spacing: 12) {
                    cardHeader(String(localized: "Night recording"),
                               String(localized: "How much of the night has beat-to-beat heart data. HRV, breathing rate and recovery are computed from it."))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(hm(Double(c.beatMinutes))).johanNumberFont(28)
                            .foregroundStyle(coverageColor(c.fraction))
                        Text(String(localized: "of \(hm(Double(c.nightMinutes)))"))
                            .font(JohanTheme.Fonts.unit).foregroundStyle(JohanTheme.textSecondary)
                        Spacer()
                        Text(String(Int((c.fraction * 100).rounded())) + " %")
                            .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                    }
                    coverageStrip(c)
                        .frame(height: 10)
                        .accessibilityHidden(true)
                    if !c.gaps.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(c.gaps.prefix(3).enumerated()), id: \.offset) { _, gap in
                                Text(String(localized: "No beats \(timeText(Date(timeIntervalSince1970: TimeInterval(gap.start))))–\(timeText(Date(timeIntervalSince1970: TimeInterval(gap.end)))) (\(hm(Double(gap.minutes))))"))
                            }
                            if c.gaps.count > 3 {
                                Text(String(localized: "and \(String(c.gaps.count - 3)) more gaps"))
                            }
                        }
                        .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                    }
                    if let share = c.liveShare {
                        Text(String(localized: "Live stream: \(String(Int((share * 100).rounded())) + " %") of the beats, the rest from the strap's history."))
                            .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if live.pairingHint != nil || live.deepPacketsThisSession > 0 {
                        coverageNote(icon: "exclamationmark.triangle.fill", color: JohanTheme.recoveryYellow,
                                     String(localized: "Another app is reading this strap, most likely the official WHOOP app. While it holds the strap, NOOP misses live beats and some features stop working. Close it or remove the strap there."))
                    }
                    if !continuousHrv {
                        coverageNote(icon: "moon.zzz.fill", color: JohanTheme.sleepViolet,
                                     String(localized: "Overnight recording is off, so only the strap's history is used at night."))
                        Button {
                            UserDefaults.standard.set(true, forKey: PuffinExperiment.continuousHrvOvernightOnlyKey)
                            continuousHrv = true
                            model.ble.setKeepRealtimeForData(true)
                        } label: {
                            Text("Turn on overnight recording")
                                .font(.system(.subheadline, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(JohanTheme.sleepViolet.opacity(0.2), in: Capsule())
                                .foregroundStyle(JohanTheme.sleepViolet)
                        }
                        .buttonStyle(JohanPressStyle())
                        .accessibilityHint(Text("Keeps the beat-to-beat stream running inside your night window. Uses more battery."))
                    }
                }
            }
        }
    }

    private func coverageColor(_ fraction: Double) -> Color {
        fraction >= 0.8 ? JohanTheme.recoveryGreen : fraction >= 0.5 ? JohanTheme.recoveryYellow : JohanTheme.recoveryRed
    }

    /// The night as one bar: recorded stretches filled, everything else the bare track.
    private func coverageStrip(_ c: JohanNightCoverage.Summary) -> some View {
        GeometryReader { geo in
            let perMinute = geo.size.width / CGFloat(max(1, c.nightMinutes))
            ZStack(alignment: .leading) {
                Capsule().fill(JohanTheme.track)
                ForEach(Array(c.covered.enumerated()), id: \.offset) { _, span in
                    Rectangle().fill(JohanTheme.sleepViolet)
                        .frame(width: max(1, perMinute * CGFloat(span.minutes)))
                        .offset(x: perMinute * CGFloat((span.start - c.nightStart) / 60))
                }
            }
            .clipShape(Capsule())
        }
    }

    private func coverageNote(icon: String, color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).accessibilityHidden(true)
            Text(text).font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Night heart rate

    @ViewBuilder
    private func heartRateCard(_ sleep: SleepModel) -> some View {
        let start = TimeInterval(sleep.night.session.effectiveStartTs)
        let bpms = coach.nightHR.filter { TimeInterval($0.ts) >= start }.map(\.bpm)
        if bpms.count >= 2, let low = bpms.min() {
            let intervals = sleep.intervals.sorted { $0.start < $1.start }
            let origin = intervals.first?.start ?? 0
            let span = max(1, (intervals.map(\.end).max() ?? 1) - origin)
            JohanCard {
                VStack(alignment: .leading, spacing: 12) {
                    cardHeader(String(localized: "Heart rate while asleep"),
                               String(localized: "Your heart rate across the night. Low and steady means your body could recover."))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(Int(low.rounded()))).johanNumberFont(28)
                            Text("bpm").font(JohanTheme.Fonts.unit).foregroundStyle(JohanTheme.textSecondary)
                        }
                        Text("Lowest of the night").font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                    }
                    VStack(spacing: 4) {
                        SleepHRChart(nightHR: coach.nightHR, intervals: intervals, origin: origin, span: span,
                                     night: sleep.night, selectedStage: highlightedStage, timeFormatter: Self.timeFormatter)
                            .frame(height: 110)
                        HStack {
                            Text(timeText(sleep.night.onsetDate.addingTimeInterval(origin)))
                            Spacer()
                            Text(timeText(sleep.night.onsetDate.addingTimeInterval(origin + span)))
                        }
                        .font(.system(.caption2).monospacedDigit())
                        .foregroundStyle(JohanTheme.textTertiary)
                        .accessibilityHidden(true)
                    }
                    Label("Tap or slide along the line for the time and heart rate.", systemImage: "hand.tap")
                        .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                    if let stage = highlightedStage {
                        Text(String(localized: "\(stageName(stage)) is highlighted. Tap the stage again to show the whole night."))
                            .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                    }
                }
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
    /// the Sleep tab's "Stages vs typical" card reads). A mean over fewer than `minTypicalNights` nights is
    /// mostly last night itself, so it is not shown as a comparison until there are enough.
    private func stagesVsTypical(_ sleep: SleepModel) -> some View {
        let s = sleep.night.stages
        let deep = typical(sleep.typicalDeepMin, \.deepMin)
        let rem = typical(sleep.typicalRemMin, \.remMin)
        let light = typical(sleep.typicalLightMin, \.lightMin)
        return VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(JohanTheme.cardBorder)
            if deep != nil || rem != nil || light != nil {
                stageLegend
            } else {
                Text(String(localized: "The comparison with your typical night appears after \(String(Self.minTypicalNights)) nights."))
                    .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
            }
            let peak = max(s.deep, s.rem, s.light)
            let phases = JohanSleepPhases.phases(sleep.intervals)
            stageButton(.deep, phases: phases, night: s) {
                stageRow(String(localized: "Deep"), last: s.deep, typical: deep, peak: peak, stage: .deep, index: 0)
            }
            stageButton(.rem, phases: phases, night: s) {
                stageRow("REM", last: s.rem, typical: rem, peak: peak, stage: .rem, index: 1)
            }
            stageButton(.light, phases: phases, night: s) {
                stageRow(String(localized: "Light"), last: s.light, typical: light, peak: peak, stage: .light, index: 2)
            }
            stageButton(.awake, phases: phases, night: s) {
                HStack(spacing: 8) {
                    Circle().fill(JohanTheme.stageColor(.awake)).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text("Awake").font(.system(.subheadline, weight: .semibold))
                    Spacer()
                    Text(hm(s.awake)).johanNumberFont(15)
                }
            }
            Text("Tap a stage to highlight it in the charts.")
                .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
        }
    }

    /// A stage row as a toggle: tapping brings that stage forward in the stage and heart-rate charts and
    /// opens a line with its share of the night, how many phases it came in and the longest one.
    private func stageButton<Row: View>(_ stage: SleepStage, phases: [JohanSleepPhases.Phase], night s: Stages,
                                        @ViewBuilder row: () -> Row) -> some View {
        let selected = highlightedStage == stage
        return Button {
            withAnimation(.snappy) { highlightedStage = selected ? nil : stage }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                row()
                if selected {
                    Text(stageDetail(stage, phases: phases, night: s))
                        .font(.system(.caption))
                        .foregroundStyle(JohanTheme.textSecondary)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? JohanTheme.stageColor(stage).opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
            .foregroundStyle(JohanTheme.textPrimary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "23% of sleep · 4 phases · longest 52 min". Awake is measured against the time in bed, since it is
    /// not part of sleep.
    private func stageDetail(_ stage: SleepStage, phases: [JohanSleepPhases.Phase], night s: Stages) -> String {
        let own = phases.filter { $0.stage == stage }
        let count = String(own.count)
        let longest = JohanSleepText.phaseDuration(own.map(\.minutes).max() ?? 0)
        let minutes: Double
        switch stage {
        case .deep: minutes = s.deep
        case .rem: minutes = s.rem
        case .light: minutes = s.light
        case .awake: minutes = s.awake
        }
        if stage == .awake {
            let pct = String(Int((minutes / max(1, s.total) * 100).rounded()))
            return String(localized: "\(pct)% of time in bed · \(count) phases · longest \(longest)")
        }
        let pct = String(Int((minutes / max(1, s.asleep) * 100).rounded()))
        return String(localized: "\(pct)% of sleep · \(count) phases · longest \(longest)")
    }

    static let minTypicalNights = 3

    /// `mean` when at least `minTypicalNights` days carry the stage (the same days `typicalStageMin` averages).
    private func typical(_ mean: Double?, _ key: KeyPath<DailyMetric, Double?>) -> Double? {
        guard let mean, repo.days.filter({ ($0[keyPath: key] ?? 0) > 0 }).count >= Self.minTypicalNights else { return nil }
        return mean
    }

    /// Key for the rows below: what the bar, the white line and the signed figure each stand for.
    private var stageLegend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Capsule().fill(JohanTheme.textSecondary).frame(width: 16, height: 6)
                Text("Last night")
            }
            HStack(spacing: 5) {
                Rectangle().fill(JohanTheme.textPrimary).frame(width: 2, height: 12)
                Text("Your typical")
            }
            Text("± difference")
        }
        .font(.system(.caption2))
        .foregroundStyle(JohanTheme.textSecondary)
        .accessibilityElement(children: .combine)
    }

    /// With a typical, each bar is scaled to its own stage so the white line has room either side; without
    /// one, every bar shares the night's longest stage as full width, so the bars compare the stages.
    private func stageRow(_ label: String, last: Double, typical: Double?, peak: Double, stage: SleepStage,
                          index: Int) -> some View {
        let color = JohanTheme.stageColor(stage)
        let scale = typical.map { max(1, max(last, $0) * 1.15) } ?? max(1, peak)
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

    // MARK: Phases

    /// Every phase of the night in order (`JohanSleepPhases`), folded away until asked for.
    @ViewBuilder
    private func phaseList(_ sleep: SleepModel) -> some View {
        let phases = JohanSleepPhases.phases(sleep.intervals)
        if !phases.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Divider().overlay(JohanTheme.cardBorder)
                Button {
                    withAnimation(.snappy) { showsPhases.toggle() }
                } label: {
                    HStack {
                        Text(String(localized: "All phases (\(String(phases.count)))"))
                            .font(.system(.subheadline, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(showsPhases ? 180 : 0))
                    }
                    .foregroundStyle(JohanTheme.sleepViolet)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsPhases {
                    VStack(spacing: 0) {
                        ForEach(Array(phases.enumerated()), id: \.offset) { i, phase in
                            Button {
                                // Marks the phase on the stage chart above, which names it under the chart.
                                selectedTime = (phase.start + phase.end) / 2
                            } label: {
                                phaseRow(phase, nightStart: sleep.night.onsetDate)
                                    .background(isMarked(phase) ? JohanTheme.stageColor(phase.stage).opacity(0.14) : Color.clear)
                                    .contentShape(Rectangle())
                                    .foregroundStyle(JohanTheme.textPrimary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isMarked(phase) ? .isSelected : [])
                            if i < phases.count - 1 { Divider().overlay(JohanTheme.cardBorder) }
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private func isMarked(_ phase: JohanSleepPhases.Phase) -> Bool {
        guard let t = selectedTime else { return false }
        return t >= phase.start && t < phase.end
    }

    private func phaseRow(_ phase: JohanSleepPhases.Phase, nightStart: Date) -> some View {
        let from = timeText(nightStart.addingTimeInterval(phase.start))
        let to = timeText(nightStart.addingTimeInterval(phase.end))
        let name = stageName(phase.stage)
        return HStack(spacing: 10) {
            Circle().fill(JohanTheme.stageColor(phase.stage)).frame(width: 8, height: 8)
            Text(name).font(.system(.subheadline)).frame(width: 64, alignment: .leading)
            Text("\(from) – \(to)").font(.system(.subheadline).monospacedDigit())
                .foregroundStyle(JohanTheme.textSecondary)
            Spacer(minLength: 8)
            Text(phaseDuration(phase.minutes)).font(.system(.subheadline, weight: .semibold).monospacedDigit())
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(name) from \(from) to \(to), \(phaseDuration(phase.minutes))"))
    }

    private func stageName(_ stage: SleepStage) -> String {
        switch stage {
        case .awake: return String(localized: "Awake")
        case .light: return String(localized: "Light")
        case .deep: return String(localized: "Deep")
        case .rem: return "REM"
        }
    }

    private func phaseDuration(_ minutes: Double) -> String { JohanSleepText.phaseDuration(minutes) }

    // MARK: Consistency

    /// The Sleep tab's consistency metric (`SleepModel.consistency`): how steady bed and wake times are.
    private func consistencyCard(_ sleep: SleepModel) -> some View {
        let c = sleep.consistency
        let latest = c.latest ?? 0
        return JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                cardHeader(String(localized: "Sleep consistency"),
                           String(localized: "How regular your bed and wake times are. Steady times make sleep more restorative."))
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(latest.rounded()))%")
                        .johanNumberFont(34)
                        .foregroundStyle(JohanTheme.recoveryColor(latest))
                    Spacer()
                    Text(consistencyCaption(c)).font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                }
                let tail = Array(c.series.suffix(30))
                if tail.count >= 2 {
                    JohanSparkline(values: tail, color: JohanTheme.sleepViolet, height: 40) { i, value in
                        let pct = String(Int(value.rounded()))
                        let back = tail.count - 1 - i
                        return back == 0 ? String(localized: "\(pct)% · latest night")
                                         : String(localized: "\(pct)% · \(String(back)) nights before the latest")
                    }
                    Text(String(localized: "Last \(String(tail.count)) nights"))
                        .font(.system(.caption2)).foregroundStyle(JohanTheme.textTertiary)
                }
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
            VStack(alignment: .leading, spacing: 12) {
                cardHeader(String(localized: "Sleep debt"),
                           String(localized: "Sleep you are short of your need, added up over recent nights. Each bar is your debt on that day."))
                if let ledger = coach.debt, ledger.nightCount > 0 {
                    let inDebt = ledger.isDebt && ledger.magnitudeMin >= SleepDebt.onTargetBandMin
                    HStack(alignment: .firstTextBaseline) {
                        Text(inDebt ? hm(ledger.magnitudeMin) : String(localized: "Balanced"))
                            .johanNumberFont(28)
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

    private func hm(_ minutes: Double) -> String { JohanSleepText.hm(minutes) }

    private func timeText(_ d: Date) -> String {
        d.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale))
    }
}
#endif
