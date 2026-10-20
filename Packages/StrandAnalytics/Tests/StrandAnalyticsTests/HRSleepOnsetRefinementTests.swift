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

    /// Strap band for a night: "still" (1) through the lead-in, then asleep (2) with a stretch of 3 every
    /// 90 minutes. One sample every 10 s, every `keepEvery`-th minute.
    private func band(awakeMinutes: Int, keepEvery: Int = 1) -> [(ts: Int, state: Int)] {
        var out: [(ts: Int, state: Int)] = []
        for minute in 0..<nightMinutes where minute % keepEvery == 0 {
            let state = minute < awakeMinutes ? 1 : ((minute - awakeMinutes) % 90 >= 70 ? 3 : 2)
            for k in 0..<6 { out.append((ts: start + minute * 60 + k * 10, state: state)) }
        }
        return out
    }

    /// HR falling steadily from 90 to 60 bpm all night, as after a late hard workout: the median lands
    /// mid-night, so HR alone puts the onset hours late. The band still recovers each injected onset.
    func testBandOnsetBeatsDriftingHeartRate() {
        let drifting = (0..<nightMinutes).flatMap { minute in
            (0..<6).map { HRSample(ts: start + minute * 60 + $0 * 10, bpm: 90 - minute * 30 / nightMinutes) }
        }
        XCTAssertEqual(HRSleepOnsetRefinement.onsetTs(start: start, end: start + nightMinutes * 60, hr: drifting),
                       start + 205 * 60)
        for lead in [20, 45, 90] {
            let out = HRSleepOnsetRefinement.refine(wholeNightLight(), hr: drifting,
                                                    bandSleepState: band(awakeMinutes: lead))
            XCTAssertEqual(out.first, StageSegment(start: start, end: start + lead * 60, stage: "wake"),
                           "lead-in \(lead) min")
        }
    }

    /// A band that covers the night and says asleep from the start is a verdict, not a gap: no HR fallback.
    func testCoveredBandThatDeclinesDoesNotFallBackToHeartRate() {
        let segs = wholeNightLight()
        XCTAssertEqual(HRSleepOnsetRefinement.refine(segs, hr: night(awakeMinutes: 60),
                                                     bandSleepState: band(awakeMinutes: 0)), segs)
    }

    func testSparseBandFallsBackToHeartRate() {
        let out = HRSleepOnsetRefinement.refine(wholeNightLight(), hr: night(awakeMinutes: 60),
                                                bandSleepState: band(awakeMinutes: 30, keepEvery: 2))
        XCTAssertEqual(out.first, StageSegment(start: start, end: start + 60 * 60, stage: "wake"))
    }

    /// Cross-platform oracle for the band path; same contract as `testOracleMatchesKotlinLiterals`.
    func testBandOracleMatchesKotlinLiterals() {
        XCTAssertEqual(Self.bandOracleOnsets(), Self.expectedBandOracle)
    }

    static let expectedBandOracle = """
        lead=0 flip=0 keep=1 onset=nil
        lead=0 flip=0 keep=3 onset=nocover
        lead=0 flip=10 keep=1 onset=nil
        lead=0 flip=10 keep=3 onset=nocover
        lead=0 flip=30 keep=1 onset=nil
        lead=0 flip=30 keep=3 onset=nocover
        lead=8 flip=0 keep=1 onset=nil
        lead=8 flip=0 keep=3 onset=nocover
        lead=8 flip=10 keep=1 onset=nil
        lead=8 flip=10 keep=3 onset=nocover
        lead=8 flip=30 keep=1 onset=nil
        lead=8 flip=30 keep=3 onset=nocover
        lead=25 flip=0 keep=1 onset=1500
        lead=25 flip=0 keep=3 onset=nocover
        lead=25 flip=10 keep=1 onset=1500
        lead=25 flip=10 keep=3 onset=nocover
        lead=25 flip=30 keep=1 onset=1500
        lead=25 flip=30 keep=3 onset=nocover
        lead=47 flip=0 keep=1 onset=2820
        lead=47 flip=0 keep=3 onset=nocover
        lead=47 flip=10 keep=1 onset=2820
        lead=47 flip=10 keep=3 onset=nocover
        lead=47 flip=30 keep=1 onset=2880
        lead=47 flip=30 keep=3 onset=nocover
        lead=90 flip=0 keep=1 onset=5400
        lead=90 flip=0 keep=3 onset=nocover
        lead=90 flip=10 keep=1 onset=5400
        lead=90 flip=10 keep=3 onset=nocover
        lead=90 flip=30 keep=1 onset=5280
        lead=90 flip=30 keep=3 onset=nocover
        lead=150 flip=0 keep=1 onset=9000
        lead=150 flip=0 keep=3 onset=nocover
        lead=150 flip=10 keep=1 onset=9000
        lead=150 flip=10 keep=3 onset=nocover
        lead=150 flip=30 keep=1 onset=8880
        lead=150 flip=30 keep=3 onset=nocover
        lead=230 flip=0 keep=1 onset=nil
        lead=230 flip=0 keep=3 onset=nocover
        lead=230 flip=10 keep=1 onset=nil
        lead=230 flip=10 keep=3 onset=nocover
        lead=230 flip=30 keep=1 onset=nil
        lead=230 flip=30 keep=3 onset=nocover
        """

    /// LCG-jittered bands over a spread of lead-ins and flip rates (percent of samples flipped between
    /// awake and asleep), plus a sparse variant; `onset=` is seconds after start, `nil`, or `nocover`.
    static func bandOracleOnsets() -> String {
        let base = 1_700_000_000 / 60 * 60
        var lines: [String] = []
        for lead in [0, 8, 25, 47, 90, 150, 230] {
            for flip in [0, 10, 30] {
                for keepEvery in [1, 3] {
                    var seed: UInt32 = UInt32(lead * 31 + flip * 7 + keepEvery)
                    var band: [(ts: Int, state: Int)] = []
                    for minute in 0..<420 where minute % keepEvery == 0 {
                        for k in 0..<6 {
                            seed = seed &* 1_664_525 &+ 1_013_904_223
                            var state = minute < lead ? 1 : ((minute - lead) % 90 >= 70 ? 3 : 2)
                            if Int(seed >> 16) % 100 < flip { state = state >= 2 ? 0 : 2 }
                            band.append((ts: base + minute * 60 + k * 10, state: state))
                        }
                    }
                    let onset = HRSleepOnsetRefinement.bandOnsetTs(start: base, end: base + 420 * 60, band: band)
                    let text = onset.map { $0.map { "\($0 - base)" } ?? "nil" } ?? "nocover"
                    lines.append("lead=\(lead) flip=\(flip) keep=\(keepEvery) onset=\(text)")
                }
            }
        }
        return lines.joined(separator: "\n")
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
