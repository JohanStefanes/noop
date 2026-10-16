#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// JohanUI twin of the original Today's `AutoWorkoutCard`: the same opt-in switch
/// (`PuffinExperiment.autoDetectWorkoutsKey`), the same candidate (`Repository.autoDetectCandidate`), and the
/// same Save / dismiss paths, so a suggestion handled on one screen is gone from the other. It only suggests:
/// nothing is saved until the wearer taps Save.
///
/// `offersSwitch` shows the opt-in row while detection is off (the Workout tab); Home leaves it out and shows
/// nothing until there is a suggestion.
struct JohanAutoWorkoutCard: View {
    var offersSwitch = false
    @EnvironmentObject private var repo: Repository
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var enabled = false
    @State private var candidate: DetectedWorkout?
    @State private var handled = false
    @State private var saving = false

    private struct LoadKey: Equatable {
        let seq: Int
        let enabled: Bool
    }

    var body: some View {
        Group {
            if enabled, !handled, let w = candidate {
                suggestion(w)
            } else if offersSwitch {
                switchRow
            }
        }
        .task(id: LoadKey(seq: repo.refreshSeq, enabled: enabled)) {
            guard enabled else { candidate = nil; return }
            let next = await repo.autoDetectCandidate()
            if next != candidate { handled = false }
            candidate = next
        }
    }

    private var switchRow: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $enabled) {
                    Label("Detect workouts automatically", systemImage: "sparkles")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(JohanTheme.textPrimary)
                }
                .tint(JohanTheme.strainBlue)
                Text(enabled
                     ? String(localized: "On. A stretch of raised heart rate that is not saved yet appears here as a suggestion.")
                     : String(localized: "Suggests a workout when your heart rate stays raised for a while. Nothing is saved without your tap."))
                    .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func suggestion(_ w: DetectedWorkout) -> some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "figure.run")
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(JohanTheme.strainBlue)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(JohanTheme.strainBlue.opacity(0.16)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Looks like a workout").font(.system(.headline)).foregroundStyle(JohanTheme.textPrimary)
                        Text(when(w)).font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 18) {
                    figure(String(localized: "Duration"), "\(w.durationMin)", "min")
                    figure(String(localized: "Avg HR"), "\(w.avgBpm)", "bpm")
                    figure(String(localized: "Max HR"), "\(w.peakBpm)", "bpm")
                }
                HStack(spacing: 10) {
                    Button { save(w) } label: {
                        Label("Save", systemImage: "checkmark")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(JohanTheme.background)
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Capsule().fill(JohanTheme.strainBlue))
                    }
                    .buttonStyle(JohanPressStyle())
                    Button { dismiss(w) } label: {
                        Text("Not a workout")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(JohanTheme.textPrimary)
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Capsule().strokeBorder(JohanTheme.cardBorder))
                    }
                    .buttonStyle(JohanPressStyle())
                }
                .disabled(saving)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private func figure(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).johanNumberFont(20)
                Text(unit).font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Today, 14:05–14:32" / "Yesterday, ..." / a date.
    private func when(_ w: DetectedWorkout) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(w.startSec))
        let end = Date(timeIntervalSince1970: TimeInterval(w.endSec))
        let fmt = AppClock.hourMinuteFormatter()
        let span = "\(fmt.string(from: start))–\(fmt.string(from: end))"
        let cal = Calendar.current
        if cal.isDateInToday(start) { return String(localized: "Today, \(span)") }
        if cal.isDateInYesterday(start) { return String(localized: "Yesterday, \(span)") }
        let day = start.formatted(Date.FormatStyle(locale: AppLanguage.activeLocale).day().month(.abbreviated))
        return "\(day), \(span)"
    }

    private func save(_ w: DetectedWorkout) {
        saving = true
        withAnimation(JohanTheme.Motion.cardIn) { handled = true }
        Task {
            _ = await repo.saveDetectedWorkout(w)
            await repo.refresh()
            saving = false
        }
    }

    private func dismiss(_ w: DetectedWorkout) {
        repo.dismissDetectedSuggestion(w)
        withAnimation(JohanTheme.Motion.cardIn) {
            handled = true
            candidate = nil
        }
    }
}
#endif
