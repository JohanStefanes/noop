#if os(iOS)
import SwiftUI

/// "Calibrate Steps": a guided walk that sets `ProfileStore.stepTicksPerStep` from a measured ratio
/// instead of a hand-tuned number. The WHOOP 5/MG step counter (`step_motion_counter@57`) counts several
/// ticks per real step, and how many differs from wearer to wearer.
///
/// The wearer walks with the phone in a pocket; the phone's pedometer (or a count they type) is the
/// reference. The strap's ticks for the same minutes only exist once the strap has offloaded them, so
/// the walk ends with a sync and waits for the window to arrive before it computes anything.
struct JohanStepCalibrationView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    /// The app's one profile (`AppModel.profile`), so the engine sees the new value at once.
    @EnvironmentObject private var profile: ProfileStore

    private enum Phase: Equatable {
        case idle
        case walking(start: Date)
        case waiting(start: Int, end: Int)
        case result(ticks: Int, start: Int, end: Int)
        case noTicks
    }

    @State private var phase: Phase = .idle
    /// The reference count: the phone's pedometer for the walk, editable in case the wearer counted.
    @State private var stepsText = ""
    @State private var applied = false

    /// Fewer steps than this make the ratio too coarse to trust.
    static let minimumSteps = 100
    /// How long to wait for the strap to offload the walk before giving up.
    static let waitSeconds = 180

    var body: some View {
        JohanScreen(title: String(localized: "Calibrate Steps")) {
            JohanCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your strap counts several ticks per step, and how many differs from person to person. A short walk measures your own ratio.")
                        .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                    Text(String(localized: "Current value: \(String(format: "%.1f", profile.stepTicksPerStep)) ticks per step"))
                        .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
                }
            }
            if !model.ble.isWhoop5 {
                Label("This calibration is for the step counter of a WHOOP 5.0/MG.", systemImage: "info.circle")
                    .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
            }
            phaseCard
        }
    }

    @ViewBuilder
    private var phaseCard: some View {
        switch phase {
        case .idle:
            JohanCard {
                VStack(alignment: .leading, spacing: 12) {
                    step(1, String(localized: "Put the phone in your pocket and wear the strap as usual."))
                    step(2, String(localized: "Tap Start and walk normally, at least \(Self.minimumSteps) steps. A few minutes is better."))
                    step(3, String(localized: "Tap Done. NOOP syncs the strap and computes your ratio."))
                    primaryButton(String(localized: "Start"), "figure.walk") { phase = .walking(start: Date()) }
                        .disabled(!live.connected)
                        .opacity(live.connected ? 1 : 0.4)
                    if !live.connected {
                        Text("Connect the strap first.").font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
                    }
                }
            }
        case .walking(let start):
            JohanCard {
                VStack(spacing: 14) {
                    Image(systemName: "figure.walk").font(.system(size: 40)).foregroundStyle(JohanTheme.recoveryGreen)
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(Duration.seconds(ctx.date.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond)))
                            .johanNumberFont(44, relativeTo: .largeTitle)
                    }
                    Text("Walking. Tap Done when you have walked enough.")
                        .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                    primaryButton(String(localized: "Done"), "checkmark") { Task { await finishWalk(start: start) } }
                    Button("Cancel") { phase = .idle }.foregroundStyle(JohanTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        case .waiting:
            JohanCard {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Syncing the strap and waiting for the walk to arrive. This can take a minute.")
                        .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                }
            }
        case .noTicks:
            JohanCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("The strap's count for the walk didn't arrive.").font(.system(.subheadline, weight: .semibold))
                    Text("Keep the strap connected and try again. The strap only hands over its step count with its history.")
                        .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                    primaryButton(String(localized: "Try again"), "arrow.clockwise") { phase = .idle }
                }
            }
        case .result(let ticks, _, _):
            resultCard(ticks: ticks)
        }
    }

    private func resultCard(ticks: Int) -> some View {
        let steps = Int(stepsText) ?? 0
        let ratio = steps > 0 ? min(max(Double(ticks) / Double(steps), 0.5), 30) : nil
        return JohanCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        JohanOverline(String(localized: "Strap ticks"))
                        Text("\(ticks)").johanNumberFont(26)
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 2) {
                        JohanOverline(String(localized: "Real steps"))
                        TextField("0", text: $stepsText)
                            .keyboardType(.numberPad)
                            .johanNumberFont(26)
                            .frame(maxWidth: 110)
                    }
                }
                Text("Real steps come from the phone's pedometer. If you counted yourself, enter your count.")
                    .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
                if let ratio {
                    Text(String(localized: "Your ratio: \(String(format: "%.1f", ratio)) ticks per step"))
                        .font(.system(.title3, weight: .semibold))
                    if steps < Self.minimumSteps {
                        Text(String(localized: "Fewer than \(Self.minimumSteps) steps. Walk longer for a reliable value."))
                            .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.recoveryYellow)
                    }
                    if applied {
                        Label("Saved. Steps are recalculated with it from now on.", systemImage: "checkmark.circle.fill")
                            .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.recoveryGreen)
                    } else {
                        primaryButton(String(localized: "Use this value"), "checkmark") {
                            profile.stepTicksPerStep = (ratio * 10).rounded() / 10
                            applied = true
                            Task { await model.intelligence.analyzeRecent(); await model.repo.refresh() }
                        }
                    }
                } else {
                    Text("Enter the real number of steps to compute the ratio.")
                        .font(JohanTheme.Fonts.body).foregroundStyle(JohanTheme.textSecondary)
                }
                Button("Start over") { phase = .idle; applied = false }.foregroundStyle(JohanTheme.textSecondary)
            }
        }
    }

    // MARK: Flow

    private func finishWalk(start: Date) async {
        let from = Int(start.timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        phase = .waiting(start: from, end: to)
        let phoneSteps = await WorkoutPedometer.steps(fromSec: from, toSec: to)
        stepsText = phoneSteps.map(String.init) ?? ""
        model.ble.syncNow()
        // The offload lands in pieces: wait until the strap's count for the window stops growing.
        var last: Int?
        var steady = 0
        for _ in 0..<(Self.waitSeconds / 5) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard case .waiting = phase else { return }
            let ticks = await model.repo.strapStepTicks(from: from, to: to)
            if let ticks, ticks > 0, ticks == last {
                steady += 1
                if steady >= 2 { phase = .result(ticks: ticks, start: from, end: to); return }
            } else {
                steady = 0
            }
            last = ticks
        }
        if let last, last > 0 { phase = .result(ticks: last, start: from, end: to) } else { phase = .noTicks }
    }

    // MARK: Pieces

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)").johanNumberFont(15).foregroundStyle(JohanTheme.recoveryGreen).frame(minWidth: 16, alignment: .leading)
            Text(text).font(.system(.subheadline)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func primaryButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(.headline))
                .foregroundStyle(JohanTheme.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(JohanTheme.recoveryGreen))
        }
        .buttonStyle(JohanPressStyle())
    }
}
#endif
