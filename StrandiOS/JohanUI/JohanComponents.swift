#if os(iOS)
import SwiftUI
import Charts
import StrandDesign

// JohanComponents.swift — reusable animated components. Visual constants come from `JohanTheme`,
// timings from `JohanTheme.Motion`, the still-gate from `JohanStill`.

// MARK: - Dial

/// Circular score dial. The arc sweeps from 0 with a spring on first appearance, whenever `replayKey`
/// changes (day change), and from the current position when `fraction` changes. The number counts up in
/// step (StrandDesign `CountUpText`) and, if requested, a light haptic fires when the sweep settles.
struct JohanDial: View {
    let title: String
    /// nil draws the empty track and an en dash.
    let value: Double?
    let format: (Double) -> String
    var unitText: String?
    let fraction: Double?
    let color: Color
    var replayKey: Int = 0
    var hapticOnSettle = false
    var size: CGFloat = JohanTheme.Metrics.dialSize
    /// Number size relative to the dial diameter.
    var numberScale: CGFloat = 0.30
    /// False hides the caption under the ring when the text right below already names it (Home hero +
    /// verdict). VoiceOver still announces `title`.
    var showsTitle = true

    @State private var progress = 0.0
    @State private var lastReplay: Int?
    private let motion = JohanStill()

    private struct SweepKey: Equatable { let replay: Int; let target: Double? }

    var body: some View {
        let lw = max(JohanTheme.Metrics.dialLineMin, size * JohanTheme.Metrics.dialLineFraction)
        let major = size * 0.055
        // The arc sits inside the bezel of ticks, with a hair of air between them.
        let arcInset = major + size * 0.035 + lw / 2
        VStack(spacing: 8) {
            ZStack {
                // Bezel: every tick dim, then the ticks up to the value lit in the dial's colour.
                JohanDialTicks(limit: 1, size: size).stroke(JohanTheme.tick, lineWidth: max(1, size * 0.008))
                JohanDialTicks(limit: progress, size: size)
                    .stroke(color.opacity(0.75), lineWidth: max(1, size * 0.008))
                Circle().inset(by: arcInset).stroke(JohanTheme.track, lineWidth: lw)
                Circle().inset(by: arcInset)
                    .trim(from: 0, to: max(0.001, progress))
                    .stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(progress > 0.001 ? 1 : 0)
                VStack(spacing: 0) {
                    Group {
                        if let value {
                            CountUpText(value: value, format: format,
                                        font: JohanTheme.number(size * numberScale),
                                        color: JohanTheme.textPrimary,
                                        animation: JohanTheme.Motion.countUp)
                                .id(replayKey)
                        } else {
                            Text("–").font(JohanTheme.number(size * numberScale))
                                .foregroundStyle(JohanTheme.textTertiary)
                        }
                    }
                    if value != nil, let unitText {
                        Text(unitText).font(JohanTheme.Fonts.unit).foregroundStyle(JohanTheme.textSecondary)
                            // Sits inside the fixed-size ring; the dial's value is also spoken via accessibilityValue.
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                }
            }
            .frame(width: size, height: size)
            if showsTitle { JohanOverline(title) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value.map(format) ?? String(localized: "no value")))
        .task(id: SweepKey(replay: replayKey, target: fraction)) { await sweep() }
    }

    @MainActor private func sweep() async {
        let target = max(0, min(1, fraction ?? 0))
        if motion.isStill { progress = target; lastReplay = replayKey; return }
        if lastReplay != replayKey {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { progress = 0 }
            lastReplay = replayKey
        }
        let from = progress
        withAnimation(JohanTheme.Motion.dialSweep) { progress = target }
        guard hapticOnSettle, fraction != nil, abs(target - from) > 0.05 else { return }
        try? await Task.sleep(for: .seconds(JohanTheme.Motion.dialSettle))
        if !Task.isCancelled { StrandHaptic.light.play() }
    }
}

/// The bezel of a `JohanDial`: 60 ticks like a watch chapter ring, longer at the quarters. `limit`
/// (0...1) keeps only the ticks up to that share of the turn and animates with the arc's sweep.
struct JohanDialTicks: Shape {
    var limit: Double
    let size: CGFloat
    var count = 60

