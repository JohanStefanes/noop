#if os(iOS)
import Foundation
import StrandAnalytics
import WhoopStore

/// Read model behind "Belastung": the recent Effort history and the latest workouts. Today's value is NOT
/// read here; the screen takes it from `JohanHomeModel` (live Effort pass) and splices it into the history,
/// so the dial and today's bar can never show two different numbers.
@MainActor
final class JohanStrainModel: ObservableObject {

    struct Day: Equatable {
        let day: String
        /// Effort on the WHOOP-style 0-21 axis; nil when the day has no stored Effort.
        let strain21: Double?
    }

    struct Workout: Identifiable, Equatable {
        var id: String { "\(startTs)|\(source)" }
        let startTs: Int
        let sport: String
        let source: String
        let durationS: Double?
        let strain21: Double?
        let avgHr: Int?
        let energyKcal: Double?
        /// The stored row, handed to `WorkoutDetailView` unchanged.
        let row: WorkoutRow

        init(row: WorkoutRow) {
            startTs = row.startTs; sport = row.sport; source = row.source; durationS = row.durationS
            strain21 = row.strain.map { UnitFormatter.effortValue($0, scale: .whoop) }
            avgHr = row.avgHr; energyKcal = row.energyKcal; self.row = row
        }
    }

    /// Days in the history chart, today included.
    static let historyDays = 14
    /// Workouts listed on the screen.
    static let recentWorkouts = 5
    /// Window read for the workout list; wide enough that a quiet fortnight still shows something.
    static let workoutWindowDays = 60

    @Published private(set) var history: [Day] = []
    @Published private(set) var workouts: [Workout] = []
    @Published private(set) var loaded = false

    func load(repo: Repository) async {
        let cal = Calendar.current
        let today = Repository.logicalDay(Date())
        let byDay = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        history = (0..<Self.historyDays).reversed().map { back in
            let date = cal.date(byAdding: .day, value: -back, to: today) ?? today
            let key = Repository.localDayKey(date)
            return Day(day: key, strain21: byDay[key]?.strain.map { UnitFormatter.effortValue($0, scale: .whoop) })
        }

        let rows = await repo.workoutRows(days: Self.workoutWindowDays)
        workouts = rows.sorted { $0.startTs > $1.startTs }.prefix(Self.recentWorkouts).map(Workout.init(row:))
        loaded = true
    }

    /// History with today's entry replaced by the live value the dial shows.
    func history(todayLive: Double?) -> [Day] {
        guard let last = history.last else { return [] }
        return history.dropLast() + [Day(day: last.day, strain21: todayLive ?? last.strain21)]
    }

    /// Mean over the last 7 days that carry a value (today's live value included); nil with none.
    static func weekAverage(_ days: [Day]) -> Double? {
        let values = days.suffix(7).compactMap(\.strain21)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
#endif
