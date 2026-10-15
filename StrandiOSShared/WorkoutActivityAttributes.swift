#if os(iOS)
import Foundation
import ActivityKit

/// Live Activity for a running workout: time, heart rate and strain on the Lock Screen and in the
/// Dynamic Island. Separate from the live-HR banner (`NOOPActivityAttributes`), which stands aside while
/// this one shows, as it does for the Lift Log banner.
///
/// Time travels as dates so the widget's clock ticks on its own; every word arrives already translated,
/// because the widget extension ships no string catalog.
public struct WorkoutActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// "Recording" or "Paused", localized app-side.
        public var status: String
        public var isPaused: Bool
        /// When a running clock would have read zero: the start shifted by the time spent paused. Nil
        /// while paused, when `pausedElapsed` is shown instead.
        public var clockStart: Date?
        public var pausedElapsed: TimeInterval
        public var bpm: Int?
        /// Strain so far, formatted app-side ("8.4").
        public var strain: String

        public init(status: String, isPaused: Bool, clockStart: Date?, pausedElapsed: TimeInterval,
                    bpm: Int?, strain: String) {
            self.status = status
            self.isPaused = isPaused
            self.clockStart = clockStart
            self.pausedElapsed = pausedElapsed
            self.bpm = bpm
            self.strain = strain
        }
    }

    /// The sport, localized.
    public var sport: String
    /// SF Symbol for the sport.
    public var symbol: String
    /// "Strain" and "bpm", localized.
    public var strainWord: String
    public var bpmWord: String

    public init(sport: String, symbol: String, strainWord: String, bpmWord: String) {
        self.sport = sport
        self.symbol = symbol
        self.strainWord = strainWord
        self.bpmWord = bpmWord
    }
}
#endif
