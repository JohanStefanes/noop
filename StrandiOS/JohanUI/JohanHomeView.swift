#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopProtocol

/// JohanUI Home, in the Fitness / Health manner: a large dated title, recovery / sleep / strain as concentric
/// rings with their values beneath, what the day means (or how far calibration has come), live heart rate
/// beside the strain target, and vitals against the personal baseline.
struct JohanHomeView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.johanReloadTick) private var reloadTick
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var profile: ProfileStore
    @StateObject private var model = JohanHomeModel()
    @Environment(\.johanSelectTab) private var selectTab
    @Environment(\.johanIntroPhase) private var introPhase
    @Environment(\.johanIntroTarget) private var reportIntroTarget
    @State private var showRecoveryDetail = false
    @State private var showCalendar = false
    /// Tonight's bedtime, from the same plan the Sleep tab shows (`JohanSleepCoachModel.recommendation`).
    @State private var tonight: JohanSleepCoachModel.Recommendation?
    @AppStorage(JohanSleepGoal.storageKey) private var sleepGoalRaw = JohanSleepGoal.peak.rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.skinTempDisplayKey) private var skinTempDisplayRaw = ""
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
        let zone = s.recovery.map(JohanTheme.RecoveryZone.init)
        let recColor = zone?.color ?? JohanTheme.textSecondary
        let gap = JohanTheme.Metrics.cardSpacing
        return JohanScreen(title: "", showsNavigationBar: false) {
            header.johanStagger(0)
            VStack(spacing: gap) {
                let ringSize = min(260, width * 0.72)
                ringsHero(s, zone: zone, recColor: recColor, size: ringSize).johanStagger(1)
                    // Outside the stagger, so the measured centre is the resting one, not the risen-from one.
                    .background { introTargetReader(size: ringSize, recColor: recColor) }
                statsRow(s, recColor: recColor).johanStagger(2)
                statusCard(s, zone: zone).padding(.top, 6).johanStagger(3)
                if s.isToday { JohanAutoWorkoutCard() }
                // Both cards take the taller one's height, so the row reads as one band.
                JohanAdaptiveStack(spacing: 12) {
                    JohanCard(padding: 14) { liveHRContent.frame(maxHeight: .infinity, alignment: .top) }
                    strainTargetCard(s, recColor: recColor)
                }
                .fixedSize(horizontal: false, vertical: true)
                .johanStagger(4)
                vitalsCard(s).johanStagger(5)
                if s.isToday, let tonight { tonightCard(tonight).johanStagger(6) }
                if !model.healthspan.isEmpty { healthspanCard(model.healthspan).johanStagger(7) }
                if s.isToday { JohanCycleHomeCard().johanStagger(8) }
            }
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
                JohanRecoveryDetail(recovery: rec, isToday: s.isToday, drivers: s.drivers, confidence: s.confidence,
                                    trend: (0..<14).reversed().map { back in
                                        let key = model.dayKey(offset: model.dayOffset + back)
                                        return .init(key: key, recovery: model.rings(for: key).recovery)
                                    })
            }
        }
        .task(id: HomeLoadKey(dayOffset: model.dayOffset, reload: reloadTick)) {
            await model.load(repo: repo, profile: profile)
        }
        .onReceive(repo.$days.dropFirst()) { _ in
            Task {
                await model.load(repo: repo, profile: profile)
                await model.loadRings(repo: repo)
                await model.loadHealthspan(repo: repo)
                planTonight()
            }
        }
        .task(id: reloadTick) {
            await model.loadRings(repo: repo)
            await model.loadHealthspan(repo: repo)
            planTonight()
        }
        .onChange(of: sleepGoalRaw) { _, _ in planTonight() }
    }

    private func planTonight() {
        let goal = JohanSleepGoal(rawValue: sleepGoalRaw) ?? .peak
        tonight = JohanSleepCoachModel.recommendation(ledger: JohanSleepCoachModel.ledger(days: repo.days), goal: goal)
    }

    /// Reloads the day when it changes or when `JohanRootView` asks every screen to reload.
    private struct HomeLoadKey: Equatable {
        let dayOffset: Int
        let reload: Int
    }

    private static let whole: (Double) -> String = { "\(Int($0.rounded()))" }
    private static let tenth: (Double) -> String = { String(format: "%.1f", $0) }

    /// Wraps content so a tap switches to the tab that explains it.
    private func tabLink<Label: View>(_ tab: JohanTab, hint: String, @ViewBuilder label: () -> Label) -> some View {
        Button { selectTab(tab) } label: { label().contentShape(Rectangle()) }
            .buttonStyle(JohanPressStyle())
            .accessibilityHint(hint)
    }

    // MARK: Header

    /// The day at the top: the date over a large title (tap it for the month calendar), a "Today" pill once
    /// the day is not today, and the strap chip trailing.
    private var header: some View {
        let maxOffset = model.maxOffset(repo: repo)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 12) {
                Button { showCalendar = true } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(dateLine)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(JohanTheme.textSecondary)
                            .lineLimit(1)
                            .id(model.dayOffset)
                            .transition(dayTextTransition)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(dayTitle)
                                .font(.system(.largeTitle, weight: .bold))
                                .foregroundStyle(JohanTheme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .id(model.dayOffset)
                                .transition(dayTextTransition)
                            Image(systemName: "chevron.down")
                                .font(.system(.footnote, weight: .bold))
                                .foregroundStyle(JohanTheme.textTertiary)
                                .rotationEffect(.degrees(showCalendar ? 180 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(JohanPressStyle())
                .accessibilityHint(Text("Opens the calendar"))
                Spacer(minLength: 0)
                if model.dayOffset > 0 {
                    Button { select(0) } label: {
                        Label("Today", systemImage: "arrow.uturn.forward")
                            .labelStyle(.titleAndIcon)
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(JohanTheme.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(Capsule().fill(JohanTheme.card)
                                .overlay(Capsule().strokeBorder(JohanTheme.cardBorder, lineWidth: 0.5)))
                    }
                    .buttonStyle(JohanPressStyle())
                    .padding(.bottom, 6)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                JohanStrapChip().padding(.bottom, 4)
            }
            .animation(JohanTheme.Motion.daySlide, value: model.dayOffset)
        }
        .padding(.top, 4)
        .sheet(isPresented: $showCalendar) {
            JohanMonthCalendar(model: model, maxOffset: maxOffset, onSelect: select)
        }
    }

    /// The date over the title, without the weekday when the title already is the weekday.
    private var dateLine: String {
        let date = model.dayDate(offset: model.dayOffset)
        let style = Date.FormatStyle(locale: AppLanguage.activeLocale)
        let sameYear = Calendar.current.isDate(date, equalTo: model.dayDate(offset: 0), toGranularity: .year)
        if model.dayOffset < 2 { return date.formatted(style.weekday(.wide).day().month(.wide)) }
        return sameYear ? date.formatted(style.day().month(.wide)) : date.formatted(style.day().month(.wide).year())
    }

    /// Header text slides in from the side the day came from, like the content below it.
    private var dayTextTransition: AnyTransition {
        motion.isStill ? .opacity : .asymmetric(
            insertion: .move(edge: enterFromLeading ? .leading : .trailing).combined(with: .opacity),
            removal: .opacity)
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

    /// delta +1 = one day back, -1 = one day forward (the content swipe).
    private func step(_ delta: Int) {
        let next = model.dayOffset + delta
        guard next >= 0, delta < 0 || model.canGoBack(repo: repo) else { return }
        select(next)
    }

    /// Jump to any day. The direction is committed first so the outgoing content's removal transition
    /// already carries it, then the day changes in the next turn.
    private func select(_ offset: Int) {
        guard offset != model.dayOffset, offset >= 0, offset <= model.maxOffset(repo: repo) else { return }
        enterFromLeading = offset > model.dayOffset
        StrandHaptic.selection.play()
        DispatchQueue.main.async {
            if motion.isStill { model.dayOffset = offset }
            else { withAnimation(JohanTheme.Motion.daySlide) { model.dayOffset = offset } }
        }
    }

    // MARK: Rings

    /// Recovery, sleep and strain as concentric rings (outermost first), the recovery ring in its zone colour
    /// over a soft glow of the same. Tapping explains the recovery score; there is nothing to explain without one.
    private func ringsHero(_ s: JohanHomeModel.Snapshot, zone: JohanTheme.RecoveryZone?, recColor: Color,
                           size: CGFloat) -> some View {
        let introDone = introPhase == .done
        return Button { showRecoveryDetail = true } label: {
            JohanActivityRings(rings: [
                .init(fraction: s.recovery.map { $0 / 100 }, color: recColor),
                .init(fraction: s.sleepPct.map { $0 / 100 }, color: JohanTheme.sleepViolet),
                .init(fraction: s.strain21.map { $0 / 21 }, color: JohanTheme.strainBlue),
            // Held at -1 while the intro's rings fly in, so the sweep starts the moment they land.
            ], size: size, lineWidth: size * 0.088, spacing: size * 0.016, replayKey: introDone ? model.dayOffset : -1)
            // The glow sits behind without taking layout space, so it never pushes the rings apart from
            // the header and the values.
            .background { JohanAmbientGlow(color: zone?.color ?? JohanTheme.strainBlue, size: size * 1.35) }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            // Hidden under the intro's rings until they land on this spot. Shown at once, not faded: the
            // intro's tracks vanish in the same frame, so a fade would read as a dip.
            .opacity(introDone ? 1 : 0)
        }
        .buttonStyle(JohanPressStyle())
        .disabled(s.recovery == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ringsAccessibilityLabel(s))
        .accessibilityHint(s.recovery == nil ? "" : String(localized: "Shows what shaped your recovery"))
    }

    /// Tells the launch intro where these rings sit and in which colour the recovery ring lands.
    @ViewBuilder
    private func introTargetReader(size: CGFloat, recColor: Color) -> some View {
        if introPhase != .done {
            GeometryReader { g in
                let target = JohanIntroTarget(center: CGPoint(x: g.frame(in: .global).midX, y: g.frame(in: .global).midY),
                                              size: size, recoveryColor: recColor)
                Color.clear
                    .onAppear { reportIntroTarget(target) }
                    .onChange(of: target) { _, t in reportIntroTarget(t) }
            }
        }
    }

    private func ringsAccessibilityLabel(_ s: JohanHomeModel.Snapshot) -> String {
        let rec = s.recovery.map { "\(Int($0.rounded())) %" } ?? "–"
        let sleep = s.sleepPct.map { "\(Int($0.rounded())) %" } ?? "–"
        let strain = s.strain21.map { String(format: "%.1f", $0) } ?? "–"
        return String(localized: "Recovery \(rec), sleep \(sleep), strain \(strain) of 21")
    }

    // MARK: Stats

    /// The three ring values under the rings, each labelled in its ring's colour. Sleep and strain open
    /// their tabs; recovery opens its breakdown.
    private func statsRow(_ s: JohanHomeModel.Snapshot, recColor: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { showRecoveryDetail = true } label: {
                stat(String(localized: "Recovery"), s.recovery, format: Self.whole, unit: "%", color: recColor)
            }
            .buttonStyle(JohanPressStyle())
            .disabled(s.recovery == nil)
            tabLink(.sleep, hint: String(localized: "Opens Sleep")) {
                stat(String(localized: "Sleep"), s.sleepPct, format: Self.whole, unit: "%", color: JohanTheme.sleepViolet)
            }
            tabLink(.strain, hint: String(localized: "Opens Strain")) {
                stat(String(localized: "Strain"), s.strain21, format: Self.tenth, unit: "/21", color: JohanTheme.strainBlue)
            }
        }
    }

    private func stat(_ title: String, _ value: Double?, format: @escaping (Double) -> String, unit: String,
                      color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(.footnote, weight: .semibold)).foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                if let value {
                    CountUpText(value: value, format: format, font: JohanTheme.number(30),
                                color: JohanTheme.textPrimary, animation: JohanTheme.Motion.countUp)
                        .id(model.dayOffset)
                    Text(unit).font(.system(.callout, design: .rounded, weight: .semibold))
                        .foregroundStyle(JohanTheme.textSecondary)
                } else {
                    Text("–").font(JohanTheme.number(30)).foregroundStyle(JohanTheme.textTertiary)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Status

    /// What today means: the recovery zone and its training hint, or, while the baselines form, how far
    /// calibration has come. A past day shows the zone without advice for a day that is over.
    @ViewBuilder
    private func statusCard(_ s: JohanHomeModel.Snapshot, zone: JohanTheme.RecoveryZone?) -> some View {
        if let day = s.calibrationDay {
            statusRow(icon: "hourglass", color: JohanTheme.strainBlue,
                      title: String(localized: "Calibrating · day \(String(day)) of \(String(model.calibrationLength))"),
                      detail: String(localized: "Recovery and sleep appear after the first nights, once your personal baselines are set. Wear the strap overnight too."))
        } else if let zone {
            statusRow(icon: "checkmark", color: zone.color, title: zone.title,
                      detail: s.isToday ? zone.hint : nil)
        }
    }

    private func statusRow(icon: String, color: Color, title: String, detail: String?) -> some View {
        JohanCard {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(color.opacity(0.16)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(.headline)).foregroundStyle(JohanTheme.textPrimary)
                    if let detail {
                        Text(detail).font(.system(.subheadline)).foregroundStyle(JohanTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Strain target

    /// The recovery-based target range with a small gauge of today's strain; opens the Strain tab.
    private func strainTargetCard(_ s: JohanHomeModel.Snapshot, recColor: Color) -> some View {
        Button { selectTab(.strain) } label: {
            JohanCard(padding: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Strain target").font(.system(.footnote, weight: .semibold)).foregroundStyle(JohanTheme.strainBlue)
                    if let band = s.targetBand {
                        Text("\(band.lowerBound)–\(band.upperBound)")
                            .font(JohanTheme.number(34)).foregroundStyle(recColor)
                            .contentTransition(.numericText())
                        miniGauge(band: band, current: s.strain21, color: recColor).padding(.top, 6)
                        Text(JohanStrainView.progressText(current: s.strain21, band: band, isToday: s.isToday))
                            .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    } else {
                        Text("–").font(JohanTheme.number(34)).foregroundStyle(JohanTheme.textTertiary)
                        Text("The target follows your recovery and appears once it has been calculated.")
                            .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .buttonStyle(JohanPressStyle())
        .accessibilityHint("Opens Strain")
    }

    /// Track 0–21, the target range outlined in the recovery colour, the day's strain filled in.
    private func miniGauge(band: ClosedRange<Int>, current: Double?, color: Color) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = { (v: Double) in w * CGFloat(min(max(v, 0), 21) / 21) }
            ZStack(alignment: .leading) {
                Capsule().fill(JohanTheme.track)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(color, lineWidth: 1.5))
                    .frame(width: x(Double(band.upperBound)) - x(Double(band.lowerBound)), height: 14)
                    .offset(x: x(Double(band.lowerBound)))
                Capsule().fill(JohanTheme.strainBlue)
                    .frame(width: max(8, x(current ?? 0)))
                    .opacity(current == nil ? 0 : 1)
                    .animation(.spring(response: 1, dampingFraction: 0.85), value: current)
            }
            .frame(height: 8)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    // MARK: Vitals

    /// The nightly vitals, in WHOOP's Health Monitor set: HRV, resting HR and respiratory rate against the
    /// personal average, then SpO₂ and skin temperature. Opens the full Health screen.
    private func vitalsCard(_ s: JohanHomeModel.Snapshot) -> some View {
        NavigationLink {
            HealthView()
                .background(JohanTheme.background.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            JohanCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Vitals").font(.system(.headline)).foregroundStyle(JohanTheme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(JohanTheme.textTertiary)
                    }
                    JohanAdaptiveStack(spacing: 8) {
                        vital("HRV", s.hrv, unit: "ms", decimals: 0, higherIsBetter: true)
                        vital(String(localized: "Resting HR"), s.restingHR, unit: "bpm", decimals: 0, higherIsBetter: false)
                        vital(String(localized: "Respiratory rate"), s.resp, unit: "/min", decimals: 1, higherIsBetter: nil)
                    }
                    JohanAdaptiveStack(spacing: 8) {
                        vital(String(localized: "Blood oxygen"), JohanHomeModel.Vital(value: s.spo2), unit: "%",
                              decimals: 0, higherIsBetter: nil,
                              caption: s.spo2IsEstimate ? String(localized: "estimate") : nil)
                        skinTempTile(s)
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1).accessibilityHidden(true)
                    }
                    if s.hrv.baseline == nil && s.restingHR.baseline == nil && s.resp.baseline == nil {
                        Text(s.isToday ? String(localized: "The comparison with your average (Ø) follows after calibration.") : String(localized: "Past days have no comparison with your average."))
                            .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                    }
                }
            }
        }
        .buttonStyle(JohanPressStyle())
        .accessibilityHint(Text("Opens Health"))
    }

    /// Skin temperature as the Health screen shows it: the absolute night mean or its deviation, whichever
    /// the wearer prefers and the night has, in their temperature unit. A deviation reads as its own delta.
    private func skinTempTile(_ s: JohanHomeModel.Snapshot) -> some View {
        let reading = SkinTempDisplay.leadReading(absC: s.skinTempAbsC, devC: s.skinTempDevC,
                                                  prefer: SkinTempDisplay.Kind(rawValue: skinTempDisplayRaw) ?? .absolute)
        let unit = UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                                override: temperatureRaw)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Skin temp").font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(TodayView.skinTempCardValue(reading: reading, fahrenheit: unit == .fahrenheit))
                .johanNumberFont(22)
                .foregroundStyle(reading == nil ? JohanTheme.textTertiary : JohanTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            if reading?.kind == .deviation {
                Text("vs. your baseline").font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(JohanTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Tonight

    /// When to go to bed tonight, the Sleep tab's plan in one line; opens Sleep.
    private func tonightCard(_ rec: JohanSleepCoachModel.Recommendation) -> some View {
        let goal = JohanSleepGoal(rawValue: sleepGoalRaw) ?? .peak
        return tabLink(.sleep, hint: String(localized: "Opens Sleep")) {
            JohanCard {
                HStack(spacing: 14) {
                    Image(systemName: "bed.double.fill")
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(JohanTheme.sleepViolet)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(JohanTheme.sleepViolet.opacity(0.16)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tonight").font(.system(.footnote, weight: .semibold)).foregroundStyle(JohanTheme.sleepViolet)
                        Text("In bed by \(Self.clock(rec.bedtimeMinutes))")
                            .font(.system(.headline)).foregroundStyle(JohanTheme.textPrimary)
                        Text("\(goal.title): \(JohanSleepText.hm(rec.targetSleepMin)) of sleep, up at \(Self.clock(rec.wakeMinutes))")
                            .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(JohanTheme.textTertiary)
                }
            }
        }
    }

    private static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    // MARK: Healthspan

    /// Body Age, VO₂max and Vitality, the weekly long-term figures; opens the Healthspan page.
    private func healthspanCard(_ h: JohanHomeModel.Healthspan) -> some View {
        NavigationLink { JohanHealthspanView() } label: {
            JohanCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Healthspan").font(.system(.headline)).foregroundStyle(JohanTheme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(JohanTheme.textTertiary)
                    }
                    JohanAdaptiveStack(spacing: 8) {
                        longTerm(String(localized: "Body Age"), h.bodyAge.map { "\(Int($0.rounded()))" },
                                 unit: String(localized: "yrs"),
                                 note: h.bodyAge.map { JohanHealthspanView.ageDeltaLine(Double(profile.age) - $0) })
                        longTerm(String(localized: "VO₂max"), h.vo2max.map { String(format: "%.1f", $0) },
                                 unit: "ml/kg/min", note: nil)
                        longTerm(String(localized: "Vitality"), h.vitality.map { "\(Int($0.rounded()))" },
                                 unit: "/100", note: nil)
                    }
                }
            }
        }
        .buttonStyle(JohanPressStyle())
        .accessibilityHint(Text("Opens Healthspan"))
    }

    private func longTerm(_ title: String, _ value: String?, unit: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "–").johanNumberFont(22)
                    .foregroundStyle(value == nil ? JohanTheme.textTertiary : JohanTheme.textPrimary)
                if value != nil {
                    Text(unit).font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            if let note {
                Text(note).font(.system(.caption2, weight: .semibold)).foregroundStyle(JohanTheme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func vital(_ title: String, _ v: JohanHomeModel.Vital, unit: String, decimals: Int,
                       higherIsBetter: Bool?, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            // Unit on the number's baseline: one line instead of two, and it reads as "89 ms".
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(v.value.map { String(format: "%.\(decimals)f", $0) } ?? "–").johanNumberFont(22)
                if v.value != nil {
                    Text(unit).font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                }
            }
            if let d = v.delta {
                deltaLabel(d, decimals: decimals, higherIsBetter: higherIsBetter)
            } else if let caption {
                Text(caption).font(.system(.caption2, weight: .semibold)).foregroundStyle(JohanTheme.textSecondary)
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
            HStack(spacing: 6) {
                // While waiting the heart beats at a calm resting tempo as a loading cue, dimmed so it is
                // not read as a measurement; the live value takes over its tempo on arrival.
                JohanPulsingHeart(bpm: liveBPM ?? (waiting ? 60 : nil), size: 14)
                    .opacity(liveBPM == nil ? 0.5 : 1)
                Text("Heart rate").font(.system(.footnote, weight: .semibold)).foregroundStyle(JohanTheme.recoveryRed)
                Spacer(minLength: 0)
                Circle().fill(live.connected ? JohanTheme.recoveryGreen : JohanTheme.textTertiary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(liveBPM.map(String.init) ?? stored.map { String($0.bpm) } ?? "–").font(JohanTheme.number(34))
                    .foregroundStyle(liveBPM == nil ? JohanTheme.textTertiary : JohanTheme.textPrimary)
                    .contentTransition(.numericText())
                    .animation(JohanTheme.Motion.cardIn, value: liveBPM)
                Text("bpm").font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(JohanTheme.textSecondary)
            }
            if waiting {
                JohanHRSearching().transition(.opacity)
            } else if samples.count >= 2 {
                JohanSparkline(values: samples)
            }
            // Connected but no reading says exactly that; why the strap sends none is not known here.
            Text(liveStatus(liveBPM: liveBPM, stored: stored))
                .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
struct JohanLiveHRDemand: ViewModifier {
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
