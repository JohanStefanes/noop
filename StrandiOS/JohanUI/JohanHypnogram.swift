#if os(iOS)
import SwiftUI
import StrandDesign

/// The night as a staircase: each stage a coloured bar on its own level (Wake on top, Deep at the bottom),
/// thin risers where the night changes level, hour marks underneath and the moments of falling asleep and
/// waking flagged above, so the shape of the night reads at a glance.
///
/// A real night arrives as dozens of short runs. Drawn at a phone's width they crowd into a comb, so the
/// chart absorbs every run narrower than `minBarWidth` points into its neighbours, whatever the night's
/// length (never less than five minutes). That is display only: the stage totals and the phase list keep
/// the raw timeline, and the phase list is where the short stretches stay readable.
///
/// Draws `intervals` (seconds after `nightStart`) across `nightStart ... nightEnd`, the same span the card
/// names as "Fell asleep" and "Woke up", so its flags can never disagree with those figures. Brief
/// fragments are absorbed for display only (`Hypnogram.displaySmoothed`); the stage totals and the phase
/// list keep the raw timeline.
///
/// Interactive: a tap or a press-and-drag (`touchScrub`) marks a moment, and the line under the chart names
/// the RAW phase at that moment (`JohanSleepPhases`) with its clock times and length, so a stretch the
/// display absorbed can still be read. `highlightedStage` dims every other stage.
struct JohanHypnogram: View {
    let intervals: [SleepInterval]
    let nightStart: Date
    let nightEnd: Date
    var height: CGFloat = 200
    /// The marked moment, in seconds after `nightStart`. Owned by the caller so a phase list can set it.
    var selectedTime: Binding<TimeInterval?> = .constant(nil)
    /// A stage to bring forward; the others are drawn faintly.
    var highlightedStage: SleepStage?

    @State private var reveal = 0.0
    private let motion = JohanStill()

    /// Top to bottom, the order the levels are drawn in.
    private static let levels: [SleepStage] = [.awake, .rem, .light, .deep]
    private static let axisWidth: CGFloat = 46
    private static let flagHeight: CGFloat = 30
    private static let barHeight: CGFloat = 10
    /// The narrowest stage run the chart draws on its own, in points.
    /// Four points keeps every sleep cycle and the early-morning wake-ups of a real nine-hour night (about
    /// twenty bars at phone width); eight merged whole cycles into one bar, five minutes left a comb of 27.
    static let minBarWidth: CGFloat = 4

    private var span: TimeInterval { max(60, nightEnd.timeIntervalSince(nightStart)) }