    var animatableData: Double {
        get { limit }
        set { limit = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let lit = Int((max(0, min(1, limit)) * Double(count)).rounded(.down))
        guard lit > 0 || limit >= 1 else { return p }
        for i in 0..<(limit >= 1 ? count : lit + 1) {
            let isMajor = i % (count / 4) == 0
            let len = isMajor ? size * 0.055 : size * 0.03
            let a = Double(i) / Double(count) * 2 * .pi - .pi / 2
            let dx = CGFloat(cos(a)), dy = CGFloat(sin(a))
            p.move(to: CGPoint(x: c.x + dx * (outer - len), y: c.y + dy * (outer - len)))
            p.addLine(to: CGPoint(x: c.x + dx * outer, y: c.y + dy * outer))
        }
        return p
    }
}

// MARK: - Calibration ring

/// Progress ring for the calibration state, drawn with the same instrument geometry as `JohanDial`
/// (tick bezel, fine arc) so the calibrating Home reads as the same family as the scored one.
struct JohanCalibrationRing: View {
    let fraction: Double
    let day: Int
    let total: Int
    var size: CGFloat = 112

    @State private var progress = 0.0
    private let motion = JohanStill()

    var body: some View {
        let lw = max(JohanTheme.Metrics.dialLineMin, size * JohanTheme.Metrics.dialLineFraction)
        let arcInset = size * 0.055 + size * 0.035 + lw / 2
        ZStack {
            JohanDialTicks(limit: 1, size: size).stroke(JohanTheme.tick, lineWidth: max(1, size * 0.008))
            JohanDialTicks(limit: progress, size: size)
                .stroke(JohanTheme.recoveryGreen.opacity(0.75), lineWidth: max(1, size * 0.008))
            Circle().inset(by: arcInset).stroke(JohanTheme.track, lineWidth: lw)
            Circle().inset(by: arcInset)
                .trim(from: 0, to: max(0.001, progress))
                .stroke(JohanTheme.recoveryGreen, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text("Day").font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                Text("\(day)/\(total)").font(JohanTheme.number(size * 0.24))
                    .foregroundStyle(JohanTheme.textPrimary)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            if motion.isStill { progress = fraction; return }
            withAnimation(JohanTheme.Motion.ringFill) { progress = fraction }
        }
        .onChange(of: fraction) { _, new in
            if motion.isStill { progress = new } else { withAnimation(JohanTheme.Motion.ringFill) { progress = new } }
        }
    }
}

// MARK: - Live heart rate

/// Heart that beats at the live BPM (scale pulse via a repeating animation re-armed on BPM change; no
/// TimelineView). Static when there is no BPM or the gate is closed.
struct JohanPulsingHeart: View {
    let bpm: Int?
    var size: CGFloat = 20
    @State private var beat = false
    private let motion = JohanStill()

    var body: some View {
        let half = bpm.map { 30.0 / Double(max(30, min(220, $0))) } ?? 0.5
        let pulsing = bpm != nil && !motion.isStill
        Image(systemName: "heart.fill")
            .font(.system(size: size))
            .foregroundStyle(JohanTheme.recoveryRed)
            .scaleEffect(pulsing && beat ? JohanTheme.Motion.heartScale : 1)
            .animation(pulsing ? .easeInOut(duration: half).repeatForever(autoreverses: true) : .default, value: beat)
            .task(id: bpm.map { $0 / 2 }) {
                guard bpm != nil, !motion.isStill else { beat = false; return }
                beat = false
                try? await Task.sleep(for: .milliseconds(40))
                beat = true
            }
    }
}

/// Line over `values`, drawn in with a trim animation on first appearance.
struct JohanSparkline: View {
    let values: [Double]
    var color: Color = JohanTheme.recoveryRed
    var height: CGFloat = 36
    @State private var drawn = 0.0
    private let motion = JohanStill()

    private struct Line: Shape {
        let values: [Double]
        func path(in rect: CGRect) -> Path {
            var p = Path()
            guard values.count >= 2, let lo = values.min(), let hi = values.max() else { return p }
            let span = max(hi - lo, 1)
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: rect.width * CGFloat(i) / CGFloat(values.count - 1),
                                 y: rect.height * (1 - CGFloat((v - lo) / span)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            return p
        }
    }

