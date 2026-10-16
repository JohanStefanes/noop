#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// Whether the cycle surfaces belong on screen, by the same rule as the original Today card
/// (`MenstrualCycleHomeCard`): not hidden by the wearer, and either the profile makes it apply, it is
/// switched on, or period starts have been logged.
struct JohanCycleGate {
    let hidden: Bool
    let enabled: Bool
    let applies: Bool
    let hasStarts: Bool
    var shows: Bool { !hidden && (applies || enabled || hasStarts) }
}

/// Phase names in the app's language, shared by the Home card and the cycle page.
enum JohanCycleText {
    static func phase(_ phase: CyclePhaseEngine.Phase) -> String {
        switch phase {
        case .follicular: return String(localized: "Follicular")
        case .periOvulatory: return String(localized: "Mid-cycle shift")
        case .luteal: return String(localized: "Luteal")
        case .unknown: return String(localized: "No clear pattern")
        case .learning: return String(localized: "Learning your pattern")
        }
    }

    static func detail(_ phase: CyclePhaseEngine.Phase) -> String {
        switch phase {
        case .follicular: return String(localized: "Skin temperature is sitting at your baseline.")
        case .periOvulatory: return String(localized: "Skin temperature is turning around the middle of your cycle.")
        case .luteal: return String(localized: "Skin temperature is running above your baseline.")
        case .unknown: return String(localized: "No clear temperature pattern yet.")
        case .learning: return String(localized: "Keep wearing the strap overnight so the pattern can be learned.")
        }
    }

    static func dayRange(_ r: CyclePhaseEngine.Result) -> String? {
        guard let lo = r.cycleDayLow, let hi = r.cycleDayHigh else { return nil }
        return lo == hi ? String(localized: "about day \(String(lo))") : String(localized: "about day \(String(lo))–\(String(hi))")
    }

    static func day(_ key: String) -> String {
        guard let date = JohanHomeModel.keyParser.date(from: key) else { return key }
        return date.formatted(Date.FormatStyle(locale: AppLanguage.activeLocale).day().month(.abbreviated))
    }
}

/// Small Home card: the phase in a line, opening the cycle page. Shows only under `JohanCycleGate`.
struct JohanCycleHomeCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(AppModel.cycleAwarenessKey) private var enabled = false
    @AppStorage(AppModel.cycleAwarenessHiddenKey) private var hidden = false
    @State private var starts: [String] = []

    var body: some View {
        Group {
            if JohanCycleGate(hidden: hidden, enabled: enabled, applies: profile.cycleAwarenessApplies,
                              hasStarts: !starts.isEmpty).shows {
                NavigationLink { JohanCycleView() } label: {
                    JohanCard {
                        HStack(spacing: 14) {
                            Image(systemName: "drop.degreesign")
                                .font(.system(.body, weight: .bold))
                                .foregroundStyle(JohanTheme.recoveryRed)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(JohanTheme.recoveryRed.opacity(0.16)))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cycle").font(.system(.footnote, weight: .semibold))
                                    .foregroundStyle(JohanTheme.recoveryRed)
                                Text(headline).font(.system(.headline)).foregroundStyle(JohanTheme.textPrimary)
                                if let sub = subline {
                                    Text(sub).font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold))
                                .foregroundStyle(JohanTheme.textTertiary)
                        }
                    }
                }
                .buttonStyle(JohanPressStyle())
            }
        }
        .task(id: repo.cycleTrackingSeq) {
            starts = await repo.periodStarts()
            if enabled, model.cyclePhase == nil { await model.refreshV5Signals() }
        }
    }

    private var headline: String {
        guard enabled else { return String(localized: "Set up cycle tracking") }
        return model.cyclePhase.map { JohanCycleText.phase($0.phase) } ?? String(localized: "Learning your pattern")
    }

    private var subline: String? {
        guard enabled, let r = model.cyclePhase else { return nil }
        if let window = r.nextPeriodWindow {
            return String(localized: "Next period likely \(JohanCycleText.day(window.earliestDay))–\(JohanCycleText.day(window.latestDay))")
        }
        return JohanCycleText.dayRange(r)
    }
}

