#if os(iOS)
import Foundation
import AppIntents

/// What a "Show Live Heart Rate" request came to, as observed by the app.
public enum ShowLiveHROutcome: Sendable {
    case started
    case alreadyShowing
    case switchedOff
    case refused
}

/// Put the live heart rate banner on the Lock Screen WITHOUT opening NOOP: from Siri, a Shortcuts automation
/// (an alarm stopped, a time of day), or the Control Center button.
///
/// `LiveActivityIntent`, not plain `AppIntent`: ActivityKit refuses a start from an app that is not on screen,
/// except from an intent of this kind, which iOS runs inside NOOP's own process. The same reason the Sync Strap
/// shortcut is one.
///
/// Compiled into the widget extension as well, because the Control Center control names it; iOS still runs
/// `perform` in the app, which installs `handler`. The extension never sets it.
public struct ShowLiveHRIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Show Live Heart Rate"
    public static var description = IntentDescription("Show your strap's live heart rate on the Lock Screen and in the Dynamic Island.")
    public static var openAppWhenRun = false

    /// Installed by the app at launch; starts (or keeps) the banner and says what happened.
    @MainActor public static var handler: (() async -> ShowLiveHROutcome)?

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        // A cold background launch can run this before the app has finished building its model.
        var handler = Self.handler
        for _ in 0..<5 where handler == nil {
            try? await Task.sleep(nanoseconds: 500_000_000)
            handler = Self.handler
        }
        switch await handler?() ?? .refused {
        case .started:        return .result(dialog: "Showing your live heart rate.")
        case .alreadyShowing: return .result(dialog: "Your live heart rate is already showing.")
        case .switchedOff:    return .result(dialog: "The live heart rate banner is switched off in the app's settings.")
        case .refused:        return .result(dialog: "iOS didn't allow the banner. Check that Live Activities are allowed for the app.")
        }
    }
}
#endif
