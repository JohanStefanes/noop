import XCTest

/// `JohanNightCoverage` counts a minute as recorded only with enough beats, lists the long holes, and
/// reports how much of the scored stream came live.
final class JohanNightCoverageTests: XCTestCase {
    private let start = 1_000_000_020

    /// One beat a second over [fromMin, toMin) minutes after `start`.
    private func beats(_ fromMin: Int, _ toMin: Int) -> [Int] {
        Array(stride(from: start + fromMin * 60, to: start + toMin * 60, by: 1))
    }

    func testCountsCoveredMinutesAndListsOnlyLongGaps() {
        // 60 min night: beats 0-20, a 5 min dropout, beats 25-40, a 15 min gap, beats 55-60.
        let ts = beats(0, 20) + beats(25, 40) + beats(55, 60)
        let s = JohanNightCoverage.summarize(start: start, end: start + 3_600, beatTimestamps: ts,
                                             liveBeats: ts.count, heartRateTimestamps: beats(0, 60))
        XCTAssertEqual(s.nightMinutes, 60)
        XCTAssertEqual(s.beatMinutes, 40)
        XCTAssertEqual(s.heartRateMinutes, 60)
        XCTAssertEqual(s.gaps, [.init(start: start + 40 * 60, end: start + 55 * 60)])
        XCTAssertEqual(s.gaps.first?.minutes, 15)
        XCTAssertEqual(s.covered.map(\.minutes), [20, 15, 5])
        XCTAssertEqual(s.fraction, 40.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(s.liveShare, 1)
    }

    func testAFewStrayBeatsDoNotCountAsARecordedMinute() {
        let stray = (0..<60).map { start + $0 * 60 }   // one beat per minute
        let s = JohanNightCoverage.summarize(start: start, end: start + 3_600, beatTimestamps: stray,
                                             liveBeats: 0, heartRateTimestamps: [])
        XCTAssertEqual(s.beatMinutes, 0)
        XCTAssertEqual(s.gaps, [.init(start: start, end: start + 3_600)])
        XCTAssertEqual(s.liveShare, 0)
    }

    func testIgnoresBeatsOutsideTheNightAndHandlesAnEmptyNight() {
        let outside = [start - 5, start + 3_600, start + 9_999]
        let s = JohanNightCoverage.summarize(start: start, end: start + 3_600, beatTimestamps: outside,
                                             liveBeats: 1, heartRateTimestamps: outside)
        XCTAssertEqual(s.beatMinutes, 0)
        XCTAssertEqual(s.heartRateMinutes, 0)
        let empty = JohanNightCoverage.summarize(start: start, end: start, beatTimestamps: [],
                                                 liveBeats: 0, heartRateTimestamps: [])
        XCTAssertEqual(empty.nightMinutes, 0)
        XCTAssertEqual(empty.fraction, 0)
        XCTAssertNil(empty.liveShare)
        XCTAssertTrue(empty.gaps.isEmpty)
    }
}
