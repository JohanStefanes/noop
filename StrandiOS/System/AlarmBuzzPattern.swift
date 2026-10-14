#if os(iOS)
import Foundation

/// The vibration the "Buzz Strap for Alarm" shortcut plays: `bursts` buzzes, each `pulses` long, with
/// `gapSeconds` between them. Built only from what is confirmed on hardware: the buzz is the existing
/// RUN_HAPTICS_PATTERN write (on a 5/MG the maverick notify buzz, whose repeat count 1...8 was measured
/// on a real strap, #926). The waveform itself is not configurable, because no other waveform has been
/// verified. `strapAlarmSignal` appends the RUN_ALARM write the original one-shot buzz always sent.
struct AlarmBuzzPattern: Codable, Equatable {
    var bursts: Int
    var pulses: Int
    var gapSeconds: Double
    var strapAlarmSignal: Bool

    static let burstRange = 1...10
    /// 8 is the most repeats any captured body evidences (`MaverickHaptics.notificationBuzz`); not raised.
    static let pulseRange = 1...8
    static let gapRange = 0.5...10.0
    /// Longest first-to-last-burst span. The shortcut plays the pattern inside its own `perform`, and iOS
    /// does not let a background App Intent run indefinitely, so a pattern stays well inside that budget.
    static let maxSpanSeconds = 24.0

    /// Most bursts that fit `maxSpanSeconds` at `gap`.
    static func maxBursts(gap: Double) -> Int {
        min(burstRange.upperBound, Int((maxSpanSeconds / max(gap, gapRange.lowerBound)).rounded(.down)) + 1)
    }

    /// Longest gap that keeps `bursts` inside `maxSpanSeconds`.
    static func maxGap(bursts: Int) -> Double {
        guard bursts > 1 else { return gapRange.upperBound }
        let g = (maxSpanSeconds / Double(bursts - 1) * 2).rounded(.down) / 2   // whole half-seconds
        return min(gapRange.upperBound, max(gapRange.lowerBound, g))
    }

    /// Clamped copy, so a stored or hand-edited value can never reach the wire outside the measured range
    /// or run past the span budget.
    var clamped: AlarmBuzzPattern {
        let gap = min(max(gapSeconds, Self.gapRange.lowerBound), Self.gapRange.upperBound)
        return AlarmBuzzPattern(bursts: min(max(bursts, Self.burstRange.lowerBound), Self.maxBursts(gap: gap)),
                                pulses: min(max(pulses, Self.pulseRange.lowerBound), Self.pulseRange.upperBound),
                                gapSeconds: gap,
                                strapAlarmSignal: strapAlarmSignal)
    }

    /// Total time from the first buzz to the last burst starting, for the summary line.
    var spanSeconds: Double { Double(bursts - 1) * gapSeconds }

    // MARK: Presets

    enum Preset: String, CaseIterable, Identifiable {
        case gentle, pulse, heartbeat, long, wakeUp, classic
        var id: String { rawValue }

        var pattern: AlarmBuzzPattern {
            switch self {
            case .gentle:    return AlarmBuzzPattern(bursts: 2, pulses: 1, gapSeconds: 5, strapAlarmSignal: false)
            case .pulse:     return AlarmBuzzPattern(bursts: 4, pulses: 2, gapSeconds: 3, strapAlarmSignal: false)
            case .heartbeat: return AlarmBuzzPattern(bursts: 5, pulses: 2, gapSeconds: 1.5, strapAlarmSignal: false)
            // The most of everything: ten maximum bursts 2 s apart (18 s). How long one 8-pulse burst lasts is
            // unmeasured, so whether the bursts touch is for the wearer to feel, not something this asserts.
            case .long:      return AlarmBuzzPattern(bursts: 10, pulses: 8, gapSeconds: 2, strapAlarmSignal: false)
            case .wakeUp:    return AlarmBuzzPattern(bursts: 8, pulses: 8, gapSeconds: 3, strapAlarmSignal: false)
            // What the shortcut sent before patterns existed: three one-shot buzzes (3 pulses + RUN_ALARM).
            case .classic:   return AlarmBuzzPattern(bursts: 3, pulses: 3, gapSeconds: 4, strapAlarmSignal: true)
            }
        }

        var title: String {
            switch self {
            case .gentle:    return String(localized: "Gentle")
            case .pulse:     return String(localized: "Pulse")
            case .heartbeat: return String(localized: "Heartbeat")
            case .long:      return String(localized: "Long")
            case .wakeUp:    return String(localized: "Wake-up call")
            case .classic:   return String(localized: "Classic")
            }
        }
    }

    // MARK: Storage

    private static let patternKey = "johan.alarmBuzz.pattern"
    /// The preset the stored pattern came from; nil once the user edits it (shown as "Custom").
    private static let presetKey = "johan.alarmBuzz.preset"

    static var saved: AlarmBuzzPattern {
        guard let data = UserDefaults.standard.data(forKey: patternKey),
              let p = try? JSONDecoder().decode(AlarmBuzzPattern.self, from: data) else { return Preset.pulse.pattern }
        return p.clamped
    }

    static var savedPreset: Preset? {
        guard UserDefaults.standard.data(forKey: patternKey) != nil else { return .pulse }
        return UserDefaults.standard.string(forKey: presetKey).flatMap(Preset.init(rawValue:))
    }

    static func save(_ pattern: AlarmBuzzPattern, preset: Preset?) {
        if let data = try? JSONEncoder().encode(pattern.clamped) {
            UserDefaults.standard.set(data, forKey: patternKey)
        }
        UserDefaults.standard.set(preset?.rawValue, forKey: presetKey)
    }
}
#endif
