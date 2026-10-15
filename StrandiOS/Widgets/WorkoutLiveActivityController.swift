#if os(iOS)
import Foundation
import ActivityKit
import Combine
import UIKit
import StrandDesign

/// Starts, updates and ends the running-workout Live Activity (`WorkoutActivityAttributes`) from
/// `AppModel.activeWorkout`, whichever screen or device started the workout. Follows the live-HR banner's
/// switch, since it takes that banner's place while a workout runs.
///
/// iOS starts a Live Activity only for the app on screen, so a workout started from the watch with NOOP
/// in the background gets its banner the next time NOOP is opened (`appBecameActive`).
@MainActor
final class WorkoutLiveActivityController {
    private var activity: Activity<WorkoutActivityAttributes>?
    private weak var model: AppModel?
    private var cancellables: Set<AnyCancellable> = []
    private var lastState: WorkoutActivityAttributes.ContentState?
    private var lastPush: Date = .distantPast
    private var isStarting = false
    private let authInfo = ActivityAuthorizationInfo()

    /// Heart rate and strain move every second; the banner takes them at most this often.
    static let numbersEvery: TimeInterval = 5
    /// Without a push for this long iOS marks the banner stale.
    static let staleAfter: TimeInterval = 120

    /// The workout banner is on screen, which the live heart rate banner makes room for.
    var isShowing: Bool { activity.map(Self.isShowing) ?? false }

    func follow(_ model: AppModel) {
        self.model = model
        model.$activeWorkout.map { _ in () }
            .merge(with: model.$bpm.map { _ in () }, model.$watchWorkoutBpm.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
    }

    func appBecameActive() { refresh(appActive: true) }

    private func refresh(appActive: Bool? = nil) {
        guard authInfo.areActivitiesEnabled, let model else { return }
        if let current = activity, !Self.isShowing(current) { activity = nil; lastState = nil }
        if activity == nil, let adopted = Activity<WorkoutActivityAttributes>.activities.first(where: Self.isShowing) {
            activity = adopted
        }
        guard UnitPrefs.liveActivityEnabled(), let workout = model.activeWorkout else {
            if activity != nil || !Activity<WorkoutActivityAttributes>.activities.isEmpty { Task { await end() } }
            return
        }
        let now = Date()
        let elapsed = workout.elapsed(at: now)
        let state = WorkoutActivityAttributes.ContentState(
            status: workout.isPaused ? String(localized: "Paused") : String(localized: "Recording"),
            isPaused: workout.isPaused,
            clockStart: workout.isPaused ? nil : now.addingTimeInterval(-elapsed),
            pausedElapsed: elapsed,
            bpm: model.bpm ?? model.watchWorkoutBpm,
            strain: String(format: "%.1f", UnitFormatter.effortValue(workout.liveStrain, scale: .whoop)))
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter))

        if let activity {
            // Pause and resume go out at once; the numbers at most every few seconds.
            let pauseChanged = lastState?.isPaused != state.isPaused
            let numbersChanged = lastState?.bpm != state.bpm || lastState?.strain != state.strain
            let due = now.timeIntervalSince(lastPush) >= Self.numbersEvery
            guard pauseChanged || (numbersChanged && due) || now.timeIntervalSince(lastPush) >= Self.staleAfter / 2
            else { return }
            lastState = state
            lastPush = now
            Task { await activity.update(content) }
        } else {
            let active = appActive ?? (UIApplication.shared.applicationState == .active)
            guard active, !isStarting else { return }
            isStarting = true
            defer { isStarting = false }
            let attributes = WorkoutActivityAttributes(
                sport: WorkoutSource.displaySport(workout.sport),
                symbol: sportSymbol(workout.sport),
                strainWord: String(localized: "Strain"),
                bpmWord: String(localized: "bpm"))
            activity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
            if activity != nil {
                lastState = state
                lastPush = now
            }
        }
    }

    private func end() async {
        for act in Activity<WorkoutActivityAttributes>.activities {
            await act.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        lastState = nil
    }

    private static func isShowing(_ activity: Activity<WorkoutActivityAttributes>) -> Bool {
        switch activity.activityState {
        case .ended, .dismissed: return false
        default: return true
        }
    }
}
#endif
