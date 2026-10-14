#if os(iOS)
import SwiftUI
import StrandDesign

// JohanIntro.swift — the cold-launch motion graphic that morphs into Home.
//
// Three dots (recovery, sleep, strain) spring in and orbit, fuse into one liquid blob, and the blob bursts
// into the three concentric rings, which then fly into the exact place of the Home rings while the black
// ground fades away. Home holds its cards back until the flight starts and its rings until they land, so
// the hand-off reads as one continuous shape. Plays on a cold launch and again when the app is opened
// after a while in the background; skipped when the motion gate is closed (`JohanStill`).

/// Where the intro stands. Home reads it to hold its entrance until the rings arrive.
enum JohanIntroPhase {
    /// Intro on screen: Home stays hidden.
    case playing
    /// Rings flying to Home: cards may stagger in, the Home rings stay hidden.
    case landing
    /// Intro gone (or never played).
    case done
}

/// What Home tells the intro about its rings, so they land on the real ones.
struct JohanIntroTarget: Equatable {
    /// Centre of the Home rings in global coordinates.
    var center: CGPoint
    var size: CGFloat
    var recoveryColor: Color
}

private struct JohanIntroPhaseKey: EnvironmentKey {
    static let defaultValue: JohanIntroPhase = .done
}

private struct JohanIntroTargetKey: EnvironmentKey {
    static let defaultValue: (JohanIntroTarget) -> Void = { _ in }
}

extension EnvironmentValues {
    var johanIntroPhase: JohanIntroPhase {
        get { self[JohanIntroPhaseKey.self] }
        set { self[JohanIntroPhaseKey.self] = newValue }
    }

    /// Home reports its ring geometry here while the intro runs.
    var johanIntroTarget: (JohanIntroTarget) -> Void {
        get { self[JohanIntroTargetKey.self] }
        set { self[JohanIntroTargetKey.self] = newValue }
    }
}

extension JohanTheme.Motion {
    /// Intro timeline, in seconds from the first frame.
    enum Intro {
        static let dotsIn: Double = 0.45
        static let merged: Double = 1.0
        static let ringsFormed: Double = 1.6
        static let flightStart: Double = 1.72
        static let flightEnd: Double = 2.32
        /// Glow and line width blend from the liquid shape to the crisp rings over this part of the burst.
        static let crispFrom: Double = 0.55
    }
}

enum JohanIntro {
    /// A cold launch plays it, switching JohanUI off and on again does not.
    @MainActor static var played = false

    /// Seconds in the background after which opening the app plays the intro again.
    static let replayAfterBackground: TimeInterval = 10

    /// DEBUG `--no-intro` skips it (deterministic simulator screenshots).
    static var suppressed: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--no-intro") || CommandLine.arguments.contains("--johan-tab")
        #else
        return false
        #endif
    }
}

/// Full-screen overlay that plays the intro and reports its phase. Purely decorative: it never takes
/// touches and is hidden from VoiceOver.
struct JohanIntroOverlay: View {
    let target: JohanIntroTarget?
    let onPhase: (JohanIntroPhase) -> Void

    @State private var start: Date?
    @State private var reported: JohanIntroPhase = .playing
    @State private var mergeTapped = false

