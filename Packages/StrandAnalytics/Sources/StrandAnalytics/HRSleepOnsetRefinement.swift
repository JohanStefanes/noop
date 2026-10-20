import Foundation
import WhoopProtocol

// HRSleepOnsetRefinement.swift — heart-rate sleep-onset refinement (Experimental, default OFF).
//
// THE PROBLEM. Session detection is a gravity-stillness spine: a run of minutes in which the wrist is still
// becomes a sleep session, and the session starts where the stillness starts. Lying awake and still in bed
// (reading, a phone, trying to fall asleep) is indistinguishable from sleep to that spine, so the session,
// and with it the shown "Fell asleep" time, can start an hour or more before the wearer fell asleep. Neither
// stager forces that lead-in to wake: V2 stages each epoch from cardiorespiratory emissions with a sticky
// HMM, and a still, quiet wearer reads as light sleep. A reported night showed a solid light-sleep block
// from 01:00 for a wearer who fell asleep around 02:45.
//
// THE FIX. A POST-PASS over the already-staged `[StageSegment]` output of either stager. Heart rate falls
// when sleep begins; lying awake keeps it above the night's sleeping level. So the pass finds the first
// `sustainMinutes`-long stretch whose mean per-minute HR is at or below the night's own median per-minute HR
// (`onsetTs`) and relabels everything before it as wake. The threshold comes from the night itself, never a
// fixed bpm, so it follows the wearer's own level. The pass only ever ADDS wake at the head of the session;
// it never changes a stage after the found onset, never moves the session bounds, and never invents sleep.
//
// GUARDS. Passthrough when HR covers less than `minHRCoverageFraction` of the session's minutes, when no
// stretch qualifies, when the found onset is less than `minShiftSeconds` after the session start, or when it
// lies beyond `maxLeadFraction` of the session (a late dip is more likely a quiet REM-free stretch late in a
// night than the onset).
//
// THE STRAP'S OWN VERDICT FIRST. Heart rate fails after a late hard workout: HR then drifts down all night,
// the night's median sits far below the first hours of real sleep, and the HR onset lands hours late (a
// reported night: run until 21:00, HR onset 01:52, real onset about 00:00). When the strap banked its own
// sleep_state band (0 wake / 1 still / 2 asleep / 3, which on banded nights only appears around sleep and
// never in waking hours), `bandOnsetTs` is used instead: the first `sustainMinutes` stretch in which at
// least `minSustainMinutesWithHR` minutes read 2 or 3, starting at its first such minute. "Still" (1) is exactly the lying-awake lead-in this
// pass exists for, so it never counts as asleep. HR is the fallback only when the band covers too little of
// the session; a covered night whose band declines is NOT handed to HR.
//
// SAFETY POSTURE. Default-off Experimental toggle (`PuffinExperiment.hrSleepOnsetEnabled`), per AGENTS.md's
// rule for a derived physiological signal: one reported night is not validation. Applied only on the
// detection path (`AnalyticsEngine.analyzeDay`), never to a hand-edited window, whose onset the wearer set.
// All thresholds are named a-priori constants, not fit to labels. Pure, deterministic, no I/O. The Kotlin
// twin is `HrSleepOnsetRefinement.kt`; its oracle test pins this file's output.
public enum HRSleepOnsetRefinement {

    // MARK: - Tunables

    /// Length of the stretch whose mean HR must sit at or below the night's median to call onset.
    public static let sustainMinutes: Int = 10
    /// Minutes inside that stretch that must carry HR for the stretch to count.
    public static let minSustainMinutesWithHR: Int = 8
    /// Share of the session's minutes that must carry HR before the pass trusts the night's median.
    public static let minHRCoverageFraction: Double = 0.6
    /// A found onset closer than this to the session start changes nothing.
    public static let minShiftSeconds: Int = 10 * 60
    /// A found onset later than this share of the session is not trusted as the onset.
    public static let maxLeadFraction: Double = 0.5

    // MARK: - Public entry points

    /// The heart-rate onset inside `[start, end)`, or nil when the guards decline (see the file header).
    /// A returned value is always at least `minShiftSeconds` after `start`.
    public static func onsetTs(start: Int, end: Int, hr: [HRSample]) -> Int? {
        guard end > start else { return nil }
        let firstMinute = start / 60
        let lastMinute = (end - 1) / 60
        let minuteCount = lastMinute - firstMinute + 1
        guard minuteCount >= sustainMinutes else { return nil }

        var sums = [Int](repeating: 0, count: minuteCount)
        var counts = [Int](repeating: 0, count: minuteCount)
        for s in hr where s.ts >= start && s.ts < end && s.bpm > 0 {
            let i = s.ts / 60 - firstMinute
            sums[i] += s.bpm
            counts[i] += 1
        }
        var means = [Double?](repeating: nil, count: minuteCount)
        var present: [Double] = []
        for i in 0..<minuteCount where counts[i] > 0 {
            let m = Double(sums[i]) / Double(counts[i])
            means[i] = m
            present.append(m)
        }
        guard Double(present.count) >= minHRCoverageFraction * Double(minuteCount) else { return nil }
        let threshold = median(present)

        for i in 0...(minuteCount - sustainMinutes) {
            var total = 0.0
            var n = 0
            for j in i..<(i + sustainMinutes) {
                if let m = means[j] { total += m; n += 1 }
            }
            guard n >= minSustainMinutesWithHR else { continue }
            guard total / Double(n) <= threshold else { continue }
            let onset = max(start, (firstMinute + i) * 60)
            guard onset - start >= minShiftSeconds else { return nil }
            guard Double(onset - start) <= maxLeadFraction * Double(end - start) else { return nil }
            return onset
        }
        return nil
    }

