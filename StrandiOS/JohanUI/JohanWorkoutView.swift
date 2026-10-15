#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// "Workout": start a live workout with the strap and follow it while it records. With nothing running
/// it offers a sport and a Start button; while a workout runs it shows time, heart rate and Effort with
/// Pause and End. Below either, the latest workouts.
///
/// Recording is the app's one manual workout (`AppModel.startWorkout` / `endWorkout`), the same session
/// the original Live screen and a workout mirrored from the watch use, so it can be ended from any of them.
struct JohanWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var repo: Repository
    @Environment(\.johanReloadTick) private var reloadTick
    @StateObject private var history = JohanStrainModel()
    /// The sport last started here, offered first next time.
    @AppStorage("johanWorkoutSport") private var selectedSport = "Tennis"
    @State private var openWorkout: JohanStrainModel.Workout?
    @State private var confirmEnd = false
    /// The just-saved workout opened from its summary card.
    @State private var summaryDetail: WorkoutRow?
    /// Read when End is tapped: why ending now would keep nothing, so the confirmation can say so.
    @State private var endBlocker: AppModel.WorkoutSaveBlocker?

    /// Sports offered for a live start. `sport` is the catalogue name (`WorkoutCatalog`), stored verbatim on
    /// the saved workout, so it must match the catalogue spelling.
    private struct SportChoice: Identifiable {
        let sport: String
        let title: LocalizedStringKey
        var id: String { sport }
    }

    private static let sports: [SportChoice] = [
        SportChoice(sport: "Tennis", title: "Tennis"),
        SportChoice(sport: "Padel", title: "Padel"),
        SportChoice(sport: "Running", title: "Running"),
        SportChoice(sport: "Cycling", title: "Cycling"),
        SportChoice(sport: "Walking", title: "Walking"),
        SportChoice(sport: "Strength", title: "Strength"),
        SportChoice(sport: "HIIT", title: "HIIT"),
        SportChoice(sport: "Other", title: "Other"),
    ]

    var body: some View {
        JohanScreen(title: String(localized: "Workout")) {
            Group {
                if let workout = model.activeWorkout {
                    activeCard(workout)
                } else {
                    if let saved = model.lastWorkout {
                        JohanWorkoutSummaryCard(row: saved,
                                                onDetails: { summaryDetail = saved },
                                                onDone: { withAnimation { model.lastWorkout = nil } })
                    }
                    startCard
                }
            }
            .johanStagger(0)
            recentCard.johanStagger(1)
        }
        .sheet(item: $openWorkout) { w in
            NavigationStack { WorkoutDetailView(row: w.row).environmentObject(repo) }
                .noopSheetPresentation(largeFirst: true)
        }
        .sheet(isPresented: Binding(get: { summaryDetail != nil }, set: { if !$0 { summaryDetail = nil } })) {
            if let row = summaryDetail {
                NavigationStack { WorkoutDetailView(row: row).environmentObject(repo) }
                    .noopSheetPresentation(largeFirst: true)
            }
        }
        .alert("End this workout?", isPresented: $confirmEnd) {
            Button("Cancel", role: .cancel) { }
            // `endWorkout` either way: it drops what it cannot save, and a watch-started workout still
            // keeps the watch's own copy.
            Button(endBlocker == nil ? LocalizedStringKey("End") : LocalizedStringKey("End without saving"), role: .destructive) { model.endWorkout() }
        } message: {
            switch endBlocker {
            case .tooShort:
                Text("It has run for less than a minute, so nothing will be saved.")
            case .noHeartRate:
                Text("No heart rate has been recorded yet, so nothing will be saved. Connect the strap and keep going to keep this workout.")
            case nil:
                Text("This stops recording and saves what's captured so far. It can't be resumed.")
            }
        }
        .task(id: reloadTick) { await history.load(repo: repo) }
        .onReceive(repo.$days.dropFirst()) { _ in Task { await history.load(repo: repo) } }
    }

    // MARK: Start

    private var startCard: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 14) {
                JohanOverline(String(localized: "Choose a sport"))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(Self.sports) { choice in sportChip(choice) }
                }
                Button {
                    model.startWorkout(sport: selectedSport)
                } label: {
                    Label("Start workout", systemImage: "play.fill")
                        .font(.system(.headline))
                        .foregroundStyle(JohanTheme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(JohanTheme.strainBlue))
                }
                .buttonStyle(JohanPressStyle())
                if !live.connected {
                    Label("Strap not connected. Connect it so the workout records heart rate.",
                          systemImage: "exclamationmark.circle")
                        .font(.system(.footnote))
                        .foregroundStyle(JohanTheme.textSecondary)
                }
            }
        }
    }

    private func sportChip(_ choice: SportChoice) -> some View {
        let selected = choice.sport == selectedSport
        return Button { selectedSport = choice.sport } label: {
            Label { Text(choice.title).lineLimit(1) } icon: { Image(systemName: sportSymbol(choice.sport)) }
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(selected ? JohanTheme.background : JohanTheme.strainBlue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Capsule().fill(selected ? JohanTheme.strainBlue : JohanTheme.strainBlue.opacity(0.16)))
        }
        .buttonStyle(JohanPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Recording

    /// The strap's heart rate, or the wrist reading of a watch-started workout while the strap is quiet:
    /// the same fallback `AppModel.ingestWatchWorkoutHeartRate` records.
    private var heartRate: Int? { model.bpm ?? model.watchWorkoutBpm }
    private var heartRateFromWatch: Bool { model.bpm == nil && model.watchWorkoutBpm != nil }

    private func activeCard(_ workout: AppModel.ActiveWorkout) -> some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: sportSymbol(workout.sport))
                        .foregroundStyle(JohanTheme.strainBlue)
                        .accessibilityHidden(true)
                    Text(WorkoutSource.displaySport(workout.sport))
                        .font(JohanTheme.Fonts.title)
                    Spacer(minLength: 0)
                    statusCapsule(paused: workout.isPaused)
                }
                if workout.fromWatch {
                    Label("Started on Apple Watch", systemImage: "applewatch")
                        .font(JohanTheme.Fonts.caption)
                        .foregroundStyle(JohanTheme.textSecondary)
                }

                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Self.clock(workout.elapsed()))
                        .johanNumberFont(56, relativeTo: .largeTitle)
                        .foregroundStyle(workout.isPaused ? JohanTheme.textSecondary : JohanTheme.textPrimary)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity)

                JohanAdaptiveStack(spacing: 12) {
                    metric(title: String(localized: "Heart rate"),
                           value: heartRate.map(String.init) ?? "–",
                           unit: heartRateFromWatch ? String(localized: "bpm · Apple Watch") : String(localized: "bpm"),
                           color: JohanTheme.recoveryRed)
                    metric(title: String(localized: "Strain"),
                           value: String(format: "%.1f", UnitFormatter.effortValue(workout.liveStrain, scale: .whoop)),
                           unit: String(localized: "of 21"),
                           color: JohanTheme.strainBlue)
                }

                if heartRate == nil {
                    Label(live.connected ? LocalizedStringKey("Waiting for heart rate from the strap.")
                                         : LocalizedStringKey("Strap not connected. Heart rate isn't being recorded."),
                          systemImage: "heart.slash")
                        .font(.system(.footnote))
                        .foregroundStyle(JohanTheme.textSecondary)
                }

                HStack(spacing: 10) {
                    controlButton(workout.isPaused ? "Resume" : "Pause",
                                  symbol: workout.isPaused ? "play.fill" : "pause.fill",
                                  filled: false) { model.toggleWorkoutPause() }
                    controlButton("End", symbol: "stop.fill", filled: true) {
                        endBlocker = model.activeWorkoutSaveBlocker()
                        confirmEnd = true
                    }
                }
            }
        }
        // Keep the strap's realtime heart rate armed while a recording is on screen, as the Live tab does.
        .modifier(JohanLiveHRDemand())
    }

    private func statusCapsule(paused: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(paused ? JohanTheme.textSecondary : JohanTheme.recoveryRed).frame(width: 7, height: 7)
            paused ? Text("Paused") : Text("Recording")
        }
        .font(.system(.caption, weight: .semibold))
        .foregroundStyle(paused ? JohanTheme.textSecondary : JohanTheme.recoveryRed)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill((paused ? JohanTheme.textSecondary : JohanTheme.recoveryRed).opacity(0.16)))
    }

    private func metric(title: String, value: String, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            JohanOverline(title)
            Text(value)
                .johanNumberFont(34, relativeTo: .title)
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text(unit)
                .font(JohanTheme.Fonts.unit)
                .foregroundStyle(JohanTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func controlButton(_ title: LocalizedStringKey, symbol: String, filled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(.headline))
                .foregroundStyle(filled ? JohanTheme.background : JohanTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(filled ? JohanTheme.recoveryRed : JohanTheme.track))
        }
        .buttonStyle(JohanPressStyle())
    }

    /// Elapsed time as m:ss, or h:mm:ss from the first hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: Recent

    private var recentCard: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 10) {
                JohanOverline(String(localized: "Recent workouts"))
                if !history.loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if history.workouts.isEmpty {
                    Text(String(localized: "No workouts in the last \(String(JohanStrainModel.workoutWindowDays)) days."))
                        .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                } else {
                    ForEach(history.workouts) { w in
                        Button { openWorkout = w } label: { JohanWorkoutRow(workout: w) }
                            .buttonStyle(JohanPressStyle())
                        if w.id != history.workouts.last?.id { Divider().overlay(JohanTheme.cardBorder) }
                    }
                }
            }
        }
    }
}

