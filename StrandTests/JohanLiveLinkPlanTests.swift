import XCTest

/// `JohanLiveLinkPlan` keeps the reminder inside the evening part of the capture window, pushes it out by the
/// grace period from each live heart rate, and moves to the next evening once the window has run out.
final class JohanLiveLinkPlanTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return c
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func fire(_ now: Date, start: Int = 21 * 60) -> Date? {
        JohanLiveLinkPlan.fireDate(now: now, nightStartMinutes: start, calendar: calendar)
    }

    func testDaytimePlanFiresShortlyAfterTheWindowOpens() {
        XCTAssertEqual(fire(at(18, 14, 0)), at(18, 21, 15))
    }

    func testHeartRateInsideTheWindowPushesItOutByTheGrace() {
        XCTAssertEqual(fire(at(18, 22, 40)), at(18, 23, 0))
        // Just after the window opens, the grace wins over the first delay.
        XCTAssertEqual(fire(at(18, 21, 1)), at(18, 21, 21))
    }

    func testPastMidnightStaysInTheSameEveningUntilItsEnd() {
        XCTAssertEqual(fire(at(19, 0, 30)), at(19, 0, 50))
        XCTAssertEqual(fire(at(19, 0, 40)), at(19, 1, 0))
    }

    func testOnceTheEveningIsOverItMovesToTheNextOne() {
        // Live heart rate at 00:45: 01:05 would be past the 01:00 end, so tonight is done.
        XCTAssertEqual(fire(at(19, 0, 45)), at(19, 21, 15))
        XCTAssertEqual(fire(at(19, 8, 0)), at(19, 21, 15))
    }

    func testAnEarlyMorningWindowWrapsCorrectly() {
        // A window opening at 23:30 runs to 03:30 the next morning.
        XCTAssertEqual(fire(at(19, 2, 0), start: 23 * 60 + 30), at(19, 2, 20))
        XCTAssertEqual(fire(at(19, 4, 0), start: 23 * 60 + 30), at(19, 23, 45))
    }

    func testOutOfRangeStartIsClamped() {
        XCTAssertEqual(fire(at(18, 12, 0), start: 5000), at(18, 23, 59).addingTimeInterval(15 * 60))
    }
}
