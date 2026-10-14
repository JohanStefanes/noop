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
    /// sits beside this strap's charge. Fitted on the strap's STORED battery series (`history`), not on
    /// `live.batteryEstimate`: that one only sees readings banked since the app last launched, so every
    /// update restarted it on a few hours of noise and it read a 12-day strap as lasting four.
    func estimate(history: [(ts: Int, soc: Double)]) -> BatteryEstimator.Estimate? {
        guard let pct = battery else { return nil }
        return JohanRuntime.estimate(history: history.isEmpty ? [(Int(Date().timeIntervalSince1970), pct)] : history,
                                     ratedHours: live.batteryRatedHours)
    }

    var statusColor: Color {
        if !live.connected { return JohanTheme.textTertiary }
        return live.lastSyncError != nil ? JohanTheme.recoveryYellow : JohanTheme.recoveryGreen
    }

    func batteryColor(_ pct: Double) -> Color {
        if charging { return JohanTheme.recoveryGreen }
        switch level(pct) {
        case .critical: return JohanTheme.recoveryRed
        case .low: return JohanTheme.recoveryYellow
        case .good, .full: return JohanTheme.recoveryGreen
        }
    }

    /// What a charge means, on the same 15 / 30 cut-offs as `batteryColor`, so the pill's word and the
    /// ring's colour cannot disagree.
    enum Level {
        case critical, low, good, full

        var text: String {
            switch self {
            case .critical: return String(localized: "Very low · charge now")
            case .low: return String(localized: "Low · charge soon")
            case .good: return String(localized: "Good charge")
            case .full: return String(localized: "Fully charged")
            }
        }

        var symbol: String {
            switch self {
            case .critical: return "battery.0percent"
            case .low: return "battery.25percent"
            case .good: return "battery.75percent"
            case .full: return "battery.100percent"
            }
        }
    }

    func level(_ pct: Double) -> Level {
        if pct < 15 { return .critical }
        if pct < 30 { return .low }
        if pct >= 95 { return .full }
        return .good
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
/// number. With no reading yet (or no strap connected) the centre shows the strap glyph instead of a stale
/// figure; whether the link is up is the chip's status dot, not this ring.
///
/// Takes plain VALUES, not `JohanStrapFacts`: the facts wrap the `LiveState` class reference, which SwiftUI
/// compares by identity, so a ring holding them was never re-rendered and kept its first (offline) state
/// beside a status dot that had long turned green.
struct JohanBatteryRing: View {
    let battery: Double?
    let connected: Bool
    let arcColor: Color
    var size: CGFloat
    var lineWidth: CGFloat

    init(facts: JohanStrapFacts, size: CGFloat, lineWidth: CGFloat) {
        battery = facts.battery
        connected = facts.connected
        arcColor = facts.battery.map(facts.batteryColor) ?? JohanTheme.textTertiary
        self.size = size
        self.lineWidth = lineWidth
    }

    var body: some View {
        ZStack {
            Circle().stroke(JohanTheme.textTertiary.opacity(0.35), lineWidth: lineWidth)
            if let pct = battery {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, pct / 100)))
                    .stroke(arcColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(JohanTheme.Motion.daySlide, value: pct)
                Text("\(Int(pct.rounded()))")
                    .font(JohanTheme.number(size * 0.34))
                    .foregroundStyle(JohanTheme.textPrimary)
                    .minimumScaleFactor(0.6)
            } else {
                JohanStrapGlyph(color: connected ? JohanTheme.textPrimary : JohanTheme.textTertiary,
                                lineWidth: max(1.2, size * 0.035))
                    .frame(width: size * 0.56, height: size * 0.56)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A generic wrist strap in a cartoon three-quarter view: the sensor pod (with its depth, a clasp plate and
/// a side button) in front of the band's loop, drawn in the line style of the SF Symbols around it. Drawn
/// rather than taken from an asset, so no vendor artwork or logo ships with the app.
struct JohanStrapGlyph: View {
    /// Stands in for an SF Symbol name where a row takes one (the More tab's Devices row).
    static let iconName = "johan.strap"

    var color: Color
    var lineWidth: CGFloat

    var body: some View {
        Canvas { gc, size in
            let s = min(size.width, size.height) / 100
            gc.translateBy(x: (size.width - 100 * s) / 2, y: (size.height - 100 * s) / 2)
            gc.scaleBy(x: s, y: s)
            let lw = lineWidth / s
            let stroke = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
            func ellipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ deg: Double) -> Path {
                Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
                    .applying(CGAffineTransform(rotationAngle: deg * .pi / 180).concatenating(.init(translationX: c.x, y: c.y)))
            }
            func rounded(_ r: CGRect, _ corner: CGFloat, _ deg: Double) -> Path {
                let c = CGPoint(x: r.midX, y: r.midY)
                return Path(roundedRect: r.offsetBy(dx: -c.x, dy: -c.y), cornerRadius: corner, style: .continuous)
                    .applying(CGAffineTransform(rotationAngle: deg * .pi / 180).concatenating(.init(translationX: c.x, y: c.y)))
            }
            // Band: a thick loop seen at three-quarters, wider on the far side.
            let outer = ellipse(CGPoint(x: 59, y: 51), 37, 43, -12)
            let inner = ellipse(CGPoint(x: 63, y: 52), 26, 34, -12)
            var band = outer; band.addPath(inner)
            gc.fill(band, with: .color(color.opacity(0.22)), style: FillStyle(eoFill: true))
            gc.stroke(outer, with: .color(color), style: stroke)
            gc.stroke(inner, with: .color(color), style: stroke)
            // Pod: its depth first (offset copy), then the face, each clearing the band beneath it.
            let tilt = -9.0
            let face = CGRect(x: 9, y: 11, width: 38, height: 78)
            let depth = rounded(face.offsetBy(dx: 6, dy: 2), 14, tilt)
            let front = rounded(face, 14, tilt)
            for p in [depth, front] {
                gc.blendMode = .clear
                gc.fill(p, with: .color(.black))
                gc.blendMode = .normal
                gc.fill(p, with: .color(color.opacity(p == depth ? 0.30 : 0.12)))
                gc.stroke(p, with: .color(color), style: stroke)
            }
            // Clasp plate across the bottom of the face, and the side button on the depth edge.
            let rot = CGAffineTransform(rotationAngle: tilt * .pi / 180)
            let fc = CGPoint(x: face.midX, y: face.midY)
            func onFace(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x - fc.x, y: y - fc.y).applying(rot).applying(.init(translationX: fc.x, y: fc.y))
            }
            var plate = Path()
            plate.move(to: onFace(face.minX + 1, 68)); plate.addLine(to: onFace(face.maxX - 1, 68))
            gc.stroke(plate, with: .color(color), style: stroke)
            var dot = Path()
            dot.move(to: onFace(face.midX - 4, 78)); dot.addLine(to: onFace(face.midX + 4, 78))
            gc.stroke(dot, with: .color(color.opacity(0.7)), style: stroke)
            var button = Path()
            button.move(to: onFace(face.maxX + 6, 34)); button.addLine(to: onFace(face.maxX + 6, 46))
            gc.stroke(button, with: .color(color), style: StrokeStyle(lineWidth: lw * 1.5, lineCap: .round))
        }
        .aspectRatio(1, contentMode: .fit)
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

/// Strap page opened from the Home header: battery, runtime, connection, sync and the strap's identity,
/// each fact through `JohanStrapFacts`. Device management itself stays on the original Devices screen.
///
/// Each fact is shown once: the charge is the number in the orb, the runtime estimate lives only in the
/// runtime card, so no headline repeats either of them.
struct JohanStrapView: View {
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var router: NavRouter
    @EnvironmentObject private var repo: Repository
    /// Bumped by a tap on the orb: the arc, the liquid and the number run their entrance again.
    @State private var replay = 0
    /// The active strap's stored SoC series for the runtime estimate; nil until the first read lands.
    @State private var batteryHistory: [(ts: Int, soc: Double)]?

    var body: some View {
        let facts = JohanStrapFacts(live: live)
        JohanScreen(title: String(localized: "Strap")) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: JohanTheme.Metrics.cardSpacing) {
                    batteryHero(facts).johanStagger(0)
                    if let pct = facts.battery, let history = batteryHistory, !facts.charging,
                       let est = facts.estimate(history: history) {
                        JohanRuntimeCard(estimate: est, battery: pct, tint: facts.batteryColor(pct),
                                         now: context.date)
                            .johanStagger(1)
                    }
                    statusCard(facts, now: context.date).johanStagger(2)
                    if live.connected { detailsCard.johanStagger(3) }
                    manageButton.johanStagger(4)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // Re-read when a new reading arrives (the % moves) and at least every ten minutes.
        .task(id: "\(live.batteryPct ?? -1)|\(Int(Date().timeIntervalSince1970) / 600)") {
            await loadBatteryHistory()
        }
    }

    private func loadBatteryHistory() async {
        guard let store = await repo.storeHandle() else { batteryHistory = []; return }
        let now = Int(Date().timeIntervalSince1970)
        let rows = (try? await store.batterySamples(deviceId: repo.deviceId,
                                                    from: now - JohanRuntime.historyDays * 86_400,
                                                    to: now, limit: 5_000)) ?? []
        batteryHistory = rows.compactMap { row in row.soc.map { (ts: row.ts, soc: $0) } }
    }

    // MARK: Battery

    private func batteryHero(_ facts: JohanStrapFacts) -> some View {
        let tint = facts.battery.map(facts.batteryColor) ?? JohanTheme.textTertiary
        return VStack(spacing: 18) {
            ZStack {
                if facts.battery != nil { JohanAmbientGlow(color: tint, size: 300) }
                JohanBatteryOrb(battery: facts.battery, connected: facts.connected, charging: facts.charging,
                                tint: tint, replay: replay, size: 220)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 236)
            .contentShape(Rectangle())
            .onTapGesture {
                guard facts.battery != nil else { return }
                StrandHaptic.selection.play()
                replay += 1
            }
            if let pct = facts.battery {
                JohanBatteryBadge(level: facts.level(pct), charging: facts.charging, tint: tint)
            } else {
                VStack(spacing: 6) {
                    Text(facts.connected ? String(localized: "Waiting for battery reading")
                                         : String(localized: "Not connected"))
                        .font(JohanTheme.Fonts.title)
                        .foregroundStyle(JohanTheme.textPrimary)
                    if !facts.connected {
                        Text("Battery and sync appear once the strap is in range.")
                            .font(.system(.subheadline))
                            .foregroundStyle(JohanTheme.textSecondary)
                    }
                }
                .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: Status

    private func statusCard(_ facts: JohanStrapFacts, now: Date) -> some View {
        JohanCard(padding: 0) {
            VStack(spacing: 0) {
                row(String(localized: "Connection"), "dot.radiowaves.left.and.right") {
                    HStack(spacing: 8) {
                        JohanLiveDot(color: facts.statusColor, pulsing: facts.connected)
                        Text(facts.connectionText).contentTransition(.opacity)
                    }
                }
                if live.connected {
                    divider
                    row(String(localized: "Wear"), live.worn ? "hand.raised.fill" : "hand.raised") {
                        Text(live.worn ? String(localized: "On wrist") : String(localized: "Off wrist"))
                            .contentTransition(.opacity)
                    }
                    if let hr = live.heartRate {
                        divider
                        row(String(localized: "Heart rate"), icon: { JohanPulsingHeart(bpm: hr, size: 15) }) {
                            Text("\(hr) bpm")
                                .contentTransition(.numericText(value: Double(hr)))
                                .animation(.snappy, value: hr)
                        }
                    }
                }
                divider
                row(String(localized: "Last sync"), icon: {
                    JohanSyncGlyph(syncing: live.backfilling, lastSyncedAt: live.lastSyncedAt)
                }) {
                    if let sync = facts.syncText(now: now) {
                        Text(sync.text)
                            .foregroundStyle(sync.isProblem ? JohanTheme.recoveryYellow : JohanTheme.textSecondary)
                            .contentTransition(.opacity)
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
                if let name = live.advertisingName {
                    row(String(localized: "Name"), "tag") { Text(name) }
                    divider
                }
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
            HStack(spacing: 12) {
                JohanStrapGlyph(color: JohanTheme.textSecondary, lineWidth: 1.6)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text("Manage devices")
                Spacer()
                Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(JohanTheme.textTertiary)
            }
            .font(.system(.body))
            .foregroundStyle(JohanTheme.textPrimary)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: JohanTheme.Metrics.cardRadius, style: .continuous)
                    .fill(JohanTheme.card)
                    .overlay(RoundedRectangle(cornerRadius: JohanTheme.Metrics.cardRadius, style: .continuous)
                        .strokeBorder(JohanTheme.cardBorder, lineWidth: 0.5))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(JohanPressStyle())
    }

    // MARK: Rows

    private var divider: some View {
        Divider().overlay(JohanTheme.cardBorder).padding(.leading, 16 + 24 + 12)
    }

    private func row<Value: View>(_ title: String, _ icon: String, @ViewBuilder value: () -> Value) -> some View {
        row(title, icon: {
            Image(systemName: icon)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(JohanTheme.textSecondary)
                .contentTransition(.symbolEffect(.replace))
        }, value: value)
    }

    private func row<Icon: View, Value: View>(_ title: String, @ViewBuilder icon: () -> Icon,
                                              @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 12) {
            icon()
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

// MARK: - Battery orb

/// The strap page's battery hero: a ring whose arc sweeps to the charge with a glowing tip, and inside it
/// a liquid that fills to the same level, sloshes as it lands and keeps a slow wave going. While charging,
/// bubbles rise through the liquid and the wave runs faster. A new `replay` value empties and refills it.
/// With no reading, the ring is an empty track around the strap glyph.
struct JohanBatteryOrb: View {
    let battery: Double?
    let connected: Bool
    let charging: Bool
    let tint: Color
    let replay: Int
    let size: CGFloat

    @State private var progress = 0.0
    @State private var fill = 0.0
    @State private var lastReplay: Int?
    private let motion = JohanStill()

    private struct SweepKey: Equatable { let replay: Int; let target: Double? }

    var body: some View {
        let lw = size * 0.055
        let ringRadius = (size - lw) / 2
        let liquidDiameter = size - lw * 2 - size * 0.07
        ZStack {
            Circle().stroke(JohanTheme.track, lineWidth: lw)
            if let battery {
                Circle()
                    .fill(tint.opacity(0.06))
                    .frame(width: liquidDiameter, height: liquidDiameter)
                liquid(diameter: liquidDiameter)
                Circle()
                    .trim(from: 0, to: max(0.001, progress))
                    .stroke(AngularGradient(colors: [tint.opacity(0.35), tint], center: .center),
                            style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(progress > 0.001 ? 1 : 0)
                // The tip: a bright bead riding the end of the arc.
                Circle()
                    .fill(Color.white)
                    .frame(width: lw * 0.42, height: lw * 0.42)
                    .shadow(color: tint, radius: 6)
                    .shadow(color: tint.opacity(0.8), radius: 14)
                    .offset(y: -ringRadius)
                    .rotationEffect(.degrees(360 * progress))
                    .opacity(progress > 0.02 ? 1 : 0)
                centre(battery)
            } else {
                JohanStrapGlyph(color: connected ? JohanTheme.textPrimary : JohanTheme.textTertiary,
                                lineWidth: max(1.5, size * 0.022))
                    .frame(width: size * 0.42, height: size * 0.42)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery"))
        .accessibilityValue(Text(accessibilityValue))
        .task(id: SweepKey(replay: replay, target: battery)) { await sweep() }
    }

    private var accessibilityValue: String {
        guard let battery else { return String(localized: "no value") }
        let pct = String(localized: "\(Int(battery.rounded())) %")
        return charging ? pct + ", " + String(localized: "Charging") : pct
    }

    private func centre(_ battery: Double) -> some View {
        VStack(spacing: 0) {
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: size * 0.09, weight: .bold))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: !motion.isStill)
                    .transition(.scale.combined(with: .opacity))
            }
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                CountUpText(value: battery, format: { "\(Int($0.rounded()))" },
                            font: JohanTheme.number(size * 0.30),
                            color: JohanTheme.textPrimary,
                            animation: JohanTheme.Motion.countUp)
                    .id(replay)
                Text("%")
                    .font(JohanTheme.number(size * 0.11))
                    .foregroundStyle(JohanTheme.textSecondary)
            }
            .shadow(color: .black.opacity(0.35), radius: 6)
        }
        .animation(JohanTheme.Motion.cardIn, value: charging)
    }

    /// Two offset sine waves (and, while charging, rising bubbles) drawn per frame. The wave drawing sits
    /// at the top of a slightly taller canvas, and the canvas is slid down by the unfilled share, so the
    /// level itself is an ordinary animatable offset that springs independently of the wave's phase.
    private func liquid(diameter d: CGFloat) -> some View {
        let amp = d * 0.032
        let charging = charging
        let tint = tint
        return TimelineView(.animation(paused: motion.isStill)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { gc, sz in
                let speed = charging ? 2.6 : 1.0
                let back = Self.wave(sz, surface: amp, amp: amp * 0.8, cycles: 1.4, phase: t * 1.7 * speed)
                gc.fill(back, with: .color(tint.opacity(0.16)))
                let front = Self.wave(sz, surface: amp, amp: amp, cycles: 1.0, phase: -t * 1.15 * speed + 1.3)
                gc.fill(front, with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.42), tint.opacity(0.14)]),
                    startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: sz.height)))
                guard charging else { return }
                for i in 0..<8 {
                    let seed = Double(i)
                    let period = 2.0 + Self.hash(seed * 3.1) * 1.6
                    let rise = (t / period + seed / 8).truncatingRemainder(dividingBy: 1)
                    let r = 1.6 + Self.hash(seed * 7.7) * 2.6
                    let x = sz.width * (0.18 + 0.64 * Self.hash(seed)) + sin(t * 2.2 + seed) * 4
                    let y = sz.height - rise * (sz.height - amp * 2)
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    gc.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.55 * (1 - rise))))
                }
            }
        }
        .frame(width: d, height: d + amp * 2)
        .offset(y: (1 - fill) * d - amp)
        .frame(width: d, height: d, alignment: .top)
        .clipShape(Circle())
        .allowsHitTesting(false)
    }

    private static func wave(_ sz: CGSize, surface: CGFloat, amp: CGFloat, cycles: Double, phase: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: sz.height))
        for x in stride(from: 0, through: sz.width, by: 2) {
            let rel = Double(x / sz.width)
            p.addLine(to: CGPoint(x: x, y: surface + amp * CGFloat(sin(rel * 2 * .pi * cycles + phase))))
        }
        p.addLine(to: CGPoint(x: sz.width, y: sz.height))
        p.closeSubpath()
        return p
    }

    /// Deterministic 0..<1 noise, so each bubble keeps its own lane, size and pace across frames.
    private static func hash(_ v: Double) -> Double {
        let s = sin(v * 12.9898 + 78.233) * 43758.5453
        return s - s.rounded(.down)
    }

    @MainActor private func sweep() async {
        let target = max(0, min(1, (battery ?? 0) / 100))
        if motion.isStill { progress = target; fill = target; lastReplay = replay; return }
        if lastReplay != replay {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { progress = 0; fill = 0 }
            lastReplay = replay
        }
        let from = progress
        withAnimation(JohanTheme.Motion.dialSweep) { progress = target }
        withAnimation(JohanTheme.Motion.liquidFill) { fill = target }
        guard battery != nil, abs(target - from) > 0.05 else { return }
        try? await Task.sleep(for: .seconds(JohanTheme.Motion.dialSettle))
        if !Task.isCancelled { StrandHaptic.light.play() }
    }
}

