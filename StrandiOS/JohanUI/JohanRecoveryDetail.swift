#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// "What shaped it": the recovery score as a dial, what lifted and what held it back, the engine's driver
/// rows (tap one for its read), and the last two weeks around it. Every driver row is shown as the engine
/// produced it (`ChargeBreakdownWiring`); only its wording goes through the string catalogue.
struct JohanRecoveryDetail: View {
    /// One day of the trend strip.
    struct TrendDay: Equatable {
        let key: String
        let recovery: Double?
    }

    let recovery: Double
    let isToday: Bool
    let drivers: [ChargeDriver]?
    let confidence: ScoreConfidence?
    /// The days up to and including the shown one, oldest first (the shown day is the last entry).
    var trend: [TrendDay] = []
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repo: Repository
    @State private var expanded: Set<String> = []
    /// What else moves with recovery over the last month, besides its own drivers; nil until scanned.
    @State private var correlations: [MetricCorrelationScan.Hit]?
    @State private var pickedTrendIndex: Int?
    private let motion = JohanStill()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: JohanTheme.Metrics.cardSpacing) {
                    hero.johanStagger(0)
                    if let drivers, !drivers.isEmpty {
                        balanceCard(drivers).johanStagger(1)
                        driversCard(drivers).johanStagger(2)
                    } else {
                        JohanCard {
                            Text("The breakdown appears once your personal HRV baseline is set. Wear the strap for a few nights.")
                                .font(JohanTheme.Fonts.body)
                                .foregroundStyle(JohanTheme.textSecondary)
                        }
                        .johanStagger(1)
                    }
                    if trend.compactMap(\.recovery).count >= 2 { trendCard.johanStagger(3) }
                    correlationsCard.johanStagger(4)
                    if drivers?.isEmpty == false {
                        Text("Points show how much a factor raised (+) or lowered (−) your recovery compared with your personal average (Ø).")
                            .font(JohanTheme.Fonts.caption)
                            .foregroundStyle(JohanTheme.textTertiary)
                            .johanStagger(5)
                    }
                }
                .padding(.horizontal, JohanTheme.Metrics.screenHPadding)
                .padding(.bottom, 24)
            }
            .background(JohanTheme.background.ignoresSafeArea())
            .task(id: repo.refreshSeq) { await scanCorrelations() }
            .navigationTitle("Recovery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(JohanTheme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(JohanTheme.background)
        .presentationCornerRadius(32)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Hero

    private var zone: JohanTheme.RecoveryZone { JohanTheme.RecoveryZone(recovery) }

    /// The average of the trend days before the shown one, so "vs your average" never includes itself.
    private var priorAverage: Double? {
        let prior = trend.dropLast().compactMap(\.recovery)
        guard prior.count >= 3 else { return nil }
        return prior.reduce(0, +) / Double(prior.count)
    }

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                JohanAmbientGlow(color: zone.color, size: 260)
                JohanDial(title: String(localized: "Recovery"), value: recovery,
                          format: { "\(Int($0.rounded()))" }, unitText: "%",
                          fraction: recovery / 100, color: zone.color, hapticOnSettle: true,
                          size: 184, numberScale: 0.3, showsTitle: false)
            }
            .frame(height: 200)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(zone.title).font(.system(.title3, weight: .bold)).foregroundStyle(JohanTheme.textPrimary)
                    if let confidence { confidencePill(confidence) }
                }
                Text(isToday ? zone.hint : String(localized: "How recovered you were that morning."))
                    .font(.system(.subheadline))
                    .foregroundStyle(JohanTheme.textSecondary)
                    .multilineTextAlignment(.center)
                if let avg = priorAverage { averageChip(avg) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private func averageChip(_ avg: Double) -> some View {
        // Within a couple of points is noise, not a direction.
        let raw = Int((recovery - avg).rounded())
        let diff = abs(raw) < 3 ? 0 : raw
        let color = diff > 0 ? JohanTheme.recoveryGreen : diff < 0 ? JohanTheme.recoveryRed : JohanTheme.textSecondary
        let icon = diff > 0 ? "arrow.up.right" : diff < 0 ? "arrow.down.right" : "equal"
        let text = diff == 0
            ? String(localized: "About your 2-week average")
            : diff > 0 ? String(localized: "\(diff) above your 2-week average")
                       : String(localized: "\(abs(diff)) below your 2-week average")
        return HStack(spacing: 6) {
            Image(systemName: icon).font(.system(.caption, weight: .bold))
            Text(text).font(.system(.footnote, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.13)))
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

    // MARK: Balance

    /// What pushed the score up against what held it down, as one tug-of-war bar from the centre.
    private func balanceCard(_ drivers: [ChargeDriver]) -> some View {
        let up = drivers.map(\.deltaPoints).filter { $0 > 0 }.reduce(0, +)
        let down = -drivers.map(\.deltaPoints).filter { $0 < 0 }.reduce(0, +)
        let scale = Double(max(up, down, 1))
        return JohanCard {
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    balanceFigure(String(localized: "Held back"), points: -down, color: JohanTheme.recoveryRed,
                                  alignment: .leading)
                    Spacer()
                    balanceFigure(String(localized: "Lifted"), points: up, color: JohanTheme.recoveryGreen,
                                  alignment: .trailing)
                }
                HStack(spacing: 3) {
                    JohanTugBar(fraction: Double(down) / scale, color: JohanTheme.recoveryRed, fromTrailing: true, index: 0)
                    JohanTugBar(fraction: Double(up) / scale, color: JohanTheme.recoveryGreen, fromTrailing: false, index: 1)
                }
                .frame(height: 10)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func balanceFigure(_ title: String, points: Int, color: Color, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title).font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
            CountUpText(value: Double(abs(points)),
                        format: { v in (points < 0 ? "−" : "+") + "\(Int(v.rounded()))" },
                        font: JohanTheme.number(26), color: points == 0 ? JohanTheme.textTertiary : color,
                        animation: JohanTheme.Motion.countUp)
        }
    }

    // MARK: Drivers

    private func driversCard(_ drivers: [ChargeDriver]) -> some View {
        let sorted = drivers.sorted { abs($0.deltaPoints) > abs($1.deltaPoints) }
        let maxMagnitude = Double(max(1, sorted.first.map { abs($0.deltaPoints) } ?? 1))
        return VStack(alignment: .leading, spacing: 8) {
            JohanOverline(isToday ? String(localized: "What shaped your recovery today") : String(localized: "What shaped your recovery"))
            JohanCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(sorted.enumerated()), id: \.element.label) { i, d in
                        driverRow(d, index: i, maxMagnitude: maxMagnitude)
                        if i < sorted.count - 1 { Divider().overlay(JohanTheme.cardBorder).padding(.leading, 16) }
                    }
                }
            }
        }
    }

    private func driverRow(_ d: ChargeDriver, index: Int, maxMagnitude: Double) -> some View {
        let color = pointsColor(d.deltaPoints)
        let open = expanded.contains(d.label)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                StrandHaptic.selection.play()
                withAnimation(motion.isStill ? nil : .spring(response: 0.38, dampingFraction: 0.86)) {
                    if open { expanded.remove(d.label) } else { expanded.insert(d.label) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(JohanL10n.engine(d.label))
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(JohanTheme.textPrimary)
                            Text(valueLine(d)).font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Text(pointsText(d.deltaPoints))
                            .font(.system(.subheadline, design: .rounded, weight: .bold).monospacedDigit())
                            .foregroundStyle(color)
                        Image(systemName: "chevron.down")
                            .font(.system(.caption, weight: .bold))
                            .foregroundStyle(JohanTheme.textTertiary)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    JohanDivergingBar(delta: Double(d.deltaPoints), maxAbs: maxMagnitude, color: color, index: index)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text(open ? "Hides the explanation" : "Shows the explanation"))
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    Text(JohanL10n.engine(d.verdict).capitalizedFirst)
                        .font(JohanTheme.Fonts.body)
                        .foregroundStyle(JohanTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let metric = Self.metric(forDriver: d.label) {
                        detailLink(metric, title: String(localized: "Show trend"))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    /// The catalogue metric behind each engine driver (the labels are the engine's fixed English keys).
    /// A driver without an entry here simply shows no trend link.
    static func metric(forDriver label: String) -> MetricDescriptor? {
        let key: String
        switch label {
        case "Heart rate variability": key = "hrv"
        case "Resting heart rate": key = "rhr"
        case "Sleep quality": key = "sleep_performance"
        case "Respiratory rate": key = "resp_rate"
        case "Skin temperature": key = "skin_temp"
        default: return nil
        }
        return MetricCatalog.metric(key: key, source: "my-whoop")
    }

    /// A small "→ trend" link pushing one metric's full detail inside this sheet's own stack.
    private func detailLink(_ metric: MetricDescriptor, title: String) -> some View {
        NavigationLink { MetricDetailView(metric: metric) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line").font(.system(.caption, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title).font(.system(.footnote, weight: .semibold))
                Image(systemName: "chevron.right").font(.system(.caption2, weight: .bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(JohanTheme.strainBlue)
            .contentShape(Rectangle())
        }
        .buttonStyle(JohanPressStyle())
    }

    // MARK: Correlations

    /// Recovery's own trend and drivers already have their place above; this card shows what ELSE moved
    /// with it over the last month, through the metric detail's own scan (`MetricCorrelationScan`), and
    /// opens that detail for the full list.
    private var correlationsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            JohanOverline(String(localized: "Moves with your recovery"))
            JohanCard {
                VStack(alignment: .leading, spacing: 12) {
                    if let hits = correlations {
                        if hits.isEmpty {
                            Text("Nothing else moved clearly with your recovery over the last 30 days.")
                                .font(JohanTheme.Fonts.caption)
                                .foregroundStyle(JohanTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(hits, id: \.metric.id) { hit in correlationRow(hit) }
                            Text("Last 30 days, besides the factors above. Moving together is not cause and effect.")
                                .font(JohanTheme.Fonts.caption)
                                .foregroundStyle(JohanTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Scanning your data…").font(JohanTheme.Fonts.caption)
                                .foregroundStyle(JohanTheme.textSecondary)
                        }
                    }
                    if let recoveryMetric = MetricCatalog.metric(key: "recovery", source: "my-whoop") {
                        detailLink(recoveryMetric, title: String(localized: "Recovery trend and all correlations"))
                    }
                }
            }
        }
    }

    private func correlationRow(_ hit: MetricCorrelationScan.Hit) -> some View {
        let up = hit.r >= 0
        let color = up ? JohanTheme.recoveryGreen : JohanTheme.recoveryRed
        return HStack(spacing: 10) {
            Image(systemName: hit.metric.icon)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(JohanTheme.textSecondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.metric.title).font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(JohanTheme.textPrimary)
                Text(up ? String(localized: "Higher when your recovery is higher")
                        : String(localized: "Higher when your recovery is lower"))
                    .font(JohanTheme.Fonts.caption).foregroundStyle(JohanTheme.textSecondary)
            }
            Spacer(minLength: 8)
            Text("\(up ? "+" : "−")\(String(format: "%.2f", abs(hit.r)))")
                .font(.system(.subheadline, design: .rounded, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }

    /// The month window the metric detail opens on, minus recovery itself and the metrics its drivers
    /// already show, top two by |r|.
    private func scanCorrelations() async {
        guard let recoveryMetric = MetricCatalog.metric(key: "recovery", source: "my-whoop"),
              let all = await repo.exploreAllSeries() else { return }
        let own = all[recoveryMetric.id] ?? []
        let excluded: Set<String> = ["recovery", "hrv", "rhr", "resp_rate", "skin_temp", "sleep_performance", "spo2"]
        let others = MetricCatalog.all.compactMap { m -> (metric: MetricDescriptor, series: [(day: String, value: Double)])? in
            guard !excluded.contains(m.key), let s = all[m.id], !s.isEmpty else { return nil }
            return (m, s)
        }
        guard !Task.isCancelled else { return }
        correlations = MetricCorrelationScan.top(windowed: MetricCorrelationScan.trailing(own, range: .month),
                                                 others: others, limit: 2)
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

    // MARK: Trend

    /// The last two weeks as zone-coloured bars with the shown day lit, the average as a dashed line.
    /// Touching a bar reads out that day.
    private var trendCard: some View {
        let values = trend.compactMap(\.recovery)
        let avg = values.reduce(0, +) / Double(max(values.count, 1))
        let picked = pickedTrendIndex.flatMap { trend.indices.contains($0) ? trend[$0] : nil }
        return JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    JohanOverline(String(localized: "Last 2 weeks"))
                    Spacer()
                    Group {
                        if let picked, let rec = picked.recovery {
                            Text("\(Self.dayLabel(picked.key)) · \(Int(rec.rounded())) %")
                                .foregroundStyle(JohanTheme.RecoveryZone(rec).color)
                        } else {
                            Text("Ø \(Int(avg.rounded())) %").foregroundStyle(JohanTheme.textSecondary)
                        }
                    }
                    .font(.system(.footnote, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: pickedTrendIndex)
                }
                JohanTrendBars(days: trend, average: avg, picked: $pickedTrendIndex)
                    .frame(height: 96)
            }
        }
    }

    private static func dayLabel(_ key: String) -> String {
        guard let date = JohanHomeModel.keyParser.date(from: key) else { return key }
        return date.formatted(.dateTime.weekday(.abbreviated).day().locale(AppLanguage.activeLocale))
    }
}

/// Half of the balance bar: a capsule that grows from the centre outwards to `fraction` of its side.
private struct JohanTugBar: View {
    let fraction: Double
    let color: Color
    let fromTrailing: Bool
    let index: Int
    @State private var grown = false
    private let motion = JohanStill()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: fromTrailing ? .trailing : .leading) {
                Capsule().fill(JohanTheme.track)
                Capsule().fill(color)
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, fraction))) * (grown || motion.isStill ? 1 : 0))
                    .shadow(color: color.opacity(0.5), radius: grown ? 5 : 0)
            }
        }
        .onAppear {
            guard !motion.isStill else { return }
            withAnimation(.spring(response: 0.8, dampingFraction: 0.72).delay(0.25 + Double(index) * 0.12)) { grown = true }
        }
        .accessibilityHidden(true)
    }
}

