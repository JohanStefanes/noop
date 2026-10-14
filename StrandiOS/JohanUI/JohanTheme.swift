#if os(iOS)
import SwiftUI
import StrandDesign

// JohanTheme.swift — the self-contained dark theme of the personal "JohanUI" layer.
//
// Everything under StrandiOS/JohanUI is additive: the original NOOP shell stays reachable through the
// `johanUIEnabled` switch (see `RootTabView`) and the "Mehr" tab. No analytics live here, only tokens and
// small presentation primitives.

/// Switch for the personal UI layer. Default ON; flip to `false` (Mehr → Original-Oberfläche) to get the
/// original NOOP shell back.
enum JohanUI {
    static let enabledKey = "johanUIEnabled"
}

private struct JohanClassicBypassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the original `RootTabView` is hosted from inside the JohanUI "Mehr" tab, so that it
    /// renders its own classic shell instead of recursing into the JohanUI shell.
    var johanClassicBypass: Bool {
        get { self[JohanClassicBypassKey.self] }
        set { self[JohanClassicBypassKey.self] = newValue }
    }
}

enum JohanTheme {
    static let background = Color(hex: "#0a0b0d")
    static let card = Color(hex: "#16181c")
    static let cardBorder = Color.white.opacity(0.06)
    static let track = Color.white.opacity(0.09)

    static let recoveryGreen = Color(hex: "#3ddc84")
    static let recoveryYellow = Color(hex: "#ffd23f")
    static let recoveryRed = Color(hex: "#ff4d4f")
    static let strainBlue = Color(hex: "#4aa8ff")
    static let sleepViolet = Color(hex: "#a78bfa")

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)

    /// Recovery zone colour. Same 67 / 34 cut-offs as `CoupledView.optimalStrainRange`.
    static func recoveryColor(_ pct: Double) -> Color {
        switch pct {
        case 67...: return recoveryGreen
        case 34..<67: return recoveryYellow
        default: return recoveryRed
        }
    }

    // MARK: Metrics (placeholders until matched against reference screenshots)
    enum Metrics {
        static let cardRadius: CGFloat = 20
        static let cardPadding: CGFloat = 16
        static let screenHPadding: CGFloat = 16
        static let cardSpacing: CGFloat = 14
        static let dialLineWidth: CGFloat = 9
        /// Hero (recovery / calibration) dial diameter as a share of the available width.
        static let heroDialWidthFraction: CGFloat = 0.54
        /// Medium dials (sleep, strain) as a share of the available width.
        static let mediumDialWidthFraction: CGFloat = 0.34
        /// Stroke width as a share of the dial diameter (floored at `dialLineMin`).
        static let dialLineFraction: CGFloat = 0.085
        static let dialLineMin: CGFloat = 7
        /// Space the header (date bar, safe areas) takes from the visible height, for the fill-the-screen minimum.
        static let homeChromeAllowance: CGFloat = 110
        static let dialSize: CGFloat = 84
        static let ringLineWidth: CGFloat = 10
        static let borderWidth: CGFloat = 1
    }

    // MARK: Fonts (system SF Pro; swap here for the fidelity pass)
    enum Fonts {
        static func number(_ size: CGFloat) -> Font {
            .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
        }
        static let overline = Font.system(size: 11, weight: .semibold)
        static let title = Font.system(size: 17, weight: .semibold)
        static let body = Font.system(size: 13)
        static let caption = Font.system(size: 12)
        static let unit = Font.system(size: 10, weight: .medium)
    }

    static func number(_ size: CGFloat) -> Font { Fonts.number(size) }
}

/// Dark rounded card used by every JohanUI screen.
struct JohanCard<Content: View>: View {
    var padding: CGFloat = JohanTheme.Metrics.cardPadding
    /// Scale to `Motion.pressScale` while touched. Off for cards that sit inside a Button/NavigationLink
    /// (those use `JohanPressStyle`).
    var pressable = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: JohanTheme.Metrics.cardRadius, style: .continuous)
                    .fill(JohanTheme.card)
                    .overlay(RoundedRectangle(cornerRadius: JohanTheme.Metrics.cardRadius, style: .continuous)
                        .stroke(JohanTheme.cardBorder, lineWidth: JohanTheme.Metrics.borderWidth))
            )
            .johanPressable(pressable)
    }
}

/// Small uppercase caption above a card or inside one.
struct JohanOverline: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(JohanTheme.Fonts.overline)
            .tracking(1.2)
            .foregroundStyle(JohanTheme.textSecondary)
    }
}

/// Title row shared by the three main screens.
struct JohanScreen<Content: View>: View {
    let title: String
    /// False hides the system bar entirely (Home draws its own date bar).
    var showsNavigationBar = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JohanTheme.Metrics.cardSpacing) {
                content()
            }
            .padding(.horizontal, JohanTheme.Metrics.screenHPadding)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(JohanTheme.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(showsNavigationBar ? .large : .inline)
        .toolbar(showsNavigationBar ? .automatic : .hidden, for: .navigationBar)
        .toolbarBackground(JohanTheme.background, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
#endif
