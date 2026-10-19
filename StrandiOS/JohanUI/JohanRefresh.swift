#if os(iOS)
import SwiftUI
import UIKit
import StrandDesign

// JohanRefresh.swift — the pull-to-refresh indicator of every `JohanScreen`.
//
// The Home rings (recovery, sleep, strain) draw themselves in as the screen is pulled, spin apart around a
// beating core while the store reloads, and snap shut with a pop when it is done. The gesture, the release
// point and the held content inset stay the system's (`.refreshable`); its spinner is made invisible and the
// rings are hosted in the refresh control in its place, so VoiceOver still announces the native control.

extension JohanTheme.Motion {
    /// Pull distance (pt) at which the rings are fully drawn.
    static let refreshPull: CGFloat = 90
    /// A refresh that finishes faster than this is held, so the spin is seen rather than flashed.
    static let refreshMinDuration: Double = 0.9
    /// How long the closing pop is shown before the system lets the content snap back.
    static let refreshCloseHold: Double = 0.38
    static let refreshClose = Animation.spring(response: 0.38, dampingFraction: 0.52)
    /// Arcs shrink from full rings to spinning segments over this long once the refresh starts.
    static let refreshMorph: Double = 0.35
    /// One cycle of the spinning rings.
    static let refreshSpinDuration: Double = 1.4
}

enum JohanRefreshPhase: Equatable {
    case idle
    case refreshing
    case done
}

/// Over-pull and refresh phase of one `JohanScreen`. Kept out of the screen's own state so a pull redraws
/// only the indicator, not the screen's content.
final class JohanRefreshState: ObservableObject {
    /// Over-pull in points (0 at rest and while scrolled into the content).
    @Published var pull: CGFloat = 0
    @Published var phase: JohanRefreshPhase = .idle

    /// Waits `seconds` even when the refresh task is cancelled: SwiftUI cancels it as the reloaded screen
    /// re-renders, and a cancelled `Task.sleep` returns at once, which would cut the spin to a single frame.
    static func hold(_ seconds: Double) async {
        guard seconds > 0 else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.resume() }
        }
    }

    func setPull(_ value: CGFloat) {
        let v = max(value, 0)
        guard v != pull else { return }
        pull = v
        if phase == .done && v < 1 { phase = .idle }
    }
}

/// The indicator, observing the shared state. Hosted inside the native refresh control (see
/// `JohanScrollProbe`), so it sits exactly where UIKit would draw its spinner: above the content on Home,
/// between the compact bar and the large title on the titled screens.
struct JohanRefreshOverlay: View {
    @ObservedObject var state: JohanRefreshState

    var body: some View {
        JohanRefreshIndicator(pull: state.pull, phase: state.phase)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }
}

struct JohanRefreshIndicator: View {
    /// Over-pull in points (0 at rest).
    let pull: CGFloat
    let phase: JohanRefreshPhase
    private let motion = JohanStill()

    static let colors = [JohanTheme.recoveryGreen, JohanTheme.sleepViolet, JohanTheme.strainBlue]
    static let diameters: [CGFloat] = [38, 27, 16]
    static let lineWidth: CGFloat = 3.6
    static var side: CGFloat { diameters[0] + lineWidth }

    private var progress: CGFloat { min(max(pull / JohanTheme.Motion.refreshPull, 0), 1) }

    var body: some View {
        Group {
            if case .refreshing = phase, !motion.isStill {
                JohanSpinningRings()
            } else {
                staticRings
            }
        }
        .frame(width: Self.side, height: Self.side)
        .scaleEffect(scale)
        .opacity(opacity)
        .animation(motion.isStill ? nil : JohanTheme.Motion.refreshClose, value: phase)
        .accessibilityHidden(true)
    }

    private var scale: CGFloat {
        switch phase {
        case .idle: return 0.55 + 0.45 * progress
        case .refreshing: return 1
        case .done: return motion.isStill ? 1 : 1.18
        }
    }

