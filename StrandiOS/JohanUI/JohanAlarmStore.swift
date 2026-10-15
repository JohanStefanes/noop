#if os(iOS)
import Foundation
import SwiftUI
import AlarmKit

/// One alarm set in JohanUI. The list itself lives here; AlarmKit holds only the scheduled copy of each
/// enabled alarm, under the same id, because an `Alarm` read back from AlarmKit carries neither its
/// label nor whether it should vibrate the strap.
struct JohanAlarm: Codable, Identifiable, Equatable {
    var id = UUID()
    var hour: Int
    var minute: Int
    /// `Calendar` weekdays (1 = Sunday … 7 = Saturday) the alarm repeats on. Empty rings once.
    var weekdays: [Int] = []
    var label = ""
    var enabled = true
    /// Also play the Alarm Vibration pattern on the strap when it rings.
    var vibrateStrap = true

    /// The next time it rings after `now`, or nil when it is off.
    func nextRing(after now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard enabled else { return nil }
        var parts = DateComponents()
        parts.hour = hour
        parts.minute = minute
        if weekdays.isEmpty {
            return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime)
        }
        return weekdays.compactMap { day -> Date? in
            var p = parts
            p.weekday = day
            return calendar.nextDate(after: now, matching: p, matchingPolicy: .nextTime)
        }.min()
    }
}

/// What happened on the strap the last time a JohanUI alarm rang.
struct JohanAlarmRing: Codable, Equatable {
    let date: Date
    /// True when the buzz writes went out on a ready link, false when no strap link was ready in time.
    let sent: Bool
}

/// The JohanUI alarm list, kept in step with AlarmKit (iOS 26), so alarms set in the app ring like the
/// Clock app's: on the Lock Screen, in silent mode, with Snooze.
///
/// iOS does not start the app when an alarm rings. The strap buzz therefore plays only when NOOP is
/// running at that moment, in the foreground or kept in the background by the strap link: `observe`
/// watches AlarmKit's updates and plays the saved `AlarmBuzzPattern` when one of these alarms starts to
/// alert. `lastRing` records what came of it, so the screen can say so instead of promising it.
@available(iOS 26.0, *)
@MainActor
final class JohanAlarmStore: ObservableObject {
    static let shared = JohanAlarmStore()

    enum Access: Equatable { case notDetermined, denied, authorized }

    @Published private(set) var alarms: [JohanAlarm] = []
    @Published private(set) var access: Access = .notDetermined
    @Published private(set) var lastRing: JohanAlarmRing?
    /// The last scheduling error, for the screen to show; cleared by the next successful change.
    @Published private(set) var problem: String?

    /// How long a snooze lasts, as in the Clock app.
    static let snoozeSeconds: TimeInterval = 9 * 60

