#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

// JohanWeekStory.swift — the Weekly Review as a full-screen story: one loud slide per fact, segmented
// progress along the top, tap right / left to step, hold to pause, swipe down to close. Every figure comes
// from `JohanWeekReview`; nothing is re-scored here.

extension JohanWeekReview {
    var hasData: Bool { days.contains { $0.recovery != nil || $0.sleepMin != nil || $0.strain21 != nil } }
    var trackedDays: Int { days.filter { $0.recovery != nil || $0.sleepMin != nil || $0.strain21 != nil }.count }
    var totalSleepMin: Double? {
        let nights = days.compactMap(\.sleepMin).filter { $0 > 0 }
        return nights.isEmpty ? nil : nights.reduce(0, +)
    }
    var peakStrainDay: Day? {
        days.filter { $0.strain21 != nil }.max { ($0.strain21 ?? 0) < ($1.strain21 ?? 0) }
    }
}

/// The slides a week has data for, in playing order.
enum JohanWeekStorySlide: Hashable {
    case intro, recovery, recoveryDays, sleep, strain, heart, best, toughest, summary

    static func slides(for r: JohanWeekReview) -> [JohanWeekStorySlide] {
        var out: [JohanWeekStorySlide] = [.intro]
        if r.averages.recovery != nil { out += [.recovery, .recoveryDays] }
        if r.totalSleepMin != nil { out.append(.sleep) }
        if r.averages.strain21 != nil { out.append(.strain) }
        if r.averages.hrv != nil || r.averages.restingHR != nil { out.append(.heart) }
        if r.best != nil { out.append(.best) }
        if r.worst != nil { out.append(.toughest) }
        out.append(.summary)
        return out
    }
}

// MARK: - Player

struct JohanWeekStoryView: View {
    let review: JohanWeekReview
    /// "This week" / "Last week" / "3 weeks ago", as the review screen names it.
    let weekTitle: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    private let motion = JohanStill()

    @State private var index = 0
    @State private var forwardStep = true
    /// Share of the current slide that has played, 0...1.
    @State private var progress: Double = 0
    @State private var pressStart: Date?
    @State private var holding = false
    @State private var dragY: CGFloat = 0

    private var slides: [JohanWeekStorySlide] { JohanWeekStorySlide.slides(for: review) }
    private var current: JohanWeekStorySlide { slides[min(index, slides.count - 1)] }
    /// VoiceOver users step with the adjustable action instead of racing a timer. Only `.background`
    /// pauses: a scene can sit in `.inactive` while fully on screen.
    private var paused: Bool { pressStart != nil || dragY > 0 || scenePhase == .background || voiceOver }

