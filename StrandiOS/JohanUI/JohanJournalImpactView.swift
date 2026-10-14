#if os(iOS)
import SwiftUI
import StrandAnalytics

/// "Journal-Einfluss": per logged behaviour, the direction and size of its effect on recovery together
/// with the sample count and the engine's confidence tier. Logging itself stays in the existing journal UI.
struct JohanJournalImpactView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = JohanJournalImpactModel()

    var body: some View {
        JohanScreen(title: "Journal") {
            logLink.johanStagger(0)
            if !model.loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            } else if model.effects.isEmpty {
                emptyState.johanStagger(1)
            } else {
                JohanOverline("Einfluss auf die Erholung")
                let maxAbs = max(10, model.effects.map { abs($0.effect.delta) }.max() ?? 10)
                ForEach(Array(model.effects.enumerated()), id: \.element.behavior) { i, r in
                    effectCard(r, index: i, maxAbs: maxAbs).johanStagger(i + 1)
                }
                Text("Muster, keine Beweise: ein Einfluss zeigt, was gemeinsam auftritt, nicht was es verursacht.")
                    .font(.system(size: 12)).foregroundStyle(JohanTheme.textTertiary)
            }
            if model.loaded, !model.pending.isEmpty { pendingCard.johanStagger(model.effects.count + 1) }
        }
        .task { await model.load(repo: repo) }
        .onReceive(repo.$days.dropFirst()) { _ in Task { await model.load(repo: repo) } }
    }

    // MARK: Link to the existing logging UI

    private var logLink: some View {
        NavigationLink {
            InsightsView()
                .background(JohanTheme.background.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            JohanCard(pressable: false) {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(JohanTheme.recoveryGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tag im Journal erfassen").font(.system(size: 16, weight: .semibold))
                        Text("\(model.loggedDays) Tage erfasst")
                            .font(.system(size: 12)).foregroundStyle(JohanTheme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(JohanTheme.textTertiary)
                }
            }
        }
        .buttonStyle(JohanPressStyle())
    }

    // MARK: Empty state

    private var emptyState: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 28)).foregroundStyle(JohanTheme.textTertiary)
                Text("Noch keine Auswertung").font(.system(size: 18, weight: .semibold))
                Text("Für jedes Verhalten braucht es mindestens \(model.minGroup) Tage mit und \(model.minGroup) Tage ohne Eintrag, jeweils mit einem Erholungswert. Erfasse dein Journal ein paar Wochen lang, dann siehst du hier, was deine Erholung hebt oder senkt.")
                    .font(.system(size: 13)).foregroundStyle(JohanTheme.textSecondary)
            }
        }
    }

    // MARK: Effect card

    private func effectCard(_ r: RankedEffect, index: Int, maxAbs: Double) -> some View {
        let e = r.effect
        let positive = e.delta > 0
        let color: Color = abs(e.delta) < 0.5 ? JohanTheme.textSecondary
            : (positive ? JohanTheme.recoveryGreen : JohanTheme.recoveryRed)
        let sign = e.delta >= 0 ? "+" : "−"
        return JohanCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.behavior).font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Text("\(sign)\(Int(abs(e.delta).rounded())) %-Pkt.")
                        .font(JohanTheme.number(20)).foregroundStyle(color)
                }
                JohanDivergingBar(delta: e.delta, maxAbs: maxAbs, color: color, index: index)
                HStack(spacing: 8) {
                    chip(magnitude(e.cohensD), color: color)
                    chip(timing(r.lag), color: JohanTheme.textSecondary)
                    chip(confidence(r.confidence), color: confidenceColor(r.confidence))
                }
                Text("Ø Erholung \(Int(e.meanWith.rounded())) % mit, \(Int(e.meanWithout.rounded())) % ohne (\(e.nWith) vs. \(e.nWithout) Tage)")
                    .font(.system(size: 12)).foregroundStyle(JohanTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func magnitude(_ d: Double) -> String {
        switch abs(d) {
        case 0.8...: return "großer Effekt"
        case 0.5..<0.8: return "mittlerer Effekt"
        case 0.2..<0.5: return "kleiner Effekt"
        default: return "kaum Effekt"
        }
    }

    private func timing(_ lag: Int) -> String {
        switch lag {
        case 0: return "am selben Tag"
        case 1: return "am nächsten Morgen"
        default: return "\(lag) Morgen später"
        }
    }

    private func confidence(_ c: ScoreConfidence) -> String {
        switch c {
        case .solid: return "zuverlässig"
        case .building: return "im Aufbau"
        case .calibrating: return "vorläufig"
        }
    }

    private func confidenceColor(_ c: ScoreConfidence) -> Color {
        switch c {
        case .solid: return JohanTheme.recoveryGreen
        case .building: return JohanTheme.recoveryYellow
        case .calibrating: return JohanTheme.textSecondary
        }
    }

    // MARK: Pending

    private var pendingCard: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 10) {
                JohanOverline("Noch zu wenig Daten")
                ForEach(model.pending) { p in
                    HStack {
                        Text(p.behavior).font(.system(size: 14))
                        Spacer()
                        Text("Ja \(p.yesDays)/\(model.minGroup) · Nein \(p.noDays)/\(model.minGroup)")
                            .font(.system(size: 12)).foregroundStyle(JohanTheme.textSecondary)
                    }
                }
            }
        }
    }
}
#endif
