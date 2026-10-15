import Foundation

/// Start times of manual workouts that the NOOP watch app started and mirrored to the phone.
///
/// The watch saves its own HKWorkout for such a session, so the phone's "manual" row for the same window
/// must not also be written to Apple Health. The row itself carries nothing that says where it began (the
/// shared `WorkoutRow` has no such column, and its `source` stays "manual" so every other screen treats it
/// like any live session), so the write-back looks its start time up here instead.
///
/// Device-local on purpose: it is not in the `.noopbak` whitelist. A restore onto another phone has no
/// watch session behind these rows, and there the worst case is one extra workout in Health.
enum WatchMirroredWorkouts {
    static let defaultsKey = "watchMirroredWorkoutStarts"

    /// How many start times to keep. Write-back only revisits a recent window, so older entries are dead
    /// weight; this keeps months of daily workouts.
    static let capacity = 400

    static func record(startTs: Int, defaults: UserDefaults = .standard) {
        var starts = defaults.array(forKey: defaultsKey) as? [Int] ?? []
        guard !starts.contains(startTs) else { return }
        starts.append(startTs)
        if starts.count > capacity { starts.removeFirst(starts.count - capacity) }
        defaults.set(starts, forKey: defaultsKey)
    }

    static func startTimes(defaults: UserDefaults = .standard) -> Set<Int> {
        Set(defaults.array(forKey: defaultsKey) as? [Int] ?? [])
    }
}