/// The one-line verdict under the orb: what the charge means (or that it is charging) in a tinted pill.
struct JohanBatteryBadge: View {
    let level: JohanStrapFacts.Level
    let charging: Bool
    let tint: Color
    private let motion = JohanStill()

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: charging ? "bolt.fill" : level.symbol)
                .font(.system(.subheadline, weight: .semibold))
                .symbolEffect(.pulse, isActive: charging && !motion.isStill)
                .contentTransition(.symbolEffect(.replace))
            Text(charging ? String(localized: "Charging") : level.text)
                .font(.system(.subheadline, weight: .semibold))
                .contentTransition(.opacity)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
        .animation(JohanTheme.Motion.cardIn, value: charging)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Runtime

/// Runtime left as a row of day cells: one cell per day a full charge lasts at the current drain, lit up to
/// the days that remain, the last one partly. The cells fill one after another on appear.
struct JohanRuntimeCard: View {
    let estimate: BatteryEstimator.Estimate
    let battery: Double
    let tint: Color
    let now: Date

    @State private var shown = false
    private let motion = JohanStill()

    var body: some View {
        let hours = estimate.remainingHours
        let fullDays = hours / max(0.05, battery / 100) / 24
        let cells = max(1, min(14, Int(fullDays.rounded(.up))))
        let litDays = hours / 24
        JohanCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    JohanOverline(String(localized: "Runtime"))
                    Spacer()
                    Text(estimate.source == .measured ? String(localized: "From your recent drain")
                                                      : String(localized: "From rated capacity"))
                        .font(JohanTheme.Fonts.caption)
                        .foregroundStyle(JohanTheme.textTertiary)
                }
                Text(Self.remainingText(hours))
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundStyle(JohanTheme.textPrimary)
                HStack(spacing: cells > 10 ? 3 : 5) {
                    ForEach(0..<cells, id: \.self) { i in
                        let lit = max(0, min(1, litDays - Double(i)))
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(JohanTheme.track)
                                Capsule()
                                    .fill(tint)
                                    .frame(width: g.size.width * (shown ? lit : 0))
                                    .shadow(color: tint.opacity(shown && lit > 0 ? 0.6 : 0), radius: 4)
                            }
                        }
                        .frame(height: 10)
                        .animation(motion.isStill ? nil
                                   : JohanTheme.Motion.cardIn.delay(0.3 + Double(i) * JohanTheme.Motion.cellStagger),
                                   value: shown)
                    }
                }
                .accessibilityHidden(true)
                HStack {
                    Text(String(localized: "Empty around \(Self.emptyText(now.addingTimeInterval(hours * 3600), now: now))"))
                    Spacer(minLength: 8)
                    Text(String(localized: "Full charge ≈ \(Int(fullDays.rounded())) d"))
                }
                .font(JohanTheme.Fonts.body)
                .foregroundStyle(JohanTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .onAppear { shown = true }
    }

    static func remainingText(_ hours: Double) -> String {
        if hours < 24 { return String(localized: "About \(Int(hours.rounded())) h left") }
        return String(localized: "About \(Int((hours / 24).rounded())) days left")
    }

    /// Weekday and hour within the coming week ("Saturday 6 PM"); past that a weekday is ambiguous, so the
    /// date ("26 Oct").
    private static func emptyText(_ date: Date, now: Date) -> String {
        let style = Date.FormatStyle(locale: AppLanguage.activeLocale)
        return date.timeIntervalSince(now) < 6 * 86_400
            ? date.formatted(style.weekday(.wide).hour())
            : date.formatted(style.day().month(.abbreviated))
    }
}

