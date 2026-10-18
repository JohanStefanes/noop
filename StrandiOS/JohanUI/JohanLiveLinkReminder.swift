#if os(iOS)
import Combine
import Foundation
import UserNotifications

/// The bedtime "no live link" reminder: one pending local notification that live heart rate keeps pushing
/// out (`JohanLiveLinkPlan`), so it fires only once heart rate has stopped arriving inside the evening
/// part of the overnight capture window.
///
/// The notification says what the app can see at that moment, that no live heart rate is arriving, and
/// not why: a swiped-away app, a strap on its charger and a strap out of range look the same from here.
/// It only runs while Continuous HRV capture is on, since without it there is no overnight live stream
/// whose absence would mean anything.
@MainActor
final class JohanLiveLinkReminder {
    static let shared = JohanLiveLinkReminder()

    /// On unless switched off in More → Notifications.
    static let enabledKey = "johan.liveLinkReminder.enabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private static let requestId = "johan-live-link"
    /// A pending request closer than this to the newly planned date is left alone, so a heart rate every
    /// second does not rewrite the notification center every second.
    private static let minimumShiftSeconds: TimeInterval = 60

    private var cancellables: Set<AnyCancellable> = []
    private var scheduledFire: Date?

    /// Starts following the strap's live heart rate. Called once from app start.
    func observe(live: LiveState) {
        guard cancellables.isEmpty else { return }
        live.$heartRate
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak live] _ in
                guard let self, live?.connected == true else { return }
                self.reschedule()
            }
            .store(in: &cancellables)
        // Its own switch, Continuous HRV capture and the night window are all stored settings, changed from
        // More or from Settings; re-planning on any change keeps an "off" from leaving a reminder pending.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reschedule() }
            .store(in: &cancellables)
        reschedule()
    }

    /// Re-plans from now, or clears the reminder when it is off. Called on start, on each live heart rate and on each settings change.
    func reschedule(now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        guard Self.isEnabled, PuffinExperiment.keepRealtimeForDataEnabled,
              let fire = JohanLiveLinkPlan.fireDate(now: now,
                                                    nightStartMinutes: ContinuousHrvSchedule.nightWindow().start)
        else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.requestId])
            scheduledFire = nil
            return
        }
        if let scheduledFire, abs(scheduledFire.timeIntervalSince(fire)) < Self.minimumShiftSeconds { return }
        scheduledFire = fire
        // A reminder already on screen is no longer true once the app runs and plans again.
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestId])

        let content = UNMutableNotificationContent()
        content.title = String(localized: "No live heart rate from the strap")
        content.body = String(localized: "Open NOOP so tonight is recorded live. The strap keeps the night either way and hands it over when NOOP connects again.")
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        // Same id: adding replaces the pending request instead of stacking a second one.
        center.add(UNNotificationRequest(identifier: Self.requestId, content: content, trigger: trigger))
    }
}
#endif
