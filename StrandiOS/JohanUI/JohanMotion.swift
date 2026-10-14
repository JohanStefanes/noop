#if os(iOS)
import SwiftUI
import StrandDesign

// JohanMotion.swift — motion tokens and the small modifiers every JohanUI animation goes through.
//
// Gate: every animation here asks `JohanStill` first. It is StrandDesign's own `NoopMotionState.poseStill`
// (system Reduce Motion + NOOP's Quiet Motion + Low Power Mode + occluded window), so JohanUI obeys the
// same switches as the rest of the app. When still, values are set instantly: no sweeps, no shimmer, no
// pulse, no stagger.

extension JohanTheme {
    /// Timings and spring parameters. Tune here only.
    enum Motion {
        // Dials
        static let dialSweep = Animation.spring(response: 0.95, dampingFraction: 0.74)
        static let dialSettle: Double = 0.85            // when the sweep counts as landed (haptic)
        static let countUp = Animation.easeOut(duration: 0.9)
        // Cards
        static let staggerStep: Double = 0.06
        static let riseOffset: CGFloat = 16
        static let cardIn = Animation.spring(response: 0.5, dampingFraction: 0.84)
        static let pressScale: CGFloat = 0.97
        static let press = Animation.spring(response: 0.25, dampingFraction: 0.7)
        // Day navigation
        static let daySlide = Animation.spring(response: 0.42, dampingFraction: 0.86)
        static let swipeMinDistance: CGFloat = 60
        // Live HR
        static let heartScale: CGFloat = 1.22
        static let sparkDraw = Animation.easeOut(duration: 1.1)
        // Calibration
        static let ringFill = Animation.spring(response: 0.9, dampingFraction: 0.8)
        // Strain gauge
        static let markerSpring = Animation.spring(response: 0.6, dampingFraction: 0.58)
        static let markerDelay: Double = 0.4
        // Charts
        static let barGrow = Animation.spring(response: 0.6, dampingFraction: 0.78)
        static let barStagger: Double = 0.05
        static let hypnogramReveal = Animation.easeOut(duration: 1.2)
    }
}

/// Reads the shared "hold still" signal. Declare `private let motion = JohanStill()` in a View and use
/// `motion.isStill`; it is a DynamicProperty, so the view re-renders when the signal flips.
struct JohanStill: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var state = NoopMotionState.shared
    var isStill: Bool { state.poseStill(reduceMotion) }
}

// MARK: - Staggered card entrance

private struct JohanStagger: ViewModifier {
    let index: Int
    private let motion = JohanStill()
    @State private var shown = false

    func body(content: Content) -> some View {
        let visible = shown || motion.isStill
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : JohanTheme.Motion.riseOffset)
            .onAppear {
                guard !shown else { return }
                if motion.isStill { shown = true; return }
                withAnimation(JohanTheme.Motion.cardIn.delay(Double(index) * JohanTheme.Motion.staggerStep)) {
                    shown = true
                }
            }
    }
}

// MARK: - Press feedback

private struct JohanPressable: ViewModifier {
    let enabled: Bool
    private let motion = JohanStill()
    @State private var pressed = false

    func body(content: Content) -> some View {
        if enabled {
            content
                .scaleEffect(pressed && !motion.isStill ? JohanTheme.Motion.pressScale : 1)
                .animation(JohanTheme.Motion.press, value: pressed)
                // A press that never completes: it only reports the touch state, scrolling still wins.
                .onLongPressGesture(minimumDuration: 60, maximumDistance: 24, perform: {},
                                    onPressingChanged: { pressed = $0 })
        } else {
            content
        }
    }
}

/// Button style for cards that are links/buttons: same 0.97 press scale.
struct JohanPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? JohanTheme.Motion.pressScale : 1)
            .animation(JohanTheme.Motion.press, value: configuration.isPressed)
    }
}

extension View {
    /// Fade + rise entrance, `index * Motion.staggerStep` seconds after the screen appears.
    func johanStagger(_ index: Int) -> some View { modifier(JohanStagger(index: index)) }
    func johanPressable(_ enabled: Bool = true) -> some View { modifier(JohanPressable(enabled: enabled)) }
}
#endif
