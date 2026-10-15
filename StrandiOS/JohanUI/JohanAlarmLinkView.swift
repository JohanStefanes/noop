#if os(iOS)
import SwiftUI

/// "Armband bei iPhone-Wecker": how to make the strap vibrate when a Clock alarm rings. iOS lets no app read
/// or observe Clock alarms and no app can create a Shortcuts automation itself, so this screen explains the
/// one-time automation and lets the user test the exact action it runs (`AlarmBuzzIntent`'s path).
struct JohanAlarmLinkView: View {
    @EnvironmentObject private var live: LiveState
    @State private var testing = false
    @State private var testResult: String?
    @State private var pattern = AlarmBuzzPattern.saved
    @State private var preset = AlarmBuzzPattern.savedPreset
    @Environment(\.openURL) private var openURL

    private let steps = [
        String(localized: "Open the Shortcuts app and choose “Automation” at the bottom."),
        String(localized: "Tap “+” and choose “Alarm”."),
        String(localized: "Set it to run when an alarm goes off, for any alarm or just one."),
        String(localized: "Choose “Run Immediately” so it doesn't ask first."),
        String(localized: "Add NOOP's “Buzz Strap for Alarm” action and tap “Done”."),
    ]

    var body: some View {
        JohanScreen(title: String(localized: "Alarm Vibration")) {
            JohanCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("When your iPhone alarm goes off, NOOP makes your strap vibrate in the pattern you choose, as long as the strap is connected.")
                        .font(.system(.subheadline, weight: .semibold))
                    Text("iOS doesn't let apps see the Clock app's alarms. The link therefore runs through a Shortcuts automation you set up once.")
                        .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                }
            }
            lastRunCard
            JohanOverline(String(localized: "Set up"))
            JohanCard {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(i + 1)").johanNumberFont(15).foregroundStyle(JohanTheme.strainBlue)
                                .frame(minWidth: 16, alignment: .leading)
                            Text(step).font(.system(.subheadline)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button {
                        if let url = URL(string: "shortcuts://") { openURL(url) }
                    } label: {
                        Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(JohanTheme.strainBlue)
                    }
                    .padding(.top, 4)
                }
            }
            patternSection
            JohanOverline(String(localized: "Test"))
            JohanCard {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack {
                            Image(systemName: "alarm.waves.left.and.right")
                            Text(testing ? String(localized: "Sending …") : String(localized: "Vibrate now"))
                        }
                        .font(.system(.body, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(JohanTheme.strainBlue.opacity(0.16)))
                        .foregroundStyle(JohanTheme.strainBlue)
                    }
                    .buttonStyle(JohanPressStyle())
                    .disabled(testing)
                    Text(testResult ?? (live.connected
                        ? String(localized: "Runs exactly the action the automation starts.")
                        : String(localized: "Strap not connected. The vibration needs an active connection, in the test and at the alarm.")))
                        .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
                }
            }
            JohanOverline(String(localized: "Good to know"))
            JohanCard {
                VStack(alignment: .leading, spacing: 8) {
                    note(String(localized: "The strap has to be connected to NOOP when the alarm goes off. If it isn't, it doesn't vibrate, and the shortcut says so."))
                    note(String(localized: "The pattern plays once. It is not a continuous alarm."))
                    note(String(localized: "Your iPhone alarm still rings as usual. The strap adds to it, it doesn't replace it."))
                }
            }
        }
    }

    // MARK: Last run

    /// What the automation last did. iOS does not let NOOP see whether the automation exists, so the last
    /// run it actually recorded is the only proof shown; before the first one this says so.
    private var lastRunCard: some View {
        let run = AlarmBuzzRun.last
        let ok = run?.sent == true
        return JohanCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: run == nil ? "questionmark.circle" : (ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                    .font(.system(.title3))
                    .foregroundStyle(run == nil ? JohanTheme.textTertiary : (ok ? JohanTheme.recoveryGreen : JohanTheme.recoveryYellow))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last alarm").font(.system(.subheadline, weight: .semibold))
                    if let run {
                        Text(run.date.formatted(.relative(presentation: .named)) + " · "
                             + run.date.formatted(date: .omitted, time: .shortened))
                            .font(JohanTheme.Fonts.body)
                        Text(ok ? String(localized: "The automation ran and the vibration was sent to the strap.")
                                : String(localized: "The automation ran, but the strap wasn't connected, so nothing was sent."))
                            .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
                    } else {
                        Text("No alarm has run the automation yet. If an alarm has already gone off, check the automation in the Shortcuts app.")
                            .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Pattern

    @ViewBuilder
    private var patternSection: some View {
        JohanOverline(String(localized: "Vibration pattern"))
        JohanCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(AlarmBuzzPattern.Preset.allCases) { p in
                    patternRow(title: p.title, summary: summary(p.pattern), selected: preset == p,
                               preview: p.pattern) { select(p.pattern, preset: p) }
                    Divider().overlay(JohanTheme.cardBorder).padding(.leading, 16)
                }
                patternRow(title: String(localized: "Custom"), summary: summary(pattern), selected: preset == nil,
                           preview: pattern) { select(pattern, preset: nil) }
                if preset == nil {
                    Divider().overlay(JohanTheme.cardBorder).padding(.leading, 16)
                    editor.padding(16)
                }
            }
        }
    }

    private func patternRow(title: String, summary: String, selected: Bool, preview: AlarmBuzzPattern,
                            select: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 12) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(.title3))
                        .foregroundStyle(selected ? JohanTheme.strainBlue : JohanTheme.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(.body)).foregroundStyle(JohanTheme.textPrimary)
                        Text(summary).font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            // Feel a pattern before choosing it; plays without changing the saved choice.
            Button {
                Task { await play(preview) }
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(.title2))
                    .foregroundStyle(testing ? JohanTheme.textTertiary : JohanTheme.strainBlue)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(testing)
            .accessibilityLabel(String(localized: "Try \(title)"))
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Stepper(value: binding(\.bursts),
                    in: AlarmBuzzPattern.burstRange.lowerBound...AlarmBuzzPattern.maxBursts(gap: pattern.gapSeconds)) {
                editorLabel(String(localized: "Bursts"), "\(pattern.bursts)")
            }
            Stepper(value: binding(\.pulses), in: AlarmBuzzPattern.pulseRange) {
                editorLabel(String(localized: "Pulses per burst"), "\(pattern.pulses)")
            }
            Stepper(value: binding(\.gapSeconds),
                    in: AlarmBuzzPattern.gapRange.lowerBound...AlarmBuzzPattern.maxGap(bursts: pattern.bursts), step: 0.5) {
                editorLabel(String(localized: "Pause between bursts"),
                            String(localized: "\(String(format: "%.1f", pattern.gapSeconds)) s"))
            }
            .disabled(pattern.bursts == 1)
            Toggle(isOn: binding(\.strapAlarmSignal)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Strap alarm signal").font(.system(.subheadline))
                    Text("Also sends the strap's own alarm command after each burst, as the original buzz did. WHOOP 4.0 only: on a 5.0/MG it would clear the strap's own wake alarm, so it is skipped there.")
                        .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
                }
            }
            .tint(JohanTheme.strainBlue)
            Text(String(localized: "Total length about \(String(format: "%.1f", pattern.spanSeconds)) s, at most \(String(Int(AlarmBuzzPattern.maxSpanSeconds))) s."))
                .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
        }
    }

    private func editorLabel(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(.subheadline))
            Spacer()
            Text(value).johanNumberFont(15).foregroundStyle(JohanTheme.strainBlue)
        }
    }

    /// Edits the custom pattern and saves it at once, so the shortcut always plays what is on screen.
    private func binding<V>(_ key: WritableKeyPath<AlarmBuzzPattern, V>) -> Binding<V> {
        Binding(get: { pattern[keyPath: key] },
                set: { pattern[keyPath: key] = $0; select(pattern, preset: nil) })
    }

    private func select(_ p: AlarmBuzzPattern, preset newPreset: AlarmBuzzPattern.Preset?) {
        pattern = p.clamped
        preset = newPreset
        AlarmBuzzPattern.save(pattern, preset: newPreset)
    }

    private func summary(_ p: AlarmBuzzPattern) -> String {
        let base = p.bursts == 1
            ? String(localized: "1 burst of \(String(p.pulses))")
            : String(localized: "\(String(p.bursts)) bursts of \(String(p.pulses)), every \(String(format: "%.1f", p.gapSeconds)) s")
        return p.strapAlarmSignal ? base + String(localized: " + alarm signal") : base
    }

    @MainActor
    private func play(_ p: AlarmBuzzPattern) async {
        testing = true
        testResult = nil
        switch await AppModel.buzzForAlarmFromShortcut(waitSeconds: 3, pattern: p) {
        case .sent: testResult = String(localized: "Sent. If you feel nothing, check the strap log under Devices.")
        case .strapNotConnected: testResult = String(localized: "Strap not connected, nothing sent.")
        }
        testing = false
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("·").foregroundStyle(JohanTheme.textTertiary)
            Text(text).font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @MainActor
    private func runTest() async { await play(pattern) }
}
#endif
