import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// `analyzeDay` builds the gravity-derived activity series once and hands it to `WorkoutDetector.detect`,
/// `WorkoutTypeFeatureExtractor.extract` and the day calorie motion, instead of each rebuilding it from the
/// same gravity. A pure speed change: the precomputed path must equal the raw path exactly, and the day's
/// outputs must be the values the per-caller rebuild produced. Twin of Kotlin `DayActivitySeriesReuseTest`,
/// same fixture and literals.
final class DayActivitySeriesReuseTests: XCTestCase {

    private let day = "2026-08-23"
    private let bouts = [(9 * 3600, 9 * 3600 + 2400), (13 * 3600, 13 * 3600 + 3600),
                         (18 * 3600, 18 * 3600 + 2700)]
    private let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")

    /// A full 1 Hz calendar day: resting HR with a faint wobble, three bouts at 150 bpm with real motion.
    private func fullDay() -> (hr: [HRSample], gravity: [GravitySample], steps: [StepSample]) {
        let base = AnalyticsEngine.dayStartUtcSeconds(day)
        var hr: [HRSample] = [], gravity: [GravitySample] = [], steps: [StepSample] = []
        hr.reserveCapacity(86_400); gravity.reserveCapacity(86_400); steps.reserveCapacity(86_400)
        for t in 0..<86_400 {
            let inBout = bouts.contains { t >= $0.0 && t < $0.1 }
            hr.append(HRSample(ts: base + t, bpm: inBout ? 150 : 62 + (t / 600) % 5))
            let x = inBout ? (t % 2 == 0 ? 0.9 : 0.5) : 0.1 + Double(t % 7) * 0.002
            gravity.append(GravitySample(ts: base + t, x: x, y: 0.1, z: 0.1))
            steps.append(StepSample(ts: base + t, counter: (t / 3) & 0xFFFF, activityClass: inBout ? 2 : 0))
        }
        return (hr, gravity, steps)
    }

    /// Gravity out of ts order, so the series' own sort is exercised on both paths.
    private func shuffledGravity(_ g: [GravitySample]) -> [GravitySample] {
        var out = g
        var i = 0
        while i + 1 < out.count { out.swapAt(i, i + 1); i += 7 }
        return out.reversed()
    }

    func testDetectWithPrecomputedSeriesEqualsRawPath() {
        let (hr, g, _) = fullDay()
        let gravity = shuffledGravity(g)
        var rawFunnel: WorkoutDetector.DetectionFunnel?
        var preFunnel: WorkoutDetector.DetectionFunnel?
        let raw = WorkoutDetector.detect(hr: hr, gravity: gravity, restingHR: 60, maxHR: 185,
                                         profile: profile, funnel: { rawFunnel = $0 })
        let pre = WorkoutDetector.detect(hr: hr, gravity: gravity,
                                         activity: WorkoutDetector.activitySeries(gravity),
                                         restingHR: 60, maxHR: 185, profile: profile,
                                         funnel: { preFunnel = $0 })
        XCTAssertEqual(raw.count, 3)
        XCTAssertEqual(pre, raw)
        XCTAssertEqual(preFunnel, rawFunnel)
    }

    func testExtractWithPrecomputedSeriesEqualsRawPath() {
        let (hr, g, steps) = fullDay()
        let gravity = shuffledGravity(g)
        let series = WorkoutDetector.activitySeries(gravity)
        let base = AnalyticsEngine.dayStartUtcSeconds(day)
        for (s, e) in bouts {
            let raw = WorkoutTypeFeatureExtractor.extract(hr: hr, gravity: gravity, steps: steps,
                                                          start: base + s, end: base + e,
                                                          restingHR: 60, maxHR: 185, caloriesKcal: 500)
            let pre = WorkoutTypeFeatureExtractor.extract(hr: hr, gravity: gravity, activity: series,
                                                          steps: steps, start: base + s, end: base + e,
                                                          restingHR: 60, maxHR: 185, caloriesKcal: 500)
            XCTAssertNotNil(raw)
            XCTAssertEqual(pre, raw)
        }
    }

    /// The day's results, pinned to what `analyzeDay` produced while each caller still rebuilt the series.
    func testAnalyzeDayOutputsUnchanged() {
        let (hr, gravity, steps) = fullDay()
        let res = AnalyticsEngine.analyzeDay(day: day, hr: hr, gravity: gravity, steps: steps,
                                             dayHr: hr, daySteps: steps, dayGravity: gravity,
                                             profile: profile)
        XCTAssertEqual(res.daily.activeKcalEst, 3610.9295848211677)
        XCTAssertEqual(res.workouts.map { $0.start }, [1_787_475_604, 1_787_490_004, 1_787_508_004])
        XCTAssertEqual(res.workouts.map { $0.end }, [1_787_477_999, 1_787_493_599, 1_787_510_699])
        XCTAssertEqual(res.workouts.map { $0.caloriesKcal }, [559.5425267789391, 839.7808540472009,
                                                               629.6021085960045])
    }
}
