#if os(iOS)
import SwiftUI

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
                Row(id: "live", title: "Live", icon: "waveform.path.ecg", tint: JohanTheme.recoveryRed, destination: AnyView(LiveView())),
                Row(id: "workouts", title: "Workouts", icon: "figure.run", tint: JohanTheme.strainBlue, destination: AnyView(WorkoutsView())),
                Row(id: "lift", title: "Lift Log", icon: "dumbbell.fill", tint: JohanTheme.strainBlue, destination: AnyView(LiftLogView())),
                Row(id: "health", title: String(localized: "Health"), icon: "heart.text.square.fill", tint: JohanTheme.recoveryRed, destination: AnyView(HealthView())),
                Row(id: "stress", title: "Stress", icon: "bolt.heart.fill", tint: JohanTheme.recoveryYellow, destination: AnyView(StressView())),
                Row(id: "breathe", title: String(localized: "Breathe"), icon: "wind", tint: JohanTheme.sleepViolet, destination: AnyView(BreathingView()))
            ]),
            (String(localized: "Insights"), [
                Row(id: "trends", title: "Trends", icon: "chart.line.uptrend.xyaxis", tint: JohanTheme.strainBlue, destination: AnyView(TrendsView())),
                Row(id: "coach", title: "Coach", icon: "sparkles", tint: JohanTheme.sleepViolet, destination: AnyView(CoachView())),
                Row(id: "insights", title: String(localized: "Journal & Insights"), icon: "lightbulb.fill", tint: JohanTheme.recoveryYellow, destination: AnyView(InsightsView())),
                Row(id: "hub", title: String(localized: "What Moves You"), icon: "wand.and.sparkles", tint: JohanTheme.sleepViolet, destination: AnyView(InsightsHubView()))
            ]),
            (String(localized: "Strap & App"), [
                Row(id: "alarms", title: String(localized: "Alarms"), icon: "alarm.fill", tint: JohanTheme.recoveryYellow, destination: AnyView(SmartAlarmView())),
                Row(id: "alarmLink", title: String(localized: "Alarm Vibration"), icon: "alarm.waves.left.and.right", tint: JohanTheme.recoveryYellow, destination: AnyView(JohanAlarmLinkView())),
                Row(id: "devices", title: String(localized: "Devices"), icon: "applewatch", tint: Self.neutral, destination: AnyView(DevicesView())),
                Row(id: "backup", title: "Backup & Sync", icon: "externaldrive.fill.badge.icloud", tint: Self.neutral, destination: AnyView(BackupSyncView())),
                Row(id: "settings", title: String(localized: "Settings"), icon: "gearshape.fill", tint: Self.neutral, destination: AnyView(SettingsView()))
            ]),
            (String(localized: "Classic View"), [
                Row(id: "today", title: String(localized: "Today (Original)"), icon: "square.grid.2x2", tint: Self.neutral, destination: AnyView(LiquidTodayView())),
                Row(id: "sleep", title: String(localized: "Sleep (Original)"), icon: "bed.double", tint: Self.neutral, destination: AnyView(SleepView()))
            ])
        ]
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
                                    row.destination
                                        .background(JohanTheme.background.ignoresSafeArea())
                                        .navigationBarTitleDisplayMode(.inline)
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
                languageSection.padding(.top, 8)
            }
            .tabRouteDestinations()
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
        Image(systemName: icon)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(tint)
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
/// List-row press feedback: the row background lightens while touched, like a system list cell.
private struct JohanRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.06 : 0))
    }
}
#endif
