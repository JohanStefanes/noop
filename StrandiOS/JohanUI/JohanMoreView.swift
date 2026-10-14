#if os(iOS)
import SwiftUI

/// "Mehr": keeps every original NOOP screen reachable from the JohanUI shell. The key screens are linked
/// directly; the complete original shell (with its own More list) opens full-screen, and the switch below
/// turns the JohanUI layer off entirely.
struct JohanMoreView: View {
    let homeScreenQuickActionsEnabled: Bool
    @AppStorage(JohanUI.enabledKey) private var johanUIEnabled = true
    @State private var showClassic = false

    private struct Row: Identifiable {
        let id: String
        let title: String
        let icon: String
        let destination: AnyView
    }

    private var rows: [(section: String, rows: [Row])] {
        [
            ("Original-Screens", [
                Row(id: "today", title: "Heute (Original)", icon: "square.grid.2x2", destination: AnyView(LiquidTodayView())),
                Row(id: "trends", title: "Trends", icon: "chart.line.uptrend.xyaxis", destination: AnyView(TrendsView())),
                Row(id: "sleep", title: "Schlaf (Original)", icon: "bed.double", destination: AnyView(SleepView())),
                Row(id: "coach", title: "Coach", icon: "sparkles", destination: AnyView(CoachView())),
                Row(id: "insights", title: "Journal & Einblicke", icon: "lightbulb.fill", destination: AnyView(InsightsView())),
                Row(id: "hub", title: "Was dich bewegt", icon: "wand.and.sparkles", destination: AnyView(InsightsHubView()))
            ]),
            ("Körper", [
                Row(id: "live", title: "Live", icon: "waveform.path.ecg", destination: AnyView(LiveView())),
                Row(id: "workouts", title: "Workouts", icon: "figure.run", destination: AnyView(WorkoutsView())),
                Row(id: "lift", title: "Lift Log", icon: "dumbbell.fill", destination: AnyView(LiftLogView())),
                Row(id: "health", title: "Gesundheit", icon: "heart.text.square.fill", destination: AnyView(HealthView())),
                Row(id: "stress", title: "Stress", icon: "bolt.heart.fill", destination: AnyView(StressView())),
                Row(id: "breathe", title: "Atmen", icon: "wind", destination: AnyView(BreathingView()))
            ]),
            ("App", [
                Row(id: "alarms", title: "Wecker", icon: "alarm.fill", destination: AnyView(SmartAlarmView())),
                Row(id: "devices", title: "Geräte", icon: "applewatch", destination: AnyView(DevicesView())),
                Row(id: "backup", title: "Backup & Sync", icon: "externaldrive.fill.badge.icloud", destination: AnyView(BackupSyncView())),
                Row(id: "settings", title: "Einstellungen", icon: "gearshape.fill", destination: AnyView(SettingsView()))
            ])
        ]
    }

    var body: some View {
        NavigationStack {
            JohanScreen(title: "Mehr") {
                ForEach(Array(rows.enumerated()), id: \.element.section) { gi, group in
                    JohanOverline(group.section).johanStagger(gi)
                    JohanCard(padding: 0, pressable: false) {
                        VStack(spacing: 0) {
                            ForEach(group.rows) { row in
                                NavigationLink {
                                    row.destination
                                        .background(JohanTheme.background.ignoresSafeArea())
                                        .navigationBarTitleDisplayMode(.inline)
                                } label: { rowLabel(row.title, row.icon) }
                                .buttonStyle(.plain)
                                if row.id != group.rows.last?.id { Divider().overlay(JohanTheme.cardBorder) }
                            }
                        }
                    }
                }
                JohanOverline("Oberfläche")
                JohanCard(padding: 0, pressable: false) {
                    VStack(spacing: 0) {
                        Button { showClassic = true } label: { rowLabel("Komplette Original-App öffnen", "rectangle.on.rectangle") }
                            .buttonStyle(.plain)
                        Divider().overlay(JohanTheme.cardBorder)
                        Toggle(isOn: $johanUIEnabled) {
                            Label("Johan-Oberfläche aktiv", systemImage: "paintpalette")
                                .font(.system(size: 16))
                        }
                        .tint(JohanTheme.recoveryGreen)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
                Text("Ausschalten stellt die ursprüngliche NOOP-Oberfläche sofort wieder her.")
                    .font(.system(size: 12)).foregroundStyle(JohanTheme.textTertiary)
            }
            .tabRouteDestinations()
        }
        .fullScreenCover(isPresented: $showClassic) {
            ZStack(alignment: .topTrailing) {
                RootTabView(homeScreenQuickActionsEnabled: homeScreenQuickActionsEnabled)
                    .environment(\.johanClassicBypass, true)
                Button { showClassic = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical).padding(12)
                }
                .accessibilityLabel("Schließen")
            }
        }
    }

    private func rowLabel(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(JohanTheme.recoveryGreen)
                .frame(width: 26)
            Text(title).font(.system(size: 16)).foregroundStyle(JohanTheme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(JohanTheme.textTertiary)
        }
        .padding(.horizontal, 16).frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}
#endif
