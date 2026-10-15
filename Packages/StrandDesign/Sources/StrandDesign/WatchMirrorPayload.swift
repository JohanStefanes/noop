import Foundation

/// The watch to phone payload carried over a mirrored `HKWorkoutSession`. The watch app's workout
/// mirrors its session to the iPhone so NOOP there learns about the workout when it starts; this is the
/// small message the watch sends through `sendToRemoteWorkoutSession(data:)` while it records.
///
/// It lives in StrandDesign beside `WatchScoreSnapshot` for the same reason: the watchOS app encodes it
/// and the iOS mirror decodes it, so both sides share one definition and one wire shape.
public struct WatchMirrorPayload: Codable, Equatable, Sendable {
    /// The latest wrist heart rate in whole BPM, straight from the watch's live workout builder.
    public var bpm: Int

    public init(bpm: Int) {
        self.bpm = bpm
    }
}
