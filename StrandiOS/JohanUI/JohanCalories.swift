import Foundation
import WhoopStore

/// One day's calorie figure and where it came from. The precedence follows the #616 rule the Liquid Today
/// tile uses (`LiquidTodayView.caloriesCount`): the day's imported Apple Health energy first, else NOOP's
/// on-device heart-rate estimate (`DailyMetric.activeKcalEst`). Unlike that tile, Apple Health counts resting
/// plus active energy when the day carries both, so it measures the same thing as NOOP's estimate (a whole
/// day's burn); active energy alone would hide most of a day, a run included. A day with no resting energy
/// still shows active only, so the source travels with the number and the screens name it.
enum JohanCalories {
    enum Source: Equatable {
        /// Apple Health resting plus active energy.
        case appleHealth
        /// Apple Health active energy only; the day carries no resting energy.
        case appleHealthActive
        case heartRate
    }

    struct Reading: Equatable {
        let kcal: Double
        let source: Source
    }

    /// One day's imported Apple Health energy.
    struct Imported: Equatable {
        var active: Double?
        var basal: Double?
    }

    /// Imported energy by day: the largest active and resting values across that day's Apple Health rows,
    /// taken separately, as Liquid Today reads active energy.
    static func importedByDay(_ rows: [AppleDaily]) -> [String: Imported] {
        var out: [String: Imported] = [:]
        for r in rows {
            var day = out[r.day] ?? Imported()
            if let k = r.activeKcal { day.active = max(day.active ?? 0, k) }
            if let k = r.basalKcal { day.basal = max(day.basal ?? 0, k) }
            out[r.day] = day
        }
        return out
    }

    /// Apple Health first when the day has active energy (resting added when present), else NOOP's estimate.
    static func reading(imported: Imported?, onDevice: Double?) -> Reading? {
        if let active = imported?.active {
            if let basal = imported?.basal, basal > 0 { return Reading(kcal: active + basal, source: .appleHealth) }
            return Reading(kcal: active, source: .appleHealthActive)
        }
        if let onDevice { return Reading(kcal: onDevice, source: .heartRate) }
        return nil
    }
}
