import XCTest
import StrandDesign

/// `JohanSleepPhases` joins back-to-back intervals of one stage and keeps every stage's minutes intact.
final class JohanSleepPhasesTests: XCTestCase {
    private func iv(_ stage: SleepStage, _ startMin: Double, _ endMin: Double) -> SleepInterval {
        SleepInterval(stage: stage, start: startMin * 60, end: endMin * 60)
    }

    func testJoinsBackToBackIntervalsOfOneStage() {
        let phases = JohanSleepPhases.phases([
            iv(.light, 0, 10), iv(.light, 10, 25), iv(.deep, 25, 70), iv(.light, 70, 80), iv(.rem, 80, 100),
        ])
        XCTAssertEqual(phases.map(\.stage), [.light, .deep, .light, .rem])
        XCTAssertEqual(phases.map(\.minutes), [25, 45, 10, 20])
    }

    func testSortsAndKeepsEachStageTotal() {
        let input = [iv(.rem, 80, 100), iv(.deep, 25, 70), iv(.light, 0, 25), iv(.awake, 70, 72), iv(.light, 72, 80)]
        let phases = JohanSleepPhases.phases(input)
        XCTAssertEqual(phases.map(\.start), [0, 25, 70, 72, 80].map { $0 * 60 })
        for stage in [SleepStage.awake, .light, .deep, .rem] {
            let fromInput = input.filter { $0.stage == stage }.reduce(0) { $0 + ($1.end - $1.start) }
            let fromPhases = phases.filter { $0.stage == stage }.reduce(0) { $0 + ($1.end - $1.start) }
            XCTAssertEqual(fromInput, fromPhases, "\(stage)")
        }
    }

    func testGapBetweenSameStageStaysTwoPhases() {
        let phases = JohanSleepPhases.phases([iv(.light, 0, 10), iv(.light, 15, 20)])
        XCTAssertEqual(phases.count, 2)
    }

    func testDropsEmptyIntervals() {
        XCTAssertEqual(JohanSleepPhases.phases([iv(.deep, 5, 5)]), [])
    }
}
