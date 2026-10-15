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

/// The phone to watch message over the same mirrored session. Pause, resume and end travel as session
/// state changes; only what a state change cannot say goes here.
public struct WatchMirrorCommand: Codable, Equatable, Sendable {
    /// The wearer discarded the workout on the phone: the watch drops its recording instead of saving it
    /// to Apple Health, where the HealthKit import would otherwise bring it straight back.
    public var discard: Bool

    public init(discard: Bool) {
        self.discard = discard
    }
}
