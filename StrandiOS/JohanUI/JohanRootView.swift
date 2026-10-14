#if os(iOS)
import SwiftUI
import StrandDesign

/// Root of the JohanUI layer: Heute, Schlaf, Journal and Mehr. `RootTabView` routes here while
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

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { JohanHomeView().tabRouteDestinations() }
                .johanTabFade(selected: selectedTab == 0, still: motion.isStill)
                .tabItem { tabLabel("Heute", "circle.hexagongrid.fill", 0) }.tag(0)
            NavigationStack { JohanSleepCoachView().tabRouteDestinations() }
                .johanTabFade(selected: selectedTab == 1, still: motion.isStill)
                .tabItem { tabLabel("Schlaf", "moon.stars.fill", 1) }.tag(1)
            NavigationStack { JohanJournalImpactView().tabRouteDestinations() }
                .johanTabFade(selected: selectedTab == 2, still: motion.isStill)
                .tabItem { tabLabel("Journal", "book.closed.fill", 2) }.tag(2)
            JohanMoreView(homeScreenQuickActionsEnabled: homeScreenQuickActionsEnabled)
                .johanTabFade(selected: selectedTab == 3, still: motion.isStill)
                .tabItem { tabLabel("Mehr", "ellipsis", 3) }.tag(3)
        }
        .onChange(of: selectedTab) { _, _ in StrandHaptic.selection.play() }
        .tint(JohanTheme.recoveryGreen)
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
            switch dest {
            case .journal: selectedTab = 2
            default: routed = dest
            }
        }
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
                    Button("Fertig") { routed = nil }
                }
            }
        }
    }
}
#endif

#if os(iOS)
private struct JohanTabFade: ViewModifier {
    let selected: Bool
    let still: Bool
    func body(content: Content) -> some View {
        content
            .opacity(selected || still ? 1 : 0)
            .animation(still ? nil : JohanTheme.Motion.tabFade, value: selected)
    }
}

extension View {
    /// Gentle fade-in of a tab's content when it becomes the selected tab.
    func johanTabFade(selected: Bool, still: Bool) -> some View { modifier(JohanTabFade(selected: selected, still: still)) }
}
#endif