/// The cycle page: phase and cycle day from the nightly skin-temperature shift (`AppModel.cyclePhase`,
/// `CyclePhaseEngine`), the likely next-period window, the temperature curve, and period starts logged on
/// this device. Off until the wearer turns it on; awareness only, never a fertility or medical claim.
struct JohanCycleView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @AppStorage(AppModel.cycleAwarenessKey) private var enabled = false
    @State private var starts: [String] = []
    @State private var showsTracker = false

    var body: some View {
        JohanScreen(title: String(localized: "Cycle")) {
            if enabled {
                phaseCard.johanStagger(0)
                if model.cycleCurve.count >= 2 { curveCard.johanStagger(1) }
                logCard.johanStagger(2)
            } else {
                setupCard.johanStagger(0)
            }
            Text("Private and on this device only. Cycle estimates are for awareness, not contraception or diagnosis.")
                .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                .padding(.horizontal, 4)
        }
        .task(id: repo.cycleTrackingSeq) {
            starts = await repo.periodStarts()
            if enabled, model.cyclePhase == nil { await model.refreshV5Signals() }
        }
        .sheet(isPresented: $showsTracker) {
            // The tracker brings its own navigation stack and Done button.
            if let result = model.cyclePhase {
                CycleTrackerView(result: result, curve: model.cycleCurve)
            } else {
                ProgressView().task { await model.refreshV5Signals() }
            }
        }
    }

    private var setupCard: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cycle tracking").font(.system(.headline)).foregroundStyle(JohanTheme.textPrimary)
                Text("Reads your cycle phase from the nightly rise and fall of skin temperature, resting heart rate and HRV. Logging the first day of a period makes it more precise.")
                    .font(.system(.subheadline)).foregroundStyle(JohanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    enabled = true
                    model.cycleAwarenessEnabled = true
                    Task { await model.refreshV5Signals() }
                } label: {
                    Text("Turn on").font(.system(.headline)).foregroundStyle(JohanTheme.background)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Capsule().fill(JohanTheme.recoveryRed))
                }
                .buttonStyle(JohanPressStyle())
            }
        }
    }

    private var phaseCard: some View {
        let r = model.cyclePhase
        return JohanCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Today").font(.system(.footnote, weight: .semibold)).foregroundStyle(JohanTheme.recoveryRed)
                Text(r.map { JohanCycleText.phase($0.phase) } ?? String(localized: "Learning your pattern"))
                    .font(.system(.title2, weight: .bold)).foregroundStyle(JohanTheme.textPrimary)
                if let r, let range = JohanCycleText.dayRange(r) {
                    Text(range).johanNumberFont(20).foregroundStyle(JohanTheme.textSecondary)
                }
                Text(JohanCycleText.detail(r?.phase ?? .learning))
                    .font(.system(.subheadline)).foregroundStyle(JohanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let r {
                    Divider().overlay(JohanTheme.cardBorder)
                    HStack(alignment: .top) {
                        fact(String(localized: "Next period"),
                             r.nextPeriodWindow.map { "\(JohanCycleText.day($0.earliestDay))–\(JohanCycleText.day($0.latestDay))" } ?? "–")
                        fact(String(localized: "Cycle length"),
                             r.cycleLengthDays.map { String(localized: "\(String($0)) days") } ?? "–")
                        fact(String(localized: "Confidence"), confidenceText(r.confidence))
                    }
                }
            }
        }
    }

    private var curveCard: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Temperature shift").font(.system(.headline)).foregroundStyle(JohanTheme.textPrimary)
                Text("Skin temperature, resting heart rate and HRV fused into one line, night by night. It rises after ovulation and falls before a period.")
                    .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                JohanSparkline(values: Array(model.cycleCurve.suffix(60)), color: JohanTheme.recoveryRed, height: 64)
            }
        }
    }

    private var logCard: some View {
        let today = Repository.localDayKey(Date())
        let loggedToday = starts.contains(today)
        return JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Latest period start").font(.system(.subheadline)).foregroundStyle(JohanTheme.textSecondary)
                    Spacer()
                    Text(starts.last.map(JohanCycleText.day) ?? String(localized: "none logged"))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(starts.isEmpty ? JohanTheme.textTertiary : JohanTheme.textPrimary)
                }
                HStack(spacing: 10) {
                    Button {
                        Task {
                            await repo.logPeriodStart(day: today)
                            await model.refreshV5Signals()
                        }
                    } label: {
                        Label(loggedToday ? String(localized: "Logged today") : String(localized: "Period started today"),
                              systemImage: loggedToday ? "checkmark" : "plus")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(loggedToday ? JohanTheme.textSecondary : JohanTheme.background)
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Capsule().fill(loggedToday ? JohanTheme.card : JohanTheme.recoveryRed))
                    }
                    .buttonStyle(JohanPressStyle())
                    .disabled(loggedToday)
                    Button { showsTracker = true } label: {
                        Text("History").font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(JohanTheme.textPrimary)
                            .padding(.horizontal, 18).padding(.vertical, 11)
                            .background(Capsule().strokeBorder(JohanTheme.cardBorder))
                    }
                    .buttonStyle(JohanPressStyle())
                }
            }
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
            Text(value).font(.system(.subheadline, weight: .semibold)).foregroundStyle(JohanTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confidenceText(_ c: CyclePhaseEngine.Confidence) -> String {
        switch c {
        case .learning: return String(localized: "learning")
        case .building: return String(localized: "building")
        case .solid: return String(localized: "solid")
        }
    }
}
#endif
