#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// "Belastung": today's Effort against the recovery-based target band, the last two weeks of Effort and
/// the latest workouts. Today's value comes from `JohanHomeModel` (the same live pass the Home dial uses).
struct JohanStrainView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @StateObject private var today = JohanHomeModel()
    @StateObject private var model = JohanStrainModel()
    @ScaledMetric(relativeTo: .body) private var iconTile: CGFloat = 32
    @State private var openWorkout: JohanStrainModel.Workout?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width - 2 * JohanTheme.Metrics.screenHPadding
            JohanScreen(title: String(localized: "Strain")) {
                todayCard(dialSize: max(120, width * JohanTheme.Metrics.mediumDialWidthFraction * 1.25))
                    .johanStagger(0)
                if model.loaded {
                    historyCard.johanStagger(1)
                    workoutsCard.johanStagger(2)
                } else {
                    JohanPlaceholderCard(height: 180)
                    JohanPlaceholderCard(height: 160)
                }
            }
        }
        .sheet(item: $openWorkout) { w in
            // Same presentation as the original Workouts list (WorkoutsView): own NavigationStack for the
            // Done item, large detent first.
            NavigationStack { WorkoutDetailView(row: w.row).environmentObject(repo) }
                .noopSheetPresentation(largeFirst: true)
        }
        .task { await reload() }
        .onReceive(repo.$days.dropFirst()) { _ in Task { await reload() } }
    }

    private func reload() async {
        await model.load(repo: repo)
        await today.load(repo: repo, profile: profile)
    }

    // MARK: Today

    private func todayCard(dialSize: CGFloat) -> some View {
        let s = today.snapshot
        let color = s.recovery.map(JohanTheme.recoveryColor) ?? JohanTheme.strainBlue
        return JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                JohanOverline(String(localized: "Today"))
                JohanAdaptiveStack(spacing: 16, rowAlignment: .center) {
                    JohanDial(title: String(localized: "Strain"), value: s.strain21, format: { String(format: "%.1f", $0) },
                              unitText: String(localized: "of 21"), fraction: s.strain21.map { $0 / 21 }, color: JohanTheme.strainBlue,
                              replayKey: 0, hapticOnSettle: true, size: dialSize,
                              showsTitle: false)
                    VStack(alignment: .leading, spacing: 6) {
                        if let band = s.targetBand {
                            Text(String(localized: "Target \(String(band.lowerBound))–\(String(band.upperBound))"))
                                .font(.system(.title3, weight: .semibold))
                                .foregroundStyle(color)
                            Text(Self.progressText(current: s.strain21, band: band))
                                .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                        } else {
                            Text("No target yet")
                                .font(.system(.headline))
                            Text("The target follows your recovery and appears once it has been calculated.")
                                .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let band = s.targetBand {
                    JohanTargetBand(band: band, current: s.strain21, color: color)
                }
            }
        }
    }

    /// Where the day's Effort stands against the target range. Shared with the Home strain card so both
    /// screens phrase the same fact the same way; a past day is told in the past tense.
    static func progressText(current: Double?, band: ClosedRange<Int>, isToday: Bool = true) -> String {
        guard let current else { return isToday ? String(localized: "No strain yet today.") : String(localized: "No strain recorded.") }
        if current < Double(band.lowerBound) {
            return isToday
                ? String(localized: "\(String(format: "%.1f", Double(band.lowerBound) - current)) to go to the target range.")
                : String(localized: "Stayed below the target range.")
        }
        if current > Double(band.upperBound) {
            return isToday ? String(localized: "Above the target range, give yourself some rest.") : String(localized: "Was above the target range.")
        }
        return isToday ? String(localized: "In the target range.") : String(localized: "Was in the target range.")
    }

    // MARK: History

    private var historyCard: some View {
        let days = model.history(todayLive: today.snapshot.strain21)
        let avg = JohanStrainModel.weekAverage(days)
        return JohanCard {
            VStack(alignment: .leading, spacing: 10) {
                JohanOverline(String(localized: "Last \(String(JohanStrainModel.historyDays)) days"))
                if days.contains(where: { $0.strain21 != nil }) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(avg.map { String(format: "%.1f", $0) } ?? "–")
                            .johanNumberFont(26).foregroundStyle(JohanTheme.strainBlue)
                        Text("Ø 7 days").font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                        Spacer()
                    }
                    JohanGrowBars(bars: days.map { .init(dayKey: $0.day, value: $0.strain21) },
                                  color: JohanTheme.strainBlue,
                                  formatValue: { String(localized: "Strain \(String(format: "%.1f", $0))") },
                                  formatAxis: { String(format: "%.0f", $0) })
                        .frame(height: 120)
                } else {
                    Text("No strain recorded yet. Wear the strap during the day and your history will show up here.")
                        .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                }
            }
        }
    }

    // MARK: Workouts

    private var workoutsCard: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 10) {
                JohanOverline(String(localized: "Recent workouts"))
                if model.workouts.isEmpty {
                    Text(String(localized: "No workouts in the last \(String(JohanStrainModel.workoutWindowDays)) days."))
                        .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                } else {
                    ForEach(model.workouts) { w in
                        // A sheet, as the original Workouts list presents it: the detail brings its own Done.
                        Button { openWorkout = w } label: { workoutRow(w) }
                            .buttonStyle(JohanPressStyle())
                        if w.id != model.workouts.last?.id { Divider().overlay(JohanTheme.cardBorder) }
                    }
                }
                NavigationLink {
                    WorkoutsView()
                        .background(JohanTheme.background.ignoresSafeArea())
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("All workouts", systemImage: "figure.run")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(JohanTheme.strainBlue)
                }
            }
        }
    }

    private func workoutRow(_ w: JohanStrainModel.Workout) -> some View {
        HStack(spacing: 12) {
            Image(systemName: sportSymbol(w.sport))
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(JohanTheme.strainBlue)
                .frame(width: iconTile, height: iconTile)
                .background(RoundedRectangle(cornerRadius: iconTile * 0.27, style: .continuous)
                    .fill(JohanTheme.strainBlue.opacity(0.16)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(WorkoutSource.displaySport(w.sport)).font(.system(.subheadline, weight: .semibold)).lineLimit(1)
                Text(subtitle(w)).font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(w.strain21.map { String(format: "%.1f", $0) } ?? "–")
                .johanNumberFont(18)
                .foregroundStyle(w.strain21 != nil ? JohanTheme.strainBlue : JohanTheme.textTertiary)
            Image(systemName: "chevron.right")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(JohanTheme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ w: JohanStrainModel.Workout) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(w.startTs))
            .formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                .locale(AppLanguage.activeLocale))
        var parts = [date]
        if let d = w.durationS { parts.append(String(localized: "\(String(Int((d / 60).rounded()))) min")) }
        if let hr = w.avgHr { parts.append("Ø \(hr) bpm") }
        return parts.joined(separator: " · ")
    }
}
#endif
