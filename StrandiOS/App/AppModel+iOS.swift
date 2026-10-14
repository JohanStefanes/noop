#if os(iOS)
import Foundation
import UIKit

/// What the "Sync Strap" shortcut observed when it asked for a sync. Each case names only what was seen.
enum StrapSyncShortcutOutcome {
    /// `syncNow` ran and a sync session is now in progress.
    case started
    /// A sync was already running when the shortcut arrived, so nothing new was requested.
    case alreadyRunning
    /// The link was not ready within the wait (NOOP was launched in the background by the shortcut and is
    /// still connecting). The request is parked and the connect handshake runs it once the link can serve.
    case willSyncWhenConnected
    /// No app model at all, so there was nowhere to park the request.
    case strapNotReady
    /// The link was ready and `syncNow` ran, but no session started. The strap log says why.
    case notStarted
}

/// What the "Buzz Strap for Alarm" shortcut observed. Each case names only what was seen.
enum AlarmBuzzShortcutOutcome {
    /// The link was ready and the buzz writes were sent.
    case sent
    /// No ready strap link within the wait, so nothing was sent.
    case strapNotConnected
}

extension AppModel {
    /// Background entry point for the "Buzz Strap for Alarm" shortcut. Waits up to `waitSeconds` for a ready
    /// link (connected and past the handshake, the same readiness the Sync Strap shortcut waits for), then
    /// plays `pattern` (the user's saved `AlarmBuzzPattern` unless one is passed, as the preview does): one
    /// `buzzBurst` per burst, `gapSeconds` apart. The intent awaits this, which keeps the background-launched
    /// process alive for the whole pattern.
    @MainActor
    static func buzzForAlarmFromShortcut(waitSeconds: Int = 10,
                                         pattern: AlarmBuzzPattern = .saved) async -> AlarmBuzzShortcutOutcome {
        let p = pattern.clamped
        func ready(_ m: AppModel?) -> Bool { m.map { $0.live.connected && $0.live.historyReady } ?? false }
        for _ in 0..<waitSeconds where !ready(shared) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let model = shared, ready(model) else {
            shared?.live.append(log: "Alarm buzz shortcut: strap link not ready within \(waitSeconds) s, nothing sent")
            return .strapNotConnected
        }
        model.live.append(log: "Alarm buzz shortcut: \(p.bursts) bursts of \(p.pulses), \(p.gapSeconds) s apart"
                          + (p.strapAlarmSignal ? ", with alarm signal" : ""))
        for i in 0..<p.bursts {
            model.ble.buzzBurst(pulses: p.pulses, strapAlarmSignal: p.strapAlarmSignal)
            if i < p.bursts - 1 { try? await Task.sleep(nanoseconds: UInt64(p.gapSeconds * 1_000_000_000)) }
        }
        return .sent
    }

    /// Execute any actions queued by App Intents while the app was suspended (mark moment, buzz,
    /// ask coach). Call when the app becomes active. The optional `router` lets the ask-coach
    /// intent navigate to the Coach tab after sending the question.
    func drainPendingIntents(router: NavRouter? = nil) {
        for item in PendingIntents.drain() {
            switch item.action {
            case .markMoment: markMoment(at: item.date ?? Date())
            // #921: the "Buzz Strap" Siri shortcut logged its write but a WHOOP 4.0 never vibrated.
            // The one-shot routine sends the confirmed pattern + RUN_ALARM sequence, acked, so a
            // busy just-foregrounded BLE link can't silently drop it.
            case .buzz:       buzzStrapOnce()
            // K9: "Ask Coach" via Siri — send the queued question to the Coach engine and navigate
            // to the Coach tab so the user sees the response. The question is consumed from a
            // dedicated key (one at a time).
            case .askCoach:
                if let question = PendingIntents.consumeCoachQuestion() {
                    router?.openCoach()
                    Task { @MainActor in
                        await coach.send(question)
                    }
                }
            }
        }
    }

    /// Background entry point for the "Sync Strap" shortcut. When iOS launches NOOP in the background to run
    /// the intent, the strap link is still coming up: NOOP auto-connects to the remembered strap on launch,
    /// but a connect + bond + handshake takes longer than an App Intent can wait, and `BLEManager.syncNow`
    /// declines until it has run (`LiveState.historyReady`). So: wait briefly for a link that is already up
    /// (the app-in-background case, where the reply can say the sync started), otherwise park the request
    /// with `armPendingManualSync` so the connect handshake runs it the moment the link can serve.
    static func startStrapSyncFromShortcut(waitSeconds: Int = 8) async -> StrapSyncShortcutOutcome {
        // The Dynamic Island readout goes up first, from here, because only a LiveActivityIntent may start
        // one from the background; the controller carries it through the sync from there.
        var islandStarted = false
        if let model = shared {
            SyncLiveActivityController.shared.startFromShortcut(live: model.live)
            islandStarted = true
        }
        for _ in 0..<waitSeconds {
            // A cold launch can hand the intent its first tick before the model exists; start the island
            // on the first tick that has one rather than never.
            if !islandStarted, let model = shared {
                SyncLiveActivityController.shared.startFromShortcut(live: model.live)
                islandStarted = true
            }
            if let model = shared, model.live.historyReady { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let model = shared else {
            SyncLiveActivityController.shared.shortcutDidNotStart()
            return .strapNotReady
        }
        guard model.live.historyReady else {
            model.ble.armPendingManualSync()
            holdProcessAliveForPendingSync()
            return .willSyncWhenConnected
        }
        if model.live.backfilling { return .alreadyRunning }
        model.ble.syncNow()
        if model.live.backfilling { return .started }
        SyncLiveActivityController.shared.shortcutDidNotStart()
        return .notStarted
    }

    /// Once the intent has replied, nothing keeps the background-launched process running, and iOS may suspend
    /// it before the strap has even answered the connect. Hold a background-time assertion until the link is
    /// ready (the parked request then fires on its own) or `maxSeconds` pass, whichever is first. Ended on every
    /// path, including the expiry handler, so the assertion never just runs out. Same idiom as the scene
    /// delegate's standard-HR flush. If the handshake needs longer than this, CoreBluetooth's own wakes on each
    /// BLE callback and state restoration take over; the parked request is persisted for exactly that case.
    private static func holdProcessAliveForPendingSync(maxSeconds: Int = 25) {
        let application = UIApplication.shared
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = application.beginBackgroundTask(withName: "sync-strap-shortcut-connect") {
            application.endBackgroundTask(taskID)
            taskID = .invalid
        }
        Task { @MainActor in
            for _ in 0..<maxSeconds {
                if taskID == .invalid { return }
                if let model = shared, model.live.historyReady || model.live.backfilling { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if taskID != .invalid {
                application.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
    }
}
#endif
