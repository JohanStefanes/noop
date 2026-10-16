import Foundation

/// How much of a night the strap actually recorded beat-to-beat: the minutes that carry R-R intervals,
/// the minutes that carry heart rate, and the stretches without beats.
///
/// HRV, respiratory rate and recovery are computed from the R-R intervals, so this is the figure that says
/// whether a night's scores rest on the whole night or on a part of it. Built from the beats the scoring
/// read returns (`Repository.rrIntervals`), so it counts what was scored, not what was banked.
/// No UI here: `StrandTests` compiles this file directly.
enum JohanNightCoverage {

    /// A stretch of the night, in unix seconds, end exclusive.
    struct Span: Equatable {
        var start: Int
        var end: Int
        var minutes: Int { (end - start) / 60 }
    }

    struct Summary: Equatable {
        /// The night's start, unix seconds: minute 0 of every count below.
        var nightStart: Int
        /// Whole minutes between the night's start and end.
        var nightMinutes: Int
        /// Minutes holding at least `minBeatsPerMinute` R-R intervals.
        var beatMinutes: Int
        /// Minutes holding at least one heart-rate sample.
        var heartRateMinutes: Int
        /// Stretches of at least `minGapMinutes` without beats, in order.
        var gaps: [Span]
        /// Every stretch with beats, in order: what a coverage strip draws.
        var covered: [Span]
        /// Share of the scored beats that came over the live Bluetooth stream (0...1), nil without beats.
        var liveShare: Double?

        var fraction: Double { nightMinutes > 0 ? Double(beatMinutes) / Double(nightMinutes) : 0 }
    }

    /// A minute counts as covered from this many beats: a third of a minute at a resting 60 bpm, so a
    /// minute with a few stray beats is not reported as recorded.
    static let minBeatsPerMinute = 20
    /// Shorter holes are ordinary dropouts and are not listed as gaps.
    static let minGapMinutes = 10

    /// - Parameters:
    ///   - beatTimestamps: the scored R-R intervals' timestamps, any order.
    ///   - liveBeats: how many of them came over the live stream (standard BLE).
    ///   - heartRateTimestamps: heart-rate sample timestamps, any order.
    static func summarize(start: Int, end: Int, beatTimestamps: [Int], liveBeats: Int,
                          heartRateTimestamps: [Int]) -> Summary {
        let minutes = max(0, (end - start) / 60)
        var beatsPerMinute = [Int](repeating: 0, count: minutes)
        var hrMinute = [Bool](repeating: false, count: minutes)
        for ts in beatTimestamps where ts >= start {
            let m = (ts - start) / 60
            if m < minutes { beatsPerMinute[m] += 1 }
        }
        for ts in heartRateTimestamps where ts >= start {
            let m = (ts - start) / 60
            if m < minutes { hrMinute[m] = true }
        }
        let hasBeats = beatsPerMinute.map { $0 >= minBeatsPerMinute }

        var covered: [Span] = []
        var gaps: [Span] = []
        var i = 0
        while i < minutes {
            var j = i
            while j < minutes && hasBeats[j] == hasBeats[i] { j += 1 }
            let span = Span(start: start + i * 60, end: start + j * 60)
            if hasBeats[i] { covered.append(span) } else if j - i >= minGapMinutes { gaps.append(span) }
            i = j
        }
        let total = beatTimestamps.count
        return Summary(nightStart: start, nightMinutes: minutes,
                       beatMinutes: hasBeats.filter { $0 }.count,
                       heartRateMinutes: hrMinute.filter { $0 }.count,
                       gaps: gaps, covered: covered,
                       liveShare: total > 0 ? Double(min(liveBeats, total)) / Double(total) : nil)
    }
}
