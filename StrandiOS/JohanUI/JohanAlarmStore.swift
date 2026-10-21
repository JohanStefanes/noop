#if os(iOS)
import Foundation
import SwiftUI
import AlarmKit
import AppIntents
import UserNotifications

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
        parts.second = 0
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
/// iOS does not start the app when an alarm rings, so the strap's own firmware alarm carries the next
/// alarm with strap vibration (`AppModel.applySmartAlarm`) and buzzes without the app. When NOOP is
/// running at that moment, `observe` also plays the saved `AlarmBuzzPattern` as the alarm starts to
/// alert; `lastRing` records what came of that.
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
        if alarm.enabled && morningSummary { Self.requestNotifications() }
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
                                         metadata: JohanAlarmMetadata(label: alarm.label.isEmpty ? nil : alarm.label,
                                                                      alarmWord: String(localized: "Alarm"),
                                                                      snoozingWord: String(localized: "Snoozing"),
                                                                      pausedWord: String(localized: "Paused")),
                                         tintColor: JohanTheme.recoveryYellow)
        let time = Alarm.Schedule.Relative.Time(hour: alarm.hour, minute: alarm.minute)
        let repeats: Alarm.Schedule.Relative.Recurrence = alarm.weekdays.isEmpty
            ? .never
            : .weekly(alarm.weekdays.sorted().compactMap(Self.localeWeekday))
        return AlarmManager.AlarmConfiguration(
            countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: Self.snoozeSeconds),
            schedule: .relative(Alarm.Schedule.Relative(time: time, repeats: repeats)),
            attributes: attributes,
            stopIntent: JohanAlarmStopIntent(alarmID: alarm.id))
    }

    // MARK: Morning summary

    private static let summaryKey = "johan.alarms.morningSummary"
    private static let summaryDayKey = "johan.alarms.morningSummaryDay"

    /// Whether stopping an alarm posts the morning summary. On unless switched off.
    var morningSummary: Bool {
        get { UserDefaults.standard.object(forKey: Self.summaryKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.summaryKey)
            if newValue { Self.requestNotifications() }
        }
    }

    static func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// The wearer stopped an alarm (`JohanAlarmStopIntent`, which iOS runs in this process). Posts the
    /// morning summary, once per day: recovery, last night's sleep and today's strain target, as far as
    /// they are known by now. A night the strap has not synced yet has no recovery, and the summary says
    /// so rather than showing yesterday's.
    func alarmStopped() async {
        guard morningSummary, let model = AppModel.shared else { return }
        let dayKey = Repository.logicalDayKey(Date())
        guard UserDefaults.standard.string(forKey: Self.summaryDayKey) != dayKey else { return }
        await model.repo.refresh()
        let home = JohanHomeModel()
        await home.load(repo: model.repo, profile: model.profile)
        let s = home.snapshot
        let sleepMin = s.isToday ? model.repo.today?.totalSleepMin : nil
        let copy = Self.summaryCopy(recovery: s.recovery, sleepMin: sleepMin, target: s.targetBand)
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.body
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "johan-morning-summary", content: content, trigger: nil))
        UserDefaults.standard.set(dayKey, forKey: Self.summaryDayKey)
    }

    static func summaryCopy(recovery: Double?, sleepMin: Double?, target: ClosedRange<Int>?) -> (title: String, body: String) {
        var parts: [String] = []
        if let recovery {
            let pct = (recovery / 100).formatted(.percent.precision(.fractionLength(0)))
            parts.append(String(localized: "Recovery \(pct)"))
        }
        if let sleepMin, sleepMin > 0 {
            let m = Int(sleepMin.rounded())
            parts.append(String(localized: "Slept \(m / 60) h \(m % 60) min"))
        }
        if let target { parts.append(String(localized: "Strain target \(target.lowerBound)–\(target.upperBound)")) }
        var body = parts.joined(separator: " · ")
        if recovery == nil {
            let note = String(localized: "Recovery appears once the strap has synced the night.")
            body = body.isEmpty ? note : body + "\n" + note
        }
        return (String(localized: "Good morning"), body)
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
        // The strap's firmware alarm carries the next vibrating alarm, so it buzzes while NOOP is suspended.
        AppModel.shared?.applySmartAlarm()
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

/// The Stop button of a JohanUI alarm. iOS runs it in NOOP's process, so stopping an alarm is a moment
/// the app reliably learns about, unlike the ring itself. Stops the alarm, then posts the morning summary.
@available(iOS 26.0, *)
struct JohanAlarmStopIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Alarm"
    static var isDiscoverable = false

    @Parameter(title: "Alarm")
    var alarmID: String

    init() {}

    init(alarmID: UUID) {
        self.alarmID = alarmID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) { try? AlarmManager.shared.stop(id: id) }
        await JohanAlarmStore.shared.alarmStopped()
        return .result()
    }
}
#endif