    var body: some View {
        // The slides run edge to edge (under the island and the home indicator), so the safe area is read
        // here and handed down as padding.
        GeometryReader { geo in
            ZStack(alignment: .top) {
                JohanStorySlideView(slide: current, review: review, weekTitle: weekTitle, insets: geo.safeAreaInsets)
                    .id(index)
                    .transition(slideTransition)

                chrome
                    .padding(.top, geo.safeAreaInsets.top)
                    .opacity(holding ? 0 : 1)
                    .animation(.easeOut(duration: 0.2), value: holding)
            }
            .clipShape(RoundedRectangle(cornerRadius: dragY > 0 ? JohanTheme.Story.sheetRadius : 0,
                                        style: .continuous))
            .scaleEffect(1 - min(dragY, 400) / 2000)
            .offset(y: dragY)
            .contentShape(Rectangle())
            .gesture(touch(width: geo.size.width))
            .ignoresSafeArea()
        }
        .background(JohanTheme.background.opacity(1 - Double(min(dragY, 400)) / 600).ignoresSafeArea())
        .statusBarHidden()
        .sensoryFeedback(.selection, trigger: index)
        .task(id: index) { await play() }
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(by: 1)
            case .decrement: step(by: -1)
            @unknown default: break
            }
        }
        .accessibilityAction(.escape) { dismiss() }
    }

    private var slideTransition: AnyTransition {
        if motion.isStill { return .opacity }
        return .asymmetric(insertion: .move(edge: forwardStep ? .trailing : .leading).combined(with: .opacity),
                           removal: .opacity)
    }

    // MARK: Chrome

    private var onColour: Bool { JohanStorySlideView.style(for: current, review: review).coloured }

    private var chrome: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(slides.indices, id: \.self) { i in
                    GeometryReader { bar in
                        Capsule()
                            .fill(onColour ? JohanTheme.Story.inkProgressTrack : JohanTheme.Story.progressTrack)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(onColour ? JohanTheme.Story.inkProgressFill : JohanTheme.Story.progressFill)
                                    .frame(width: bar.size.width * fill(for: i))
                            }
                    }
                    .frame(height: 3)
                }
            }
            HStack {
                Text("Weekly Review").font(JohanTheme.Story.label)
                Text(JohanWeekView.range(review.weekStart)).font(JohanTheme.Fonts.caption).opacity(0.75)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(.title3, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("Close"))
            }
        }
        .foregroundStyle(onColour ? JohanTheme.Story.ink : JohanTheme.textPrimary)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
    }

    private func fill(for i: Int) -> CGFloat {
        i < index ? 1 : i > index ? 0 : CGFloat(progress)
    }

    // MARK: Timing

    @MainActor private func play() async {
        progress = 0
        var last = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(33))
            let now = Date()
            let dt = now.timeIntervalSince(last)
            last = now
            if let pressStart, !holding, now.timeIntervalSince(pressStart) >= JohanTheme.Motion.storyHold {
                holding = true
            }
            guard !paused else { continue }
            progress = min(1, progress + dt / JohanTheme.Motion.storySlide)
            if progress >= 1 {
                // The summary stays up so it can be read and shared; every other slide moves on.
                if index < slides.count - 1 { step(by: 1) }
                return
            }
        }
    }

    private func step(by delta: Int) {
        let target = index + delta
        if target >= slides.count { dismiss(); return }
        if target < 0 { progress = 0; return }
        forwardStep = delta > 0
        if motion.isStill {
            index = target
        } else {
            withAnimation(JohanTheme.Motion.storyStep) { index = target }
        }
    }

    // MARK: Touch

    /// One gesture for everything, so a tap, a hold and a pull-down never fight: a short touch steps (left
    /// third back, the rest forward), a long one pauses for as long as it is held, a pull down closes.
    private func touch(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pressStart == nil { pressStart = Date() }
                let pull = value.translation.height
                if pull > 0, abs(pull) > abs(value.translation.width) { dragY = pull }
            }
            .onEnded { value in
                let held = pressStart.map { Date().timeIntervalSince($0) } ?? 0
                let moved = hypot(value.translation.width, value.translation.height)
                pressStart = nil
                holding = false
                if dragY > 140 || value.predictedEndTranslation.height > 400 {
                    dismiss()
                    return
                }
                withAnimation(JohanTheme.Motion.storyStep) { dragY = 0 }
                guard held < JohanTheme.Motion.storyHold, moved < 12 else { return }
                step(by: value.startLocation.x < width / 3 ? -1 : 1)
            }
    }
}

// MARK: - Slides

struct JohanStorySlideView: View {
    let slide: JohanWeekStorySlide
    let review: JohanWeekReview
    let weekTitle: String
    var insets = EdgeInsets()

    struct Style {
        let background: Color
        /// True for a single-hue slide with black ink; false for a black slide with white ink.
        let coloured: Bool
    }

    static func style(for slide: JohanWeekStorySlide, review: JohanWeekReview) -> Style {
        switch slide {
        case .intro, .recoveryDays, .summary:
            return Style(background: JohanTheme.background, coloured: false)
        case .recovery:
            return Style(background: JohanTheme.recoveryColor(review.averages.recovery ?? 0), coloured: true)
        case .sleep: return Style(background: JohanTheme.sleepViolet, coloured: true)
        case .strain: return Style(background: JohanTheme.strainBlue, coloured: true)
        case .heart: return Style(background: JohanTheme.recoveryRed, coloured: true)
        case .best: return Style(background: JohanTheme.recoveryGreen, coloured: true)
        case .toughest: return Style(background: JohanTheme.stageREM, coloured: true)
        }
    }

