#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// "Healthspan": the long-term picture in one place. Body Age and Vitality (weekly, `VitalityEngine` via
/// IntelligenceEngine), Fitness Age and VO₂max (weekly, the Fitness Age engine), each read back as the
/// latest stored point, with the "what's driving it" breakdown from `VitalityBreakdown` (the same one
/// Health shows) and the trend of the stored weekly points. Nothing is re-scored here.
struct JohanHealthspanView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.johanReloadTick) private var reloadTick
    @State private var bodyAge: [(day: String, value: Double)] = []
    @State private var vitality: [(day: String, value: Double)] = []
    @State private var fitnessAge: [(day: String, value: Double)] = []
    @State private var vo2max: [(day: String, value: Double)] = []
    @State private var loaded = false

    private static let teal = JohanTheme.strainBlue

    var body: some View {
        JohanScreen(title: String(localized: "Healthspan")) {
            if !loaded {
                JohanPlaceholderCard(height: 200)
                JohanPlaceholderCard(height: 160)
            } else if bodyAge.isEmpty && vitality.isEmpty && fitnessAge.isEmpty && vo2max.isEmpty {
                emptyCard.johanStagger(0)
            } else {
                heroCard.johanStagger(0)
                driversCard.johanStagger(1)
                fitnessCard.johanStagger(2)
                if bodyAge.count >= 2 { trendCard.johanStagger(3) }
                Text("A wellness estimate from your habits, not a clinical biological age.")
                    .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                    .padding(.horizontal, 4)
            }
        }
        .task(id: reloadTick) { await load() }
    }

    // MARK: Cards

    private var emptyCard: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Not enough data yet", systemImage: "hourglass")
                    .font(.system(.headline)).foregroundStyle(JohanTheme.textPrimary)
                Text("Body Age and Vitality are worked out once a week from resting heart rate, HRV, sleep and steps. Wear the strap for a few days and nights and they appear here.")
                    .font(.system(.subheadline)).foregroundStyle(JohanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Body Age against the real age, beside the Vitality dial.
    private var heroCard: some View {
        JohanCard {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Body Age").font(.system(.footnote, weight: .semibold)).foregroundStyle(Self.teal)
                    if let ba = bodyAge.last?.value {
                        Text("\(Int(ba.rounded()))").johanNumberFont(52).foregroundStyle(JohanTheme.textPrimary)
                        let delta = Double(profile.age) - ba
                        Label(Self.ageDeltaLine(delta),
                              systemImage: abs(delta) < 0.5 ? "equal" : (delta > 0 ? "arrow.down" : "arrow.up"))
                            .labelStyle(JohanCompactLabelStyle())
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(abs(delta) < 0.5 ? JohanTheme.textSecondary
                                             : (delta > 0 ? JohanTheme.recoveryGreen : JohanTheme.recoveryYellow))
                        Text("Your age: \(String(profile.age))")
                            .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                    } else {
                        Text("–").johanNumberFont(52).foregroundStyle(JohanTheme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
                JohanDial(title: String(localized: "Vitality"), value: vitality.last?.value,
                          format: { "\(Int($0.rounded()))" }, unitText: String(localized: "of 100"),
                          fraction: vitality.last.map { min(1, max(0, $0.value / 100)) },
                          color: JohanTheme.recoveryGreen, size: 120)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// What moves Body Age: each factor's push, left = younger, right = older.
    @ViewBuilder
    private var driversCard: some View {
        let items = VitalityBreakdown.contributions(days: repo.days, age: profile.age)
            .sorted { $0.lnHazard < $1.lnHazard }
        if !items.isEmpty {
            let maxAbs = items.map { abs($0.lnHazard) }.max() ?? 1
            JohanCard {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("What drives it").font(.system(.headline)).foregroundStyle(JohanTheme.textPrimary)
                        Text("Your last seven days against what is typical for your age. Left of the line makes you younger, right of it older.")
                            .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.key) { i, c in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(Self.factorName(c.key, fallback: c.label))
                                    .font(.system(.subheadline)).foregroundStyle(JohanTheme.textPrimary)
                                Spacer()
                                Text(Self.effectText(c.lnHazard))
                                    .font(.system(.caption, weight: .semibold))
                                    .foregroundStyle(Self.effectColor(c.lnHazard))
                            }
                            JohanDivergingBar(delta: c.lnHazard, maxAbs: maxAbs,
                                              color: Self.effectColor(c.lnHazard), index: i)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    /// Fitness Age and VO₂max, the cardio half of the picture.
    @ViewBuilder
    private var fitnessCard: some View {
        if fitnessAge.last != nil || vo2max.last != nil {
            JohanCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Cardio fitness").font(.system(.headline)).foregroundStyle(JohanTheme.textPrimary)
                    JohanAdaptiveStack(spacing: 12) {
                        figure(String(localized: "VO₂max"), vo2max.last?.value, decimals: 1, unit: "ml/kg/min")
                        figure(String(localized: "Fitness Age"), fitnessAge.last?.value, decimals: 0,
                               unit: String(localized: "yrs"))
                    }
                    if vo2max.count >= 2 {
                        // No scrub readout: its hint speaks of single nights, and these are weekly points.
                        JohanSparkline(values: vo2max.suffix(26).map(\.value), color: Self.teal, height: 44)
                    }
                    Text("Estimated from your resting heart rate, age and body measures, updated weekly.")
                        .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var trendCard: some View {
        let pts = Array(bodyAge.suffix(26))
        return JohanCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Body Age over time").font(.system(.headline)).foregroundStyle(JohanTheme.textPrimary)
                JohanSparkline(values: pts.map(\.value), color: JohanTheme.recoveryGreen, height: 60)
                if let first = pts.first, let last = pts.last {
                    Text("\(Self.weekText(first.day)) – \(Self.weekText(last.day)), one point per week")
                        .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                }
            }
        }
    }

    private func figure(_ title: String, _ value: Double?, decimals: Int, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.map { String(format: "%.\(decimals)f", $0) } ?? "–").johanNumberFont(28)
                    .foregroundStyle(value == nil ? JohanTheme.textTertiary : JohanTheme.textPrimary)
                if value != nil {
                    Text(unit).font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Data

    private func load() async {
        async let b = repo.exploreSeries(key: "body_age", source: "my-whoop")
        async let v = repo.exploreSeries(key: "vitality", source: "my-whoop")
        async let f = repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        async let o = repo.exploreSeries(key: "vo2max_est", source: "my-whoop")
        bodyAge = await b
        vitality = await v
        fitnessAge = await f
        vo2max = await o
        loaded = true
    }

    // MARK: Text

    static func ageDeltaLine(_ delta: Double) -> String {
        let yrs = Int(abs(delta).rounded())
        if yrs == 0 { return String(localized: "about your age") }
        switch (delta > 0, yrs == 1) {
        case (true, true): return String(localized: "1 yr younger")
        case (true, false): return String(localized: "\(yrs) yrs younger")
        case (false, true): return String(localized: "1 yr older")
        case (false, false): return String(localized: "\(yrs) yrs older")
        }
    }

    /// The engine's factor keys in the app's language; the engine's own English label is the fallback.
    private static func factorName(_ key: String, fallback: String) -> String {
        switch key {
        case "rhr": return String(localized: "Resting heart rate")
        case "vo2max": return String(localized: "Cardio fitness")
        case "sleep": return String(localized: "Sleep duration")
        case "consistency": return String(localized: "Sleep regularity")
        case "hrv": return String(localized: "Heart-rate variability")
        case "steps": return String(localized: "Daily steps")
        default: return fallback
        }
    }

    private static func effectText(_ ln: Double) -> String {
        if abs(ln) < 0.01 { return String(localized: "neutral") }
        return ln < 0 ? String(localized: "makes you younger") : String(localized: "makes you older")
    }

    private static func effectColor(_ ln: Double) -> Color {
        if abs(ln) < 0.01 { return JohanTheme.textSecondary }
        return ln < 0 ? JohanTheme.recoveryGreen : JohanTheme.recoveryYellow
    }

    private static func weekText(_ day: String) -> String {
        guard let date = JohanHomeModel.keyParser.date(from: day) else { return day }
        return date.formatted(Date.FormatStyle(locale: AppLanguage.activeLocale).day().month(.abbreviated))
    }
}
#endif
