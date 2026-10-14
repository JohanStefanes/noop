#if os(iOS)
import SwiftUI
import StrandDesign

// JohanDayPicker.swift — how Home moves between days: a week strip of dates under the title, a
// month calendar behind the title, and a "Today" pill to come back. Every day is addressed by its offset
// from today (0 = today, 1 = yesterday), the same coordinate `JohanHomeModel.dayOffset` uses, and every
// date goes through `JohanHomeModel.dayDate(offset:)`, so the strip, the calendar and the content cannot
// name different days.

/// Calendar arithmetic over day offsets, anchored on the model's logical "today".
@MainActor
struct JohanDayMath {
    let model: JohanHomeModel
    private var cal: Calendar {
        var c = Calendar.current
        c.locale = AppLanguage.activeLocale
        return c
    }

    var today: Date { model.dayDate(offset: 0) }

    func offset(of date: Date) -> Int {
        cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: today)).day ?? 0
    }

    /// The seven days of the week `weeksBack` weeks before the current one, oldest first.
    func week(_ weeksBack: Int) -> [Date] {
        let start = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = cal.date(byAdding: .day, value: -7 * weeksBack, to: start) ?? start
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: first) }
    }

    func weeksBack(ofOffset offset: Int) -> Int {
        let date = model.dayDate(offset: offset)
        let a = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let b = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        return max(0, (cal.dateComponents([.day], from: a, to: b).day ?? 0) / 7)
    }

    /// First day of the month `monthsBack` months before the current one.
    func monthStart(_ monthsBack: Int) -> Date {
        let start = cal.dateInterval(of: .month, for: today)?.start ?? today
        return cal.date(byAdding: .month, value: -monthsBack, to: start) ?? start
    }

    func monthsBack(ofOffset offset: Int) -> Int {
        let d = model.dayDate(offset: offset)
        let a = cal.dateComponents([.year, .month], from: d)
        let b = cal.dateComponents([.year, .month], from: today)
        return max(0, ((b.year ?? 0) - (a.year ?? 0)) * 12 + (b.month ?? 0) - (a.month ?? 0))
    }

    /// The month's days, preceded by nils for the weekday columns before its first day.
    func monthGrid(_ monthsBack: Int) -> [Date?] {
        let first = monthStart(monthsBack)
        let count = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead)
            + (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: first) }
    }

    /// Weekday initials in the calendar's own order (Monday first where the locale says so).
    var weekdayInitials: [String] {
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(cal.firstWeekday - 1 + $0) % 7] }
    }

    func dayNumber(_ date: Date) -> String {
        date.formatted(.dateTime.day().locale(AppLanguage.activeLocale))
    }
}

// MARK: - Week strip

/// Seven days under the Home title: the date, and a dot in the day's recovery colour. A filled circle
/// glides to the chosen day; swiping the strip pages whole weeks (browsing does not change the day, a tap does). The strip
/// follows the content: a swipe or a calendar pick that leaves the visible week brings that week in.
struct JohanWeekStrip: View {
    @ObservedObject var model: JohanHomeModel
    let maxOffset: Int
    let onSelect: (Int) -> Void

    @State private var page = 0
    @Namespace private var selection
    private let motion = JohanStill()

