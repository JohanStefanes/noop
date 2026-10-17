#if os(iOS)
import SwiftUI
import StrandDesign
import WhoopProtocol

/// "Gym equipment" on the Workout tab: the WHOOP MG second live-HR receiver opt-in
/// (`BLEManager.setLiveSecondHrm`, `whoop_live_2_hrm_devices`) next to the Broadcast-HR switch, so a treadmill
/// or bike can be tried as a second receiver while NOOP stays connected.
///
/// It is the same opt-in as the Test Centre switch, not a second copy of it: both read
/// `PuffinExperiment.liveSecondHrmKey` and `LiveState.liveSecondHrmReadBack`, and both go through
/// `setLiveSecondHrm`. Turning it on asks first; turning it off writes back the value read before the first
/// write. Nothing here runs on its own: a workout starting or ending sends nothing, the card only reminds
/// that the opt-in is still in force. What the setting does on the strap is unverified.
struct JohanGymModeCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @AppStorage(PuffinExperiment.liveSecondHrmKey) private var secondHrmOn = false
    @AppStorage(PuffinExperiment.broadcastHrKey) private var broadcastOn = false
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop4.rawValue
    @State private var confirmOn = false

    /// Shown for a WHOOP 5/MG, and always while the opt-in is in force so it can be turned off again.
    static func isOffered(selectedModelRaw: String, optInOn: Bool) -> Bool {
        optInOn || selectedModelRaw == WhoopModel.whoop5mg.rawValue
    }

    /// Why the switches are off limits right now, or nil when a write can go out. `setLiveSecondHrm` checks
    /// the same conditions again and logs a refusal, so this only keeps the control honest.
    private var blocker: LocalizedStringKey? {
        if !live.connected { return "Connect your strap to change this." }
        if live.whoop5Variant != Whoop5Variant.mg.label { return "Only on WHOOP MG." }
        if !live.encryptedBond { return "Needs the full pairing with NOOP, not the live heart-rate link." }
        return nil
    }

    private var busy: Bool { live.liveSecondHrmBusy || live.broadcastHrBusy }

    var body: some View {
        if Self.isOffered(selectedModelRaw: selectedWhoopModelRaw, optInOn: secondHrmOn) {
            card
        }
    }

    private var card: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    JohanOverline(String(localized: "Gym equipment"))
                    Spacer(minLength: 0)
                    Text("Unverified")
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(JohanTheme.recoveryYellow)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(JohanTheme.recoveryYellow.opacity(0.16)))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(get: { secondHrmOn }, set: { on in
                        // Never written from the switch alone: ON asks first, OFF restores the saved value.
                        if on { confirmOn = true } else { model.ble.setLiveSecondHrm(false) }
                    })) {
                        Label("Send heart rate to gym equipment too", systemImage: "figure.run.treadmill")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(JohanTheme.textPrimary)
                    }
                    .tint(JohanTheme.strainBlue)
                    .disabled(blocker != nil || busy)
                    Text("Lets a second receiver, such as a treadmill, a bike or a second phone, get live heart rate while NOOP stays connected.")
                        .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    status
                }

                Divider().overlay(JohanTheme.cardBorder)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(get: { broadcastOn }, set: { on in
                        // The flag first: the 5/MG send gate admits the write only while it is set.
                        broadcastOn = on
                        model.ble.setBroadcastHr(on)
                    })) {
                        Label("Show the strap as a heart-rate sensor", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(JohanTheme.textPrimary)
                    }
                    .tint(JohanTheme.strainBlue)
                    .disabled(blocker != nil || busy)
                    Text("Broadcast heart rate: equipment that looks for a standard heart-rate sensor can find the strap. Same switch as in the Test Centre.")
                        .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let blocker {
                    Label(blocker, systemImage: "exclamationmark.circle")
                        .font(.system(.footnote)).foregroundStyle(JohanTheme.textSecondary)
                } else if secondHrmOn, model.activeWorkout == nil {
                    Label("Still on. Turn it off after training so NOOP writes the saved value back.",
                          systemImage: "arrow.uturn.backward.circle")
                        .font(.system(.footnote)).foregroundStyle(JohanTheme.recoveryYellow)
                } else {
                    Text("To test: pair the equipment or a second phone as a heart-rate sensor, then check that both show your heart rate.")
                        .font(.system(.caption)).foregroundStyle(JohanTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .confirmationDialog("Send heart rate to gym equipment?", isPresented: $confirmOn, titleVisibility: .visible) {
            Button("Read, save and write") { model.ble.setLiveSecondHrm(true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("NOOP changes the WHOOP MG setting whoop_live_2_hrm_devices so the strap may serve live heart rate to a second receiver. What this does is unverified, and it may change how the strap connects. NOOP reads the current value first and saves it. Turning the switch off writes that value back and reads it again.")
        }
    }

    /// Only the strap's read-back is shown, never the requested value or the write ack.
    @ViewBuilder private var status: some View {
        if live.liveSecondHrmBusy {
            Label("Reading and writing the strap setting…", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
        } else if let value = live.liveSecondHrmReadBack {
            Text("strap reports: \(value)")
                .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
        } else {
            Text("strap reports: unknown")
                .font(.system(.caption)).foregroundStyle(JohanTheme.textSecondary)
        }
    }
}
#endif