    /// Shortest run, in seconds, that stays its own bar at `width` points across `span` seconds.
    static func minRunSeconds(span: TimeInterval, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 300 }
        return max(300, span * TimeInterval(minBarWidth / width))
    }

    private func shown(width: CGFloat) -> [SleepInterval] {
        let sorted = intervals.sorted { $0.start < $1.start }
            .map { SleepInterval(stage: $0.stage, start: max(0, $0.start), end: min(span, $0.end)) }
            .filter { $0.end > $0.start }
        return Hypnogram.displaySmoothed(sorted, minDuration: Self.minRunSeconds(span: span, width: width))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                stageAxis
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, size in draw(in: &ctx, size: size) }
                            .frame(width: w, height: height)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: max(0, w * reveal))
                            }
                            .padding(.top, Self.flagHeight)
                        flag(icon: "moon.fill", time: nightStart, x: 0, width: w)
                        flag(icon: "sun.max.fill", time: nightEnd, x: w, width: w)
                        if let t = selectedTime.wrappedValue {
                            selectionRule(x: x(t, w))
                        }
                        // The touch target is the plot only, not the flags above it.
                        Color.clear
                            .frame(width: w, height: height)
                            .touchScrub(x: scrubX(width: w))
                            .padding(.top, Self.flagHeight)
                    }
                }
                .frame(height: height + Self.flagHeight)
            }
            hourAxis
                .padding(.leading, Self.axisWidth + 8)
            readout
                .padding(.top, 4)
        }
        .onAppear {
            guard reveal == 0 else { return }
            if motion.isStill { reveal = 1 } else { withAnimation(.easeOut(duration: 0.9)) { reveal = 1 } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Sleep stages from \(timeText(nightStart)) to \(timeText(nightEnd))"))
        .accessibilityValue(selectedPhase.map(phaseSentence) ?? "")
    }

    // MARK: Selection

    /// The finger's x, kept as a time so the mark stays on its moment when the width changes.
    private func scrubX(width w: CGFloat) -> Binding<CGFloat?> {
        Binding(
            get: { selectedTime.wrappedValue.map { x($0, w) } },
            set: { newX in
                selectedTime.wrappedValue = newX.map { min(span, max(0, TimeInterval($0 / max(1, w)) * span)) }
            })
    }

    /// The raw phase under the marked moment, or the nearest one when the moment falls in a gap.
    private var selectedPhase: JohanSleepPhases.Phase? {
        guard let t = selectedTime.wrappedValue else { return nil }
        let phases = JohanSleepPhases.phases(intervals)
        return phases.first { t >= $0.start && t < $0.end }
            ?? phases.min { min(abs($0.start - t), abs($0.end - t)) < min(abs($1.start - t), abs($1.end - t)) }
    }

    private func selectionRule(x: CGFloat) -> some View {
        Rectangle()
            .fill(JohanTheme.textPrimary.opacity(0.8))
            .frame(width: 1.5, height: height)
            .offset(x: x - 0.75, y: Self.flagHeight)
            .allowsHitTesting(false)
    }

    /// One line under the chart: the marked phase, or how to mark one.
    @ViewBuilder private var readout: some View {
        Group {
            if let phase = selectedPhase {
                HStack(spacing: 8) {
                    Circle().fill(JohanTheme.stageColor(phase.stage)).frame(width: 8, height: 8)
                    Text(name(phase.stage)).font(.system(.subheadline, weight: .semibold))
                    Text("\(clock(phase.start)) – \(clock(phase.end))")
                        .font(.system(.subheadline).monospacedDigit())
                        .foregroundStyle(JohanTheme.textSecondary)
                    Spacer(minLength: 8)
                    Text(JohanSleepText.phaseDuration(phase.minutes))
                        .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                }
            } else {
                Label("Tap or slide along the chart to see each phase.", systemImage: "hand.tap")
                    .font(.system(.caption))
                    .foregroundStyle(JohanTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .padding(.leading, Self.axisWidth + 8)
        .accessibilityHidden(true)
    }

    private func clock(_ offset: TimeInterval) -> String { timeText(nightStart.addingTimeInterval(offset)) }

    private func phaseSentence(_ phase: JohanSleepPhases.Phase) -> String {
        let n = name(phase.stage), from = clock(phase.start), to = clock(phase.end)
        let length = JohanSleepText.phaseDuration(phase.minutes)
        return String(localized: "\(n) from \(from) to \(to), \(length)")
    }

    // MARK: Drawing

    private func rowY(_ stage: SleepStage, _ h: CGFloat) -> CGFloat {
        let i = CGFloat(Self.levels.firstIndex(of: stage) ?? 0)
        let pad = Self.barHeight / 2 + 2
        return pad + i * (h - 2 * pad) / CGFloat(Self.levels.count - 1)
    }

    private func x(_ t: TimeInterval, _ w: CGFloat) -> CGFloat { CGFloat(t / span) * w }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        // Level guides and hour marks, quiet enough to sit behind the night.
        for stage in Self.levels {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: rowY(stage, h)))
            line.addLine(to: CGPoint(x: w, y: rowY(stage, h)))
            ctx.stroke(line, with: .color(JohanTheme.track.opacity(0.7)), lineWidth: 1)
        }
        for hour in hourMarks() {
            var tick = Path()
            let hx = x(hour.timeIntervalSince(nightStart), w)
            tick.move(to: CGPoint(x: hx, y: 0))
            tick.addLine(to: CGPoint(x: hx, y: h))
            ctx.stroke(tick, with: .color(JohanTheme.track.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
        }
        let ivs = shown(width: w)
        // Risers first, so the bars sit on top of them.
        var risers = Path()
        for (a, b) in zip(ivs, ivs.dropFirst()) {
            let rx = x(b.start, w)
            risers.move(to: CGPoint(x: rx, y: rowY(a.stage, h)))
            risers.addLine(to: CGPoint(x: rx, y: rowY(b.stage, h)))
        }
        ctx.stroke(risers, with: .color(JohanTheme.textTertiary.opacity(0.55)), lineWidth: 1)
        for iv in ivs {
            let x0 = x(iv.start, w), x1 = x(iv.end, w)
            let rect = CGRect(x: x0, y: rowY(iv.stage, h) - Self.barHeight / 2,
                              width: max(3, x1 - x0), height: Self.barHeight)
            let faded = highlightedStage.map { $0 != iv.stage } ?? false
            ctx.fill(Path(roundedRect: rect, cornerRadius: Self.barHeight / 2.5),
                     with: .color(JohanTheme.stageColor(iv.stage).opacity(faded ? 0.22 : 1)))
        }
    }

    // MARK: Axes

    private var stageAxis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Color.clear.frame(width: Self.axisWidth, height: Self.flagHeight)
            ZStack(alignment: .topTrailing) {
                ForEach(Self.levels, id: \.rawValue) { stage in
                    Text(name(stage))
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(JohanTheme.stageColor(stage))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(height: 16)
                        .offset(y: rowY(stage, height) - 8)
                }
            }
            .frame(width: Self.axisWidth, height: height, alignment: .topTrailing)
        }
        .accessibilityHidden(true)
    }

    /// Whole hours inside the night; every second one when the night is long, so labels never crowd.
    private func hourMarks() -> [Date] {
        let cal = Calendar.current
        guard var hour = cal.nextDate(after: nightStart, matching: DateComponents(minute: 0, second: 0),
                                      matchingPolicy: .nextTime) else { return [] }
        let step = span > 6 * 3600 ? 2 : 1
        if step == 2, cal.component(.hour, from: hour) % 2 == 1 {
            hour = cal.date(byAdding: .hour, value: 1, to: hour) ?? hour
        }
        var out: [Date] = []
        while hour < nightEnd {
            out.append(hour)
            hour = cal.date(byAdding: .hour, value: step, to: hour) ?? nightEnd
        }
        return out
    }

    private var hourAxis: some View {
        GeometryReader { geo in
            ForEach(hourMarks(), id: \.self) { hour in
                Text(hour.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).locale(AppLanguage.activeLocale)))
                    .font(.system(.caption2).monospacedDigit())
                    .foregroundStyle(JohanTheme.textTertiary)
                    .fixedSize()
                    .position(x: x(hour.timeIntervalSince(nightStart), geo.size.width), y: 7)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    /// The bedtime or wake flag: a small pill with a pointer, held inside the chart's width.
    private func flag(icon: String, time: Date, x: CGFloat, width: CGFloat) -> some View {
        let pillWidth: CGFloat = 76
        let left = min(max(0, x - pillWidth / 2), width - pillWidth)
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(timeText(time)).font(.system(.caption2, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(JohanTheme.textPrimary)
            .frame(width: pillWidth, height: 20)
            .background(Capsule().fill(JohanTheme.track))
            Rectangle().fill(JohanTheme.textTertiary).frame(width: 1, height: 8)
                .offset(x: x - left - pillWidth / 2)
        }
        .frame(width: pillWidth)
        .offset(x: left)
    }

    private func name(_ stage: SleepStage) -> String {
        switch stage {
        case .awake: return String(localized: "Awake")
        case .rem: return "REM"
        case .light: return String(localized: "Light")
        case .deep: return String(localized: "Deep")
        }
    }

    private func timeText(_ d: Date) -> String {
        d.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale))
    }
}
#endif

#if os(iOS)
/// Duration wording shared by the Sleep page and its charts, so a phase reads the same in the list and
/// under the chart.
enum JohanSleepText {
    static func hm(_ minutes: Double) -> String {
        let t = max(0, Int(minutes.rounded()))
        let h = String(t / 60), m = String(t % 60)
        return t >= 60 ? String(localized: "\(h) h \(m) min") : String(localized: "\(m) min")
    }

    /// Under a minute reads in seconds, so a short wake-up is not shown as "0 min".
    static func phaseDuration(_ minutes: Double) -> String {
        guard minutes < 1 else { return hm(minutes) }
        let sec = String(Int((minutes * 60).rounded()))
        return String(localized: "\(sec) s")
    }
}
#endif
