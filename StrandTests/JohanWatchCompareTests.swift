import XCTest
import WhoopProtocol

/// `JohanWatchCompare` over one synthetic night with known answers: strap 2 bpm above the Watch, one
/// 20-minute strap gap, and beats alternating ±20 ms around 1000 ms (RMSSD 40, SDNN about 20).
final class JohanWatchCompareTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return c
    }()

    private func ts(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Int {
        Int(cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!.timeIntervalSince1970)
    }

    func testWindowsPreferWatchThenStrapThenFixed() {
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9))!
        let w = JohanWatchCompare.windows(
            count: 3, now: now,
            watchAsleep: [(ts(2026, 10, 13, 23, 10), ts(2026, 10, 14, 3)), (ts(2026, 10, 14, 3, 20), ts(2026, 10, 14, 6, 50))],
            strapSleeps: [(ts(2026, 10, 12, 22, 30), ts(2026, 10, 13, 6, 30))],
            calendar: cal)
        XCTAssertEqual(w.map(\.source), [.fixed, .strap, .watch])
        XCTAssertEqual(w[0].start, ts(2026, 10, 11, 23))
        XCTAssertEqual(w[1].start, ts(2026, 10, 12, 22, 30))
        // Two Watch spans of one night merge into one window.
        XCTAssertEqual(w[2].start, ts(2026, 10, 13, 23, 10))
        XCTAssertEqual(w[2].end, ts(2026, 10, 14, 6, 50))
    }

    func testEveningStillShowsLastNightNotTonight() {
        let evening = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 21))!
        let w = JohanWatchCompare.windows(count: 1, now: evening, watchAsleep: [], strapSleeps: [], calendar: cal)
        XCTAssertEqual(w.first?.start, ts(2026, 10, 13, 23))
    }

    func testOneNight() {
        let start = ts(2026, 10, 13, 23)
        let end = start + 8 * 3600
        let gap = (start + 3600)..<(start + 3600 + 20 * 60)
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for (i, t) in (start..<end).enumerated() where !gap.contains(t) {
            hr.append(HRSample(ts: t, bpm: 60))
            rr.append(RRInterval(ts: t, rrMs: i % 2 == 0 ? 980 : 1020))
        }
        let watchTimes = stride(from: start + 30, to: end, by: 300)
        let watchHR = watchTimes.map { HRSample(ts: $0, bpm: 58) }
        let paired = watchTimes.filter { !((gap.lowerBound - 30)..<(gap.upperBound + 30)).contains($0) }.count
        let hrv = [JohanWatchCompare.HRVReading(start: start + 3 * 3600, end: start + 3 * 3600 + 60, sdnnMs: 25),
                   // In the gap: no strap beats, so no pair.
                   JohanWatchCompare.HRVReading(start: gap.lowerBound + 60, end: gap.lowerBound + 120, sdnnMs: 30)]

        let n = JohanWatchCompare.compare(night: Date(), source: .watch, start: start, end: end,
                                          strapHR: hr, strapRR: rr, watchHR: watchHR, watchHRV: hrv)
        XCTAssertEqual(n.gapCount, 1)
        XCTAssertEqual(n.longestGapSec, 20 * 60 + 1)
        XCTAssertEqual(n.coverage, 460.0 / 480.0, accuracy: 1e-9)
        XCTAssertEqual(n.watchHRCount, watchHR.count)
        XCTAssertEqual(n.hrPairs, paired)
        XCTAssertEqual(n.hrBias!, 2, accuracy: 1e-9)
        XCTAssertEqual(n.hrMAE!, 2, accuracy: 1e-9)
        XCTAssertEqual(n.rmssd!, 40, accuracy: 1e-9)
        XCTAssertEqual(n.watchHRVCount, 2)
        XCTAssertEqual(n.hrvPairs.count, 1)
        XCTAssertEqual(n.hrvPairs[0].watch, 25)
        XCTAssertEqual(n.hrvPairs[0].strap, 20, accuracy: 0.5)

        let s = JohanWatchCompare.summarize([n, JohanWatchCompare.compare(
            night: Date(), source: .fixed, start: end + 86_400, end: end + 2 * 86_400,
            strapHR: [], strapRR: [], watchHR: [], watchHRV: [])])
        XCTAssertEqual(s.nights, 2)
        XCTAssertEqual(s.nightsBoth, 1)
        XCTAssertEqual(s.hrPairs, paired)
        XCTAssertEqual(s.hrBias!, 2, accuracy: 1e-9)
        XCTAssertEqual(s.hrvPairs, 1)
    }

    /// SpO₂: the strap's off-window zeros and out-of-band bytes are dropped, readings outside the window
    /// are ignored, and the summary pairs night means.
    func testSpO2NightMeansAndSummary() {
        let start = ts(2026, 10, 13, 23)
        let end = start + 8 * 3600
        let strap: [(ts: Int, pct: Double)] = [(start + 10, 0), (start + 20, 94), (start + 30, 96), (start + 40, 120),
                                              (end + 10, 80)]
        let watch: [(ts: Int, pct: Double)] = [(start + 3600, 97), (start + 7200, 95), (start - 60, 90)]
        let n = JohanWatchCompare.compare(night: Date(), source: .watch, start: start, end: end,
                                          strapHR: [], strapRR: [], watchHR: [], watchHRV: [],
                                          strapSpO2: strap, watchSpO2: watch)
        XCTAssertEqual(n.strapSpO2Count, 2)
        XCTAssertEqual(n.strapSpO2!, 95, accuracy: 1e-9)
        XCTAssertEqual(n.watchSpO2Count, 2)
        XCTAssertEqual(n.watchSpO2!, 96, accuracy: 1e-9)

        // Five nights where the strap tracks the Watch one point low: bias -1, r 1, spread 4.
        let nights = (0..<5).map { i -> JohanWatchCompare.Night in
            var m = JohanWatchCompare.Night(night: Date(), source: .watch, start: 0, end: 1)
            m.watchSpO2 = 94 + Double(i); m.strapSpO2 = 93 + Double(i)
            return m
        }
        let s = JohanWatchCompare.summarize(nights)
        XCTAssertEqual(s.spo2Nights, 5)
        XCTAssertEqual(s.spo2Bias!, -1, accuracy: 1e-9)
        XCTAssertEqual(s.spo2MAE!, 1, accuracy: 1e-9)
        XCTAssertEqual(s.spo2R!, 1, accuracy: 1e-9)
        XCTAssertEqual(s.spo2WatchSpread!, 4, accuracy: 1e-9)
        // Under five nights there is no r.
        XCTAssertNil(JohanWatchCompare.summarize(Array(nights.prefix(4))).spo2R)
    }
}