    var body: some View {
        Line(values: values)
            .trim(from: 0, to: drawn)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(height: height)
            .onAppear {
                if motion.isStill { drawn = 1 } else { withAnimation(JohanTheme.Motion.sparkDraw) { drawn = 1 } }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Target strain band

/// Strain gauge on the 0-21 axis: the day's Effort fills from the left, the recovery-based target range
/// sits on the track as a framed segment, and a scale underneath names 0, the range bounds and 21, so the
/// bar reads without the sentence beside it.
struct JohanTargetBand: View {
    let band: ClosedRange<Int>
    let current: Double?
    let color: Color
    @State private var shown = false
    private let motion = JohanStill()
    private let maxValue = 21.0
    private let barHeight: CGFloat = 10

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (v: Double) in w * CGFloat(min(max(v, 0), maxValue) / maxValue) }
                ZStack(alignment: .leading) {
                    Capsule().fill(JohanTheme.track)
                    // Target range: tinted fill plus a crisp outline, so it stays visible under the progress.
                    RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous)
                        .fill(color.opacity(0.28))
                        .overlay(RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous)
                            .stroke(color.opacity(0.9), lineWidth: 1.5))
                        .frame(width: x(Double(band.upperBound)) - x(Double(band.lowerBound)))
                        .offset(x: x(Double(band.lowerBound)))
                    if let current {
                        Capsule().fill(JohanTheme.strainBlue)
                            .frame(width: max(barHeight, shown ? x(current) : barHeight))
                        Circle().fill(JohanTheme.textPrimary)
                            .frame(width: barHeight + 6, height: barHeight + 6)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                            .offset(x: max(0, min(w - barHeight - 6, (shown ? x(current) : 0) - (barHeight + 6) / 2)))
                    }
                }
            }
            .frame(height: barHeight + 6)
            .animation(motion.isStill ? nil : JohanTheme.Motion.markerSpring, value: current)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    scaleLabel("0", at: 0, width: w, anchor: .leading)
                    scaleLabel("\(band.lowerBound)", at: Double(band.lowerBound), width: w, anchor: .center, emphasised: true)
                    scaleLabel("\(band.upperBound)", at: Double(band.upperBound), width: w, anchor: .center, emphasised: true)
                    scaleLabel("21", at: maxValue, width: w, anchor: .trailing)
                }
            }
            .frame(height: 16)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .onAppear {
            if motion.isStill { shown = true; return }
            withAnimation(JohanTheme.Motion.markerSpring.delay(JohanTheme.Motion.markerDelay)) { shown = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Target range \(String(band.lowerBound)) to \(String(band.upperBound)) of 21"))
        .accessibilityValue(current.map { String(localized: "now \(String(format: "%.1f", $0))") } ?? String(localized: "no strain yet"))
    }

    private enum Anchor { case leading, center, trailing }

    private func scaleLabel(_ text: String, at value: Double, width: CGFloat, anchor: Anchor,
                            emphasised: Bool = false) -> some View {
        let x = width * CGFloat(value / maxValue)
        let labelWidth: CGFloat = 28
        let offset: CGFloat
        switch anchor {
        case .leading: offset = 0
        case .center: offset = min(max(0, x - labelWidth / 2), width - labelWidth)
        case .trailing: offset = width - labelWidth
        }
        return Text(text)
            .font(.system(.caption2, weight: emphasised ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(emphasised ? color : JohanTheme.textTertiary)
            .frame(width: labelWidth, alignment: anchor == .leading ? .leading : anchor == .trailing ? .trailing : .center)
            .offset(x: offset)
    }
}

// MARK: - Charts

/// Bar that grows from the centre line to `delta` (right = positive, left = negative), staggered.
struct JohanDivergingBar: View {
    let delta: Double
    let maxAbs: Double
    let color: Color
    let index: Int
    @State private var grown = false
    private let motion = JohanStill()

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let len = half * CGFloat(min(1, abs(delta) / max(maxAbs, 0.0001)))
            ZStack {
                Capsule().fill(JohanTheme.track).frame(height: 6)
                Rectangle().fill(JohanTheme.textTertiary).frame(width: 1, height: 14)
                Capsule().fill(color)
                    .frame(width: max(len, 3), height: 6)
                    .scaleEffect(x: grown || motion.isStill ? 1 : 0.001, anchor: delta >= 0 ? .leading : .trailing)
                    .offset(x: delta >= 0 ? (len / 2 + 0.5) : -(len / 2 + 0.5))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 14)
        .onAppear {
            guard !motion.isStill else { return }
            withAnimation(JohanTheme.Motion.barGrow.delay(0.15 + Double(index) * JohanTheme.Motion.barStagger)) { grown = true }
        }
        .accessibilityHidden(true)
    }
}

/// Vertical bars that grow up from the baseline one after another. A nil value is a day without data and
/// draws no bar, so it cannot be mistaken for a measured zero. Each bar carries its x label and its real
/// (not mid-animation) value for VoiceOver.
struct JohanGrowBars: View {
    struct Bar {
        /// Short axis label, e.g. a weekday initial.
        let label: String
        /// Spoken label, e.g. the full date.
        let spokenLabel: String
        let value: Double?
    }

    let bars: [Bar]
    let color: Color
    /// Spoken value text, unit included where it helps ("4,2", "1 Std. 10 Min.").
    var formatValue: (Double) -> String
    /// Y-axis tick text; `formatValue` when nil.
    var formatAxis: ((Double) -> String)?
    @State private var factors: [Double] = []
    private let motion = JohanStill()

    var body: some View {
        let top = max(bars.compactMap(\.value).max() ?? 1, 1) * 1.1
        Chart {
            ForEach(Array(bars.enumerated()), id: \.offset) { i, bar in
                if let v = bar.value {
                    BarMark(x: .value("Day", i), y: .value("Value", v * (factors.indices.contains(i) ? factors[i] : 0)))
                        .foregroundStyle(color)
                        .cornerRadius(3)
                        .accessibilityLabel(bar.spokenLabel)
                        .accessibilityValue(formatValue(v))
                }
            }
        }
        .chartXScale(domain: -0.5...(Double(max(bars.count, 1)) - 0.5))
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: Array(bars.indices)) { v in
                AxisValueLabel(centered: true) {
                    if let i = v.as(Int.self), bars.indices.contains(i) {
                        Text(bars[i].label).font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(JohanTheme.track)
                AxisValueLabel {
                    if let m = v.as(Double.self) {
                        Text((formatAxis ?? formatValue)(m)).font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
                    }
                }
            }
        }
        // Axis labels are secondary to the bars and the headline figure above the chart; past xxxLarge they
        // would crowd the plot, and each bar's value is spoken by VoiceOver anyway.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onAppear { grow() }
        .onChange(of: bars.count) { _, _ in grow() }
    }

    private func grow() {
        if motion.isStill { factors = Array(repeating: 1, count: bars.count); return }
        factors = Array(repeating: 0, count: bars.count)
        for i in bars.indices {
            withAnimation(JohanTheme.Motion.barGrow.delay(Double(i) * JohanTheme.Motion.barStagger)) {
                if factors.indices.contains(i) { factors[i] = 1 }
            }
        }
    }
}

extension JohanGrowBars.Bar {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Bar for a `YYYY-MM-DD` day key: weekday initial on the axis, full date for VoiceOver.
    init(dayKey: String, value: Double?) {
        let locale = AppLanguage.activeLocale
        if let date = Self.parser.date(from: dayKey) {
            self.init(label: String(date.formatted(.dateTime.weekday(.narrow).locale(locale))),
                      spokenLabel: date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale)),
                      value: value)
        } else {
            self.init(label: "", spokenLabel: dayKey, value: value)
        }
    }
}

private struct JohanRevealLeadingToTrailing: ViewModifier {
    @State private var reveal = 0.0
    private let motion = JohanStill()
    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                Rectangle().scaleEffect(x: max(reveal, 0.001), anchor: .leading)
            }
            .onAppear {
                if motion.isStill { reveal = 1 } else { withAnimation(JohanTheme.Motion.hypnogramReveal) { reveal = 1 } }
            }
    }
}

