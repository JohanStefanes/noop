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
    // Apple-native dark: true black ground, translucent glass cards, the system's dark-mode signal colours
    // (the Fitness / Health family), so the app reads as part of iOS rather than as a theme laid over it.
    static let background = Color.black
    /// Glass fill for cards: white at a low alpha over black, under a hairline edge (`cardBorder`).
    static let card = inkAlpha(0.075, highContrast: 0.16)
    static let cardBorder = inkAlpha(0.10, highContrast: 0.30)
    static let track = inkAlpha(0.12, highContrast: 0.28)
    /// Unlit bezel ticks (calibration and strain dials).
    static let tick = inkAlpha(0.20, highContrast: 0.36)

    // iOS dark-mode system colours; each clears 6:1 on black.
    static let recoveryGreen = Color(hex: "#30D158")
    static let recoveryYellow = Color(hex: "#FFD60A")
    static let recoveryRed = Color(hex: "#FF453A")
    static let strainBlue = Color(hex: "#64D2FF")
    static let sleepViolet = Color(hex: "#A294FF")

    static let textPrimary = Color.white
    /// The system secondary label (#EBEBF5 at 60 %): 9.6:1 on black.
    static let textSecondary = inkAlpha(0.60, highContrast: 0.80)
    /// 6.4:1 on black, still a clear step below `textSecondary`.
    static let textTertiary = inkAlpha(0.46, highContrast: 0.68)

    /// The system label ink (#EBEBF5) at `alpha`, raised to `highContrast` while Increase Contrast is on.
    private static func inkAlpha(_ alpha: CGFloat, highContrast: CGFloat) -> Color {
        Color(UIColor { traits in
            UIColor(red: 0xeb / 255, green: 0xeb / 255, blue: 0xf5 / 255,
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
        static let cardRadius: CGFloat = 22
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
        /// Figures: SF Pro Rounded semibold with fixed-width digits, as Fitness and Health set them.
        static func number(_ size: CGFloat) -> Font {
            .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
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
            // Glass: a faint fill under a hairline edge, the Fitness / Health card.
            .background(
                RoundedRectangle(cornerRadius: JohanTheme.Metrics.cardRadius, style: .continuous)
                    .fill(JohanTheme.card)
                    .overlay(RoundedRectangle(cornerRadius: JohanTheme.Metrics.cardRadius, style: .continuous)
                        .strokeBorder(JohanTheme.cardBorder, lineWidth: 0.5))
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