    private typealias T = JohanTheme.Motion.Intro

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: reported == .done)) { timeline in
                let t = start.map { timeline.date.timeIntervalSince($0) } ?? 0
                let origin = geo.frame(in: .global).origin
                frame(t: t, size: geo.size, origin: origin)
                    .onChange(of: t >= T.merged) { _, merged in
                        if merged && !mergeTapped { mergeTapped = true; StrandHaptic.light.play() }
                    }
                    .onChange(of: t >= T.flightStart) { _, on in if on { advance(to: .landing) } }
                    .onChange(of: t >= T.flightEnd) { _, on in
                        if on { StrandHaptic.selection.play(); advance(to: .done) }
                    }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if start == nil { start = Date() } }
    }

    private func advance(to phase: JohanIntroPhase) {
        guard phase != reported else { return }
        reported = phase
        onPhase(phase)
    }

    // MARK: Frame

    private func frame(t: Double, size: CGSize, origin: CGPoint) -> some View {
        let home = target.map { CGPoint(x: $0.center.x - origin.x, y: $0.center.y - origin.y) }
            ?? CGPoint(x: size.width / 2, y: size.height * 0.34)
        let ringSize = target?.size ?? min(260, (size.width - 32) * 0.72)
        let stage = CGPoint(x: size.width / 2, y: size.height * 0.46)
        // Flight: from the stage to the Home rings, slightly larger on the stage so the landing settles.
        let f = Self.easeInOut(Self.progress(t, T.flightStart, T.flightEnd))
        let center = CGPoint(x: Self.lerp(stage.x, home.x, f), y: Self.lerp(stage.y, home.y, f))
        let scale = Self.lerp(1.12, 1, f)
        let recColor = target?.recoveryColor ?? JohanTheme.recoveryGreen
        let colors = [recColor, JohanTheme.sleepViolet, JohanTheme.strainBlue]
        let groundOpacity = 1 - Self.easeIn(Self.progress(t, T.flightStart, T.flightEnd - 0.12))

        return ZStack {
            JohanTheme.background.opacity(groundOpacity)
            Canvas { ctx, _ in
                draw(ctx, t: t, center: center, ringSize: ringSize * scale, colors: colors)
            }
            Text(verbatim: "NOOP")
                .font(.system(.footnote, design: .rounded, weight: .bold))
                .tracking(6)
                .foregroundStyle(JohanTheme.textSecondary)
                .opacity(Self.bump(t, rise: (1.2, 1.45), fall: (T.flightStart, T.flightStart + 0.2)))
                .offset(y: Self.lerp(6, 0, Self.easeOut(Self.progress(t, 1.2, 1.5))))
                .position(x: stage.x, y: stage.y + ringSize * 1.12 / 2 + 34)
        }
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, t: Double, center c: CGPoint, ringSize s: CGFloat, colors: [Color]) {
        let lw = s * 0.088, sp = s * 0.016
        let radii = (0..<3).map { i in (s - CGFloat(i) * 2 * (lw + sp) - lw) / 2 }

        // Dots: spring out to an orbit, then spiral in and fuse.
        let pIn = Self.progress(t, 0, T.dotsIn)
        let pMerge = Self.progress(t, T.dotsIn, T.merged)
        let orbit = 40 * Self.easeOutBack(pIn) * (1 - Self.easeIn(pMerge))
        let dotR = 13 * Self.easeOutBack(pIn) + 5 * pMerge
        let spin = 0.9 * t + 7 * pow(max(0, t - T.dotsIn), 2)
        // The fused blob gathers as the dots meet, dips just before the burst and is spent by the rings.
        let pBurst = Self.progress(t, T.merged, T.ringsFormed)
        let blobR = 26 * Self.easeOut(Self.progress(pMerge, 0.55, 1)) * (1 - 0.18 * Self.bump(t, rise: (0.92, 1.0), fall: (1.0, 1.06)))
            * (1 - Self.easeIn(Self.progress(pBurst, 0, 0.45)))
        // Rings: each starts as a disc the size of the blob (a ring of radius 0 and a fat stroke) and
        // hollows out to its own radius; outer ring leads.
        let ringP = (0..<3).map { i in Self.easeOutBack(Self.progress(pBurst, Double(i) * 0.08, 0.84 + Double(i) * 0.08), overshoot: 1.2) }
        let crisp = Self.easeInOut(Self.progress(pBurst, T.crispFrom, 1))
        let ringsOn = t >= T.merged

        // 1. The liquid layer: blur + threshold make anything close enough melt together.
        let gooOpacity = 1 - crisp
        if gooOpacity > 0.001 {
            var goo = ctx
            goo.opacity = gooOpacity
            goo.drawLayer { layer in
                let bounds = CGRect(x: c.x - s, y: c.y - s, width: 2 * s, height: 2 * s)
                layer.drawLayer { shape in
                    shape.addFilter(.alphaThreshold(min: 0.5, color: .white))
                    shape.addFilter(.blur(radius: Self.lerp(10, 3, crisp)))
                    shape.drawLayer { blobs in
                        if !ringsOn || pBurst < 0.2 {
                            for k in 0..<3 {
                                let a = spin + Double(k) * 2 * .pi / 3 - .pi / 2
                                let p = CGPoint(x: c.x + orbit * cos(a), y: c.y + orbit * sin(a))
                                blobs.fill(Self.disc(p, dotR * (1 - Self.easeIn(Self.progress(pBurst, 0, 0.2)))), with: .color(.white))
                            }
                        }
                        if blobR > 0.5 { blobs.fill(Self.disc(c, blobR), with: .color(.white)) }
                        if ringsOn {
                            for i in 0..<3 {
                                let r = max(0.1, radii[i] * ringP[i])
                                let w = Self.lerp(2 * 26, lw, Self.easeOut(min(1, ringP[i])))
                                blobs.stroke(Self.circle(c, r), with: .color(.white), lineWidth: w)
                            }
                        }
                    }
                }
                // Colour the liquid: spinning sweep while the dots orbit (each dot keeps its hue), radial
                // bands once the rings separate (each ring takes its own colour).
                layer.blendMode = .sourceAtop
                let sweep = Gradient(colors: colors + [colors[0]])
                let radialMix = ringsOn ? Self.easeOut(Self.progress(pBurst, 0, 0.35)) : 0
                var conic = layer
                conic.opacity = 1 - radialMix
                conic.fill(Path(bounds), with: .conicGradient(sweep, center: c, angle: .radians(spin - .pi / 2 - .pi / 3)))
                if radialMix > 0 {
                    var radial = layer
                    radial.opacity = radialMix
                    let r = radii.indices.map { radii[$0] * max(0.01, ringP[$0]) }
                    let outer = max(1, r[0] + lw)
                    let cut1 = min(1, (r[1] + r[0]) / 2 / outer), cut2 = min(cut1, (r[2] + r[1]) / 2 / outer)
                    let bands = Gradient(stops: [
                        .init(color: colors[2], location: 0), .init(color: colors[2], location: cut2),
                        .init(color: colors[1], location: cut2), .init(color: colors[1], location: cut1),
                        .init(color: colors[0], location: cut1), .init(color: colors[0], location: 1),
                    ])
                    radial.fill(Path(bounds), with: .radialGradient(bands, center: c, startRadius: 0, endRadius: outer))
                }
            }
        }

        guard ringsOn else { return }

        // 2. Shockwave of the burst.
        let wave = Self.progress(t, T.merged, T.merged + 0.55)
        if wave > 0, wave < 1 {
            var w = ctx
            w.opacity = 0.55 * (1 - wave)
            w.stroke(Self.circle(c, Self.lerp(26, radii[0] * 1.45, Self.easeOut(wave))),
                     with: .color(.white), lineWidth: Self.lerp(5, 0.5, wave))
        }

        // 3. Glow under the rings, gone by the landing (Home's own glow takes over).
        let glow = crisp * (1 - Self.easeIn(Self.progress(t, T.flightStart, T.flightEnd)))
        if glow > 0.001 {
            var g = ctx
            g.opacity = 0.7 * glow
            g.addFilter(.blur(radius: 40))
            g.fill(Self.disc(c, s * 0.62), with: .radialGradient(Gradient(colors: [colors[0].opacity(0.45), .clear]),
                                                                center: c, startRadius: 0, endRadius: s * 0.62))
        }

        // 4. The crisp rings. They land as bare tracks, exactly what the Home rings draw before their sweep.
        if crisp > 0.001 {
            let bright = 1 - Self.easeInOut(Self.progress(t, T.flightStart + 0.1, T.flightEnd))
            for i in 0..<3 {
                let path = Self.circle(c, radii[i] * min(1, ringP[i]))
                var track = ctx
                track.opacity = crisp
                track.stroke(path, with: .color(colors[i].opacity(0.18)), lineWidth: lw)
                var lit = ctx
                lit.opacity = crisp * bright
                lit.stroke(path, with: .color(colors[i]), lineWidth: lw)
            }
        }
    }

    // MARK: Helpers

    private static func disc(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> Path { disc(c, max(0.1, r)) }

    private static func progress(_ t: Double, _ a: Double, _ b: Double) -> Double {
        min(1, max(0, (t - a) / (b - a)))
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a + (b - a) * CGFloat(p) }
    private static func easeIn(_ p: Double) -> Double { p * p * p }
    private static func easeOut(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
    private static func easeInOut(_ p: Double) -> Double { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }
    private static func easeOutBack(_ p: Double, overshoot k: Double = 1.7) -> Double {
        p <= 0 ? 0 : 1 + (k + 1) * pow(p - 1, 3) + k * pow(p - 1, 2)
    }

    /// 0 → 1 over `rise`, held, 1 → 0 over `fall`.
    private static func bump(_ t: Double, rise: (Double, Double), fall: (Double, Double)) -> Double {
        easeOut(progress(t, rise.0, rise.1)) * (1 - easeIn(progress(t, fall.0, fall.1)))
    }
}
#endif
