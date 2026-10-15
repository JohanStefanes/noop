import Foundation
import StrandDesign

/// The night as a list: each stretch of one stage, in order, with its clock times and length.
///
/// Built from the same stage intervals the hypnogram draws, without display smoothing, so a stage's phases
/// add up to the same minutes as its total on the card. Back-to-back intervals of one stage are one phase.
/// No UI here: `StrandTests` compiles this file directly.
enum JohanSleepPhases {

    struct Phase: Equatable {
        var stage: SleepStage
        /// Seconds after the night's start, as the intervals carry them.
        var start: TimeInterval
        var end: TimeInterval
        var minutes: Double { (end - start) / 60 }
    }

    /// Intervals closer than this count as back to back (decoded epochs can leave sub-second seams).
    static let joinToleranceSec: TimeInterval = 1

    static func phases(_ intervals: [SleepInterval]) -> [Phase] {
        var out: [Phase] = []
        for iv in intervals.sorted(by: { $0.start < $1.start }) where iv.end > iv.start {
            if var last = out.last, last.stage == iv.stage, iv.start - last.end <= joinToleranceSec {
                last.end = max(last.end, iv.end)
                out[out.count - 1] = last
            } else {
                out.append(Phase(stage: iv.stage, start: iv.start, end: iv.end))
            }
        }
        return out
    }
}
