#if os(iOS)
import Foundation
import HealthKit
import StrandDesign

/// Receives a workout that the NOOP watch app mirrors to the phone, and keeps the phone's live workout in
/// step with it.
///
/// When the watch starts a workout it calls `startMirroringToCompanionDevice`. HealthKit then hands the
/// mirrored `HKWorkoutSession` to `workoutSessionMirroringStartHandler`, launching NOOP in the background
/// first if it is not running, so the phone knows about the workout from its first second instead of from
/// the saved HKWorkout after it ends. The phone side is the ordinary manual workout (`AppModel.startWorkout`)
/// started at the watch session's own start time: the strap scores it exactly as it scores a workout
/// started on the phone, and a strap offload during the session finds a real row to collapse against
/// once it ends.
///
/// Pause, resume and end travel both ways. A state change from the watch arrives through the session
/// delegate and is applied with `fromWatch: true`, so it is not echoed back; a change made on the phone
/// reaches the watch through `AppModel.onWatchWorkoutControl`.
///
/// Workouts started in Apple's own Workout app are not mirrored to third-party apps and still arrive only
/// through the HealthKit import once they are saved.
@MainActor
final class WatchWorkoutMirror: NSObject {
    private let store = HKHealthStore()
    private weak var model: AppModel?
    private var session: HKWorkoutSession?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Register the mirroring handler. Must run during launch, before it finishes: when HealthKit launches
    /// the app in the background for a mirrored session, it delivers the session to the handler set by then.
    func arm() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        store.workoutSessionMirroringStartHandler = { [weak self] mirrored in
            Task { @MainActor in self?.adopt(mirrored) }
        }
        model?.onWatchWorkoutControl = { [weak self] control in
            self?.send(control)
        }
    }

    private func adopt(_ mirrored: HKWorkoutSession) {
        session = mirrored
        mirrored.delegate = self
        guard let model else { return }
        // The phone workout this session started, rehydrated after iOS killed the app: pick its state back
        // up instead of starting another one.
        if let w = model.activeWorkout, w.fromWatch {
            model.setWorkoutPaused(mirrored.state == .paused, fromWatch: true)
            if mirrored.state == .ended || mirrored.state == .stopped { remoteEnded(mirrored) }
            return
        }
        // A workout already running on the phone keeps going; the watch records its own copy as before.
        guard model.activeWorkout == nil else { return }
        model.startWorkout(sport: HealthKitBridge.sportName(mirrored.workoutConfiguration.activityType),
                           start: mirrored.startDate ?? Date(),
                           fromWatch: true)
        if mirrored.state == .paused { model.setWorkoutPaused(true, fromWatch: true) }
    }

    private func send(_ control: AppModel.WatchWorkoutControl) {
        guard let session else { return }
        switch control {
        case .pause:  session.pause()
        case .resume: session.resume()
        case .end:
            session.end()
            self.session = nil
        case .discard:
            // Tell the watch first, so its stop handler drops the recording instead of saving it. If the
            // message cannot be delivered the session still ends and the watch keeps its copy, as before.
            self.session = nil
            guard let data = try? JSONEncoder().encode(WatchMirrorCommand(discard: true)) else {
                session.end()
                return
            }
            session.sendToRemoteWorkoutSession(data: data) { _, _ in
                Task { @MainActor in session.end() }
            }
        }
    }

    /// The mirrored session finished on the watch. Ends the phone workout only if it is the one this
    /// session started, never a phone workout that was already running when the watch began.
    private func remoteEnded(_ ended: HKWorkoutSession) {
        guard ended === session else { return }
        session = nil
        if model?.activeWorkout?.fromWatch == true { model?.endWorkout(fromWatch: true) }
    }
}

extension WatchWorkoutMirror: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        Task { @MainActor in
            guard workoutSession === self.session,
                  self.model?.activeWorkout?.fromWatch == true else { return }
            switch toState {
            case .paused:           self.model?.setWorkoutPaused(true, fromWatch: true)
            case .running:          self.model?.setWorkoutPaused(false, fromWatch: true)
            case .stopped, .ended:  self.remoteEnded(workoutSession)
            default:                break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        // The phone workout keeps its own clock and strap feed, so it carries on; the wearer ends it
        // from either device. Only the link to the watch is gone.
        Task { @MainActor in
            if workoutSession === self.session { self.session = nil }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        // Batches can queue up while the phone was suspended; only the newest reading is current.
        guard let last = data.last,
              let payload = try? JSONDecoder().decode(WatchMirrorPayload.self, from: last) else { return }
        Task { @MainActor in
            guard workoutSession === self.session else { return }
            self.model?.ingestWatchWorkoutHeartRate(payload.bpm)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didDisconnectFromRemoteDeviceWithError error: Error?) {
        // Same as a failure: the phone workout continues on its own and the watch saves its copy.
        Task { @MainActor in
            if workoutSession === self.session { self.session = nil }
        }
    }
}
#endif
