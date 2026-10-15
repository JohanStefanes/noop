import XCTest
@testable import Strand

/// The start times Apple Health write-back reads to leave out workouts the NOOP watch app started, since
/// the watch already saved its own HKWorkout for them.
final class WatchMirroredWorkoutsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "WatchMirroredWorkoutsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testRecordedStartIsReturned() {
        XCTAssertTrue(WatchMirroredWorkouts.startTimes(defaults: defaults).isEmpty)
        WatchMirroredWorkouts.record(startTs: 1_700_000_000, defaults: defaults)
        XCTAssertEqual(WatchMirroredWorkouts.startTimes(defaults: defaults), [1_700_000_000])
    }

    func testRecordingTheSameStartTwiceKeepsOneEntry() {
        WatchMirroredWorkouts.record(startTs: 42, defaults: defaults)
        WatchMirroredWorkouts.record(startTs: 42, defaults: defaults)
        XCTAssertEqual((defaults.array(forKey: WatchMirroredWorkouts.defaultsKey) as? [Int])?.count, 1)
    }

    func testOldestStartsDropOnceOverCapacity() {
        let total = WatchMirroredWorkouts.capacity + 3
        for ts in 0..<total { WatchMirroredWorkouts.record(startTs: ts, defaults: defaults) }
        let kept = WatchMirroredWorkouts.startTimes(defaults: defaults)
        XCTAssertEqual(kept.count, WatchMirroredWorkouts.capacity)
        XCTAssertFalse(kept.contains(0))
        XCTAssertTrue(kept.contains(total - 1))
    }
}
