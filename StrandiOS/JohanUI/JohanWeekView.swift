#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// One Monday-to-Sunday week from the stored daily rows: the averages beside the week before, and the
/// best and worst day by recovery. Days come from `Repository.days` as they are; nothing is re-scored.
struct JohanWeekReview: Equatable, Identifiable {
    var id: String { weekStart }
    struct Day: Equatable {
        let key: String
        let recovery: Double?
        let sleepMin: Double?
        /// 0-21.
        let strain21: Double?
    }

    struct Averages: Equatable {
        var recovery: Double?
        var sleepMin: Double?
        var strain21: Double?
        var hrv: Double?
        var restingHR: Double?
    }

    let weekStart: String
    /// Mon...Sun, always seven entries; a day without a row has nil values.
    let days: [Day]
    let averages: Averages
    let previous: Averages

    var best: Day? { ranked.first }
    var worst: Day? { ranked.count >= 2 ? ranked.last : nil }
    /// Days that have a recovery, best first.
    private var ranked: [Day] {
        days.filter { $0.recovery != nil }.sorted { ($0.recovery ?? 0) > ($1.recovery ?? 0) }
    }

    static func build(rows: [DailyMetric], weekStart: String) -> JohanWeekReview {
        let byDay = Dictionary(rows.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        let keys = (0..<7).map { WeeklyDigestEngine.addDays(weekStart, $0) }
        let prevKeys = (0..<7).map { WeeklyDigestEngine.addDays(weekStart, $0 - 7) }
        let days = keys.map { key -> Day in
            let r = byDay[key]
            return Day(key: key, recovery: r?.recovery, sleepMin: r?.totalSleepMin,
                       strain21: r?.strain.map { UnitFormatter.effortValue($0, scale: .whoop) })
        }
        return JohanWeekReview(weekStart: weekStart, days: days,
                               averages: averages(keys.compactMap { byDay[$0] }),
                               previous: averages(prevKeys.compactMap { byDay[$0] }))
    }

    private static func averages(_ rows: [DailyMetric]) -> Averages {
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        return Averages(recovery: mean(rows.compactMap(\.recovery)),
                        sleepMin: mean(rows.compactMap(\.totalSleepMin).filter { $0 > 0 }),
                        strain21: mean(rows.compactMap(\.strain).map { UnitFormatter.effortValue($0, scale: .whoop) }),
                        hrv: mean(rows.compactMap(\.avgHrv)),
                        restingHR: mean(rows.compactMap(\.restingHr).map(Double.init)))
    }
}

/// "Weekly Review": the week, with arrows to step back through earlier weeks.
struct JohanWeekView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.johanReloadTick) private var reloadTick
    /// 0 = this week, 1 = last week, ...
    @State private var weeksBack = 0
    @State private var review: JohanWeekReview?
    @State private var playing: JohanWeekReview?

    private var weekStart: String {
        let today = Repository.logicalDayKey(Date())
        let monday = WeeklyDigestEngine.mondayOfWeek(containing: today) ?? today
        return WeeklyDigestEngine.addDays(monday, -7 * weeksBack)
    }

    var body: some View {
        JohanScreen(title: String(localized: "Weekly Review")) {
            navigator
            if let review {
                if review.days.allSatisfy({ $0.recovery == nil && $0.sleepMin == nil && $0.strain21 == nil }) {
                    JohanCard {
                        Text("No data for this week.")
                            .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                    }
                } else {
                    JohanWeekStoryCover(review: review, weekTitle: weekTitle) { playing = review }
                    averagesCard(review)
                    recoveryBars(review)
                    if let best = review.best { dayCard(String(localized: "Best day"), best) }
                    if let worst = review.worst { dayCard(String(localized: "Toughest day"), worst) }
                }
            } else {
                JohanPlaceholderCard(height: 200)
            }
        }
        .task(id: "\(weeksBack)|\(reloadTick)") { review = JohanWeekReview.build(rows: repo.days, weekStart: weekStart) }
        .onReceive(repo.$days.dropFirst()) { rows in review = JohanWeekReview.build(rows: rows, weekStart: weekStart) }
        .fullScreenCover(item: $playing) { JohanWeekStoryView(review: $0, weekTitle: weekTitle) }
    }

    private var weekTitle: String {
        weeksBack == 0 ? String(localized: "This week")
            : weeksBack == 1 ? String(localized: "Last week")
                             : String(localized: "\(weeksBack) weeks ago")
    }

    // MARK: Parts

    private var navigator: some View {
        HStack {
            Button { weeksBack += 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel(Text("Previous week"))
            Spacer()
            VStack(spacing: 2) {
                Text(weekTitle)
                    .font(JohanTheme.Fonts.title)
                Text(Self.range(weekStart)).font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
            }
            Spacer()
            Button { weeksBack -= 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(weeksBack == 0)
                .opacity(weeksBack == 0 ? 0.3 : 1)
                .accessibilityLabel(Text("Next week"))
        }
        .foregroundStyle(JohanTheme.textPrimary)
    }

    private func averagesCard(_ r: JohanWeekReview) -> some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                JohanOverline(String(localized: "Average vs the week before"))
                avgRow(String(localized: "Recovery"), r.averages.recovery, r.previous.recovery, higherIsBetter: true,
                       format: { "\(Int($0.rounded())) %" }, deltaFormat: { "\(Int($0.rounded()))" })
                avgRow(String(localized: "Sleep"), r.averages.sleepMin, r.previous.sleepMin, higherIsBetter: true,
                       format: Self.hours, deltaFormat: { "\(Int($0.rounded())) min" })
                avgRow(String(localized: "Strain"), r.averages.strain21, r.previous.strain21, higherIsBetter: nil,
                       format: { String(format: "%.1f", $0) }, deltaFormat: { String(format: "%.1f", $0) })
                avgRow(String(localized: "HRV"), r.averages.hrv, r.previous.hrv, higherIsBetter: true,
                       format: { "\(Int($0.rounded())) ms" }, deltaFormat: { "\(Int($0.rounded()))" })
                avgRow(String(localized: "Resting HR"), r.averages.restingHR, r.previous.restingHR, higherIsBetter: false,
                       format: { "\(Int($0.rounded())) bpm" }, deltaFormat: { "\(Int($0.rounded()))" })
            }
        }
    }

    /// One average with its change from the week before. `higherIsBetter` nil colours the change neutrally
    /// (more strain is neither good nor bad on its own).
    private func avgRow(_ title: String, _ value: Double?, _ previous: Double?, higherIsBetter: Bool?,
                        format: (Double) -> String, deltaFormat: (Double) -> String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(.subheadline)).foregroundStyle(JohanTheme.textSecondary)
            Spacer()
            Text(value.map(format) ?? "–").johanNumberFont(17).foregroundStyle(JohanTheme.textPrimary)
            Group {
                if let value, let previous, abs(value - previous) >= 0.05 {
                    let up = value > previous
                    let good = higherIsBetter.map { $0 == up }
                    Label(deltaFormat(abs(value - previous)), systemImage: up ? "arrow.up" : "arrow.down")
                        .foregroundStyle(good == nil ? JohanTheme.textSecondary
                                         : good! ? JohanTheme.recoveryGreen : JohanTheme.recoveryRed)
                } else {
                    Text(" ")
                }
            }
            .font(JohanTheme.Fonts.caption)
            .frame(width: 76, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func recoveryBars(_ r: JohanWeekReview) -> some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 10) {
                JohanOverline(String(localized: "Recovery by day"))
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(r.days, id: \.key) { day in
                        VStack(spacing: 6) {
                            Text(day.recovery.map { "\(Int($0.rounded()))" } ?? "–")
                                .font(JohanTheme.Fonts.unit).foregroundStyle(JohanTheme.textSecondary)
                            Capsule()
                                .fill(day.recovery.map(JohanTheme.recoveryColor) ?? JohanTheme.track)
                                .frame(width: 14, height: max(6, 110 * (day.recovery ?? 0) / 100))
                            Text(Self.weekday(day.key, short: true))
                                .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 150, alignment: .bottom)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(r.days.map { "\(Self.weekday($0.key, short: false)) \($0.recovery.map { "\(Int($0.rounded())) %" } ?? "–")" }
            .joined(separator: ", ")))
    }

    private func dayCard(_ title: String, _ day: JohanWeekReview.Day) -> some View {
        JohanCard {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    JohanOverline(title)
                    Text(Self.weekday(day.key, short: false)).font(JohanTheme.Fonts.title)
                }
                Spacer()
                stat(day.recovery.map { "\(Int($0.rounded())) %" } ?? "–", String(localized: "Recovery"),
                     day.recovery.map(JohanTheme.recoveryColor) ?? JohanTheme.textPrimary)
                stat(day.sleepMin.map(Self.hours) ?? "–", String(localized: "Sleep"), JohanTheme.textPrimary)
                stat(day.strain21.map { String(format: "%.1f", $0) } ?? "–", String(localized: "Strain"), JohanTheme.strainBlue)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).johanNumberFont(17).foregroundStyle(color)
            Text(label).font(JohanTheme.Fonts.unit).foregroundStyle(JohanTheme.textSecondary)
        }
    }

    // MARK: Formatting

    static func hours(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }

    private static func date(_ key: String) -> Date? {
        guard let (y, m, d) = WeeklyDigestEngine.parseYMD(key) else { return nil }
        return Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))
    }

    static func weekday(_ key: String, short: Bool) -> String {
        guard let date = date(key) else { return key }
        let style = Date.FormatStyle(locale: AppLanguage.activeLocale)
        return date.formatted(short ? style.weekday(.abbreviated) : style.weekday(.wide))
    }

    static func range(_ start: String) -> String {
        guard let a = date(start), let b = date(WeeklyDigestEngine.addDays(start, 6)) else { return start }
        let style = Date.FormatStyle(locale: AppLanguage.activeLocale).day().month(.abbreviated)
        return a.formatted(style) + " – " + b.formatted(style)
    }
}
#endif
