#if os(iOS)
import Foundation
import StrandAnalytics
import WhoopStore

/// Read model behind "Journal-Einfluss": how each logged journal behaviour lines up with recovery.
///
/// Mirrors how `InsightsHubView` feeds the engine (yes-days and no-days kept apart, outcome series =
/// stored `recovery` series plus the `DailyMetric` column as fallback) and hands the result to
/// `EffectRanker.rank`, which owns lag search, significance gating (`BehaviorInsights`) and the
/// confidence tier. Nothing statistical is computed here.
@MainActor
final class JohanJournalImpactModel: ObservableObject {

    /// A behaviour that is logged but has too few yes- or no-days for the engine to produce an effect.
    struct Pending: Identifiable, Equatable {
        var id: String { behavior }
        let behavior: String
        let yesDays: Int
        let noDays: Int
    }

    @Published private(set) var effects: [RankedEffect] = []
    @Published private(set) var pending: [Pending] = []
    @Published private(set) var loggedDays = 0
    @Published private(set) var loaded = false

    /// Group size the engine needs on each side before it reports an effect.
    let minGroup = BehaviorInsights.minGroupForSignificance

    func load(repo: Repository) async {
        let entries = await repo.journalEntries()
        var yes: [String: Set<String>] = [:]
        var no: [String: Set<String>] = [:]
        for e in entries {
            if e.answeredYes { yes[e.question, default: []].insert(e.day) }
            else { no[e.question, default: []].insert(e.day) }
        }

        var outcome: [String: Double] = [:]
        for row in await repo.series(key: "recovery", source: "my-whoop") { outcome[row.day] = row.value }
        for d in repo.days where outcome[d.day] == nil {
            if let r = d.recovery { outcome[d.day] = r }
        }

        let ranked = EffectRanker.rank(behaviors: yes, controls: no, outcomeByDay: outcome, outcome: "Charge")
        let ranking = Set(ranked.map(\.behavior))
        let names = Set(yes.keys).union(no.keys).subtracting(ranking)
        effects = ranked
        pending = names.sorted().map {
            Pending(behavior: $0, yesDays: yes[$0]?.count ?? 0, noDays: no[$0]?.count ?? 0)
        }
        loggedDays = Set(entries.map(\.day)).count
        loaded = true
    }
}
#endif
