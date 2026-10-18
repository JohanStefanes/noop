#if os(iOS)
import SwiftUI
import UserNotifications
import StrandDesign

/// "Mehr": keeps every original NOOP screen reachable from the JohanUI shell. The key screens are linked
/// directly; the complete original shell (with its own More list) opens full-screen, and the switch below
/// turns the JohanUI layer off entirely.
struct JohanMoreView: View {
    let homeScreenQuickActionsEnabled: Bool
    @AppStorage(JohanUI.enabledKey) private var johanUIEnabled = true
    @State private var showClassic = false
    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 30
    /// The app-wide language choice (`AppLanguage`, the same setting as Settings → Language).
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.english.rawValue
    /// The three Live Activity switches, on the SAME keys as Settings → Live notifications, so the two screens
    /// cannot disagree.
    @AppStorage(UnitPrefs.liveActivityKey) private var liveHREnabled = true
    @AppStorage(UnitPrefs.liftLiveActivityKey) private var liftActivityEnabled = true
    @AppStorage(UnitPrefs.syncLiveActivityKey) private var syncActivityEnabled = true
    /// The alert switches below bind the SAME `BehaviorStore` fields as Automations, so the two screens cannot
    /// disagree about whether an alert is on.
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var behavior: BehaviorStore
    @Environment(\.scenePhase) private var scenePhase
    /// The bedtime "no live heart rate" reminder (`JohanLiveLinkReminder`), and the capture it depends on.
    @AppStorage(JohanLiveLinkReminder.enabledKey) private var liveLinkReminder = true
    @AppStorage(PuffinExperiment.keepRealtimeForDataKey) private var continuousHrv = false
    /// iOS's own permission, re-read on appear and on return from the Settings app.
    @State private var notificationStatus: UNAuthorizationStatus?

    private struct Row: Identifiable {
        let id: String
        let title: String
        let icon: String
        /// Tile colour. Green is left out on purpose: it means "well recovered" everywhere else.
        let tint: Color
        let destination: AnyView
    }

    private static let neutral = JohanTheme.textSecondary

