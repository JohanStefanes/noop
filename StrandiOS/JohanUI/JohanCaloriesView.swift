#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// "Kalorien": today's calories with their source, the last two weeks and the latest workouts that burned
/// some. Today's value comes from `JohanHomeModel` (the same pass the Home card uses).
struct JohanCaloriesView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.johanReloadTick) private var reloadTick
    @EnvironmentObject private var profile: ProfileStore
    @StateObject private var today = JohanHomeModel()
    @StateObject private var model = JohanCaloriesModel()
    @State private var openWorkout: JohanStrainModel.Workout?

    var body: some View {
        JohanScreen(title: String(localized: "Calories")) {
            if model.loaded {
                let days = model.history(todayLive: today.snapshot.calories)
                todayCard(days: days).johanStagger(0)
                historyCard(days: days).johanStagger(1)
                workoutsCard.johanStagger(2)
            } else {
                JohanPlaceholderCard(height: 150)
                JohanPlaceholderCard(height: 180)
                JohanPlaceholderCard(height: 160)
            }
        }
        .sheet(item: $openWorkout) { w in
            NavigationStack { WorkoutDetailView(row: w.row).environmentObject(repo) }
                .noopSheetPresentation(largeFirst: true)
        }
        .task(id: reloadTick) { await reload() }
        .onReceive(repo.$days.dropFirst()) { _ in Task { await reload() } }
    }

    private func reload() async {
        await model.load(repo: repo)
        await today.load(repo: repo, profile: profile)
    }

    static func kcalText(_ kcal: Double) -> String {
        Int(kcal.rounded()).formatted(.number.locale(AppLanguage.activeLocale))
    }

    /// Which figure the number is, in one sentence. Apple Health counts active energy only; NOOP's own
    /// estimate is the whole day, resting energy included.
    static func sourceText(_ source: JohanCalories.Source) -> String {
        switch source {
        case .appleHealth: String(localized: "Active energy from Apple Health")
        case .heartRate: String(localized: "Estimated from heart rate, resting and active energy")
        }
    }

    // MARK: Today

    private func todayCard(days: [JohanCaloriesModel.Day]) -> some View {
        let reading = today.snapshot.calories
        let avg = JohanCaloriesModel.weekAverage(days)
        let startOfDay = Int(Calendar.current.startOfDay(for: Repository.logicalDay(Date())).timeIntervalSince1970)
        let todayWorkouts = model.workouts.filter { $0.startTs >= startOfDay }
        let workoutKcal = todayWorkouts.compactMap(\.energyKcal).reduce(0, +)
        return JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                JohanOverline(String(localized: "So far today"))
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(reading.map { Self.kcalText($0.kcal) } ?? "–")
                        .johanNumberFont(44)
                        .foregroundStyle(reading == nil ? JohanTheme.textTertiary : JohanTheme.caloriesOrange)
                        .contentTransition(.numericText())
                    if reading != nil {
                        Text("kcal").font(.system(.title3, weight: .semibold)).foregroundStyle(JohanTheme.textSecondary)
                    }
                }
                Text(reading.map { Self.sourceText($0.source) }
                     ?? String(localized: "No calories yet today. Wear the strap or import Apple Health and they show up here."))
                    .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                JohanAdaptiveStack(spacing: 8) {
                    figure(String(localized: "Ø 7 days"), avg.map(Self.kcalText))
                    figure(String(localized: "Workouts today"), todayWorkouts.isEmpty ? nil : Self.kcalText(workoutKcal))
                }
            }
        }
    }

    private func figure(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "–").johanNumberFont(22)
                    .foregroundStyle(value == nil ? JohanTheme.textTertiary : JohanTheme.textPrimary)
                if value != nil {
                    Text("kcal").font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: History

    private func historyCard(days: [JohanCaloriesModel.Day]) -> some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 10) {
                JohanOverline(String(localized: "Last \(String(JohanCaloriesModel.historyDays)) days"))
                if days.contains(where: { $0.reading != nil }) {
                    JohanGrowBars(bars: days.map { .init(dayKey: $0.day, value: $0.reading?.kcal) },
                                  color: JohanTheme.caloriesOrange,
                                  formatValue: { String(localized: "Calories \(Self.kcalText($0))") },
                                  formatAxis: { Self.kcalText($0) })
                        .frame(height: 120)
                    if JohanCaloriesModel.mixesSources(days) {
                        Text("Days from Apple Health count active energy only; the other days are heart-rate estimates that include resting energy.")
                            .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("No calories recorded yet. Wear the strap during the day and your history will show up here.")
                        .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                }
            }
        }
    }

    // MARK: Workouts

    private var workoutsCard: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 10) {
                JohanOverline(String(localized: "Recent workouts"))
                if model.workouts.isEmpty {
                    Text(String(localized: "No workouts with calories in the last \(String(JohanCaloriesModel.workoutWindowDays)) days."))
                        .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                } else {
                    ForEach(model.workouts) { w in
                        Button { openWorkout = w } label: { JohanWorkoutRow(workout: w, figure: .calories) }
                            .buttonStyle(JohanPressStyle())
                        if w.id != model.workouts.last?.id { Divider().overlay(JohanTheme.cardBorder) }
                    }
                }
            }
        }
    }
}
#endif
