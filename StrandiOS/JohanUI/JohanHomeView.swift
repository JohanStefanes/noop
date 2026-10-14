#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandDesign

/// JohanUI Home: day navigation, Sleep / Recovery / Strain dials, vitals vs baseline, a strain
/// recommendation and the live HR card. While the personal baselines are still forming, the recovery and
/// sleep dials are replaced by a calibration card ("Tag X/4").
struct JohanHomeView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var profile: ProfileStore
    @StateObject private var model = JohanHomeModel()
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
            dayNavigator.johanStagger(0)
            // Flexible spacers share any spare height, so on a tall phone the sections spread out to fill the
            // screen; the minimum height only applies when everything already fits, so small phones and large
            // Dynamic Type simply scroll.
            VStack(spacing: gap) {
                if let day = s.calibrationDay {
                    calibrationHero(day: day, size: hero).johanStagger(1)
                    Spacer(minLength: 0)
                    HStack(alignment: .top, spacing: gap) {
                        JohanCard { strainDial(s, size: medium, haptic: true) }
                        JohanCard { liveHRContent }
                    }
                    .johanStagger(2)
                } else {
                    JohanDial(title: "Erholung", value: s.recovery, format: Self.whole, unitText: "%",
                              fraction: s.recovery.map { $0 / 100 },
                              color: s.recovery.map(JohanTheme.recoveryColor) ?? JohanTheme.recoveryGreen,
                              replayKey: model.dayOffset, hapticOnSettle: true, size: hero, numberScale: 0.34)
                        .johanStagger(1)
                    Spacer(minLength: 0)
                    HStack(alignment: .top, spacing: gap) {
                        JohanDial(title: "Schlaf", value: s.sleepPct, format: Self.whole, unitText: "%",
                                  fraction: s.sleepPct.map { $0 / 100 }, color: JohanTheme.sleepViolet,
                                  replayKey: model.dayOffset, size: medium)
                        strainDial(s, size: medium, haptic: false)
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
        .clipped()
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
            let dx = v.translation.width, dy = v.translation.height
            guard abs(dx) > JohanTheme.Motion.swipeMinDistance, abs(dx) > abs(dy) * 1.6 else { return }
            step(dx > 0 ? 1 : -1)
        })
        .task(id: model.dayOffset) { await model.load(repo: repo, profile: profile) }
        .onReceive(repo.$days.dropFirst()) { _ in Task { await model.load(repo: repo, profile: profile) } }
    }

    private static let whole: (Double) -> String = { "\(Int($0.rounded()))" }

    // MARK: Day navigation

    private var dayNavigator: some View {
        HStack {
            Button { step(1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .disabled(!model.canGoBack(repo: repo))
                .accessibilityLabel("Vorheriger Tag")
            Spacer()
            VStack(spacing: 2) {
                Text(dayTitle).font(.system(size: 17, weight: .semibold))
                    .contentTransition(.interpolate)
                Text(model.dayDate(offset: model.dayOffset)
                    .formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "de_DE"))))
                    .font(.system(size: 12)).foregroundStyle(JohanTheme.textSecondary)
            }
            .animation(JohanTheme.Motion.daySlide, value: model.dayOffset)
            Spacer()
            Button { step(-1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(model.dayOffset == 0)
                .accessibilityLabel("Nächster Tag")
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(JohanTheme.textPrimary)
    }

    private var dayTitle: String {
        switch model.dayOffset {
        case 0: return "Heute"
        case 1: return "Gestern"
        default:
            return model.dayDate(offset: model.dayOffset)
                .formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "de_DE")))
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
        JohanDial(title: "Belastung", value: s.strain21, format: { String(format: "%.1f", $0) },
                  unitText: "von 21", fraction: s.strain21.map { $0 / 21 }, color: JohanTheme.strainBlue,
                  replayKey: model.dayOffset, hapticOnSettle: haptic, size: size)
    }

    // MARK: Calibration

    private func calibrationHero(day: Int, size: CGFloat) -> some View {
        let total = model.calibrationLength
        return VStack(spacing: 12) {
            JohanCalibrationRing(fraction: Double(day) / Double(total), day: day, total: total, size: size)
            JohanOverline("Kalibrierung")
            Text("Dein Armband lernt dich kennen")
                .font(.system(size: 17, weight: .semibold))
            Text("Erholung und Schlaf erscheinen nach den ersten Nächten, sobald deine persönlichen Basiswerte stehen. Trag das Armband auch nachts.")
                .font(.system(size: 13)).foregroundStyle(JohanTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Vitals

    private func vitalsCard(_ s: JohanHomeModel.Snapshot) -> some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                JohanOverline("Vitalwerte")
                HStack(alignment: .top, spacing: 8) {
                    vital("HRV", s.hrv, unit: "ms", decimals: 0, higherIsBetter: true)
                    vital("Ruhepuls", s.restingHR, unit: "bpm", decimals: 0, higherIsBetter: false)
                    vital("Atemfrequenz", s.resp, unit: "/min", decimals: 1, higherIsBetter: nil)
                }
                if s.hrv.baseline == nil && s.restingHR.baseline == nil && s.resp.baseline == nil {
                    Text(s.isToday ? "Vergleich zur Basis folgt nach der Kalibrierung." : "Kein Vergleich zur Basis für vergangene Tage.")
                        .font(.system(size: 12)).foregroundStyle(JohanTheme.textTertiary)
                }
            }
        }
    }

    private func vital(_ title: String, _ v: JohanHomeModel.Vital, unit: String, decimals: Int,
                       higherIsBetter: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12)).foregroundStyle(JohanTheme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(v.value.map { String(format: "%.\(decimals)f", $0) } ?? "–")
                .font(JohanTheme.number(24))
            Text(unit).font(.system(size: 11)).foregroundStyle(JohanTheme.textTertiary)
            if let d = v.delta {
                let sign = d >= 0 ? "+" : "−"
                let text = sign + String(format: "%.\(decimals)f", abs(d))
                Text(text + " zur Basis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(deltaColor(d, higherIsBetter))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deltaColor(_ d: Double, _ higherIsBetter: Bool?) -> Color {
        guard let higherIsBetter, abs(d) > 0.0001 else { return JohanTheme.textSecondary }
        return (d > 0) == higherIsBetter ? JohanTheme.recoveryGreen : JohanTheme.recoveryRed
    }

    // MARK: Recommendation

    @ViewBuilder
    private func recommendationCard(_ s: JohanHomeModel.Snapshot) -> some View {
        if let band = s.targetBand, let rec = s.recovery {
            let color = JohanTheme.recoveryColor(rec)
            JohanCard {
                VStack(alignment: .leading, spacing: 8) {
                    JohanOverline("Empfehlung")
                    HStack(alignment: .firstTextBaseline) {
                        Text("Zielbelastung \(band.lowerBound)–\(band.upperBound)")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(color)
                        Spacer()
                        if let cur = s.strain21 {
                            Text("aktuell \(String(format: "%.1f", cur))")
                                .font(.system(size: 13)).foregroundStyle(JohanTheme.textSecondary)
                        }
                    }
                    JohanTargetBand(band: band, current: s.strain21, color: color)
                    Text(advice(rec, current: s.strain21, band: band))
                        .font(.system(size: 13)).foregroundStyle(JohanTheme.textSecondary)
                }
            }
        }
    }

    private func advice(_ rec: Double, current: Double?, band: ClosedRange<Int>) -> String {
        let zone: String
        switch rec {
        case 67...: zone = "Du bist gut erholt, heute ist Platz für hohe Belastung."
        case 34..<67: zone = "Moderate Erholung, ein solides Training ist drin."
        default: zone = "Dein Körper braucht Ruhe, halte die Belastung niedrig."
        }
        guard let current else { return zone }
        if current < Double(band.lowerBound) { return zone + " Du liegst noch unter dem Zielbereich." }
        if current > Double(band.upperBound) { return zone + " Du bist bereits über dem Zielbereich." }
        return zone + " Du liegst im Zielbereich."
    }

    // MARK: Live HR

    private var liveHRContent: some View {
        let samples = live.recentHrSamples.suffix(90).map { Double($0.bpm) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                JohanOverline("Live-Puls")
                Spacer()
                Circle().fill(live.connected ? JohanTheme.recoveryGreen : JohanTheme.textTertiary)
                    .frame(width: 8, height: 8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                JohanPulsingHeart(bpm: live.heartRate)
                Text(live.heartRate.map(String.init) ?? "–").font(JohanTheme.number(40))
                    .contentTransition(.numericText())
                    .animation(JohanTheme.Motion.cardIn, value: live.heartRate)
                Text("bpm").font(.system(size: 13)).foregroundStyle(JohanTheme.textSecondary)
            }
            if samples.count >= 2 { JohanSparkline(values: samples) }
            Text(live.connected ? "Armband verbunden" : "Nicht verbunden")
                .font(.system(size: 12)).foregroundStyle(JohanTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
#endif