    private var rows: [(section: String, rows: [Row])] {
        [
            (String(localized: "Training & Body"), [
                Row(id: "live", title: String(localized: "Live"), icon: "waveform.path.ecg", tint: JohanTheme.recoveryRed, destination: AnyView(LiveView())),
                Row(id: "workouts", title: String(localized: "Workouts"), icon: "figure.run", tint: JohanTheme.strainBlue, destination: AnyView(WorkoutsView())),
                Row(id: "lift", title: String(localized: "Lift Log"), icon: "dumbbell.fill", tint: JohanTheme.strainBlue, destination: AnyView(LiftLogView())),
                Row(id: "health", title: String(localized: "Health"), icon: "heart.text.square.fill", tint: JohanTheme.recoveryRed, destination: AnyView(HealthView())),
                Row(id: "stress", title: String(localized: "Stress"), icon: "bolt.heart.fill", tint: JohanTheme.recoveryYellow, destination: AnyView(StressView())),
                Row(id: "breathe", title: String(localized: "Breathe"), icon: "wind", tint: JohanTheme.sleepViolet, destination: AnyView(BreathingView())),
                Row(id: "intervals", title: String(localized: "Interval Timer"), icon: "timer", tint: JohanTheme.strainBlue, destination: AnyView(IntervalTimerView())),
                Row(id: "healthspan", title: String(localized: "Healthspan"), icon: "hourglass", tint: JohanTheme.strainBlue, destination: AnyView(JohanHealthspanView())),
                Row(id: "cycle", title: String(localized: "Cycle"), icon: "drop.degreesign", tint: JohanTheme.recoveryRed, destination: AnyView(JohanCycleView()))
            ]),
            (String(localized: "Insights"), [
                Row(id: "week", title: String(localized: "Weekly Review"), icon: "calendar", tint: JohanTheme.recoveryGreen, destination: AnyView(JohanWeekView())),
                Row(id: "trends", title: String(localized: "Trends"), icon: "chart.line.uptrend.xyaxis", tint: JohanTheme.strainBlue, destination: AnyView(TrendsView())),
                Row(id: "coach", title: String(localized: "Coach"), icon: "sparkles", tint: JohanTheme.sleepViolet, destination: AnyView(CoachView())),
                Row(id: "insights", title: String(localized: "Journal & Insights"), icon: "lightbulb.fill", tint: JohanTheme.recoveryYellow, destination: AnyView(InsightsView())),
                Row(id: "explore", title: String(localized: "Metric Explorer"), icon: "chart.xyaxis.line", tint: JohanTheme.strainBlue, destination: AnyView(MetricExplorerView())),
                Row(id: "compare", title: String(localized: "Compare"), icon: "arrow.left.arrow.right", tint: JohanTheme.strainBlue, destination: AnyView(CompareView())),
                Row(id: "labBook", title: String(localized: "Lab Book"), icon: "testtube.2", tint: JohanTheme.recoveryRed, destination: AnyView(LabBookView())),
                Row(id: "hub", title: String(localized: "What Moves You"), icon: "wand.and.sparkles", tint: JohanTheme.sleepViolet, destination: AnyView(InsightsHubView())),
                Row(id: "watchCompare", title: String(localized: "MG vs Watch"), icon: "applewatch", tint: JohanTheme.strainBlue, destination: AnyView(JohanWatchCompareView()))
            ]),
            (String(localized: "Strap & App"), [
                Row(id: "alarmClock", title: String(localized: "Alarm Clock"), icon: "alarm.fill", tint: JohanTheme.recoveryYellow, destination: AnyView(JohanAlarmsView())),
                Row(id: "alarms", title: String(localized: "Strap Alarm"), icon: "bed.double.fill", tint: JohanTheme.recoveryYellow, destination: AnyView(SmartAlarmView())),
                Row(id: "alarmLink", title: String(localized: "Alarm Vibration"), icon: "alarm.waves.left.and.right", tint: JohanTheme.recoveryYellow, destination: AnyView(JohanAlarmLinkView())),
                Row(id: "steps", title: String(localized: "Calibrate Steps"), icon: "shoeprints.fill", tint: JohanTheme.recoveryGreen, destination: AnyView(JohanStepCalibrationView())),
                Row(id: "devices", title: String(localized: "Devices"), icon: JohanStrapGlyph.iconName, tint: Self.neutral, destination: AnyView(DevicesView())),
                Row(id: "backup", title: String(localized: "Backup & Sync"), icon: "externaldrive.fill.badge.icloud", tint: Self.neutral, destination: AnyView(BackupSyncView())),
                Row(id: "settings", title: String(localized: "Settings"), icon: "gearshape.fill", tint: Self.neutral, destination: AnyView(SettingsView()))
            ]),
            (String(localized: "Classic View"), [
                Row(id: "today", title: String(localized: "Today (Original)"), icon: "square.grid.2x2", tint: Self.neutral, destination: AnyView(LiquidTodayView())),
                Row(id: "sleep", title: String(localized: "Sleep (Original)"), icon: "bed.double", tint: Self.neutral, destination: AnyView(SleepView()))
            ])
        ]
    }

    /// The original settings screens in "Strap & App", drawn in the JohanUI look.
    private static let settingsRowIDs: Set<String> = ["alarms", "devices", "backup", "settings"]

