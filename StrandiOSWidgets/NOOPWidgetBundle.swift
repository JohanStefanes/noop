import WidgetKit
import SwiftUI

/// The widget extension entry point. Bundles the glanceable widget, the live-HR Live Activity,
/// the K10 Coach brief widget (stored morning brief on Lock Screen / Home Screen), the
/// heart-rate trace widget (#1957), the stress curve widget (#2040), the Lift Log session
/// Live Activity, the strap-sync Live Activity, and (iOS 18+) the Control Center button that starts the live-HR
/// one without opening the app.
@main
struct NOOPWidgetBundle: WidgetBundle {
    var body: some Widget {
        NOOPWidget()
        NOOPLiveActivity()
        CoachBriefWidget()
        HeartRateWidget()
        StressWidget()
        LiftLiveActivity()
        SyncLiveActivity()
        if #available(iOS 18.0, *) {
            LiveHRControl()
        }
    }
}
