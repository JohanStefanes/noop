#if os(iOS)
import SwiftUI
import StrandDesign
import WhoopStore

/// The card the Workout tab shows right after a workout is saved (`AppModel.lastWorkout`): time, heart
/// rate, calories, the time in each heart-rate zone and the strain, beside the day's strain so far.
///
/// Strain does not add up (the scale is logarithmic), so the card shows the workout's own strain and the
/// day's total after it, and does not claim a share of one in the other.
struct JohanWorkoutSummaryCard: View {
    let row: WorkoutRow
    var onDetails: () -> Void
    var onDone: () -> Void

    @EnvironmentObject private var repo: Repository
    @StateObject private var profile = ProfileStore()
    @StateObject private var home = JohanHomeModel()
    @State private var zoneMinutes: [Double]?

    var body: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: sportSymbol(row.sport))
                        .foregroundStyle(JohanTheme.strainBlue)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(WorkoutSource.displaySport(row.sport)).font(JohanTheme.Fonts.title)
                        Text(Self.window(row)).font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(JohanTheme.recoveryGreen)
                }

                JohanAdaptiveStack(spacing: 12) {
                    stat(String(localized: "Time"), Self.duration(row.durationS ?? Double(row.endTs - row.startTs)), nil)
                    stat(String(localized: "Avg HR"), row.avgHr.map(String.init) ?? "–", String(localized: "bpm"))
                    stat(String(localized: "Peak HR"), row.maxHr.map(String.init) ?? "–", String(localized: "bpm"))
                    stat(String(localized: "Calories"), row.energyKcal.map { "\(Int($0.rounded()))" } ?? "–", String(localized: "kcal"))
                }

                strainRow

                if let z = zoneMinutes, z.reduce(0, +) > 0 { zones(z) }

                HStack(spacing: 10) {
                    Button(action: onDetails) {
                        Text("Details").frame(maxWidth: .infinity, minHeight: 40)
                            .background(Capsule().fill(JohanTheme.strainBlue.opacity(0.16)))
                            .foregroundStyle(JohanTheme.strainBlue)
                    }
                    Button(action: onDone) {
                        Text("Done").frame(maxWidth: .infinity, minHeight: 40)
                            .background(Capsule().fill(JohanTheme.strainBlue))
                            .foregroundStyle(JohanTheme.background)
                    }
                }
                .font(.system(.subheadline, weight: .semibold))
                .buttonStyle(JohanPressStyle())
            }
        }
        .task(id: row.startTs) {
            zoneMinutes = await repo.workoutZoneMinutes(from: row.startTs, to: row.endTs,
                                                        zoneSet: profile.hrZoneSet, source: row.source)
            await home.load(repo: repo, profile: profile)
        }
        // The day's strain catches up once the saved workout is analysed.
        .onReceive(repo.$days.dropFirst()) { _ in Task { await home.load(repo: repo, profile: profile) } }
    }

    private var strainRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                JohanOverline(String(localized: "Workout strain"))
                Text(row.strain.map { String(format: "%.1f", UnitFormatter.effortValue($0, scale: .whoop)) } ?? "–")
                    .johanNumberFont(34, relativeTo: .title)
                    .foregroundStyle(JohanTheme.strainBlue)
            }
            VStack(alignment: .leading, spacing: 2) {
                JohanOverline(String(localized: "Day strain now"))
                Text(home.snapshot.isToday ? home.snapshot.strain21.map { String(format: "%.1f", $0) } ?? "–" : "–")
                    .johanNumberFont(34, relativeTo: .title)
                    .foregroundStyle(JohanTheme.textPrimary)
                if let band = home.snapshot.targetBand {
                    Text(String(localized: "Target \(band.lowerBound)–\(band.upperBound)"))
                        .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Minutes in zones 1-5, as a stacked bar with the minutes under each zone.
    private func zones(_ z: [Double]) -> some View {
        let total = max(z.reduce(0, +), 0.01)
        return VStack(alignment: .leading, spacing: 8) {
            JohanOverline(String(localized: "Heart-rate zones"))
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(0..<min(5, z.count), id: \.self) { i in
                        if z[i] > 0 {
                            Capsule().fill(StrandPalette.hrZoneColor(i + 1))
                                .frame(width: max(4, (g.size.width - 8) * z[i] / total))
                        }
                    }
                }
            }
            .frame(height: 10)
            HStack {
                ForEach(0..<min(5, z.count), id: \.self) { i in
                    VStack(spacing: 1) {
                        Text("Z\(i + 1)").font(JohanTheme.Fonts.unit).foregroundStyle(StrandPalette.hrZoneColor(i + 1))
                        Text("\(Int(z[i].rounded())) min").font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text((1...min(5, z.count)).map { String(localized: "zone \($0) \(Int(z[$0 - 1].rounded())) minutes") }
            .joined(separator: ", ")))
    }

    private func stat(_ title: String, _ value: String, _ unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            JohanOverline(title)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).johanNumberFont(22, relativeTo: .title3).foregroundStyle(JohanTheme.textPrimary)
                if let unit { Text(unit).font(JohanTheme.Fonts.unit).foregroundStyle(JohanTheme.textSecondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    private static func window(_ row: WorkoutRow) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
        let end = Date(timeIntervalSince1970: TimeInterval(row.endTs))
        return start.formatted(date: .omitted, time: .shortened) + "–" + end.formatted(date: .omitted, time: .shortened)
    }
}
#endif
