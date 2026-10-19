import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Pins `HRSleepOnsetRefinement` against SYNTHETIC nights only. `night` lays down one HR sample every
/// 10 s: an awake lead-in at 66 bpm, then sleep at 54 bpm with a 20-minute REM bump to 60 bpm every
/// 90 minutes. Apple twin of the Android `HrSleepOnsetRefinementTest`, whose oracle literals come from
/// this file's algorithm.
final class HRSleepOnsetRefinementTests: XCTestCase {

    /// Minute-aligned so every assertion can reason in whole minutes.
    private let start = 1_700_000_000 / 60 * 60
    private let nightMinutes = 420

    private func night(awakeMinutes: Int, keepEvery: Int = 1, totalMinutes: Int? = nil) -> [HRSample] {
        let total = totalMinutes ?? nightMinutes
        var out: [HRSample] = []
        for minute in 0..<total where minute % keepEvery == 0 {
            let bpm: Int
            if minute < awakeMinutes {
                bpm = 66
            } else {
                let sinceOnset = minute - awakeMinutes
                bpm = (sinceOnset % 90) >= 70 ? 60 : 54
            }
            for k in 0..<6 { out.append(HRSample(ts: start + minute * 60 + k * 10, bpm: bpm)) }
        }
        return out
    }

    private func wholeNightLight() -> [StageSegment] {
        [StageSegment(start: start, end: start + nightMinutes * 60, stage: "light")]
    }

    /// Recovers several different injected onsets, not one: the method must track a moving input.
    func testRecoversInjectedOnsets() {
        for lead in [30, 60, 105] {
            let out = HRSleepOnsetRefinement.refine(wholeNightLight(), hr: night(awakeMinutes: lead))
            XCTAssertEqual(out, [
                StageSegment(start: start, end: start + lead * 60, stage: "wake"),
                StageSegment(start: start + lead * 60, end: start + nightMinutes * 60, stage: "light"),
            ], "lead-in \(lead) min")
        }
    }

    func testNoLeadInIsPassthrough() {
        let segs = wholeNightLight()
        XCTAssertEqual(HRSleepOnsetRefinement.refine(segs, hr: night(awakeMinutes: 0)), segs)
    }

    func testShiftBelowMinimumIsPassthrough() {
        let segs = wholeNightLight()
        XCTAssertNil(HRSleepOnsetRefinement.onsetTs(start: start, end: start + nightMinutes * 60,
                                                     hr: night(awakeMinutes: 5)))
        XCTAssertEqual(HRSleepOnsetRefinement.refine(segs, hr: night(awakeMinutes: 5)), segs)
    }

    func testSparseHeartRateIsPassthrough() {
        let segs = wholeNightLight()
        XCTAssertEqual(HRSleepOnsetRefinement.refine(segs, hr: night(awakeMinutes: 60, keepEvery: 2)), segs)
    }

    func testOnsetPastHalfTheSessionIsRejected() {
        XCTAssertNil(HRSleepOnsetRefinement.onsetTs(start: start, end: start + nightMinutes * 60,
                                                    hr: night(awakeMinutes: 260)))
    }

    func testStagesAfterOnsetAreUnchanged() {
        let segs = [
            StageSegment(start: start, end: start + 40 * 60, stage: "light"),
            StageSegment(start: start + 40 * 60, end: start + 100 * 60, stage: "deep"),
            StageSegment(start: start + 100 * 60, end: start + nightMinutes * 60, stage: "rem"),
        ]
        XCTAssertEqual(HRSleepOnsetRefinement.refine(segs, hr: night(awakeMinutes: 60)), [
            StageSegment(start: start, end: start + 60 * 60, stage: "wake"),
            StageSegment(start: start + 60 * 60, end: start + 100 * 60, stage: "deep"),
            StageSegment(start: start + 100 * 60, end: start + nightMinutes * 60, stage: "rem"),
        ])
    }

    func testExistingLeadingWakeMerges() {
        let segs = [
            StageSegment(start: start, end: start + 20 * 60, stage: "wake"),
            StageSegment(start: start + 20 * 60, end: start + nightMinutes * 60, stage: "light"),
        ]
        XCTAssertEqual(HRSleepOnsetRefinement.refine(segs, hr: night(awakeMinutes: 60)), [
            StageSegment(start: start, end: start + 60 * 60, stage: "wake"),
            StageSegment(start: start + 60 * 60, end: start + nightMinutes * 60, stage: "light"),
        ])
    }

    func testSessionEfficiencyIsRecomputed() {
        let session = SleepSession(start: start, end: start + nightMinutes * 60, efficiency: 1.0,
                                   stages: wholeNightLight(), restingHR: 52, avgHRV: 60)
        let out = HRSleepOnsetRefinement.refine(session, hr: night(awakeMinutes: 105))
        XCTAssertEqual(out.start, session.start)
        XCTAssertEqual(out.end, session.end)
        XCTAssertEqual(out.restingHR, 52)
        XCTAssertEqual(out.efficiency, Double(nightMinutes - 105) / Double(nightMinutes), accuracy: 1e-9)
    }

    /// Cross-platform oracle: the same jittered nights the Kotlin test feeds, with the onsets this
    /// algorithm returns. Changing either side must change both.
    func testOracleMatchesKotlinLiterals() {
        XCTAssertEqual(Self.oracleOnsets(), Self.expectedOracle)
    }

    static let expectedOracle = """
        lead=0 noise=0 onset=nil
        lead=0 noise=3 onset=nil
        lead=0 noise=6 onset=nil
        lead=8 noise=0 onset=nil
        lead=8 noise=3 onset=nil
        lead=8 noise=6 onset=nil
        lead=25 noise=0 onset=1500
        lead=25 noise=3 onset=1500
        lead=25 noise=6 onset=1500
        lead=47 noise=0 onset=2820
        lead=47 noise=3 onset=2820
        lead=47 noise=6 onset=2760
        lead=90 noise=0 onset=5400
        lead=90 noise=3 onset=5400
        lead=90 noise=6 onset=5400
        lead=150 noise=0 onset=8880
        lead=150 noise=3 onset=8820
        lead=150 noise=6 onset=8820
        lead=230 noise=0 onset=nil
        lead=230 noise=3 onset=nil
        lead=230 noise=6 onset=nil
        """

    /// Deterministic LCG-jittered nights over a spread of lead-ins and noise levels; one line per case,
    /// `lead=<min> noise=<bpm> onset=<seconds after start | nil>`.
    static func oracleOnsets() -> String {
        let base = 1_700_000_000 / 60 * 60
        var lines: [String] = []
        for lead in [0, 8, 25, 47, 90, 150, 230] {
            for noise in [0, 3, 6] {
                var seed: UInt32 = UInt32(lead * 31 + noise * 7 + 1)
                var hr: [HRSample] = []
                for minute in 0..<420 {
                    for k in 0..<6 {
                        seed = seed &* 1_664_525 &+ 1_013_904_223
                        let jitter = noise == 0 ? 0 : Int(seed >> 16) % (2 * noise + 1) - noise
                        let level = minute < lead ? 66 : ((minute - lead) % 90 >= 70 ? 60 : 54)
                        hr.append(HRSample(ts: base + minute * 60 + k * 10, bpm: level + jitter))
                    }
                }
                let onset = HRSleepOnsetRefinement.onsetTs(start: base, end: base + 420 * 60, hr: hr)
                lines.append("lead=\(lead) noise=\(noise) onset=\(onset.map { "\($0 - base)" } ?? "nil")")
            }
        }
        return lines.joined(separator: "\n")
    }
}