/// Runtime from the stored battery series. `BatteryEstimator` trusts a measured slope after 2 h and a 2 %
/// drop, which the in-memory series hits on its first noisy readings; on a 12-day strap that is a few
/// tenths of a percent of real discharge. Here a measured slope must also span `minMeasuredSpanHours`
/// since the last charge, else the generation's rated life stands in.
enum JohanRuntime {
    static let historyDays = 14
    static let minMeasuredSpanHours: Double = 12

    static func estimate(history: [(ts: Int, soc: Double)], ratedHours: Double) -> BatteryEstimator.Estimate? {
        let sorted = history.sorted { $0.ts < $1.ts }
        guard let last = sorted.last,
              let fitted = BatteryEstimator.estimate(samples: sorted, ratedHours: ratedHours) else { return nil }
        guard fitted.source == .measured else { return fitted }
        var start = 0
        for i in stride(from: sorted.count - 1, through: 1, by: -1)
        where sorted[i].soc > sorted[i - 1].soc + BatteryEstimator.chargeStepPct {
            start = i
            break
        }
        let spanHours = Double(last.ts - sorted[start].ts) / 3600
        if spanHours >= minMeasuredSpanHours { return fitted }
        // One sample cannot fit a slope, so the estimator falls back to the rated life.
        return BatteryEstimator.estimate(samples: [last], ratedHours: ratedHours)
    }
}