extension View {
    /// Wipes the view in from left to right on first appearance.
    func johanRevealLeftToRight() -> some View { modifier(JohanRevealLeadingToTrailing()) }
}
#endif

#if os(iOS)
// MARK: - Loading placeholder

/// Card-shaped stand-in shown while a screen's first load runs, so the layout appears at once instead of a
/// spinner or a gap. Pulses gently unless the motion gate is closed. Hidden from VoiceOver except for a
/// single "Lädt" element.
struct JohanPlaceholderCard: View {
    var height: CGFloat = 140
    @State private var dim = false
    private let motion = JohanStill()

    var body: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                bar(width: 90, height: 10)
                bar(width: 160, height: 28)
                Spacer(minLength: 0)
                bar(width: nil, height: 10)
                bar(width: 200, height: 10)
            }
            .frame(height: height, alignment: .topLeading)
            .opacity(dim ? 0.45 : 1)
        }
        .onAppear {
            guard !motion.isStill else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }

    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(JohanTheme.track)
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .frame(width: width, height: height)
    }
}
#endif

#if os(iOS)
// MARK: - Waiting for live heart rate

/// Shown in the live HR card while the strap is connected but its first live sample has not arrived:
/// one ECG-style beat traced left to right, over and over, so the seconds the strap takes to start
/// streaming read as "working", not "broken". Purely presentational; it shows no value. Still (a flat
/// dim trace) when the motion gate is closed.
struct JohanHRSearching: View {
    var color: Color = JohanTheme.recoveryRed
    @State private var phase: CGFloat = 0
    private let motion = JohanStill()