    private var style: Style { Self.style(for: slide, review: review) }
    private var ink: Color { style.coloured ? JohanTheme.Story.ink : JohanTheme.textPrimary }
    private var inkSecondary: Color { style.coloured ? JohanTheme.Story.inkSecondary : JohanTheme.textSecondary }

    var body: some View {
        ZStack {
            style.background
            JohanStoryBlobs(colours: blobColours)
            content
                .foregroundStyle(ink)
                .padding(.horizontal, 28)
                .padding(.top, insets.top + 96)
                .padding(.bottom, insets.bottom + 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var blobColours: [Color] {
        switch slide {
        case .intro: return [JohanTheme.sleepViolet, JohanTheme.recoveryGreen, JohanTheme.strainBlue]
        case .recoveryDays: return [JohanTheme.recoveryColor(review.averages.recovery ?? 0)]
        case .summary: return [JohanTheme.stageREM, JohanTheme.sleepViolet]
        default: return [JohanTheme.Story.blob, JohanTheme.Story.blob]
        }
    }

    @ViewBuilder private var content: some View {
        switch slide {
        case .intro: intro
        case .recovery: recovery
        case .recoveryDays: recoveryDays
        case .sleep: sleep
        case .strain: strain
        case .heart: heart
        case .best: day(String(localized: "Best day"), review.best)
        case .toughest: day(String(localized: "Toughest day"), review.worst)
        case .summary: summary
        }
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text(weekTitle).font(JohanTheme.Story.kicker).foregroundStyle(inkSecondary).storyRise(0)
            Text("Your week, wrapped.").font(JohanTheme.Story.headline).storyRise(1)
            Text(JohanWeekView.range(review.weekStart)).font(JohanTheme.Story.label).storyRise(2)
            Spacer()
            Label(String(localized: "Tap to continue, hold to pause"), systemImage: "hand.tap")
                .font(JohanTheme.Fonts.caption).foregroundStyle(inkSecondary).storyRise(3)
        }
    }

    // MARK: Recovery

    private var recovery: some View {
        let avg = review.averages.recovery ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text("Your average recovery").font(JohanTheme.Story.kicker).storyRise(0)
            JohanStoryCount(value: avg, size: 120) { "\(Int($0.rounded())) %" }.storyRise(1)
            Text(JohanTheme.RecoveryZone(avg).title).font(JohanTheme.Story.headline).storyRise(2)
            change(avg, review.previous.recovery, unit: { Self.points($0) }).storyRise(3)
            Spacer()
        }
    }

    private var recoveryDays: some View {
        let peak = review.best
        return VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("Your week, day by day").font(JohanTheme.Story.headline).storyRise(0)
            JohanStoryBars(days: review.days).frame(height: 260).storyRise(1)
            if let peak {
                Text("\(JohanWeekView.weekday(peak.key, short: false)) was your peak")
                    .font(JohanTheme.Story.kicker).foregroundStyle(inkSecondary).storyRise(2)
            }
            Spacer()
        }
    }

    // MARK: Sleep

