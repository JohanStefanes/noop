import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen / Action Button control that puts the live heart rate banner up without opening
/// NOOP. A button, not a toggle: iOS owns the banner's lifetime (it can end or the user can swipe it away without
/// NOOP hearing), so a toggle would claim a state it cannot know. Runs `ShowLiveHRIntent` in NOOP's process.
@available(iOS 18.0, *)
struct LiveHRControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.noop.control.liveHR") {
            ControlWidgetButton(action: ShowLiveHRIntent()) {
                Label("Live Heart Rate", systemImage: "heart.text.square")
            }
        }
        .displayName("Live Heart Rate")
        .description("Show your strap's live heart rate on the Lock Screen.")
    }
}
