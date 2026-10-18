#if os(iOS)
import Foundation
import WhoopStore

/// One day's calorie figure and where it came from. The precedence is the #616 rule the Liquid Today tile
/// uses (`LiquidTodayView.caloriesCount`): the day's imported Apple Health active energy first, else NOOP's
/// on-device heart-rate estimate (`DailyMetric.activeKcalEst`). The two are different quantities (active
/// only vs. resting plus active), so the source travels with the number and the screens name it.
enum JohanCalories {
    enum Source: Equatable {
        case appleHealth
        case heartRate
    }

    struct Reading: Equatable {
        let kcal: Double
        let source: Source
    }

    /// Imported active energy by day: the largest value across that day's Apple Health rows, as Liquid Today reads it.
    static func importedByDay(_ rows: [AppleDaily]) -> [String: Double] {
        var out: [String: Double] = [:]
        for r in rows {
            if let k = r.activeKcal { out[r.day] = max(out[r.day] ?? 0, k) }
        }
        return out
    }

    static func reading(imported: Double?, onDevice: Double?) -> Reading? {
        if let imported { return Reading(kcal: imported, source: .appleHealth) }
        if let onDevice { return Reading(kcal: onDevice, source: .heartRate) }
        return nil
    }
}

/// Read model behind "Kalorien": the recent calorie history and the latest workouts that burned some.
/// Today's value is NOT read here; the screen takes it from `JohanHomeModel` and splices it into the history,
/// so the Home card, the headline and today's bar can never show two different numbers.
@MainActor
final class JohanCaloriesModel: ObservableObject {

    struct Day: Equatable {
        let day: String
        let reading: JohanCalories.Reading?
    }

    /// Days in the history chart, today included.
    static let historyDays = 14
    /// Workouts listed on the screen.
    static let recentWorkouts = 5
    /// Window read for the workout list, the same one the Strain page uses.
    static let workoutWindowDays = JohanStrainModel.workoutWindowDays

    @Published private(set) var history: [Day] = []
    @Published private(set) var workouts: [JohanStrainModel.Workout] = []
    @Published private(set) var loaded = false

    func load(repo: Repository) async {
        let cal = Calendar.current
        let today = Repository.logicalDay(Date())
        let imported = JohanCalories.importedByDay(await repo.appleDailyRows(days: Self.historyDays + 1))
        let byDay = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        history = (0..<Self.historyDays).reversed().map { back in
            let date = cal.date(byAdding: .day, value: -back, to: today) ?? today
            let key = Repository.localDayKey(date)
            return Day(day: key, reading: JohanCalories.reading(imported: imported[key], onDevice: byDay[key]?.activeKcalEst))
        }

        let rows = await repo.workoutRows(days: Self.workoutWindowDays)
        workouts = rows.filter { $0.energyKcal != nil }
            .sorted { $0.startTs > $1.startTs }
            .prefix(Self.recentWorkouts)
            .map(JohanStrainModel.Workout.init(row:))
        loaded = true
    }

    /// History with today's entry replaced by the value the Home card shows.
    func history(todayLive: JohanCalories.Reading?) -> [Day] {
        guard let last = history.last else { return [] }
        return history.dropLast() + [Day(day: last.day, reading: todayLive ?? last.reading)]
    }

    /// Mean over the 7 days before today that carry a value; nil with none. Today is left out because it is
    /// still running, and a half day would pull the average down every morning.
    static func weekAverage(_ days: [Day]) -> Double? {
        let values = days.dropLast().suffix(7).compactMap { $0.reading?.kcal }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// True when the chart holds days from both sources, which measure different things.
    static func mixesSources(_ days: [Day]) -> Bool {
        Set(days.compactMap { $0.reading.map { $0.source == .appleHealth } }).count > 1
    }
}
#endif