// MARK: - Small live glyphs

/// Status dot with a sonar ping while `pulsing` (the link is up). Static under the motion gate.
struct JohanLiveDot: View {
    let color: Color
    let pulsing: Bool
    @State private var ping = false
    private let motion = JohanStill()

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .background(
                Circle()
                    .stroke(color, lineWidth: 1.5)
                    .scaleEffect(ping ? 2.8 : 1)
                    .opacity(ping ? 0 : 0.7)
            )
            .animation(.easeInOut(duration: 0.3), value: color)
            .task(id: pulsing && !motion.isStill) {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { ping = false }
                guard pulsing, !motion.isStill else { return }
                try? await Task.sleep(for: .milliseconds(400))
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { ping = true }
            }
    }
}

/// Sync arrows that spin while an offload runs and bounce once each time a sync lands.
struct JohanSyncGlyph: View {
    let syncing: Bool
    let lastSyncedAt: Double?
    @State private var spin = false
    private let motion = JohanStill()

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(syncing ? JohanTheme.strainBlue : JohanTheme.textSecondary)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .symbolEffect(.bounce, value: motion.isStill ? nil : lastSyncedAt)
            .task(id: syncing && !motion.isStill) {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { spin = false }
                guard syncing, !motion.isStill else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}
#endif