    private var sleep: some View {
        let total = review.totalSleepMin ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text("This week you slept").font(JohanTheme.Story.kicker).storyRise(0)
            JohanStoryCount(value: total / 60, size: 120) { "\(Int($0.rounded())) h" }.storyRise(1)
            if let avg = review.averages.sleepMin {
                Text("That is \(JohanWeekView.hours(avg)) a night on average")
                    .font(JohanTheme.Story.headline).storyRise(2)
                change(avg, review.previous.sleepMin, unit: { "\(Int($0.rounded())) min" }).storyRise(3)
            }
            Spacer()
        }
    }

    // MARK: Strain

    private var strain: some View {
        let avg = review.averages.strain21 ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text("Your average strain").font(JohanTheme.Story.kicker).storyRise(0)
            JohanStoryCount(value: avg, size: 120) { String(format: "%.1f", $0) }.storyRise(1)
            if let peak = review.peakStrainDay, let value = peak.strain21 {
                Text("Highest: \(String(format: "%.1f", value)) on \(JohanWeekView.weekday(peak.key, short: false))")
                    .font(JohanTheme.Story.headline).storyRise(2)
            }
            change(avg, review.previous.strain21, unit: { String(format: "%.1f", $0) }).storyRise(3)
            Spacer()
        }
    }

    // MARK: Heart

    private var heart: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            Text("Your heart").font(JohanTheme.Story.headline).storyRise(0)
            if let hrv = review.averages.hrv {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HRV").font(JohanTheme.Story.kicker)
                    JohanStoryCount(value: hrv, size: 84) { "\(Int($0.rounded())) ms" }
                    change(hrv, review.previous.hrv, unit: { "\(Int($0.rounded())) ms" })
                }
                .storyRise(1)
            }
            if let rhr = review.averages.restingHR {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resting HR").font(JohanTheme.Story.kicker)
                    JohanStoryCount(value: rhr, size: 84) { "\(Int($0.rounded())) bpm" }
                    change(rhr, review.previous.restingHR, unit: { "\(Int($0.rounded())) bpm" })
                }
                .storyRise(2)
            }
            Spacer()
        }
    }

    // MARK: Best / toughest

    private func day(_ title: String, _ day: JohanWeekReview.Day?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text(title).font(JohanTheme.Story.kicker).storyRise(0)
            Text(day.map { JohanWeekView.weekday($0.key, short: false) } ?? "–")
                .font(JohanTheme.Story.headline).scaleEffect(1.4, anchor: .leading)
                .padding(.vertical, 8)
                .storyRise(1)
            if let day {
                VStack(alignment: .leading, spacing: 10) {
                    statLine(String(localized: "Recovery"), day.recovery.map { "\(Int($0.rounded())) %" })
                    statLine(String(localized: "Sleep"), day.sleepMin.map(JohanWeekView.hours))
                    statLine(String(localized: "Strain"), day.strain21.map { String(format: "%.1f", $0) })
                }
                .storyRise(2)
            }
            Spacer()
        }
    }

    private func statLine(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(JohanTheme.Story.kicker)
            Spacer()
            Text(value ?? "–").johanNumberFont(34, relativeTo: .title)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(inkSecondary.opacity(0.4)).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    // MARK: Summary

    private var summary: some View {
        let image = JohanStorySummaryCard.snapshot(review: review, weekTitle: weekTitle)
        return VStack(alignment: .leading, spacing: 20) {
            Spacer()
            JohanStorySummaryCard(review: review, weekTitle: weekTitle).storyRise(0)
            ShareLink(item: image, preview: SharePreview(String(localized: "Weekly Review"), image: image)) {
                Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                    .font(JohanTheme.Story.label)
                    .foregroundStyle(JohanTheme.Story.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(JohanTheme.textPrimary))
            }
            .storyRise(1)
            Spacer()
        }
    }

    // MARK: Pieces

    /// The change from the week before in plain words; silent when there is no earlier week to compare.
    @ViewBuilder private func change(_ value: Double, _ previous: Double?, unit: (Double) -> String) -> some View {
        if let previous {
            let delta = value - previous
            Label {
                Text(abs(delta) < 0.5 ? String(localized: "Same as last week")
                     : delta > 0 ? String(localized: "\(unit(abs(delta))) more than last week")
                                 : String(localized: "\(unit(abs(delta))) less than last week"))
            } icon: {
                Image(systemName: abs(delta) < 0.5 ? "equal" : delta > 0 ? "arrow.up.right" : "arrow.down.right")
            }
            .font(JohanTheme.Story.label)
            .foregroundStyle(inkSecondary)
        }
    }

    private static func points(_ value: Double) -> String {
        String(localized: "\(Int(value.rounded())) points")
    }
}

