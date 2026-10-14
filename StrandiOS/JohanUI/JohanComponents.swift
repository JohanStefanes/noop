#if os(iOS)
import SwiftUI
import Charts
import StrandDesign

// JohanComponents.swift — reusable animated components. Visual constants come from `JohanTheme`,
// timings from `JohanTheme.Motion`, the still-gate from `JohanStill`.

// MARK: - Dial

/// Circular score dial. The arc sweeps from 0 with a spring on first appearance, whenever `replayKey`
/// changes (day change), and from the current position when `fraction` changes. The number counts up in
/// step (StrandDesign `CountUpText`), a soft glow dot rides the arc's end cap and, if requested, a light
/// haptic fires when the sweep settles.
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

    @State private var progress = 0.0
    @State private var lastReplay: Int?
    private let motion = JohanStill()

    private struct SweepKey: Equatable { let replay: Int; let target: Double? }

    var body: some View {
        let lw = max(JohanTheme.Metrics.dialLineMin, size * JohanTheme.Metrics.dialLineFraction)
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(JohanTheme.track, lineWidth: lw)
                Circle()
                    .trim(from: 0, to: max(0.001, progress))
                    .stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(progress > 0.001 ? 1 : 0)
                // Glow dot on the end cap.
                if progress > 0.004 {
                    ZStack {
                        Circle().fill(color).frame(width: lw * 1.9, height: lw * 1.9).blur(radius: 5).opacity(0.85)
                        Circle().fill(.white).frame(width: lw * 0.42, height: lw * 0.42)
                    }
                    .offset(y: -size / 2)
                    .rotationEffect(.degrees(progress * 360))
                }
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
                    }
                }
            }
            .frame(width: size, height: size)
            JohanOverline(title)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value.map(format) ?? "kein Wert"))
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

// MARK: - Calibration ring

/// Progress ring for the calibration state: the fill animates to `fraction`, and while the motion gate is
/// open a soft highlight rotates around the filled arc (a rotating angular gradient masked to the arc,
/// driven by Core Animation, not per-frame view updates).
struct JohanCalibrationRing: View {
    let fraction: Double
    let day: Int
    let total: Int
    var size: CGFloat = 112

    @State private var progress = 0.0
    @State private var spin = 0.0
    private let motion = JohanStill()

    var body: some View {
        let lw = max(JohanTheme.Metrics.dialLineMin, size * JohanTheme.Metrics.dialLineFraction)
        ZStack {
            Circle().stroke(JohanTheme.track, lineWidth: lw)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(JohanTheme.recoveryGreen, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if !motion.isStill {
                Circle()
                    .stroke(AngularGradient(colors: [.clear, .white.opacity(0.55), .clear, .clear],
                                            center: .center), lineWidth: lw)
                    .rotationEffect(.degrees(spin))
                    .mask(Circle().trim(from: 0, to: max(0.001, progress))
                        .stroke(style: StrokeStyle(lineWidth: lw, lineCap: .round))
                        .rotationEffect(.degrees(-90)))
                    .animation(.linear(duration: JohanTheme.Motion.shimmerPeriod).repeatForever(autoreverses: false),
                               value: spin)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                Text("Tag").font(.system(size: max(11, size * 0.075), weight: .medium)).foregroundStyle(JohanTheme.textSecondary)
                Text("\(day)/\(total)").font(JohanTheme.number(size * 0.26))
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            if motion.isStill { progress = fraction; return }
            withAnimation(JohanTheme.Motion.ringFill) { progress = fraction }
            spin = 360
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

/// 0-21 track with the target band and the current-strain marker. The band fades in first, then the
/// marker springs from the start of the track to its value.
struct JohanTargetBand: View {
    let band: ClosedRange<Int>
    let current: Double?
    let color: Color
    @State private var bandShown = false
    @State private var markerShown = false
    private let motion = JohanStill()

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(JohanTheme.track)
                Capsule().fill(color.opacity(0.35))
                    .frame(width: w * CGFloat(band.upperBound - band.lowerBound) / 21)
                    .offset(x: w * CGFloat(band.lowerBound) / 21)
                    .opacity(bandShown ? 1 : 0)
                if let current {
                    Capsule().fill(JohanTheme.strainBlue)
                        .frame(width: 4, height: 14)
                        .offset(x: markerShown ? max(0, min(w - 4, w * CGFloat(current / 21) - 2)) : 0)
                        .opacity(markerShown ? 1 : 0)
                        .animation(JohanTheme.Motion.markerSpring, value: current)
                }
            }
        }
        .frame(height: 14)
        .onAppear {
            if motion.isStill { bandShown = true; markerShown = true; return }
            withAnimation(JohanTheme.Motion.bandFade) { bandShown = true }
            withAnimation(JohanTheme.Motion.markerSpring.delay(JohanTheme.Motion.markerDelay)) { markerShown = true }
        }
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

/// Vertical bars that grow up from the baseline one after another.
struct JohanGrowBars: View {
    let values: [Double]
    let color: Color
    var formatAxis: (Double) -> String
    @State private var factors: [Double] = []
    private let motion = JohanStill()

    var body: some View {
        let top = max(values.max() ?? 1, 1) * 1.1
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                BarMark(x: .value("Nacht", i), y: .value("Min.", v * (factors.indices.contains(i) ? factors[i] : 0)))
                    .foregroundStyle(color.gradient)
                    .cornerRadius(3)
            }
        }
        .chartYScale(domain: 0...top)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(JohanTheme.track)
                AxisValueLabel {
                    if let m = v.as(Double.self) {
                        Text(formatAxis(m)).font(.system(size: 10)).foregroundStyle(JohanTheme.textTertiary)
                    }
                }
            }
        }
        .onAppear { grow() }
        .onChange(of: values.count) { _, _ in grow() }
    }

    private func grow() {
        if motion.isStill { factors = Array(repeating: 1, count: values.count); return }
        factors = Array(repeating: 0, count: values.count)
        for i in values.indices {
            withAnimation(JohanTheme.Motion.barGrow.delay(Double(i) * JohanTheme.Motion.barStagger)) {
                if factors.indices.contains(i) { factors[i] = 1 }
            }
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