    /// One beat across the width: flat, a small P bump, the QRS spike, a T bump, flat.
    private struct Beat: Shape {
        func path(in rect: CGRect) -> Path {
            let w = rect.width, h = rect.height, mid = rect.midY
            let pts: [(CGFloat, CGFloat)] = [
                (0, 0), (0.22, 0), (0.27, -0.12), (0.32, 0), (0.40, 0), (0.43, 0.18),
                (0.47, -0.95), (0.51, 0.45), (0.55, 0), (0.66, 0), (0.73, -0.22), (0.80, 0), (1, 0)
            ]
            var p = Path()
            for (i, pt) in pts.enumerated() {
                let point = CGPoint(x: pt.0 * w, y: mid + pt.1 * h / 2)
                if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
            return p
        }
    }

    var body: some View {
        ZStack {
            Beat().stroke(JohanTheme.track, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if !motion.isStill {
                // A short bright segment runs along the beat, fading at its tail.
                Beat()
                    .trim(from: max(0, phase - 0.28), to: phase)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .shadow(color: color.opacity(0.6), radius: 4)
            }
        }
        .frame(height: 30)
        .onAppear {
            guard !motion.isStill else { return }
            phase = 0
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.28 }
        }
        .accessibilityHidden(true)
    }
}
#endif

#if os(iOS)
// MARK: - Activity rings

/// Concentric rings in the Fitness manner, outermost first. Each draws in from 12 o'clock with a spring,
/// staggered, on appear and on `replayKey` changes (a new day), and glides to a new fraction when the value
/// moves. A nil fraction shows only the ring's track. Purely the graphic: the caller states the values.
struct JohanActivityRings: View {
    struct Ring {
        let fraction: Double?
        let color: Color
    }

    let rings: [Ring]
    var size: CGFloat = 250
    var lineWidth: CGFloat = 22
    var spacing: CGFloat = 4
    var replayKey: Int = 0

    @State private var shown: [Double] = []
    @State private var lastReplay: Int?
    private let motion = JohanStill()

    var body: some View {
        ZStack {
            ForEach(Array(rings.enumerated()), id: \.offset) { i, ring in
                let d = size - CGFloat(i) * 2 * (lineWidth + spacing)
                Circle()
                    .stroke(ring.color.opacity(0.18), lineWidth: lineWidth)
                    .frame(width: d - lineWidth, height: d - lineWidth)
                Circle()
                    .trim(from: 0, to: max(0.0001, shown.indices.contains(i) ? shown[i] : 0))
                    .stroke(ring.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: d - lineWidth, height: d - lineWidth)
                    .opacity((shown.indices.contains(i) ? shown[i] : 0) > 0.001 ? 1 : 0)
            }
        }
        .frame(width: size, height: size)
        .task(id: Key(replay: replayKey, targets: rings.map { $0.fraction ?? 0 })) { await animate() }
        .accessibilityHidden(true)
    }

    private struct Key: Equatable { let replay: Int; let targets: [Double] }

    @MainActor private func animate() async {
        let targets = rings.map { min(max($0.fraction ?? 0, 0), 1) }
        if motion.isStill { shown = targets; lastReplay = replayKey; return }
        if lastReplay != replayKey || shown.count != targets.count {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { shown = Array(repeating: 0, count: targets.count) }
            lastReplay = replayKey
            try? await Task.sleep(for: .milliseconds(30))
        }
        for i in targets.indices {
            withAnimation(.spring(response: 1.1, dampingFraction: 0.82).delay(Double(i) * 0.12)) {
                if shown.indices.contains(i) { shown[i] = targets[i] }
            }
        }
    }
}

/// Soft light behind the rings in the recovery colour, slowly breathing. Decoration only; still when the
/// motion gate is closed.
struct JohanAmbientGlow: View {
    let color: Color
    var size: CGFloat = 340
    @State private var breathe = false
    private let motion = JohanStill()

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(0.30), .clear], center: .center,
                                 startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .blur(radius: 40)
            .scaleEffect(breathe ? 1.12 : 1)
            .opacity(breathe ? 0.9 : 0.6)
            .animation(.easeInOut(duration: 1.2), value: color)
            .onAppear {
                guard !motion.isStill else { return }
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { breathe = true }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
#endif
