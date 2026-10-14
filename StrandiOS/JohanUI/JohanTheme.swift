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

/// The JohanUI tabs, in tab-bar order.
enum JohanTab: Int {
    case home, sleep, strain, more
}

private struct JohanSelectTabKey: EnvironmentKey {
    static let defaultValue: (JohanTab) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Switches the JohanUI tab bar, so content (a ring on Home) can jump to the tab that owns it.
    var johanSelectTab: (JohanTab) -> Void {
        get { self[JohanSelectTabKey.self] }
        set { self[JohanSelectTabKey.self] = newValue }
    }

    /// True while the original `RootTabView` is hosted from inside the JohanUI "Mehr" tab, so that it
    /// renders its own classic shell instead of recursing into the JohanUI shell.
    var johanClassicBypass: Bool {
        get { self[JohanClassicBypassKey.self] }
        set { self[JohanClassicBypassKey.self] = newValue }
    }
}

enum JohanTheme {
    // Warm graphite, not blue-black: the palette of an instrument case rather than a template dark mode.
    static let background = Color(hex: "#0d0d0c")
    static let card = Color(hex: "#181816")
    static let cardBorder = inkAlpha(0.07, highContrast: 0.22)
    static let track = inkAlpha(0.08, highContrast: 0.24)
    /// Unlit bezel ticks: a step above `track` so the chapter ring reads at a glance.
    static let tick = inkAlpha(0.18, highContrast: 0.34)

    // Muted signal colours: each still clears 5.7:1 on `card`, none of them neon.
    static let recoveryGreen = Color(hex: "#5cc98d")
    static let recoveryYellow = Color(hex: "#e6c04f")
    static let recoveryRed = Color(hex: "#ec6a5b")
    static let strainBlue = Color(hex: "#6ba4ea")
    static let sleepViolet = Color(hex: "#a294f0")

    /// Warm off-white ink; pure white glares against the graphite.
    static let textPrimary = Color(hex: "#f2efe8")
    /// 6.9:1 on `card` (higher with Increase Contrast).
    static let textSecondary = inkAlpha(0.66, highContrast: 0.82)
    /// 5.0:1 on `card`: above the 4.5:1 floor for small text, still a step below `textSecondary`.
    static let textTertiary = inkAlpha(0.52, highContrast: 0.72)

    /// The warm ink at `alpha`, raised to `highContrast` while the system Increase Contrast setting is on.
    private static func inkAlpha(_ alpha: CGFloat, highContrast: CGFloat) -> Color {
        Color(UIColor { traits in
            UIColor(red: 0xf2 / 255, green: 0xef / 255, blue: 0xe8 / 255,
                    alpha: traits.accessibilityContrast == .high ? highContrast : alpha)
        })
    }

    /// Recovery zone: the one place that turns a recovery % into a word, a colour and a training hint, so
    /// the dial, the verdict under it and the strain card can never disagree. Same 67 / 34 cut-offs as
    /// `CoupledView.optimalStrainRange`, which sets the target range.
    enum RecoveryZone {
        case high, medium, low

        init(_ pct: Double) {
            switch pct {
            case 67...: self = .high
            case 34..<67: self = .medium
            default: self = .low
            }
        }

        var color: Color {
            switch self {
            case .high: return JohanTheme.recoveryGreen
            case .medium: return JohanTheme.recoveryYellow
            case .low: return JohanTheme.recoveryRed
            }
        }

        var title: String {
            switch self {
            case .high: return String(localized: "Well recovered")
            case .medium: return String(localized: "Moderate recovery")
            case .low: return String(localized: "Low recovery")
            }
        }

        var hint: String {
            switch self {
            case .high: return String(localized: "There is room for high strain today.")
            case .medium: return String(localized: "A solid workout is on the cards.")
            case .low: return String(localized: "Your body needs rest, keep strain low.")
            }
        }
    }

    static func recoveryColor(_ pct: Double) -> Color { RecoveryZone(pct).color }

