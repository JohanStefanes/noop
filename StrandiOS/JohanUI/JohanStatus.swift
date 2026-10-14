#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// The strap facts Home and the strap page read, resolved once from `LiveState` with the same gates the
/// original Today's Data Sources rows use (battery only while a WHOOP strap is the connected, active
/// device, #2208; no sync line while an offload runs). Both surfaces go through this one resolver so the
/// header chip and the page it opens cannot disagree.
@MainActor
struct JohanStrapFacts {
    let live: LiveState

    var connected: Bool { live.connected }

    var battery: Double? {
        guard live.connected, live.activeIsWhoop else { return nil }
        return live.batteryPct
    }

    var charging: Bool { battery != nil && live.charging == true }

    /// Runtime estimate under the same gate as the percentage, so a ring's or a stale strap's figure never
    /// sits beside this strap's charge.
    var estimate: BatteryEstimator.Estimate? { battery == nil ? nil : live.batteryEstimate }

    var statusColor: Color {
        if !live.connected { return JohanTheme.textTertiary }
        return live.lastSyncError != nil ? JohanTheme.recoveryYellow : JohanTheme.recoveryGreen
    }

    func batteryColor(_ pct: Double) -> Color {
        if charging { return JohanTheme.recoveryGreen }
        if pct < 15 { return JohanTheme.recoveryRed }
        if pct < 30 { return JohanTheme.recoveryYellow }
        return JohanTheme.textPrimary
    }

    var connectionText: String { live.connected ? String(localized: "Connected") : String(localized: "Not connected") }

    func syncText(now: Date) -> (text: String, isProblem: Bool)? {
        if live.backfilling { return (String(localized: "Syncing …"), false) }
        if live.lastSyncError != nil { return (String(localized: "Sync interrupted"), true) }
        guard let at = live.lastSyncedAt else { return nil }
        let date = Date(timeIntervalSince1970: at)
        if now.timeIntervalSince(date) < 60 { return (String(localized: "Just synced"), false) }
        return (String(localized: "Synced \(Self.relative.localizedString(for: date, relativeTo: now))"), false)
    }

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = AppLanguage.activeLocale
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// Battery ring shared by the header chip and the strap page: the arc is the charge, the centre the
/// number. Disconnected (or no reading yet) shows an empty ring with a slashed antenna instead of a stale
/// figure.
struct JohanBatteryRing: View {
    let facts: JohanStrapFacts
    var size: CGFloat
    var lineWidth: CGFloat

