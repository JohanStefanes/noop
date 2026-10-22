#if os(iOS)
import SwiftUI

/// "Alarm Clock": alarms set in the app that ring like the Clock app's (AlarmKit, iOS 26) and can also
/// make the strap vibrate. The Clock app's own alarms stay invisible to every app; the Alarm Vibration
/// screen covers those through a Shortcuts automation.
struct JohanAlarmsView: View {
    var body: some View {
        if #available(iOS 26.0, *) {
            JohanAlarmsList()
        } else {
            JohanScreen(title: String(localized: "Alarm Clock")) {
                JohanCard {
                    Text("Alarms in this app need iOS 26. Until then, use the Clock app with Alarm Vibration so the strap vibrates with it.")
                        .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                }
            }
        }
    }
}

@available(iOS 26.0, *)
private struct JohanAlarmsList: View {
    @ObservedObject private var store = JohanAlarmStore.shared
    @EnvironmentObject private var live: LiveState
    @Environment(\.openURL) private var openURL
    @State private var editing: JohanAlarm?

    var body: some View {
        JohanScreen(title: String(localized: "Alarm Clock")) {
            if store.access == .denied { deniedCard }
            if let problem = store.problem, store.access != .denied {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.recoveryYellow)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                nextCard(now: context.date)
            }
            if store.alarms.isEmpty {
                JohanCard {
                    Text("No alarms yet. Tap + to add one.")
                        .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                }
            } else {
                JohanCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(store.sorted.enumerated()), id: \.element.id) { i, alarm in
                            if i > 0 { Divider().overlay(JohanTheme.cardBorder).padding(.leading, 16) }
                            row(alarm)
                        }
                    }
                }
            }
            summaryCard
            strapCard
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = Self.newAlarm()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("Add Alarm"))
            }
        }
        .sheet(item: $editing) { alarm in
            JohanAlarmEditor(alarm: alarm, isNew: !store.alarms.contains { $0.id == alarm.id })
        }
    }

    /// A new alarm starts at 07:00, the Clock app's default.
    private static func newAlarm() -> JohanAlarm {
        JohanAlarm(hour: 7, minute: 0)
    }

    // MARK: Cards

    private var deniedCard: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Alarms aren't allowed").font(.system(.subheadline, weight: .semibold))
                Text("Allow alarms for this app in Settings, otherwise the alarms below won't ring.")
                    .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(JohanTheme.strainBlue)
            }
        }
    }

    private func nextCard(now: Date) -> some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 6) {
                JohanOverline(String(localized: "Next alarm"))
                if let next = store.next(after: now) {
                    Text(next.date.formatted(date: .omitted, time: .shortened))
                        .johanNumberFont(44, relativeTo: .largeTitle)
                        .foregroundStyle(JohanTheme.textPrimary)
                    Text(Self.countdown(to: next.date, now: now)
                         + (next.alarm.label.isEmpty ? "" : " · " + next.alarm.label))
                        .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                } else {
                    Text("No alarm on").font(JohanTheme.Fonts.title).foregroundStyle(JohanTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The morning summary switch: posted when an alarm is stopped.
    private var summaryCard: some View {
        JohanCard {
            Toggle(isOn: Binding(get: { store.morningSummary }, set: { store.morningSummary = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Morning summary").font(.system(.subheadline, weight: .semibold))
                    Text("When you stop an alarm: recovery, last night's sleep and today's strain target, once a day.")
                        .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
                }
            }
            .tint(JohanTheme.recoveryGreen)
        }
    }

    /// When the strap can vibrate with an alarm, and what it did last time.
    private var strapCard: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Strap vibration", systemImage: "alarm.waves.left.and.right")
                    .font(.system(.subheadline, weight: .semibold))
                Text("The next alarm with strap vibration on is stored on the strap itself, so it vibrates even when the app is closed. When the app is running, your Alarm Vibration pattern then repeats until you stop or snooze the alarm.")
                    .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let ring = store.lastRing {
                    Text(ring.sent
                         ? String(localized: "Last alarm \(ring.date.formatted(.relative(presentation: .named))): vibration sent to the strap.")
                         : String(localized: "Last alarm \(ring.date.formatted(.relative(presentation: .named))): the strap wasn't connected."))
                        .font(JohanTheme.Fonts.caption)
                        .foregroundStyle(ring.sent ? JohanTheme.recoveryGreen : JohanTheme.recoveryYellow)
                }
                if !live.connected {
                    Text("Strap not connected right now.")
                        .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
                }
            }
        }
    }

    // MARK: Rows

    private func row(_ alarm: JohanAlarm) -> some View {
        HStack(spacing: 12) {
            Button { editing = alarm } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.timeText(alarm))
                        .johanNumberFont(34, relativeTo: .title)
                        .foregroundStyle(alarm.enabled ? JohanTheme.textPrimary : JohanTheme.textTertiary)
                    HStack(spacing: 6) {
                        Text([alarm.label.isEmpty ? nil : alarm.label, Self.repeatText(alarm.weekdays)]
                            .compactMap { $0 }.joined(separator: " · "))
                        if alarm.vibrateStrap {
                            Image(systemName: "alarm.waves.left.and.right").accessibilityLabel(Text("Strap vibration"))
                        }
                    }
                    .font(JohanTheme.Fonts.body)
                    .foregroundStyle(alarm.enabled ? JohanTheme.textSecondary : JohanTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("", isOn: Binding(get: { alarm.enabled },
                                     set: { on in Task { await store.setEnabled(on, for: alarm.id) } }))
                .labelsHidden()
                .tint(JohanTheme.recoveryGreen)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contextMenu {
            Button(role: .destructive) { store.delete(alarm.id) } label: {
                Label("Delete Alarm", systemImage: "trash")
            }
        }
    }

    static func timeText(_ alarm: JohanAlarm) -> String {
        var parts = DateComponents()
        parts.hour = alarm.hour
        parts.minute = alarm.minute
        let date = Calendar.current.date(from: parts) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// "Never", "Every day", "Weekdays", "Weekends", or the short day names.
    static func repeatText(_ weekdays: [Int]) -> String {
        let set = Set(weekdays)
        switch set {
        case []: return String(localized: "Never")
        case Set(1...7): return String(localized: "Every day")
        case Set(2...6): return String(localized: "Weekdays")
        case [1, 7]: return String(localized: "Weekends")
        default:
            let symbols = Calendar.current.shortWeekdaySymbols
            return JohanAlarmEditor.dayOrder.filter(set.contains).map { symbols[$0 - 1] }.joined(separator: " ")
        }
    }

    /// "in 6 h 20 min" within a day; past that the weekday, which reads better than "in 79 h".
    private static func countdown(to date: Date, now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes >= 24 * 60 {
            return date.formatted(Date.FormatStyle(locale: AppLanguage.activeLocale).weekday(.wide))
        }
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? String(localized: "in \(h) h \(m) min") : String(localized: "in \(m) min")
    }
}

/// Add or edit one alarm: time, repeat days, label and strap vibration.
@available(iOS 26.0, *)
private struct JohanAlarmEditor: View {
    @State var alarm: JohanAlarm
    let isNew: Bool
    @ObservedObject private var store = JohanAlarmStore.shared
    @Environment(\.dismiss) private var dismiss

    /// Monday first, as a week reads in most of Europe; Calendar weekday numbers.
    static let dayOrder = [2, 3, 4, 5, 6, 7, 1]

    private var time: Binding<Date> {
        Binding(get: {
            var parts = DateComponents()
            parts.hour = alarm.hour
            parts.minute = alarm.minute
            return Calendar.current.date(from: parts) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            alarm.hour = parts.hour ?? 7
            alarm.minute = parts.minute ?? 0
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }
                Section("Repeat") {
                    HStack(spacing: 6) {
                        ForEach(Self.dayOrder, id: \.self) { day in dayChip(day) }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    TextField("Label", text: $alarm.label)
                    Toggle("Strap vibration", isOn: $alarm.vibrateStrap)
                        .tint(JohanTheme.recoveryGreen)
                } footer: {
                    Text("The strap vibrates when the alarm rings, even with the app closed. It needs to have been connected since you set the alarm.")
                }
                if !isNew {
                    Section {
                        Button("Delete Alarm", role: .destructive) {
                            store.delete(alarm.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? String(localized: "Add Alarm") : String(localized: "Edit Alarm"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = alarm
                        saved.enabled = true
                        Task { await store.save(saved) }
                        dismiss()
                    }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    private func dayChip(_ day: Int) -> some View {
        let on = alarm.weekdays.contains(day)
        let symbol = Calendar.current.veryShortWeekdaySymbols[day - 1]
        return Button {
            if on { alarm.weekdays.removeAll { $0 == day } } else { alarm.weekdays.append(day) }
        } label: {
            Text(symbol)
                .font(.system(.subheadline, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(on ? JohanTheme.background : JohanTheme.textPrimary)
                .background(Circle().fill(on ? JohanTheme.recoveryYellow : JohanTheme.track))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Calendar.current.weekdaySymbols[day - 1]))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
#endif
