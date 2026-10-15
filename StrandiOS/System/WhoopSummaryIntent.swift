#if os(iOS)
import Foundation
import AppIntents

/// Hand today's glance numbers to a Shortcut as JSON, so the user's own automation can put them
/// somewhere else they own (a note, an iCloud Drive file a desktop dashboard reads, ...).
///
/// Reads the App Group `WidgetSnapshot`, the same values the Home Screen widgets show, and nothing
/// more: it never opens SQLite and never contacts the strap. The snapshot is only as fresh as the
/// app's last publish, so `updated` travels with the numbers and the reader decides how stale is too
/// stale. NOOP sends nothing anywhere; where the text goes is the Shortcut's business.
struct WhoopSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Today's Summary"
    static var description = IntentDescription("Returns today's Charge, Effort, Rest, HRV, resting heart rate and strap battery as JSON text, for use in a Shortcut.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: WhoopSummary.json(from: WidgetSnapshot.load()))
    }
}

/// The JSON shape `WhoopSummaryIntent` returns. Versioned so a reader can refuse a shape it does not know.
enum WhoopSummary {
    static let version = 1

    static func json(from snapshot: WidgetSnapshot?, now: Date = Date()) -> String {
        let iso = ISO8601DateFormatter()
        var out: [String: Any] = [
            "type": "noop-summary",
            "version": version,
            "exportedAt": iso.string(from: now),
        ]
        if let s = snapshot, s.updated != .distantPast {
            out["updated"] = iso.string(from: s.updated)
            out["connected"] = s.bonded
            out["charge"] = s.recovery
            out["effort"] = s.effort
            out["effortDisplay"] = s.effortDisplay
            out["effortScale"] = (s.effortWhoop ?? false) ? "whoop" : "noop"
            out["rest"] = s.rest
            out["hrv"] = s.hrv
            out["restingHr"] = s.restingHr
            out["bpm"] = s.bpm
            out["batteryPct"] = s.batteryPct
            // Pairs, not objects: the file is read on every dashboard refresh and the trace is the bulk of it.
            out["hr"] = (s.hrSeries ?? []).map { [$0.ts, Int64($0.bpm)] }
            out["stress"] = s.stressCurve(now: now).compactMap { p in
                p.level.map { [Double(p.ts), $0] }
            }
        }
        // Assigning a nil optional through the subscript removes the key, so a missing metric is absent, not null.
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
#endif