    var body: some View {
        let pct = facts.battery
        ZStack {
            Circle().stroke(JohanTheme.textTertiary.opacity(0.35), lineWidth: lineWidth)
            if let pct {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, pct / 100)))
                    .stroke(facts.batteryColor(pct), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(JohanTheme.Motion.daySlide, value: pct)
                Text("\(Int(pct.rounded()))")
                    .font(JohanTheme.number(size * 0.34))
                    .foregroundStyle(JohanTheme.textPrimary)
                    .minimumScaleFactor(0.6)
            } else {
                Image(systemName: facts.connected ? "battery.0" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(JohanTheme.textTertiary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Header chip on Home: the strap's battery ring with a status dot (green connected, yellow sync problem,
/// grey offline) and a bolt while charging. Tapping it opens `JohanStrapView`.
struct JohanStrapChip: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        let facts = JohanStrapFacts(live: live)
        NavigationLink {
            JohanStrapView()
        } label: {
            JohanBatteryRing(facts: facts, size: 34, lineWidth: 3)
                .overlay(alignment: .topTrailing) {
                    Group {
                        if facts.charging {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(JohanTheme.background)
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(JohanTheme.recoveryGreen))
                        } else {
                            Circle().fill(facts.statusColor).frame(width: 9, height: 9)
                        }
                    }
                    .overlay(Circle().stroke(JohanTheme.background, lineWidth: 2))
                    .offset(x: 3, y: -3)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(JohanPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(facts))
        .accessibilityHint("Shows strap details")
    }

    private func accessibilityText(_ facts: JohanStrapFacts) -> String {
        var parts = [facts.connectionText]
        if let pct = facts.battery { parts.append(String(localized: "Battery \(Int(pct.rounded())) %")) }
        if facts.charging { parts.append(String(localized: "Charging")) }
        if let sync = facts.syncText(now: .now) { parts.append(sync.text) }
        return parts.joined(separator: ", ")
    }
}

/// Strap page opened from the Home header: battery, connection, sync and the strap's identity, each
/// fact through `JohanStrapFacts`. Device management itself stays on the original Devices screen.
struct JohanStrapView: View {
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var router: NavRouter

    var body: some View {
        let facts = JohanStrapFacts(live: live)
        JohanScreen(title: String(localized: "Strap")) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: JohanTheme.Metrics.cardSpacing) {
                    batteryHero(facts).johanStagger(0)
                    statusCard(facts, now: context.date).johanStagger(1)
                    if live.connected { detailsCard.johanStagger(2) }
                    manageButton.johanStagger(3)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Battery

    private func batteryHero(_ facts: JohanStrapFacts) -> some View {
        VStack(spacing: 14) {
            JohanBatteryRing(facts: facts, size: 150, lineWidth: 12)
            Text(batteryHeadline(facts))
                .font(JohanTheme.Fonts.title)
                .foregroundStyle(JohanTheme.textPrimary)
                .multilineTextAlignment(.center)
            if let sub = batterySubline(facts) {
                Text(sub)
                    .font(.system(.subheadline))
                    .foregroundStyle(JohanTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func batteryHeadline(_ facts: JohanStrapFacts) -> String {
        if !facts.connected { return String(localized: "Not connected") }
        guard let pct = facts.battery else { return String(localized: "Waiting for battery reading") }
        if facts.charging { return String(localized: "Charging · \(Int(pct.rounded())) %") }
        return String(localized: "Battery \(Int(pct.rounded())) %")
    }

    private func batterySubline(_ facts: JohanStrapFacts) -> String? {
        if !facts.connected { return String(localized: "Battery and sync appear once the strap is in range.") }
        guard !facts.charging, let est = facts.estimate else { return nil }
        let hours = est.remainingHours
        if hours < 24 { return String(localized: "About \(Int(hours.rounded())) h left") }
        return String(localized: "About \(Int((hours / 24).rounded())) days left")
    }

    // MARK: Status

    private func statusCard(_ facts: JohanStrapFacts, now: Date) -> some View {
        JohanCard(padding: 0) {
            VStack(spacing: 0) {
                row(String(localized: "Connection"), "dot.radiowaves.left.and.right") {
                    HStack(spacing: 6) {
                        Circle().fill(facts.statusColor).frame(width: 7, height: 7)
                        Text(facts.connectionText)
                    }
                }
                if live.connected {
                    divider
                    row(String(localized: "Wear"), "hand.raised") {
                        Text(live.worn ? String(localized: "On wrist") : String(localized: "Off wrist"))
                    }
                    if let hr = live.heartRate {
                        divider
                        row(String(localized: "Heart rate"), "heart.fill") { Text("\(hr) bpm") }
                    }
                }
                divider
                row(String(localized: "Last sync"), "arrow.triangle.2.circlepath") {
                    if let sync = facts.syncText(now: now) {
                        Text(sync.text).foregroundStyle(sync.isProblem ? JohanTheme.recoveryYellow : JohanTheme.textSecondary)
                    } else {
                        Text("–")
                    }
                }
            }
        }
    }

    // MARK: Details

    private var detailsCard: some View {
        JohanCard(padding: 0) {
            VStack(spacing: 0) {
                row(String(localized: "Name"), "tag") { Text(live.advertisingName ?? "–") }
                divider
                row(String(localized: "Firmware"), "cpu") { Text(live.strapFirmware ?? "–") }
                if let mv = live.batteryMv, live.activeIsWhoop {
                    divider
                    row(String(localized: "Voltage"), "bolt") {
                        Text((Double(mv) / 1000).formatted(.number.precision(.fractionLength(2)).locale(AppLanguage.activeLocale)) + " V")
                    }
                }
            }
        }
    }

    private var manageButton: some View {
        Button { router.openDevices() } label: {
            HStack {
                Text("Manage devices")
                Spacer()
                Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(JohanTheme.textTertiary)
            }
            .font(.system(.body))
            .foregroundStyle(JohanTheme.textPrimary)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: JohanTheme.Metrics.cardRadius, style: .continuous).fill(JohanTheme.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(JohanPressStyle())
    }

    // MARK: Rows

    private var divider: some View {
        Divider().overlay(JohanTheme.cardBorder).padding(.leading, 16 + 24 + 12)
    }

    private func row<Value: View>(_ title: String, _ icon: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(JohanTheme.textSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title).foregroundStyle(JohanTheme.textPrimary)
            Spacer(minLength: 8)
            value().foregroundStyle(JohanTheme.textSecondary).lineLimit(1)
        }
        .font(.system(.body))
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
    }
}
#endif
