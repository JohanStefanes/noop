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
struct JohanHypnogram: View {
    let intervals: [SleepInterval]
    let nightStart: Date
    let nightEnd: Date
    var height: CGFloat = 200

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
                    }
                }
                .frame(height: height + Self.flagHeight)
            }
            hourAxis
                .padding(.leading, Self.axisWidth + 8)
        }
        .onAppear {
            guard reveal == 0 else { return }
            if motion.isStill { reveal = 1 } else { withAnimation(.easeOut(duration: 0.9)) { reveal = 1 } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Sleep stages from \(timeText(nightStart)) to \(timeText(nightEnd))"))
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
            ctx.fill(Path(roundedRect: rect, cornerRadius: Self.barHeight / 2.5),
                     with: .color(JohanTheme.stageColor(iv.stage)))
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