    /// An original screen in the JohanUI chrome. Settings screens also switch their cards to glass on black
    /// and their switches to the JohanUI tint, which carries into the screens they push.
    @ViewBuilder
    private func destination(_ row: Row, settingsGroup: Bool) -> some View {
        let screen = JohanStaticDestination(content: row.destination).equatable()
        if settingsGroup {
            screen
                .environment(\.noopSurfaceStyle, .glass)
                // The shell tints white; a white switch on a dark card reads as off.
                .tint(JohanTheme.sleepViolet)
                .background(JohanTheme.background.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .modifier(JohanPushedBarBackground())
        } else {
            screen
                .background(JohanTheme.background.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    var body: some View {
        NavigationStack {
            JohanScreen(title: String(localized: "More")) {
                ForEach(Array(rows.enumerated()), id: \.element.section) { gi, group in
                    JohanOverline(group.section).padding(.top, gi == 0 ? 0 : 8).johanStagger(gi)
                    JohanCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(group.rows) { row in
                                NavigationLink {
                                    destination(row, settingsGroup: Self.settingsRowIDs.contains(row.id))
                                } label: { rowLabel(row.title, row.icon, tint: row.tint) }
                                .buttonStyle(JohanRowStyle())
                                if row.id != group.rows.last?.id { rowDivider }
                            }
                            if group.section == rows.last?.section {
                                rowDivider
                                Button { showClassic = true } label: {
                                    rowLabel(String(localized: "Open the full original app"), "rectangle.on.rectangle", tint: Self.neutral)
                                }
                                .buttonStyle(JohanRowStyle())
                                rowDivider
                                Toggle(isOn: $johanUIEnabled) {
                                    HStack(spacing: 14) {
                                        iconTile("paintpalette.fill", tint: JohanTheme.sleepViolet)
                                        Text("Johan Interface").font(.system(.body)).foregroundStyle(JohanTheme.textPrimary)
                                    }
                                }
                                // The shell tints white; a white switch on a dark card reads as off.
                                .tint(JohanTheme.sleepViolet)
                                .padding(.horizontal, 16).frame(minHeight: 52)
                            }
                        }
                    }
                    .johanStagger(gi)
                }
                Text("Turning it off brings back the original NOOP interface right away.")
                    .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                notificationsSection.padding(.top, 8)
                liveActivitiesSection.padding(.top, 8)
                languageSection.padding(.top, 8)
            }
            .tabRouteDestinations()
        }
        .task { await refreshNotificationStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshNotificationStatus() } }
        }
        .fullScreenCover(isPresented: $showClassic) {
            ZStack(alignment: .topTrailing) {
                RootTabView(homeScreenQuickActionsEnabled: homeScreenQuickActionsEnabled)
                    .environment(\.johanClassicBypass, true)
                Button { showClassic = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(.title))
                        .symbolRenderingMode(.hierarchical).padding(12)
                }
                .accessibilityLabel("Close")
            }
        }
    }

    // MARK: Notifications

    /// Only the alerts that ask for an action today: charge the strap, or take it easy. The once-a-day strain
    /// nudge and the morning brief stay in Automations and Coach; they are not offered here.
    @ViewBuilder
    private var notificationsSection: some View {
        JohanOverline(String(localized: "Notifications"))
        JohanCard(padding: 0) {
            VStack(spacing: 0) {
                if notificationStatus == .notDetermined || notificationStatus == .denied {
                    permissionRow
                    rowDivider
                }
                alertToggle("Strap battery", "battery.25", tint: JohanTheme.recoveryYellow,
                            detail: "When the strap runs low or nears the cutoff. Cleared once it charges.",
                            isOn: $behavior.batteryAlerts)
                rowDivider
                alertToggle("Won't last the night", "moon.zzz.fill", tint: JohanTheme.sleepViolet,
                            detail: "Before bed, if the battery won't cover tonight's sleep.",
                            isOn: $behavior.batteryPredictiveAlerts)
                    .disabled(!behavior.batteryAlerts)
                rowDivider
                alertToggle("Early illness signs", "cross.case.fill", tint: JohanTheme.recoveryRed,
                            detail: "When two or more signals drift together. At most once a day; needs 14 days of history.",
                            isOn: $behavior.illnessWatch)
                rowDivider
                // Without Continuous HRV capture there is no overnight live stream, so the reminder never
                // runs; the switch says so instead of showing an "on" that cannot fire.
                alertToggle("No live heart rate at bedtime", "antenna.radiowaves.left.and.right",
                            tint: JohanTheme.sleepViolet,
                            detail: continuousHrv
                                ? "In the evening, when NOOP stops receiving live heart rate, for example after it was swiped away."
                                : "Needs Continuous HRV capture, which records the night live.",
                            isOn: $liveLinkReminder)
                    .disabled(!continuousHrv)
            }
        }
        .onChange(of: behavior.illnessWatch) { _, _ in model.reevaluateIllness() }
    }

    @ViewBuilder
    private var permissionRow: some View {
        let denied = notificationStatus == .denied
        Button {
            if denied {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } else {
                Task { await requestNotificationPermission() }
            }
        } label: {
            HStack(spacing: 14) {
                iconTile("bell.badge.fill", tint: JohanTheme.recoveryRed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(denied ? "Notifications are off for NOOP" : "Allow notifications")
                        .font(.system(.body)).foregroundStyle(JohanTheme.textPrimary)
                    Text(denied ? "Turn them on in iOS Settings, or the alerts below stay silent."
                                : "The alerts below need iOS's permission before they can arrive.")
                        .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: denied ? "arrow.up.forward.app" : "chevron.right")
                    .font(.system(.footnote, weight: .semibold)).foregroundStyle(JohanTheme.textTertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(JohanRowStyle())
    }

    private func alertToggle(_ title: LocalizedStringKey, _ icon: String, tint: Color,
                             detail: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        liveActivityToggle(title, icon, tint: tint, detail: detail, isOn: Binding(
            get: { isOn.wrappedValue },
            set: { on in
                isOn.wrappedValue = on
                // Switching an alert on is the moment to ask, not the first 3 a.m. crossing.
                if on, notificationStatus == .notDetermined { Task { await requestNotificationPermission() } }
            }))
    }

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshNotificationStatus()
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: Live Activities

    /// One switch per Live Activity the app has. A switch only hides its banner. Off ends the heart rate banner at
    /// once and a Lift Log banner at its next update; a sync banner already up runs to its end, and none starts after.
    @ViewBuilder
    private var liveActivitiesSection: some View {
        JohanOverline(String(localized: "Live notifications"))
        JohanCard(padding: 0) {
            VStack(spacing: 0) {
                liveActivityToggle("Live heart rate", "heart.fill", tint: JohanTheme.recoveryRed,
                                   detail: "Your heart rate while the strap measures it, a dash while it doesn't.", isOn: $liveHREnabled)
                rowDivider
                liveActivityToggle("Lift Log session", "dumbbell.fill", tint: JohanTheme.strainBlue,
                                   detail: "Your set, rest and heart rate, and the Lock Screen light-up on a double-tap.",
                                   isOn: $liftActivityEnabled)
                rowDivider
                liveActivityToggle("Strap sync", "arrow.triangle.2.circlepath", tint: Self.neutral,
                                   detail: "Progress while NOOP pulls history from the strap.", isOn: $syncActivityEnabled)
            }
        }
        Text("Shown on the Lock Screen and in the Dynamic Island. A switch only hides one: NOOP still measures and records everything.")
            .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
    }

    private func liveActivityToggle(_ title: LocalizedStringKey, _ icon: String, tint: Color,
                                    detail: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 14) {
                iconTile(icon, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(.body)).foregroundStyle(JohanTheme.textPrimary)
                    Text(detail).font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // As with the interface switch: the shell tints white, and a white switch on a dark card reads as off.
        .tint(JohanTheme.sleepViolet)
        .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 52)
    }

    // MARK: Language

    /// English / Deutsch. iOS binds the app's language at launch, so a change applies after NOOP is
    /// reopened; the note says so only while the choice differs from the running language.
    @ViewBuilder
    private var languageSection: some View {
        let options: [AppLanguage] = [.english, .german]
        JohanOverline(String(localized: "Language"))
        JohanCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(options) { language in
                    Button {
                        appLanguageRaw = language.rawValue
                        AppLanguage.apply(language.rawValue)
                    } label: {
                        HStack {
                            Text(language.autonym).font(.system(.body)).foregroundStyle(JohanTheme.textPrimary)
                            Spacer()
                            if AppLanguage.resolve(appLanguageRaw) == language {
                                Image(systemName: "checkmark")
                                    .font(.system(.body, weight: .semibold))
                                    .foregroundStyle(JohanTheme.strainBlue)
                            }
                        }
                        .padding(.horizontal, 16).frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(JohanRowStyle())
                    .accessibilityAddTraits(AppLanguage.resolve(appLanguageRaw) == language ? .isSelected : [])
                    if language != options.last { Divider().overlay(JohanTheme.cardBorder).padding(.leading, 16) }
                }
            }
        }
        if languageNeedsReopen {
            Text("Reopen NOOP to switch the language.")
                .font(.system(.caption)).foregroundStyle(JohanTheme.recoveryYellow)
        }
    }

    /// True while the stored choice differs from the language the app is running in.
    private var languageNeedsReopen: Bool {
        let running = Bundle.main.preferredLocalizations.first?.split(separator: "-").first.map(String.init) ?? "en"
        let chosen = AppLanguage.resolve(appLanguageRaw)
        return chosen != .system && chosen.rawValue != running
    }

    private var rowDivider: some View {
        // Inset past the icon tile, like a system grouped list.
        Divider().overlay(JohanTheme.cardBorder).padding(.leading, 16 + tileSize + 14)
    }

    private func iconTile(_ icon: String, tint: Color) -> some View {
        Group {
            if icon == JohanStrapGlyph.iconName {
                JohanStrapGlyph(color: tint, lineWidth: max(1.3, tileSize * 0.05))
                    .frame(width: tileSize * 0.74, height: tileSize * 0.74)
            } else {
                Image(systemName: icon)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
            .frame(width: tileSize, height: tileSize)
            // Tinted glyph on a faint wash of its own colour: quieter than a saturated tile per row.
            .background(RoundedRectangle(cornerRadius: tileSize * 0.27, style: .continuous).fill(tint.opacity(0.14)))
            .accessibilityHidden(true)
    }

    private func rowLabel(_ title: String, _ icon: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            iconTile(icon, tint: tint)
            Text(title).font(.system(.body)).foregroundStyle(JohanTheme.textPrimary)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold))
                .foregroundStyle(JohanTheme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16).frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}
#endif

#if os(iOS)
/// A More destination that never re-renders because the stack rebuilt it. Every row's screen takes no
/// inputs, so two instances are always the same screen. Without this the NavigationStack re-created a
/// pushed Settings on every pass and Settings, too large to rebuild in a frame, kept the main thread busy
/// for good: the app froze the moment Settings opened.
private struct JohanStaticDestination: View, Equatable {
    let content: AnyView
    static func == (lhs: Self, rhs: Self) -> Bool { true }
    var body: some View { content }
}
#endif

#if os(iOS)
/// The black bar behind a pushed settings screen, on iOS 26 only. On iOS 17 and 18 a toolbar background on
/// a `ScreenScaffold` screen pushed onto this stack never settles: UIKit re-lays the hosting view out on
/// every pass and the app hangs at full CPU the moment Backup & Sync or Settings opens. Without it those
/// releases show their default bar, which is transparent at the top of the screen anyway.
private struct JohanPushedBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.toolbarBackground(JohanTheme.background, for: .navigationBar)
        } else {
            content
        }
    }
}
#endif

#if os(iOS)
/// List-row press feedback: the row background lightens while touched, like a system list cell.
private struct JohanRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.06 : 0))
    }
}
#endif