    private var opacity: Double {
        switch phase {
        case .idle: return Double(min(progress * 1.6, 1))
        case .refreshing: return 1
        case .done: return pull > 4 ? 1 : 0
        }
    }

    /// Pulling: the rings draw in, outer first, winding a little as the pull deepens. Done (and refreshing
    /// under Reduce Motion): three closed rings.
    private var staticRings: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let dir: Double = i == 1 ? -1 : 1
                let drawing = phase == .idle
                let length = drawing ? min(max((progress - CGFloat(i) * 0.14) / 0.72, 0), 1) : 1
                ZStack {
                    Circle()
                        .stroke(Self.colors[i].opacity(0.16), lineWidth: Self.lineWidth)
                    Circle()
                        .trim(from: 0, to: length)
                        .stroke(Self.colors[i], style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                        .rotationEffect(.degrees((drawing ? dir * Double(progress) * 120 : 0) - 90))
                }
                .frame(width: Self.diameters[i], height: Self.diameters[i])
            }
            Circle()
                .fill(JohanTheme.textPrimary)
                .frame(width: coreSize, height: coreSize)
                .shadow(color: JohanTheme.recoveryGreen.opacity(0.6), radius: 4)
        }
    }

    private var coreSize: CGFloat {
        switch phase {
        case .idle: return 5 * progress
        case .refreshing: return 5
        case .done: return 8
        }
    }
}

/// The refreshing state: each ring shrinks to a glowing segment and spins, the outer and inner ones one
/// way and the middle one the other, around a beating core. Built from Core Animation layers rather than
/// SwiftUI state, so the render server keeps it turning while the main thread is busy reloading the screens.
struct JohanSpinningRings: UIViewRepresentable {
    func makeUIView(context: Context) -> RingsView { RingsView() }
    func updateUIView(_ uiView: RingsView, context: Context) {}

    final class RingsView: UIView {
        /// Whole turns per cycle (whole, so the repeat is seamless).
        private static let turns: [Double] = [1, -1, 2]
        /// Segment length each ring shrinks to.
        private static let segments: [CGFloat] = [0.3, 0.42, 0.55]
        private var arcs: [CAShapeLayer] = []
        private var tracks: [CAShapeLayer] = []
        private let core = CAShapeLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            for color in JohanRefreshIndicator.colors.map(UIColor.init) {
                let track = CAShapeLayer()
                track.fillColor = nil
                track.strokeColor = color.withAlphaComponent(0.16).cgColor
                track.lineWidth = JohanRefreshIndicator.lineWidth
                layer.addSublayer(track)
                tracks.append(track)

                let arc = CAShapeLayer()
                arc.fillColor = nil
                arc.strokeColor = color.cgColor
                arc.lineWidth = JohanRefreshIndicator.lineWidth
                arc.lineCap = .round
                arc.shadowColor = color.cgColor
                arc.shadowOpacity = 0.8
                arc.shadowRadius = 4
                arc.shadowOffset = .zero
                layer.addSublayer(arc)
                arcs.append(arc)
            }
            core.fillColor = UIColor.white.cgColor
            core.shadowColor = UIColor(JohanTheme.recoveryGreen).cgColor
            core.shadowOpacity = 1
            core.shadowRadius = 5
            core.shadowOffset = .zero
            layer.addSublayer(core)
        }
        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            for i in 0..<3 {
                let r = JohanRefreshIndicator.diameters[i] / 2
                // Each ring is its own layer centred on the view, so a rotation turns it in place.
                let frame = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                let path = UIBezierPath(arcCenter: CGPoint(x: r, y: r), radius: r, startAngle: -.pi / 2,
                                        endAngle: 1.5 * .pi, clockwise: true).cgPath
                for l in [tracks[i], arcs[i]] {
                    l.frame = frame
                    l.path = path
                }
            }
            let coreR: CGFloat = 2.5
            core.frame = CGRect(x: c.x - coreR, y: c.y - coreR, width: 2 * coreR, height: 2 * coreR)
            core.path = UIBezierPath(ovalIn: core.bounds).cgPath
            if arcs[0].animation(forKey: "spin") == nil { startAnimations() }
        }

        private func startAnimations() {
            let now = CACurrentMediaTime()
            for (i, arc) in arcs.enumerated() {
                arc.strokeEnd = Self.segments[i]
                let shrink = CABasicAnimation(keyPath: "strokeEnd")
                shrink.fromValue = 1
                shrink.toValue = Self.segments[i]
                shrink.duration = JohanTheme.Motion.refreshMorph
                shrink.timingFunction = CAMediaTimingFunction(name: .easeOut)
                arc.add(shrink, forKey: "shrink")

                // A gentle breathing of the segment length, offset per ring, after the shrink lands.
                let breathe = CABasicAnimation(keyPath: "strokeEnd")
                breathe.fromValue = Self.segments[i]
                breathe.toValue = Self.segments[i] + 0.14
                breathe.duration = 0.6 + Double(i) * 0.15
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.beginTime = now + JohanTheme.Motion.refreshMorph
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                arc.add(breathe, forKey: "breathe")

                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = Self.turns[i] * 2 * .pi
                spin.duration = JohanTheme.Motion.refreshSpinDuration
                spin.repeatCount = .infinity
                arc.add(spin, forKey: "spin")
            }
            // Heartbeat: two quick beats, then a rest.
            let beat = CAKeyframeAnimation(keyPath: "transform.scale")
            beat.values = [1, 1.6, 1, 1.35, 1, 1]
            beat.keyTimes = [0, 0.1, 0.22, 0.32, 0.45, 1]
            beat.duration = 0.95
            beat.repeatCount = .infinity
            core.add(beat, forKey: "beat")
        }
    }
}

