#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopProtocol

/// JohanUI Home: day navigation, Sleep / Recovery / Strain dials, vitals vs baseline, a strain
/// recommendation and the live HR card. While the personal baselines are still forming, the recovery and
/// sleep dials are replaced by a calibration card ("Tag X/4").
struct JohanHomeView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var profile: ProfileStore
    @StateObject private var model = JohanHomeModel()
    @Environment(\.johanSelectTab) private var selectTab
    @State private var showRecoveryDetail = false
    private let motion = JohanStill()

    /// True when the visible day was reached by going back in time (content enters from the leading edge).
    @State private var enterFromLeading = false

    var body: some View {
        GeometryReader { geo in
            content(width: geo.size.width - 2 * JohanTheme.Metrics.screenHPadding, visibleHeight: geo.size.height)
        }
    }

    private func content(width: CGFloat, visibleHeight: CGFloat) -> some View {
        let s = model.snapshot.dayKey == model.dayKey(offset: model.dayOffset) ? model.snapshot : JohanHomeModel.Snapshot()
        let hero = max(150, width * JohanTheme.Metrics.heroDialWidthFraction)
        let medium = max(100, width * JohanTheme.Metrics.mediumDialWidthFraction)
        let gap = JohanTheme.Metrics.cardSpacing
        return JohanScreen(title: "", showsNavigationBar: false) {
            header.johanStagger(0)
            // Flexible spacers share any spare height, so on a tall phone the sections spread out to fill the
            // screen; the minimum height only applies when everything already fits, so small phones and large
            // Dynamic Type simply scroll.
            VStack(spacing: gap) {
                if let day = s.calibrationDay {
                    calibrationHero(day: day, size: hero).johanStagger(1)
                    Spacer(minLength: 0)
                    // Both cards take the taller one's height, so the row reads as one band.
                    JohanAdaptiveStack(spacing: gap) {
                        JohanCard { strainDial(s, size: medium, haptic: true).frame(maxHeight: .infinity) }
                        JohanCard { liveHRContent.frame(maxHeight: .infinity, alignment: .top) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .johanStagger(2)
                } else {
                    // Tapping the score explains it; nothing to explain without a score.
                    Button { showRecoveryDetail = true } label: {
                        JohanDial(title: String(localized: "Recovery"), value: s.recovery, format: Self.whole, unitText: "%",
                                  fraction: s.recovery.map { $0 / 100 },
                                  color: s.recovery.map(JohanTheme.recoveryColor) ?? JohanTheme.recoveryGreen,
                                  replayKey: model.dayOffset, hapticOnSettle: true, size: hero, numberScale: 0.34,
                                  showsTitle: s.recovery == nil)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(JohanPressStyle())
                    .disabled(s.recovery == nil)
                    .accessibilityHint("Shows what shaped your recovery")
                    .johanStagger(1)
                    if let rec = s.recovery { verdict(rec, isToday: s.isToday).johanStagger(1) }
                    Spacer(minLength: 0)
                    JohanAdaptiveStack(spacing: gap) {
                        tabLink(.sleep, hint: String(localized: "Opens Sleep")) {
                            JohanDial(title: String(localized: "Sleep"), value: s.sleepPct, format: Self.whole, unitText: "%",
                                      fraction: s.sleepPct.map { $0 / 100 }, color: JohanTheme.sleepViolet,
                                      replayKey: model.dayOffset, size: medium)
                        }
                        tabLink(.strain, hint: String(localized: "Opens Strain")) { strainDial(s, size: medium, haptic: false) }
                    }
                    .johanStagger(2)
                }
                Spacer(minLength: 0)
                vitalsCard(s).johanStagger(3)
                if s.calibrationDay == nil {
                    Spacer(minLength: 0)
                    recommendationCard(s).johanStagger(4)
                }
                if s.calibrationDay == nil, live.connected || live.heartRate != nil {
                    JohanCard { liveHRContent }.johanStagger(5)
                }
            }
            .frame(minHeight: max(0, visibleHeight - JohanTheme.Metrics.homeChromeAllowance))
            .id(model.dayOffset)
            .transition(.asymmetric(
                insertion: .move(edge: enterFromLeading ? .leading : .trailing).combined(with: .opacity),
                removal: .move(edge: enterFromLeading ? .trailing : .leading).combined(with: .opacity)))
        }
        // No `.clipped()` here: it cut the scroll content at the safe area, so Home alone showed a black
        // band under the tab bar. The scroll view already clips the day-slide transition at its own edges.
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
            let dx = v.translation.width, dy = v.translation.height
            guard abs(dx) > JohanTheme.Motion.swipeMinDistance, abs(dx) > abs(dy) * 1.6 else { return }
            step(dx > 0 ? 1 : -1)
        })
        .sheet(isPresented: $showRecoveryDetail) {
            let s = model.snapshot
            if let rec = s.recovery {
                JohanRecoveryDetail(recovery: rec, isToday: s.isToday, drivers: s.drivers, confidence: s.confidence)
            }
        }
        .task(id: model.dayOffset) { await model.load(repo: repo, profile: profile) }
        .onReceive(repo.$days.dropFirst()) { _ in Task { await model.load(repo: repo, profile: profile) } }
    }

    private static let whole: (Double) -> String = { "\(Int($0.rounded()))" }

    /// Wraps a ring so a tap switches to the tab that explains it.
    private func tabLink<Label: View>(_ tab: JohanTab, hint: String, @ViewBuilder label: () -> Label) -> some View {
        Button { selectTab(tab) } label: { label().contentShape(Rectangle()) }
            .buttonStyle(JohanPressStyle())
            .accessibilityHint(hint)
    }

    // MARK: Day navigation

    /// One row: the day switcher centred, the strap chip trailing. The chevrons sit right beside the title
    /// so the switcher reads as one control; connection, battery and sync live behind the chip.
    private var header: some View {
        ZStack {
            dayNavigator
            HStack {
                Spacer()
                JohanStrapChip()
            }
        }
        .padding(.top, 4)
    }

    private var dayNavigator: some View {
        HStack(spacing: 0) {
            Button { step(1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .disabled(!model.canGoBack(repo: repo))
                .accessibilityLabel("Previous day")
            VStack(spacing: 1) {
                Text(dayTitle).font(.system(.headline))
                    .contentTransition(.interpolate)
                Text(model.dayDate(offset: model.dayOffset)
                    .formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale)))
                    .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
            }
            .frame(minWidth: 110)
            .lineLimit(1)
            .animation(JohanTheme.Motion.daySlide, value: model.dayOffset)
            Button { step(-1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(model.dayOffset == 0)
                .opacity(model.dayOffset == 0 ? 0.25 : 1)
                .accessibilityLabel("Next day")
        }
        .font(.system(.subheadline, weight: .semibold))
        .foregroundStyle(JohanTheme.textPrimary)
    }

    private var dayTitle: String {
        switch model.dayOffset {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        default:
            return model.dayDate(offset: model.dayOffset)
                .formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))
        }
    }

    /// delta +1 = one day back, -1 = one day forward. The direction is committed first so the outgoing
    /// content's removal transition already carries it, then the day changes in the next turn.
    private func step(_ delta: Int) {
        let next = model.dayOffset + delta
        guard next >= 0, delta < 0 || model.canGoBack(repo: repo) else { return }
        enterFromLeading = delta > 0
        StrandHaptic.selection.play()
        DispatchQueue.main.async {
            if motion.isStill { model.dayOffset = next }
            else { withAnimation(JohanTheme.Motion.daySlide) { model.dayOffset = next } }
        }
    }

    // MARK: Dials

    private func strainDial(_ s: JohanHomeModel.Snapshot, size: CGFloat, haptic: Bool) -> some View {
        JohanDial(title: String(localized: "Strain"), value: s.strain21, format: { String(format: "%.1f", $0) },
                  unitText: String(localized: "of 21"), fraction: s.strain21.map { $0 / 21 }, color: JohanTheme.strainBlue,
                  replayKey: model.dayOffset, hapticOnSettle: haptic, size: size)
    }

    // MARK: Calibration

    private func calibrationHero(day: Int, size: CGFloat) -> some View {
        let total = model.calibrationLength
        return VStack(spacing: 12) {
            JohanCalibrationRing(fraction: Double(day) / Double(total), day: day, total: total, size: size)
            JohanOverline(String(localized: "Calibration"))
            Text("Your strap is getting to know you")
                .font(.system(.headline))
            Text("Recovery and sleep appear after the first nights, once your personal baselines are set. Wear the strap overnight too.")
                .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Vitals

    private func vitalsCard(_ s: JohanHomeModel.Snapshot) -> some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                JohanOverline(String(localized: "Vitals"))
                JohanAdaptiveStack(spacing: 8) {
                    vital("HRV", s.hrv, unit: "ms", decimals: 0, higherIsBetter: true)
                    vital(String(localized: "Resting HR"), s.restingHR, unit: "bpm", decimals: 0, higherIsBetter: false)
                    vital(String(localized: "Respiratory rate"), s.resp, unit: "/min", decimals: 1, higherIsBetter: nil)
                }
                if s.hrv.baseline == nil && s.restingHR.baseline == nil && s.resp.baseline == nil {
                    Text(s.isToday ? String(localized: "The comparison with your average (Ø) follows after calibration.") : String(localized: "Past days have no comparison with your average."))
                        .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                }
            }
        }
    }

    private func vital(_ title: String, _ v: JohanHomeModel.Vital, unit: String, decimals: Int,
                       higherIsBetter: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            // Unit on the number's baseline: one line instead of two, and it reads as "89 ms".
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(v.value.map { String(format: "%.\(decimals)f", $0) } ?? "–").johanNumberFont(24)
                if v.value != nil {
                    Text(unit).font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                }
            }
            if let d = v.delta {
                deltaLabel(d, decimals: decimals, higherIsBetter: higherIsBetter)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "▲ 7 über Ø": the arrow carries the direction, so it never depends on the colour alone.
    private func deltaLabel(_ d: Double, decimals: Int, higherIsBetter: Bool?) -> some View {
        let rounded = (abs(d) * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))
        let amount = String(format: "%.\(decimals)f", rounded)
        let text: String
        let symbol: String
        if rounded == 0 { text = String(localized: "same as Ø"); symbol = "equal" }
        else if d > 0 { text = String(localized: "\(amount) above Ø"); symbol = "arrow.up" }
        else { text = String(localized: "\(amount) below Ø"); symbol = "arrow.down" }
        return Label(text, systemImage: symbol)
            .font(.system(.caption2, weight: .semibold))
            .foregroundStyle(rounded == 0 ? JohanTheme.textSecondary : deltaColor(d, higherIsBetter))
            .labelStyle(JohanCompactLabelStyle())
            .lineLimit(1).minimumScaleFactor(0.8)
    }

    private func deltaColor(_ d: Double, _ higherIsBetter: Bool?) -> Color {
        guard let higherIsBetter, abs(d) > 0.0001 else { return JohanTheme.textSecondary }
        return (d > 0) == higherIsBetter ? JohanTheme.recoveryGreen : JohanTheme.recoveryRed
    }

    // MARK: Verdict

    /// The answer to "how am I today", directly under the dial: the zone as a word (so it never depends on
    /// colour alone) and what it means for training. The strain card below no longer repeats it.
    /// The training hint is advice for the day ahead, so a past day shows the zone only.
    private func verdict(_ recovery: Double, isToday: Bool) -> some View {
        let zone = JohanTheme.RecoveryZone(recovery)
        return VStack(spacing: 4) {
            Text(zone.title)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(zone.color)
            if isToday {
                Text(zone.hint)
                    .font(.system(.subheadline))
                    .foregroundStyle(JohanTheme.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Strain target

    @ViewBuilder
    private func recommendationCard(_ s: JohanHomeModel.Snapshot) -> some View {
        if let band = s.targetBand, let rec = s.recovery {
            let color = JohanTheme.recoveryColor(rec)
            Button { selectTab(.strain) } label: {
                JohanCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            JohanOverline(String(localized: "Strain target"))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(.footnote, weight: .semibold))
                                .foregroundStyle(JohanTheme.textTertiary)
                                .accessibilityHidden(true)
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(band.lowerBound)–\(band.upperBound)")
                                .johanNumberFont(26, relativeTo: .title3)
                                .foregroundStyle(color)
                            Spacer()
                            if let cur = s.strain21 {
                                Text(String(localized: "now \(String(format: "%.1f", cur))"))
                                    .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                            }
                        }
                        JohanTargetBand(band: band, current: s.strain21, color: color)
                        Text(JohanStrainView.progressText(current: s.strain21, band: band, isToday: s.isToday))
                            .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                    }
                }
            }
            .buttonStyle(JohanPressStyle())
            .accessibilityHint("Opens Strain")
        }
    }

    // MARK: Live HR

    /// The live HR card, holding the realtime-HR stream while it is on screen (see `JohanLiveHRDemand`).
    private var liveHRContent: some View {
        liveHRReadout.modifier(JohanLiveHRDemand())
    }

    private var liveHRReadout: some View {
        let samples = live.recentHrSamples.suffix(90).map { Double($0.bpm) }
        let liveBPM = live.heartRate
        // While no live sample has arrived, the newest stored one stands in: dimmed and with its age, so it
        // can't be read as live. Only one number is ever shown; the live value replaces it on arrival.
        let stored = liveBPM == nil ? model.lastStoredHR.flatMap(recentEnough) : nil
        // Connected and asking, nothing live yet: the few seconds the strap takes to start streaming.
        let waiting = live.connected && liveBPM == nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                JohanOverline(String(localized: "Live heart rate"))
                Spacer()
                Circle().fill(live.connected ? JohanTheme.recoveryGreen : JohanTheme.textTertiary)
                    .frame(width: 8, height: 8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // While waiting the heart beats at a calm resting tempo as a loading cue, dimmed so it is
                // not read as a measurement; the live value takes over its tempo on arrival.
                JohanPulsingHeart(bpm: liveBPM ?? (waiting ? 60 : nil))
                    .opacity(liveBPM == nil ? 0.45 : 1)
                Text(liveBPM.map(String.init) ?? stored.map { String($0.bpm) } ?? "–").johanNumberFont(40)
                    .foregroundStyle(liveBPM == nil ? JohanTheme.textTertiary : JohanTheme.textPrimary)
                    .contentTransition(.numericText())
                    .animation(JohanTheme.Motion.cardIn, value: liveBPM)
                Text("bpm").font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
            }
            if waiting {
                JohanHRSearching().transition(.opacity)
            } else if samples.count >= 2 {
                JohanSparkline(values: samples)
            }
            // Connected but no reading says exactly that; why the strap sends none is not known here.
            Text(liveStatus(liveBPM: liveBPM, stored: stored))
                .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// A stored sample is worth showing only while it is recent; older than that it says nothing about now.
    private func recentEnough(_ s: HRSample) -> HRSample? {
        Date().timeIntervalSince1970 - TimeInterval(s.ts) <= 2 * 3600 ? s : nil
    }

    private func liveStatus(liveBPM: Int?, stored: HRSample?) -> String {
        if liveBPM != nil { return String(localized: "Strap connected") }
        if let stored {
            let age = Self.relative.localizedString(for: Date(timeIntervalSince1970: TimeInterval(stored.ts)),
                                                    relativeTo: Date())
            return live.connected
                ? String(localized: "Last reading \(age), waiting for live data")
                : String(localized: "Not connected, last reading \(age)")
        }
        return live.connected ? String(localized: "Connected, no heart rate yet") : String(localized: "Not connected")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = AppLanguage.activeLocale
        f.unitsStyle = .abbreviated
        return f
    }()
}
#endif

#if os(iOS)
/// Keeps the strap's realtime HR stream armed while the live HR card is visible and the app is active.
/// A WHOOP 5/MG sends live BPM only while that stream is requested, which the original Live tab does on
/// appear; without this the card only ever showed what some other screen had asked for. Same ref-counted
/// API the Live tab uses (`startRealtimeHR` / `stopRealtimeHR`, balanced exactly once), released when the
/// app leaves the foreground because the stream costs strap battery, and re-sent on a new connection
/// the way the Live tab's `reconnectLiveSession` does.
private struct JohanLiveHRDemand: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .onAppear { setHolding(scenePhase == .active) }
            .onDisappear { setHolding(false) }
            .onChange(of: scenePhase) { _, phase in setHolding(phase == .active) }
            .onChange(of: live.connected) { _, _ in if holding { model.rearmRealtimeIfWanted() } }
            .onChange(of: live.bonded) { _, _ in if holding { model.rearmRealtimeIfWanted() } }
    }

    private func setHolding(_ want: Bool) {
        guard want != holding else { return }
        holding = want
        if want { model.startRealtimeHR() } else { model.stopRealtimeHR() }
    }
}
#endif