// MARK: - Summary card

/// The closing card, and the image that Share hands to the system sheet.
struct JohanStorySummaryCard: View {
    let review: JohanWeekReview
    let weekTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(weekTitle).font(JohanTheme.Story.kicker).foregroundStyle(JohanTheme.Story.inkSecondary)
                Text("Your week in numbers").font(JohanTheme.Story.headline)
                Text(JohanWeekView.range(review.weekStart)).font(JohanTheme.Story.label)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 16) {
                cell(String(localized: "Recovery"), review.averages.recovery.map { "\(Int($0.rounded())) %" })
                cell(String(localized: "Sleep"), review.averages.sleepMin.map(JohanWeekView.hours))
                cell(String(localized: "Strain"), review.averages.strain21.map { String(format: "%.1f", $0) })
                cell(String(localized: "HRV"), review.averages.hrv.map { "\(Int($0.rounded())) ms" })
                cell(String(localized: "Best day"), review.best.map { JohanWeekView.weekday($0.key, short: false) })
                cell(String(localized: "Resting HR"), review.averages.restingHR.map { "\(Int($0.rounded())) bpm" })
            }
            Text("\(review.trackedDays) of 7 days tracked")
                .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.Story.inkSecondary)
        }
        .foregroundStyle(JohanTheme.Story.ink)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: JohanTheme.Story.sheetRadius, style: .continuous)
                .fill(LinearGradient(colors: [JohanTheme.sleepViolet, JohanTheme.strainBlue, JohanTheme.recoveryGreen],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
    }

    private func cell(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.Story.inkSecondary)
            Text(value ?? "–").johanNumberFont(26, relativeTo: .title2).lineLimit(1).minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
    }

    @MainActor static func snapshot(review: JohanWeekReview, weekTitle: String) -> Image {
        let renderer = ImageRenderer(content:
            JohanStorySummaryCard(review: review, weekTitle: weekTitle)
                .padding(20)
                .frame(width: 390)
                .background(JohanTheme.background)
                .environment(\.colorScheme, .dark))
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) } ?? Image(systemName: "calendar")
    }
}

// MARK: - Bits

/// A figure that counts up from zero when its slide appears (shown at once when motion is held still).
struct JohanStoryCount: View {
    let value: Double
    var size: CGFloat = 96
    let format: (Double) -> String
    private let motion = JohanStill()
    @State private var shown: Double = 0

    var body: some View {
        CountingText(value: motion.isStill ? value : shown, format: format)
            .johanNumberFont(size, relativeTo: .largeTitle)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .accessibilityLabel(Text(format(value)))
            .onAppear {
                guard !motion.isStill else { return }
                withAnimation(JohanTheme.Motion.storyCount.delay(0.2)) { shown = value }
            }
    }

    private struct CountingText: View, Animatable {
        var value: Double
        let format: (Double) -> String
        var animatableData: Double {
            get { value }
            set { value = newValue }
        }
        var body: some View { Text(format(value)) }
    }
}

/// Seven recovery bars that grow one after another.
struct JohanStoryBars: View {
    let days: [JohanWeekReview.Day]
    private let motion = JohanStill()
    @State private var grown = false

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(days.enumerated()), id: \.element.key) { i, day in
                    VStack(spacing: 8) {
                        Text(day.recovery.map { "\(Int($0.rounded()))" } ?? "–")
                            .johanNumberFont(17)
                            .foregroundStyle(JohanTheme.textPrimary)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(day.recovery.map(JohanTheme.recoveryColor) ?? JohanTheme.track)
                            .frame(height: barHeight(day, in: geo.size.height - 56))
                            .animation(JohanTheme.Motion.barGrow.delay(0.3 + Double(i) * 0.08), value: grown)
                        Text(JohanWeekView.weekday(day.key, short: true))
                            .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .onAppear { grown = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(days.map {
            "\(JohanWeekView.weekday($0.key, short: false)) \($0.recovery.map { "\(Int($0.rounded())) %" } ?? "–")"
        }.joined(separator: ", ")))
    }

    private func barHeight(_ day: JohanWeekReview.Day, in height: CGFloat) -> CGFloat {
        let full = max(8, height * (day.recovery ?? 0) / 100)
        return grown || motion.isStill ? full : 8
    }
}