/// Recovery bars for the trend card. Each bar takes its zone colour; the last (the shown day) is lit and
/// the others dimmed, a dashed line marks the average, and a drag across the bars picks a day.
private struct JohanTrendBars: View {
    let days: [JohanRecoveryDetail.TrendDay]
    let average: Double
    @Binding var picked: Int?
    @State private var grown = false
    private let motion = JohanStill()

    var body: some View {
        GeometryReader { geo in
            let count = max(days.count, 1)
            let slot = geo.size.width / CGFloat(count)
            let barW = max(4, slot * 0.56)
            let plotH = geo.size.height - 16
            // Scale to the fortnight's own range so a run of middling days still reads, not 0–100.
            let top = max(60, (days.compactMap(\.recovery).max() ?? 100) * 1.15)
            ZStack(alignment: .bottomLeading) {
                // Average line.
                Path { p in
                    let y = plotH * (1 - CGFloat(average / top))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                .stroke(JohanTheme.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                ForEach(days.indices, id: \.self) { i in
                    let day = days[i]
                    let isShown = i == days.count - 1
                    let isPicked = picked == i
                    VStack(spacing: 4) {
                        Spacer(minLength: 0)
                        if let rec = day.recovery {
                            Capsule()
                                .fill(JohanTheme.RecoveryZone(rec).color)
                                .frame(width: barW, height: max(barW, plotH * CGFloat(min(1, rec / top)) * (grown || motion.isStill ? 1 : 0.02)))
                                .opacity(isShown || isPicked ? 1 : (picked == nil ? 0.45 : 0.3))
                                .animation(motion.isStill ? nil : JohanTheme.Motion.barGrow.delay(Double(i) * 0.035), value: grown)
                        } else {
                            Capsule().fill(JohanTheme.track).frame(width: barW, height: barW)
                        }
                        Text(Self.initial(day.key))
                            .font(.system(size: 9, weight: isShown ? .bold : .medium))
                            .foregroundStyle(isShown ? JohanTheme.textPrimary : JohanTheme.textTertiary)
                            .frame(height: 12)
                    }
                    .frame(width: slot, height: geo.size.height)
                    .offset(x: slot * CGFloat(i))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let i = min(days.count - 1, max(0, Int(v.location.x / slot)))
                    if picked != i, days[i].recovery != nil {
                        StrandHaptic.selection.play()
                        withAnimation(.snappy) { picked = i }
                    }
                }
                .onEnded { _ in withAnimation(.snappy.delay(1.2)) { picked = nil } })
        }
        .onAppear { grown = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Recovery, last 2 weeks"))
        .accessibilityValue(Text(days.compactMap { $0.recovery.map { "\(Int($0.rounded())) %" } }.joined(separator: ", ")))
    }

    private static func initial(_ key: String) -> String {
        guard let date = JohanHomeModel.keyParser.date(from: key) else { return "" }
        return date.formatted(.dateTime.weekday(.narrow).locale(AppLanguage.activeLocale))
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Engine strings (driver labels, verdicts) are English keys in the app's string catalogue, built at
/// runtime, so they are looked up by key in the language the app launched with.
enum JohanL10n {
    static func engine(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }
}
#endif