    /// The strap-band onset inside `[start, end)`. Outer nil: the band covers less than
    /// `minHRCoverageFraction` of the session's minutes, so it cannot decide. Inner nil: it covers the night
    /// and the guards decline. A minute reads asleep when at least half its samples are state 2 or 3.
    public static func bandOnsetTs(start: Int, end: Int, band: [(ts: Int, state: Int)]) -> Int?? {
        guard end > start else { return nil }
        let firstMinute = start / 60
        let minuteCount = (end - 1) / 60 - firstMinute + 1
        guard minuteCount >= sustainMinutes else { return nil }
        var asleepCounts = [Int](repeating: 0, count: minuteCount)
        var counts = [Int](repeating: 0, count: minuteCount)
        for s in band where s.ts >= start && s.ts < end {
            let i = s.ts / 60 - firstMinute
            counts[i] += 1
            if s.state >= 2 { asleepCounts[i] += 1 }
        }
        let covered = counts.filter { $0 > 0 }.count
        guard Double(covered) >= minHRCoverageFraction * Double(minuteCount) else { return nil }
        let asleep = (0..<minuteCount).map { counts[$0] > 0 && 2 * asleepCounts[$0] >= counts[$0] }
        for i in 0...(minuteCount - sustainMinutes) {
            guard asleep[i..<(i + sustainMinutes)].filter({ $0 }).count >= minSustainMinutesWithHR else { continue }
            // The window may open on up to two awake minutes; onset is its first asleep minute.
            let first = (i..<(i + sustainMinutes)).first { asleep[$0] } ?? i
            let onset = max(start, (firstMinute + first) * 60)
            guard onset - start >= minShiftSeconds else { return .some(nil) }
            guard Double(onset - start) <= maxLeadFraction * Double(end - start) else { return .some(nil) }
            return onset
        }
        return .some(nil)
    }

    /// Relabel every stage before the onset as wake: the band onset when the strap banked one, else HR. `segments` must tile one contiguous window
    /// in order (as every `stageSession` returns). Byte-identical passthrough when the guards decline.
    public static func refine(_ segments: [StageSegment], hr: [HRSample],
                              bandSleepState: [(ts: Int, state: Int)] = []) -> [StageSegment] {
        guard let windowStart = segments.first?.start, let windowEnd = segments.last?.end,
              let onset = bandOnsetTs(start: windowStart, end: windowEnd, band: bandSleepState)
                ?? onsetTs(start: windowStart, end: windowEnd, hr: hr) else { return segments }
        var out: [StageSegment] = []
        out.reserveCapacity(segments.count + 1)
        for seg in segments {
            if seg.end <= onset {
                appendMerging(StageSegment(start: seg.start, end: seg.end, stage: "wake"), into: &out)
            } else if seg.start < onset {
                appendMerging(StageSegment(start: seg.start, end: onset, stage: "wake"), into: &out)
                appendMerging(StageSegment(start: onset, end: seg.end, stage: seg.stage), into: &out)
            } else {
                appendMerging(seg, into: &out)
            }
        }
        return out
    }

    /// Session-level convenience: refines `session.stages` and recomputes `efficiency` from the result.
    /// Bounds, `restingHR`, `avgHRV` and `hrOnly` are carried over unchanged.
    public static func refine(_ session: SleepSession, hr: [HRSample],
                              bandSleepState: [(ts: Int, state: Int)] = []) -> SleepSession {
        let newStages = refine(session.stages, hr: hr, bandSleepState: bandSleepState)
        guard newStages != session.stages else { return session }
        let newEfficiency = SleepStager.efficiency(start: session.start, end: session.end, stages: newStages)
        return SleepSession(start: session.start, end: session.end, efficiency: newEfficiency,
                            stages: newStages, restingHR: session.restingHR, avgHRV: session.avgHRV,
                            hrOnly: session.hrOnly)
    }

    // MARK: - Helpers

    /// Median of a non-empty list; the mean of the two middle values for an even count.
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    static func appendMerging(_ piece: StageSegment, into out: inout [StageSegment]) {
        guard piece.end > piece.start else { return }
        if let lastIdx = out.indices.last, out[lastIdx].stage == piece.stage, out[lastIdx].end == piece.start {
            out[lastIdx].end = piece.end
        } else {
            out.append(piece)
        }
    }
}