/// Large soft shapes drifting behind a slide. Decoration only; still when the motion gate is closed.
struct JohanStoryBlobs: View {
    let colours: [Color]
    private let motion = JohanStill()
    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                ForEach(Array(colours.enumerated()), id: \.offset) { i, colour in
                    Circle()
                        .fill(colour.opacity(colour == JohanTheme.Story.blob ? 1 : 0.55))
                        .frame(width: w * (0.9 - CGFloat(i) * 0.15))
                        .blur(radius: colour == JohanTheme.Story.blob ? 0 : 60)
                        .offset(x: (i.isMultiple(of: 2) ? 1 : -1) * w * (drift ? 0.32 : 0.18),
                                y: geo.size.height * (CGFloat(i) * 0.3 - 0.25 + (drift ? 0.06 : -0.06)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !motion.isStill else { return }
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

private struct JohanStoryRise: ViewModifier {
    let index: Int
    private let motion = JohanStill()
    @State private var shown = false

    func body(content: Content) -> some View {
        let visible = shown || motion.isStill
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 28)
            .onAppear {
                guard !motion.isStill else { return }
                withAnimation(JohanTheme.Motion.storyRise.delay(0.1 + Double(index) * JohanTheme.Motion.storyRiseStep)) {
                    shown = true
                }
            }
    }
}

extension View {
    /// Fade + rise when a story slide appears, `index` steps after the first line.
    fileprivate func storyRise(_ index: Int) -> some View { modifier(JohanStoryRise(index: index)) }
}

// MARK: - Entry card

/// The story's cover on the Weekly Review screen: a ringed badge in the way a story is offered, tapping
/// it plays the week.
struct JohanWeekStoryCover: View {
    let review: JohanWeekReview
    let weekTitle: String
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .strokeBorder(AngularGradient(colors: [JohanTheme.stageREM, JohanTheme.sleepViolet,
                                                               JohanTheme.strainBlue, JohanTheme.recoveryGreen,
                                                               JohanTheme.stageREM], center: .center),
                                      lineWidth: 3)
                    Circle().fill(JohanTheme.background).padding(5)
                    Image(systemName: "play.fill").font(.system(.title3)).foregroundStyle(JohanTheme.textPrimary)
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your week, wrapped.").font(JohanTheme.Story.label).foregroundStyle(JohanTheme.Story.ink)
                    Text("\(weekTitle) · \(review.trackedDays) of 7 days tracked")
                        .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.Story.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(JohanTheme.Story.inkSecondary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: JohanTheme.Metrics.cardRadius, style: .continuous)
                    .fill(LinearGradient(colors: [JohanTheme.sleepViolet, JohanTheme.strainBlue, JohanTheme.recoveryGreen],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            )
        }
        .buttonStyle(JohanPressStyle())
        .accessibilityHint(Text("Plays the week as a story"))
    }
}

#if DEBUG
/// DEBUG-only host so `--demo-screen weekstory` plays last week's story over the seeded store.
struct JohanWeekStoryDemoHost: View {
    @EnvironmentObject private var repo: Repository

    var body: some View {
        let today = Repository.logicalDayKey(Date())
        let monday = WeeklyDigestEngine.mondayOfWeek(containing: today) ?? today
        JohanWeekStoryView(review: JohanWeekReview.build(rows: repo.days, weekStart: WeeklyDigestEngine.addDays(monday, -7)),
                           weekTitle: String(localized: "Last week"))
            .toolbar(.hidden, for: .navigationBar)
    }
}
#endif
#endif