    // MARK: Metrics
    enum Metrics {
        static let cardRadius: CGFloat = 16
        static let cardPadding: CGFloat = 16
        static let screenHPadding: CGFloat = 16
        static let cardSpacing: CGFloat = 14
        /// Hero (recovery / calibration) dial diameter as a share of the available width.
        static let heroDialWidthFraction: CGFloat = 0.54
        /// Medium dials (sleep, strain) as a share of the available width.
        static let mediumDialWidthFraction: CGFloat = 0.34
        /// Arc stroke as a share of the dial diameter (floored at `dialLineMin`): a fine instrument line.
        static let dialLineFraction: CGFloat = 0.032
        static let dialLineMin: CGFloat = 3
        /// Space the header (date bar, safe areas) takes from the visible height, for the fill-the-screen minimum.
        static let homeChromeAllowance: CGFloat = 110
        static let dialSize: CGFloat = 84
        static let ringLineWidth: CGFloat = 10
    }

    // MARK: Fonts (SF Pro text styles, so everything follows Dynamic Type)
    enum Fonts {
        /// Instrument numerals: SF Pro with fixed-width digits, lighter as they grow (a 56 pt figure in
        /// bold reads as a poster; in light it reads as a gauge). Small figures stay medium for legibility.
        static func number(_ size: CGFloat) -> Font {
            let weight: Font.Weight = size >= 40 ? .light : size >= 22 ? .regular : .medium
            return .system(size: size, weight: weight).monospacedDigit()
        }
        static let overline = Font.system(.subheadline, weight: .semibold)
        static let title = Font.system(.headline)
        static let body = Font.system(.footnote)
        static let caption = Font.system(.caption)
        static let unit = Font.system(.caption2, weight: .medium)
    }

    static func number(_ size: CGFloat) -> Font { Fonts.number(size) }
}

/// Rounded bold number at `size` points at the default text size, scaled with Dynamic Type relative to
/// `style` (capped so a hero number cannot outgrow the screen).
private struct JohanNumberFont: ViewModifier {
    @ScaledMetric private var scaled: CGFloat
    private let size: CGFloat

    init(size: CGFloat, relativeTo style: Font.TextStyle) {
        self.size = size
        _scaled = ScaledMetric(wrappedValue: size, relativeTo: style)
    }

    func body(content: Content) -> some View {
        content.font(JohanTheme.Fonts.number(min(scaled, size * 2.5)))
    }
}

extension View {
    /// Rounded bold number that follows Dynamic Type. Use instead of `.font(JohanTheme.number(_:))`.
    func johanNumberFont(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(JohanNumberFont(size: size, relativeTo: style))
    }
}

/// Graphite surface card used by every JohanUI screen.
struct JohanCard<Content: View>: View {
    var padding: CGFloat = JohanTheme.Metrics.cardPadding
    /// Scale to `Motion.pressScale` while touched. Off by default: a card that shrinks under a finger reads
    /// as tappable, so only turn it on for a card that does something. Cards inside a Button/NavigationLink
    /// use `JohanPressStyle` instead.
    var pressable = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Surface alone separates the card; no outline, which is the first thing that reads as a template.
            .background(
                RoundedRectangle(cornerRadius: JohanTheme.Metrics.cardRadius, style: .continuous)
                    .fill(JohanTheme.card)
            )
            .johanPressable(pressable)
    }
}

/// Section label above a card or inside one: plain sentence case, the way a well-set document labels a
/// section, not a tracked all-caps eyebrow on every block.
struct JohanOverline: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(JohanTheme.Fonts.overline)
            .foregroundStyle(JohanTheme.textSecondary)
    }
}

/// Title row shared by the three main screens.
struct JohanScreen<Content: View>: View {
    let title: String
    /// False hides the system bar entirely (Home draws its own date bar).
    var showsNavigationBar = true
    @ViewBuilder var content: () -> Content
    @EnvironmentObject private var repo: Repository

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
        // Pull to refresh re-reads the store; each screen reloads from `repo.$days` like after any refresh.
        .refreshable { await repo.refresh() }
        .background(JohanTheme.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(showsNavigationBar ? .large : .inline)
        .toolbar(showsNavigationBar ? .automatic : .hidden, for: .navigationBar)
        .toolbarBackground(JohanTheme.background, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
#endif

#if os(iOS)
/// Row that turns into a leading-aligned column at the accessibility text sizes, so side-by-side items
/// (dials, stat columns) never truncate or overlap when the text grows.
struct JohanAdaptiveStack<Content: View>: View {
    var spacing: CGFloat? = nil
    var rowAlignment: VerticalAlignment = .top
    @ViewBuilder var content: () -> Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: rowAlignment, spacing: spacing))
        layout { content() }
    }
}
#endif

#if os(iOS)
/// Icon and title close together, for small inline labels ("▲ 7 über Ø").
struct JohanCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
#endif