    private let manager = AlarmManager.shared
    private static let alarmsKey = "johan.alarms"
    private static let lastRingKey = "johan.alarms.lastRing"
    /// Alarms seen alerting in the last update, so a strap buzz plays once per ring, not per update.
    private var alerting: Set<UUID> = []
    /// Alarms being scheduled right now, which an update may not list yet and must not switch off.
    private var scheduling: Set<UUID> = []
    private var observing = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.alarmsKey),
           let saved = try? JSONDecoder().decode([JohanAlarm].self, from: data) {
            alarms = saved
        }
        if let data = UserDefaults.standard.data(forKey: Self.lastRingKey) {
            lastRing = try? JSONDecoder().decode(JohanAlarmRing.self, from: data)
        }
        access = Self.access(manager.authorizationState)
    }

    /// Follow AlarmKit from process start. Called once from the app's `init`, so a background launch
    /// (the strap reconnecting) also watches for a ring.
    func observe() {
        guard !observing else { return }
        observing = true
        Task { [weak self] in
            guard let updates = self?.manager.alarmUpdates else { return }
            for await scheduled in updates { self?.reconcile(scheduled) }
        }
        Task { [weak self] in
            guard let updates = self?.manager.authorizationUpdates else { return }
            for await state in updates { self?.access = Self.access(state) }
        }
        if let scheduled = try? manager.alarms { reconcile(scheduled) }
    }

    /// The alarms sorted as the Clock app sorts them: by time of day.
    var sorted: [JohanAlarm] {
        alarms.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    /// The enabled alarm that rings next, with its time.
    func next(after now: Date = Date()) -> (alarm: JohanAlarm, date: Date)? {
        alarms.compactMap { a in a.nextRing(after: now).map { (a, $0) } }.min { $0.1 < $1.1 }
    }

    // MARK: Changes

    /// Add or replace `alarm`, scheduling it when enabled.
    func save(_ alarm: JohanAlarm) async {
        if let i = alarms.firstIndex(where: { $0.id == alarm.id }) { alarms[i] = alarm } else { alarms.append(alarm) }
        persist()
        await sync(alarm)
    }

    func setEnabled(_ enabled: Bool, for id: UUID) async {
        guard var alarm = alarms.first(where: { $0.id == id }) else { return }
        alarm.enabled = enabled
        await save(alarm)
    }

    func delete(_ id: UUID) {
        try? manager.cancel(id: id)
        alarms.removeAll { $0.id == id }
        persist()
    }

    /// Ask for permission once, the first time an alarm is switched on.
    private func ensureAccess() async -> Bool {
        if access == .notDetermined {
            access = Self.access((try? await manager.requestAuthorization()) ?? .denied)
        }
        return access == .authorized
    }

    /// Bring AlarmKit in line with `alarm`: cancel the scheduled copy and, if it is on, schedule it anew.
    private func sync(_ alarm: JohanAlarm) async {
        try? manager.cancel(id: alarm.id)
        guard alarm.enabled else { problem = nil; return }
        guard await ensureAccess() else {
            problem = String(localized: "Alarms aren't allowed. Turn them on for this app in Settings.")
            return
        }
        scheduling.insert(alarm.id)
        defer { scheduling.remove(alarm.id) }
        do {
            _ = try await manager.schedule(id: alarm.id, configuration: configuration(for: alarm))
            problem = nil
        } catch {
            problem = String(localized: "The alarm couldn't be set: \(error.localizedDescription)")
        }
    }

    private func configuration(for alarm: JohanAlarm) -> AlarmManager.AlarmConfiguration<JohanAlarmMetadata> {
        let title: LocalizedStringResource = alarm.label.isEmpty ? "Alarm" : "\(alarm.label)"
        let snooze = AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz")
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: title, secondaryButton: snooze, secondaryButtonBehavior: .countdown)
        } else {
            alert = AlarmPresentation.Alert(title: title,
                                            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"),
                                            secondaryButton: snooze, secondaryButtonBehavior: .countdown)
        }
        let presentation = AlarmPresentation(alert: alert, countdown: AlarmPresentation.Countdown(title: "Snoozing"))
        let attributes = AlarmAttributes(presentation: presentation,
                                         metadata: JohanAlarmMetadata(label: alarm.label.isEmpty ? nil : alarm.label),
                                         tintColor: JohanTheme.recoveryYellow)
        let time = Alarm.Schedule.Relative.Time(hour: alarm.hour, minute: alarm.minute)
        let repeats: Alarm.Schedule.Relative.Recurrence = alarm.weekdays.isEmpty
            ? .never
            : .weekly(alarm.weekdays.sorted().compactMap(Self.localeWeekday))
        return AlarmManager.AlarmConfiguration(
            countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: Self.snoozeSeconds),
            schedule: .relative(Alarm.Schedule.Relative(time: time, repeats: repeats)),
            attributes: attributes)
    }

    // MARK: Updates

    /// Called with AlarmKit's current list. Plays the strap buzz for an alarm that just started alerting,
    /// and switches off a one-time alarm once AlarmKit has dropped it (it rang and was stopped), as the
    /// Clock app does.
    private func reconcile(_ scheduled: [Alarm]) {
        let nowAlerting = Set(scheduled.filter { $0.state == .alerting }.map(\.id))
        for id in nowAlerting.subtracting(alerting) {
            if let alarm = alarms.first(where: { $0.id == id }), alarm.vibrateStrap { buzzStrap() }
        }
        alerting = nowAlerting

        let present = Set(scheduled.map(\.id))
        var changed = false
        for i in alarms.indices where alarms[i].enabled && alarms[i].weekdays.isEmpty
            && !present.contains(alarms[i].id) && !scheduling.contains(alarms[i].id) {
            alarms[i].enabled = false
            changed = true
        }
        if changed { persist() }
    }

    private func buzzStrap() {
        Task {
            let outcome = await AppModel.buzzForAlarmFromShortcut()
            let ring = JohanAlarmRing(date: Date(), sent: outcome == .sent)
            lastRing = ring
            if let data = try? JSONEncoder().encode(ring) {
                UserDefaults.standard.set(data, forKey: Self.lastRingKey)
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(alarms) {
            UserDefaults.standard.set(data, forKey: Self.alarmsKey)
        }
    }

    private static func access(_ state: AlarmManager.AuthorizationState) -> Access {
        switch state {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    private static func localeWeekday(_ calendarWeekday: Int) -> Locale.Weekday? {
        switch calendarWeekday {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        case 7: return .saturday
        default: return nil
        }
    }
}
#endif