    var body: some View {
        let math = JohanDayMath(model: model)
        let lastPage = math.weeksBack(ofOffset: maxOffset)
        TabView(selection: $page) {
            ForEach(Array((0...lastPage).reversed()), id: \.self) { weeksBack in
                weekRow(math.week(weeksBack), math: math).tag(weeksBack)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: 66)
        .onAppear { page = math.weeksBack(ofOffset: model.dayOffset) }
        .onChange(of: model.dayOffset) { _, offset in
            let target = math.weeksBack(ofOffset: offset)
            guard target != page else { return }
            if motion.isStill { page = target } else { withAnimation(JohanTheme.Motion.daySlide) { page = target } }
        }
        .onChange(of: page) { _, _ in StrandHaptic.selection.play() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Days"))
    }

    private func weekRow(_ days: [Date], math: JohanDayMath) -> some View {
        HStack(spacing: 4) {
            ForEach(days, id: \.self) { date in
                cell(date, offset: math.offset(of: date), math: math)
            }
        }
        .padding(.horizontal, 2)
    }

    private func cell(_ date: Date, offset: Int, math: JohanDayMath) -> some View {
        let selected = offset == model.dayOffset
        let isToday = offset == 0
        let available = offset >= 0 && offset <= maxOffset
        let rings = model.rings(for: model.dayKey(offset: offset))
        return Button {
            guard available, !selected else { return }
            onSelect(offset)
        } label: {
            VStack(spacing: 6) {
                Text(date.formatted(.dateTime.weekday(.narrow).locale(AppLanguage.activeLocale)))
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(JohanTheme.textTertiary)
                Text(math.dayNumber(date))
                    .font(.system(.callout, design: .rounded, weight: selected || isToday ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(selected ? JohanTheme.background
                                     : available ? JohanTheme.textPrimary : JohanTheme.textTertiary.opacity(0.6))
                    .frame(width: 34, height: 34)
                    .background {
                        if selected {
                            Circle().fill(JohanTheme.textPrimary)
                                .matchedGeometryEffect(id: "pill", in: selection)
                        } else if isToday {
                            Circle().strokeBorder(JohanTheme.textTertiary, lineWidth: 1)
                        }
                    }
                // One signal per day: the recovery zone, nothing where there is no score.
                Circle()
                    .fill(available ? rings.recovery.map { JohanTheme.RecoveryZone($0).color } ?? .clear : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(JohanPressStyle())
        .disabled(!available)
        .accessibilityLabel(Text(Self.accessibilityText(date, rings: rings, isToday: isToday)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func accessibilityText(_ date: Date, rings: JohanHomeModel.DayRings, isToday: Bool) -> String {
        var parts = [date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.activeLocale))]
        if isToday { parts.insert(String(localized: "Today"), at: 0) }
        if let r = rings.recovery { parts.append(String(localized: "Recovery \(Int(r.rounded())) %")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Month calendar

/// Month sheet behind the Home title: every day as a recovery ring around its date, months paged by swipe
/// or the chevrons, a summary of the month's recovery zones underneath. Picking a day jumps Home to it.
struct JohanMonthCalendar: View {
    @ObservedObject var model: JohanHomeModel
    let maxOffset: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        let math = JohanDayMath(model: model)
        let lastPage = math.monthsBack(ofOffset: maxOffset)
        VStack(spacing: 18) {
            header(math: math, lastPage: lastPage)
            HStack(spacing: 0) {
                ForEach(Array(math.weekdayInitials.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(JohanTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            TabView(selection: $page) {
                ForEach(Array((0...lastPage).reversed()), id: \.self) { monthsBack in
                    VStack(spacing: 16) {
                        grid(math.monthGrid(monthsBack), math: math)
                        summary(math.monthGrid(monthsBack).compactMap { $0 }, math: math)
                        Spacer(minLength: 0)
                    }
                    .tag(monthsBack)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .padding(.horizontal, JohanTheme.Metrics.screenHPadding)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .background(JohanTheme.background.ignoresSafeArea())
        .presentationDetents([.height(560), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(JohanTheme.background)
        .presentationCornerRadius(32)
        .preferredColorScheme(.dark)
        .onAppear { page = math.monthsBack(ofOffset: model.dayOffset) }
        .onChange(of: page) { _, _ in StrandHaptic.selection.play() }
    }

    private func header(math: JohanDayMath, lastPage: Int) -> some View {
        HStack(spacing: 4) {
            Text(math.monthStart(page).formatted(.dateTime.month(.wide).year().locale(AppLanguage.activeLocale)))
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(JohanTheme.textPrimary)
                .contentTransition(.numericText(value: Double(-page)))
                .animation(.snappy, value: page)
            Spacer()
            pageButton("chevron.left", enabled: page < lastPage) { page += 1 }
                .accessibilityLabel(Text("Previous month"))
            pageButton("chevron.right", enabled: page > 0) { page -= 1 }
                .accessibilityLabel(Text("Next month"))
        }
    }

    private func pageButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(JohanTheme.Motion.daySlide) { action() } } label: {
            Image(systemName: icon)
                .font(.system(.subheadline, weight: .bold))
                .frame(width: 38, height: 38)
                .background(Circle().fill(JohanTheme.card))
        }
        .buttonStyle(JohanPressStyle())
        .foregroundStyle(enabled ? JohanTheme.textPrimary : JohanTheme.textTertiary)
        .disabled(!enabled)
    }

    private func grid(_ days: [Date?], math: JohanDayMath) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8) {
            ForEach(days.indices, id: \.self) { i in
                if let date = days[i] {
                    dayCell(date, offset: math.offset(of: date), math: math)
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
    }

    private func dayCell(_ date: Date, offset: Int, math: JohanDayMath) -> some View {
        let available = offset >= 0 && offset <= maxOffset
        let selected = offset == model.dayOffset
        let isToday = offset == 0
        let rings = model.rings(for: model.dayKey(offset: offset))
        let zone = rings.recovery.map(JohanTheme.RecoveryZone.init)
        return Button {
            onSelect(offset)
            dismiss()
        } label: {
            ZStack {
                if selected {
                    Circle().fill(JohanTheme.textPrimary).padding(5)
                }
                if available, let rec = rings.recovery, let zone {
                    Circle().stroke(zone.color.opacity(0.2), lineWidth: 3)
                    Circle().trim(from: 0, to: rec / 100)
                        .stroke(zone.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else if available {
                    Circle().stroke(JohanTheme.track, lineWidth: 3)
                }
                Text(math.dayNumber(date))
                    .font(.system(.subheadline, design: .rounded, weight: selected || isToday ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(selected ? JohanTheme.background
                                     : available ? JohanTheme.textPrimary : JohanTheme.textTertiary.opacity(0.6))
                if isToday && !selected {
                    Circle().fill(JohanTheme.textPrimary).frame(width: 4, height: 4).offset(y: 13)
                }
            }
            .padding(3)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(JohanPressStyle())
        .disabled(!available)
        .accessibilityLabel(Text(JohanWeekStrip.accessibilityText(date, rings: rings, isToday: isToday)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The month in recovery terms: the average and how many days fell in each zone.
    private func summary(_ days: [Date], math: JohanDayMath) -> some View {
        let values = days.compactMap { date -> Double? in
            let offset = math.offset(of: date)
            guard offset >= 0, offset <= maxOffset else { return nil }
            return model.rings(for: model.dayKey(offset: offset)).recovery
        }
        let zones = values.map(JohanTheme.RecoveryZone.init)
        return JohanCard(padding: 14) {
            if values.isEmpty {
                Text("No recovery scores this month")
                    .font(JohanTheme.Fonts.body)
                    .foregroundStyle(JohanTheme.textSecondary)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Avg recovery").font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
                        let avg = values.reduce(0, +) / Double(values.count)
                        Text("\(Int(avg.rounded())) %")
                            .font(JohanTheme.number(26))
                            .foregroundStyle(JohanTheme.RecoveryZone(avg).color)
                    }
                    Spacer(minLength: 4)
                    ForEach([JohanTheme.RecoveryZone.high, .medium, .low], id: \.self) { z in
                        VStack(spacing: 3) {
                            Text("\(zones.filter { $0 == z }.count)")
                                .font(JohanTheme.number(20))
                                .foregroundStyle(JohanTheme.textPrimary)
                            Capsule().fill(z.color).frame(width: 18, height: 4)
                        }
                        .frame(minWidth: 34)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
#endif