/// One workout in a JohanUI list: sport icon, name, date with duration and average heart rate, and its
/// Strain on the 0 to 21 scale. Shared by the Strain and Workout pages.
struct JohanWorkoutRow: View {
    let workout: JohanStrainModel.Workout
    @ScaledMetric(relativeTo: .body) private var iconTile: CGFloat = 32

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: sportSymbol(workout.sport))
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(JohanTheme.strainBlue)
                .frame(width: iconTile, height: iconTile)
                .background(RoundedRectangle(cornerRadius: iconTile * 0.27, style: .continuous)
                    .fill(JohanTheme.strainBlue.opacity(0.16)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(WorkoutSource.displaySport(workout.sport)).font(.system(.subheadline, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(workout.strain21.map { String(format: "%.1f", $0) } ?? "–")
                .johanNumberFont(18)
                .foregroundStyle(workout.strain21 != nil ? JohanTheme.strainBlue : JohanTheme.textTertiary)
            Image(systemName: "chevron.right")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(JohanTheme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let date = Date(timeIntervalSince1970: TimeInterval(workout.startTs))
            .formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                .locale(AppLanguage.activeLocale))
        var parts = [date]
        if let d = workout.durationS { parts.append(String(localized: "\(String(Int((d / 60).rounded()))) min")) }
        if let hr = workout.avgHr { parts.append("Ø \(hr) bpm") }
        return parts.joined(separator: " · ")
    }
}
#endif
