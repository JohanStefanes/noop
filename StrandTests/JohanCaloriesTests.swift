import XCTest
import WhoopStore

/// `JohanCalories`: Apple Health counts the whole day (resting plus active) when it has both, active only
/// when it has no resting energy, and NOOP's estimate only when Apple Health has no active energy.
final class JohanCaloriesTests: XCTestCase {
    private func apple(_ day: String, active: Double?, basal: Double?) -> AppleDaily {
        AppleDaily(day: day, steps: nil, activeKcal: active, basalKcal: basal, vo2max: nil,
                   avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil)
    }

    func testAppleHealthAddsRestingEnergy() {
        let r = JohanCalories.reading(imported: .init(active: 825, basal: 1650), onDevice: 2300)
        XCTAssertEqual(r, .init(kcal: 2475, source: .appleHealth))
    }

    func testAppleHealthWithoutRestingEnergyIsActiveOnly() {
        XCTAssertEqual(JohanCalories.reading(imported: .init(active: 825, basal: nil), onDevice: 2300),
                       .init(kcal: 825, source: .appleHealthActive))
        XCTAssertEqual(JohanCalories.reading(imported: .init(active: 825, basal: 0), onDevice: nil),
                       .init(kcal: 825, source: .appleHealthActive))
    }

    func testRestingEnergyAloneFallsBackToEstimate() {
        XCTAssertEqual(JohanCalories.reading(imported: .init(active: nil, basal: 1650), onDevice: 2300),
                       .init(kcal: 2300, source: .heartRate))
        XCTAssertNil(JohanCalories.reading(imported: nil, onDevice: nil))
    }

    func testImportedByDayTakesEachLargestValueSeparately() {
        let byDay = JohanCalories.importedByDay([
            apple("2026-10-19", active: 825, basal: nil),
            apple("2026-10-19", active: 400, basal: 1650),
            apple("2026-10-18", active: nil, basal: nil),
        ])
        XCTAssertEqual(byDay["2026-10-19"], .init(active: 825, basal: 1650))
        XCTAssertEqual(byDay["2026-10-18"], .init(active: nil, basal: nil))
    }
}
