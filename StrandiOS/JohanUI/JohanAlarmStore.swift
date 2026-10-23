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
    /// Oversleep check: this many minutes after the alarm rings, the strap vibrates until the wearer
    /// double-taps it, unless they have double-tapped or opened NOOP by then. nil is off. Optional, so
    /// alarms saved before it existed still decode.
    var oversleepMinutes: Int?

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

/// An alarm rang with the oversleep check on, and the wearer has not confirmed being awake yet.
struct JohanOversleepCheck: Codable, Equatable {
    /// The JohanUI alarm that started it; nil for a Clock app alarm.
    let alarmID: UUID?
    /// When the strap starts vibrating if nobody has confirmed by then.
    let due: Date
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
    @Published private(set) var oversleepCheck: JohanOversleepCheck?
    /// The last scheduling error, for the screen to show; cleared by the next successful change.
    @Published private(set) var problem: String?

    /// How long a snooze lasts, as in the Clock app.
    static let snoozeSeconds: TimeInterval = 9 * 60

    private let manager = AlarmManager.shared
    private static let alarmsKey = "johan.alarms"
    private static let lastRingKey = "johan.alarms.lastRing"
    private static let oversleepKey = "johan.alarms.oversleepCheck"
    /// The choices the editor offers for the oversleep check, in minutes.
    static let oversleepRange = 10...30
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
        if let data = UserDefaults.standard.data(forKey: Self.oversleepKey),
           let check = try? JSONDecoder().decode(JohanOversleepCheck.self, from: data),
           Date().timeIntervalSince(check.due) < Self.maxBuzzSeconds {
            oversleepCheck = check
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

    /// The next instant the strap's firmware alarm should hold: the next alarm with strap vibration, or a
    /// pending oversleep check, whichever is first.
    func nextStrapWake(after now: Date = Date()) -> Date? {
        let ring = alarms.filter(\.vibrateStrap).compactMap { $0.nextRing(after: now) }.min()
        let check = oversleepCheck.map(\.due).flatMap { $0 > now ? $0 : nil }
        return [ring, check].compactMap { $0 }.min()
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
            guard let alarm = alarms.first(where: { $0.id == id }) else { continue }
            if let minutes = alarm.oversleepMinutes, oversleepCheck?.alarmID != id { startOversleepCheck(alarm, minutes: minutes) }
            if alarm.vibrateStrap { buzzStrap(recordRing: true) { [weak self] in self?.isAlerting(id) == true } }
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

    /// How long the strap keeps buzzing for one ring at most, as long as the Clock app's alarm rings.
    static let maxBuzzSeconds: TimeInterval = 15 * 60
    /// True while a buzz loop runs, so a second update doesn't start a second loop.
    private var buzzing = false

    /// Repeat the Alarm Vibration pattern while `keepGoing` holds (the alarm still alerting, or the
    /// oversleep check unanswered), for `maxBuzzSeconds` at most. Holds background time, because the
    /// strap's own alarm event may be the only thing that woke NOOP; past that, each BLE write's reply is
    /// what keeps the process running.
    private func buzzStrap(recordRing: Bool, pauseFirst: Bool = false, while keepGoing: @escaping @MainActor () -> Bool) {
        guard !buzzing else { return }
        buzzing = true
        let application = UIApplication.shared
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = application.beginBackgroundTask(withName: "johan-alarm-buzz") {
            application.endBackgroundTask(taskID)
            taskID = .invalid
        }
        Task {
            let start = Date()
            var sent = false
            var skip = pauseFirst
            repeat {
                if !skip, await AppModel.buzzForAlarmFromShortcut() == .sent { sent = true }
                skip = false
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            } while keepGoing() && Date().timeIntervalSince(start) < Self.maxBuzzSeconds
            buzzing = false
            if recordRing {
                let ring = JohanAlarmRing(date: start, sent: sent)
                lastRing = ring
                if let data = try? JSONEncoder().encode(ring) {
                    UserDefaults.standard.set(data, forKey: Self.lastRingKey)
                }
            }
            if taskID != .invalid {
                application.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
    }

    /// Asked of AlarmKit directly, not of the last update, which a suspended process may never have seen.
    private func isAlerting(_ id: UUID) -> Bool {
        (try? manager.alarms)?.contains { $0.id == id && $0.state == .alerting } ?? false
    }

    /// The strap reported its firmware alarm fired, which wakes NOOP even while suspended. AlarmKit may mark
    /// the matching alarm alerting a moment later, so look for a few seconds and start the buzz loop.
    func strapAlarmFired() async {
        if let check = activeCheck(), Date() >= check.due.addingTimeInterval(-90) {
            AppModel.shared?.live.append(log: "Oversleep check: not confirmed awake, vibrating until a double-tap")
            buzzStrap(recordRing: false) { [weak self] in self?.oversleepCheck == check }
            // Cleared after the loop's cap even unanswered, so a strap left on the nightstand stops.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.maxBuzzSeconds * 1_000_000_000))
                if self?.oversleepCheck == check { self?.setOversleepCheck(nil) }
            }
            return
        }
        for _ in 0..<5 {
            if let scheduled = try? manager.alarms { reconcile(scheduled) }
            if buzzing { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: Clock app alarms

    /// A Clock app alarm is ringing: its "goes off" automation ran and its "stopped" or "snoozed" one has
    /// not yet. iOS shows apps nothing else of those alarms, so these two automations are all NOOP knows.
    private var clockAlarmRinging = false
    private static let clockOversleepKey = "johan.clockAlarm.oversleepMinutes"

    /// The oversleep check after a Clock app alarm, in minutes; nil is off.
    var clockOversleepMinutes: Int? {
        get { UserDefaults.standard.object(forKey: Self.clockOversleepKey) as? Int }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.clockOversleepKey)
        }
    }

    /// "Buzz Strap for Alarm" ran and has played the pattern once (`firstSent`). Keeps buzzing until the
    /// alarm is stopped or snoozed, a double-tap, or `maxBuzzSeconds`, and starts the oversleep check.
    func clockAlarmWentOff(firstSent: Bool) {
        clockAlarmRinging = true
        if let minutes = clockOversleepMinutes, activeCheck() == nil {
            let due = Date().addingTimeInterval(TimeInterval(minutes * 60))
            setOversleepCheck(JohanOversleepCheck(alarmID: nil, due: due))
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            AppModel.shared?.live.append(log: "Oversleep check: double-tap the strap or open NOOP by \(fmt.string(from: due))")
        }
        buzzStrap(recordRing: false, pauseFirst: firstSent) { [weak self] in self?.clockAlarmRinging == true }
    }

    /// "Stop Strap Buzz for Alarm" ran: the Clock alarm was stopped or snoozed. Not proof of being awake,
    /// so the oversleep check stays.
    func clockAlarmStopped() {
        clockAlarmRinging = false
    }

    // MARK: Oversleep check

    /// The alarm started ringing: the check is due `minutes` after its set time, not after whenever NOOP
    /// noticed, so a late wake of the app doesn't push it back.
    private func startOversleepCheck(_ alarm: JohanAlarm, minutes: Int) {
        let now = Date()
        let rang = Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: now)
            .flatMap { $0 <= now ? $0 : nil } ?? now
        setOversleepCheck(JohanOversleepCheck(alarmID: alarm.id, due: rang.addingTimeInterval(TimeInterval(minutes * 60))))
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        AppModel.shared?.live.append(log: "Oversleep check: double-tap the strap or open NOOP by \(fmt.string(from: rang.addingTimeInterval(TimeInterval(minutes * 60))))")
    }

    /// The wearer showed they are awake (`via` says how, for the log). Clears a pending check and stops
    /// its vibration; returns whether there was one, so a double-tap that answered it runs nothing else.
    @discardableResult
    func confirmAwake(via: String) -> Bool {
        // A double-tap while a Clock alarm buzzes means up: the strap stops with it.
        let wasRinging = clockAlarmRinging
        clockAlarmRinging = false
        guard activeCheck() != nil else {
            if oversleepCheck != nil { setOversleepCheck(nil) }
            return wasRinging
        }
        AppModel.shared?.live.append(log: "Oversleep check: awake confirmed by \(via)")
        setOversleepCheck(nil)
        return true
    }

    /// The pending check, unless it lapsed (the strap never reported its alarm, say), so a stale check
    /// can neither swallow tomorrow's double-tap nor start a buzz loop at the next alarm.
    private func activeCheck(now: Date = Date()) -> JohanOversleepCheck? {
        oversleepCheck.flatMap { now.timeIntervalSince($0.due) < Self.maxBuzzSeconds ? $0 : nil }
    }

    private func setOversleepCheck(_ check: JohanOversleepCheck?) {
        oversleepCheck = check
        if let check, let data = try? JSONEncoder().encode(check) {
            UserDefaults.standard.set(data, forKey: Self.oversleepKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.oversleepKey)
        }
        // Moves the strap's firmware alarm to the check, or off it once answered.
        AppModel.shared?.applySmartAlarm()
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
