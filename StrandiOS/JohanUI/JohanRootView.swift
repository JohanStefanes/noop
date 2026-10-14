#if os(iOS)
import SwiftUI
import StrandDesign

/// Root of the JohanUI layer: Heute, Schlaf, Belastung and Mehr. `RootTabView` routes here while
/// `johanUIEnabled` is on. The original shell is still reachable from "Mehr".
struct JohanRootView: View {
    let homeScreenQuickActionsEnabled: Bool

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var router: NavRouter
    @State private var selectedTab = JohanRootView.initialTab
    private let motion = JohanStill()

    /// DEBUG only: `--johan-tab <0-3>` picks the starting tab (simulator screenshots).
    private static var initialTab: Int {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--johan-tab"), i + 1 < args.count, let n = Int(args[i + 1]), (0...3).contains(n) {
            return n
        }
        #endif
        return 0
    }
    @State private var routed: NavRouter.Destination?
    @State private var introPhase: JohanIntroPhase = JohanIntro.played || JohanIntro.suppressed ? .done : .playing
    @State private var introTarget: JohanIntroTarget?
    /// When the app last went to the background, so a real return replays the intro and an app-switcher
    /// flick does not.
    @State private var backgroundedAt: Date?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { JohanHomeView().tabRouteDestinations() }
                .tabItem { tabLabel(String(localized: "Today"), "circle.hexagongrid.fill", 0) }.tag(0)
            NavigationStack { JohanSleepCoachView().tabRouteDestinations() }
                .tabItem { tabLabel(String(localized: "Sleep"), "moon.stars.fill", 1) }.tag(1)
            NavigationStack { JohanStrainView().tabRouteDestinations() }
                .tabItem { tabLabel(String(localized: "Strain"), "flame.fill", 2) }.tag(2)
            JohanMoreView(homeScreenQuickActionsEnabled: homeScreenQuickActionsEnabled)
                .tabItem { tabLabel(String(localized: "More"), "ellipsis", 3) }.tag(3)
        }
        .environment(\.johanSelectTab) { tab in selectedTab = tab.rawValue }
        .environment(\.johanIntroPhase, introPhase)
        .environment(\.johanIntroTarget) { target in
            if introPhase != .done && introTarget != target { introTarget = target }
        }
        .overlay {
            if introPhase != .done {
                JohanIntroOverlay(target: introTarget) { introPhase = $0 }
            }
        }
        .onAppear {
            guard introPhase != .done else { return }
            JohanIntro.played = true
            if motion.isStill { introPhase = .done }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: backgroundedAt = Date()
            case .active: replayIntroAfterReturn()
            default: break
            }
        }
        // White, not an accent: green is reserved for "well recovered" in the content below.
        .tint(JohanTheme.textPrimary)
        // noop's own appearance setting sets preferredColorScheme higher up and wins over ours, so the
        // resolved scheme is forced for this subtree too; otherwise semantic colours render black on black.
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .task { await repo.refresh() }
        .sheet(item: $routed) { dest in routedScreen(dest) }
        // The original shell answers these cross-screen requests; here the common ones are honoured so a
        // "Manage devices" or "Open journal" tap inside an original screen never dead-ends.
        .onChange(of: router.requestedDestination) { _, dest in
            guard let dest else { return }
            router.requestedDestination = nil
            routed = dest
        }
    }

    /// Opening the app from the background plays the intro again, as a cold launch does. Only on Today
    /// with nothing presented over it, since the rings land on the Home rings.
    private func replayIntroAfterReturn() {
        defer { backgroundedAt = nil }
        guard let away = backgroundedAt, Date().timeIntervalSince(away) >= JohanIntro.replayAfterBackground,
              introPhase == .done, selectedTab == JohanTab.home.rawValue, routed == nil,
              !motion.isStill, !JohanIntro.suppressed else { return }
        introPhase = .playing
    }

    /// Tab label whose icon bounces when its tab becomes selected (best effort: UIKit renders the bar item).
    private func tabLabel(_ title: String, _ icon: String, _ tag: Int) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon).symbolEffect(.bounce, value: motion.isStill ? -1 : (selectedTab == tag ? 1 : 0))
        }
    }

    @ViewBuilder
    private func routedScreen(_ dest: NavRouter.Destination) -> some View {
        NavigationStack {
            Group {
                switch dest {
                case .insightsHub: InsightsHubView()
                case .labBook: LabBookView()
                case .fusedRecord: FusedRecordHost()
                case .rhythm: RhythmHost(onClose: { routed = nil })
                case .devices: DevicesView()
                case .trends: TrendsView()
                case .activeWorkout: LiveView()
                case .liveSession: LiquidTodayView()
                case .journal: InsightsView()
                case .coach: CoachView()
                case .alarms: SmartAlarmView()
                }
            }
            .tabRouteDestinations()
            .background(JohanTheme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { routed = nil }
                }
            }
        }
    }
}
#endif
