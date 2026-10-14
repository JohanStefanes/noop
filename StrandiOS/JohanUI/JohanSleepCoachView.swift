#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

/// "Schlaf-Coach": tonight's bedtime from sleep need + sleep debt (+ body clock), last night's hypnogram
/// and the sleep-debt trend.
struct JohanSleepCoachView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @StateObject private var coach = JohanSleepCoachModel()

    var body: some View {
        JohanScreen(title: "Schlaf") {
            if let rec = coach.recommendation {
                bedtimeCard(rec).johanStagger(0)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            }
            if coach.loaded {
                nightCard.johanStagger(1)
                debtCard.johanStagger(2)
            }
        }
        .task { await coach.load(repo: repo, circadian: model.circadianPhase) }
        .onReceive(repo.$days.dropFirst()) { _ in
            Task { await coach.load(repo: repo, circadian: model.circadianPhase) }
        }
    }

    // MARK: Bedtime

    private func bedtimeCard(_ rec: JohanSleepCoachModel.Recommendation) -> some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                JohanOverline("Empfohlene Schlafenszeit heute")
                Text(clock(rec.bedtimeMinutes))
                    .font(JohanTheme.number(56)).foregroundStyle(JohanTheme.sleepViolet)
                HStack(spacing: 18) {
                    stat("Aufstehen", clock(rec.wakeMinutes))
                    stat("Ziel", hm(rec.targetSleepMin))
                    stat("Bedarf", hm(rec.needMin))
                    if rec.paybackMin >= 1 { stat("Schuld", "+" + hm(rec.paybackMin)) }
                }
                Text(explanation(rec)).font(.system(size: 12)).foregroundStyle(JohanTheme.textSecondary)
                if let clockWindow = JohanSleepCoachModel.bodyClock(model.circadianPhase, durationMin: rec.targetSleepMin) {
                    Divider().overlay(JohanTheme.cardBorder)
                    JohanOverline("Innere Uhr")
                    Text("Ideales Fenster \(hourText(clockWindow.idealBedHour)) bis \(hourText(clockWindow.idealWakeHour)). \(clockWindow.note)")
                        .font(.system(size: 13)).foregroundStyle(JohanTheme.textSecondary)
                }
                NavigationLink {
                    SmartAlarmView()
                        .background(JohanTheme.background.ignoresSafeArea())
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Aufstehzeit & Erinnerung anpassen", systemImage: "alarm")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(JohanTheme.sleepViolet)
                }
            }
        }
    }

    private func explanation(_ rec: JohanSleepCoachModel.Recommendation) -> String {
        if rec.nightsUsed == 0 {
            return "Noch keine Schlafdaten: Die Empfehlung nutzt den Standardbedarf von \(hm(rec.needMin)) und deine eingestellte Aufstehzeit. Sie wird genauer, sobald Nächte aufgezeichnet sind."
        }
        let extra = rec.paybackMin >= 1 ? " plus \(hm(rec.paybackMin)) zum Abbau deiner Schlafschuld" : ""
        return "Aufstehzeit minus Schlafbedarf (\(hm(rec.needMin)))\(extra), basierend auf \(rec.nightsUsed) Nächten."
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(JohanTheme.textSecondary)
            Text(value).font(JohanTheme.number(17)).lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    // MARK: Last night

    private var nightCard: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 12) {
                JohanOverline("Letzte Nacht")
                if let night = coach.night {
                    Text("\(timeText(night.start)) – \(timeText(night.end)) · \(hm(night.stages.asleep)) Schlaf")
                        .font(.system(size: 15, weight: .semibold))
                    Hypnogram(intervals: night.intervals, height: 130, showsStageAxis: true,
                              showsHover: false, nightStart: night.start, showsTimeAxis: true, filled: true)
                        .johanRevealLeftToRight()
                    HStack(spacing: 14) {
                        stageStat("Tief", night.stages.deep)
                        stageStat("REM", night.stages.rem)
                        stageStat("Leicht", night.stages.light)
                        stageStat("Wach", night.stages.awake)
                    }
                } else {
                    Text("Noch keine Nacht aufgezeichnet. Trag das Armband über Nacht, dann erscheint hier dein Schlafverlauf.")
                        .font(.system(size: 13)).foregroundStyle(JohanTheme.textSecondary)
                }
            }
        }
    }

    private func stageStat(_ title: String, _ min: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(JohanTheme.textSecondary)
            Text(hm(min)).font(JohanTheme.number(15))
        }
    }

    // MARK: Debt trend

    private var debtCard: some View {
        JohanCard {
            VStack(alignment: .leading, spacing: 10) {
                JohanOverline("Schlafschuld")
                if let ledger = coach.debt, ledger.nightCount > 0 {
                    let inDebt = ledger.isDebt && ledger.magnitudeMin >= SleepDebt.onTargetBandMin
                    HStack(alignment: .firstTextBaseline) {
                        Text(inDebt ? hm(ledger.magnitudeMin) : "Ausgeglichen")
                            .font(JohanTheme.number(26))
                            .foregroundStyle(inDebt ? JohanTheme.recoveryYellow : JohanTheme.recoveryGreen)
                        Spacer()
                        Text("letzte \(ledger.nightCount) Nächte").font(.system(size: 12))
                            .foregroundStyle(JohanTheme.textSecondary)
                    }
                    if coach.debtTrend.count >= 2 {
                        JohanGrowBars(values: coach.debtTrend.map(\.value), color: JohanTheme.sleepViolet,
                                      formatAxis: hm)
                            .frame(height: 120)
                    }
                } else {
                    Text("Die Schlafschuld wird aus den Nächten der letzten zwei Wochen berechnet und erscheint nach der ersten aufgezeichneten Nacht.")
                        .font(.system(size: 13)).foregroundStyle(JohanTheme.textSecondary)
                }
            }
        }
    }

    // MARK: Formatting

    private func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    private func hourText(_ hour: Double) -> String {
        let m = Int((hour * 60).rounded()) % 1440
        return clock((m + 1440) % 1440)
    }

    private func hm(_ minutes: Double) -> String {
        let t = max(0, Int(minutes.rounded()))
        return t >= 60 ? "\(t / 60) Std. \(t % 60) Min." : "\(t) Min."
    }

    private func timeText(_ d: Date) -> String {
        d.formatted(.dateTime.hour().minute().locale(Locale(identifier: "de_DE")))
    }
}
#endif
