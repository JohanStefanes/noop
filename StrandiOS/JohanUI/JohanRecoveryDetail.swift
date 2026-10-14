#if os(iOS)
import SwiftUI
import StrandAnalytics

/// "What shaped it": the recovery score with the engine's own driver rows. Every row is shown as the
/// engine produced it (`ChargeBreakdownWiring`); only its wording goes through the string catalogue.
struct JohanRecoveryDetail: View {
    let recovery: Double
    let isToday: Bool
    let drivers: [ChargeDriver]?
    let confidence: ScoreConfidence?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: JohanTheme.Metrics.cardSpacing) {
                    header
                    if let drivers, !drivers.isEmpty {
                        driversCard(drivers)
                        Text("Points show how much a factor raised (+) or lowered (−) your recovery compared with your personal average (Ø).")
                            .font(JohanTheme.Fonts.caption)
                            .foregroundStyle(JohanTheme.textTertiary)
                    } else {
                        JohanCard {
                            Text("The breakdown appears once your personal HRV baseline is set. Wear the strap for a few nights.")
                                .font(JohanTheme.Fonts.body)
                                .foregroundStyle(JohanTheme.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, JohanTheme.Metrics.screenHPadding)
                .padding(.vertical, 8)
            }
            .background(JohanTheme.background.ignoresSafeArea())
            .navigationTitle("Recovery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(JohanTheme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(JohanTheme.background)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    private var header: some View {
        let zone = JohanTheme.RecoveryZone(recovery)
        return HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(recovery.rounded()))").johanNumberFont(52, relativeTo: .largeTitle)
                Text("%").font(.system(.title3, weight: .regular))
                    .foregroundStyle(JohanTheme.textSecondary)
            }
            .foregroundStyle(zone.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(zone.title).font(.system(.headline)).foregroundStyle(JohanTheme.textPrimary)
                if let confidence { confidencePill(confidence) }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    /// The engine's confidence tier for this score (same tier the original sheet's chip shows).
    private func confidencePill(_ c: ScoreConfidence) -> some View {
        let text: String
        let color: Color
        switch c {
        case .calibrating: text = String(localized: "Calibrating"); color = JohanTheme.textSecondary
        case .building: text = String(localized: "Provisional"); color = JohanTheme.strainBlue
        case .solid: text = String(localized: "Reliable"); color = JohanTheme.recoveryGreen
        }
        return Text(text)
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    // MARK: Drivers

    private func driversCard(_ drivers: [ChargeDriver]) -> some View {
        let maxMagnitude = max(1, drivers.map { abs($0.deltaPoints) }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            JohanOverline(isToday ? String(localized: "What shaped your recovery today") : String(localized: "What shaped your recovery"))
            JohanCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(drivers.enumerated()), id: \.offset) { i, d in
                        driverRow(d, maxMagnitude: maxMagnitude)
                        if i < drivers.count - 1 { Divider().overlay(JohanTheme.cardBorder) }
                    }
                }
            }
        }
    }

    private func driverRow(_ d: ChargeDriver, maxMagnitude: Int) -> some View {
        let color = pointsColor(d.deltaPoints)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(JohanL10n.engine(d.label)).font(.system(.subheadline, weight: .semibold))
                Spacer(minLength: 8)
                Text(pointsText(d.deltaPoints))
                    .font(.system(.footnote, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.15)))
            }
            Text(valueLine(d)).font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
            // Share of the day's biggest mover, so the order of importance reads at a glance.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(JohanTheme.track)
                    Capsule().fill(color)
                        .frame(width: max(4, geo.size.width * CGFloat(abs(d.deltaPoints)) / CGFloat(maxMagnitude)))
                        .opacity(d.deltaPoints == 0 ? 0 : 1)
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
            Text(JohanL10n.engine(d.verdict))
                .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func pointsText(_ p: Int) -> String {
        p > 0 ? String(localized: "+\(String(p)) pts") : p < 0 ? String(localized: "−\(String(abs(p))) pts") : String(localized: "0 pts")
    }

    private func pointsColor(_ p: Int) -> Color {
        p > 0 ? JohanTheme.recoveryGreen : p < 0 ? JohanTheme.recoveryRed : JohanTheme.textSecondary
    }

    /// "89 ms · Ø 82 ms". The engine writes the reference as "82 ms baseline"; only that suffix is
    /// reworded, the number is the engine's.
    private func valueLine(_ d: ChargeDriver) -> String {
        guard !d.baselineText.isEmpty else { return d.valueText }
        let base = d.baselineText.hasSuffix(" baseline")
            ? "Ø " + String(d.baselineText.dropLast(" baseline".count))
            : d.baselineText
        return "\(d.valueText) · \(base)"
    }
}

/// Engine strings (driver labels, verdicts) are English keys in the app's string catalogue, built at
/// runtime, so they are looked up by key in the language the app launched with.
enum JohanL10n {
    static func engine(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }
}
#endif