/// Reads the enclosing scroll view's over-pull straight from UIKit, makes its native refresh spinner
/// invisible and hosts `JohanRefreshOverlay` in the refresh control in its place. Scoped to that one scroll
/// view rather than `UIRefreshControl.appearance()`, so the classic NOOP shell keeps its system spinner.
struct JohanScrollProbe: UIViewRepresentable {
    let state: JohanRefreshState

    func makeUIView(context: Context) -> Probe { Probe(state: state) }
    func updateUIView(_ uiView: Probe, context: Context) { uiView.attach() }

    final class Probe: UIView {
        private let state: JohanRefreshState
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var host: UIHostingController<JohanRefreshOverlay>?

        init(state: JohanRefreshState) {
            self.state = state
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
        }

        func attach() {
            // SwiftUI attaches the refresh control after the first layout pass; resolve on the next turn.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                var view = self.superview
                while let v = view, !(v is UIScrollView) { view = v.superview }
                guard let scroll = view as? UIScrollView else { return }
                Self.hideSpinner(of: scroll)
                self.installIndicator(in: scroll)
                guard scroll !== self.scrollView else { return }
                self.scrollView = scroll
                self.observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                    Self.hideSpinner(of: scroll)
                    let pull = -(scroll.contentOffset.y + scroll.safeAreaInsets.top)
                    self?.state.setPull(pull)
                }
            }
        }

        private func installIndicator(in scroll: UIScrollView) {
            guard let control = scroll.refreshControl else { return }
            let host = self.host ?? {
                let h = UIHostingController(rootView: JohanRefreshOverlay(state: state))
                h.view.backgroundColor = .clear
                h.view.isUserInteractionEnabled = false
                h.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                h.safeAreaRegions = []
                self.host = h
                return h
            }()
            guard host.view.superview !== control else { return }
            host.view.frame = control.bounds
            control.addSubview(host.view)
        }

        private static func hideSpinner(of scroll: UIScrollView) {
            guard let control = scroll.refreshControl, control.tintColor != .clear else { return }
            control.tintColor = .clear
        }
    }
}
#endif
