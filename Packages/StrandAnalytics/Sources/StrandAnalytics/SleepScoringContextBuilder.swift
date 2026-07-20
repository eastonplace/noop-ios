import Foundation

public struct ScoredSleepDay: Codable, Equatable, Sendable {
    public let day: String
    public let summary: SleepNightSummary
    public let need: SleepNeedV2.Breakdown
    public let performance: SleepPerformanceV2.Result?
    public let debtAfterNight: SleepNeedV2.DebtUpdate
    public let modelVersion: String

    public init(day: String, summary: SleepNightSummary, need: SleepNeedV2.Breakdown,
                performance: SleepPerformanceV2.Result?, debtAfterNight: SleepNeedV2.DebtUpdate,
                modelVersion: String = SleepPerformanceV2.modelVersion) {
        self.day = day; self.summary = summary; self.need = need
        self.performance = performance; self.debtAfterNight = debtAfterNight
        self.modelVersion = modelVersion
    }
}

/// Stateful oldest-first fold for dynamic need, timing consistency, and debt.
public enum SleepScoringContextBuilder {
    public struct DailyEffort: Equatable, Sendable {
        public let day: String
        public let value: Double
        public init(day: String, value: Double) { self.day = day; self.value = value }
    }

    public static func replay(summaries: [SleepNightSummary], efforts: [DailyEffort],
                              initialDebtMinutes: Double = 0,
                              userBaselineOverrideMinutes: Double? = nil,
                              previousScoredHistory: [ScoredSleepDay] = []) -> [ScoredSleepDay] {
        let effortByDay = Dictionary(uniqueKeysWithValues: efforts.map { ($0.day, $0.value) })
        var history = previousScoredHistory.sorted { $0.day < $1.day }
        var debt = max(0, initialDebtMinutes)
        if let last = history.last { debt = last.debtAfterNight.newBalanceMinutes }
        var output: [ScoredSleepDay] = []

        for summary in summaries.sorted(by: { $0.wakeDay < $1.wakeDay }) {
            let previousDay = dayBefore(summary.wakeDay)
            let previousEffort = previousDay.flatMap { effortByDay[$0] }
            let baselineHistory = history.map { day in
                SleepNeedV2.BaselineNight(
                    totalSleepMinutes: day.summary.mainSleepMinutes,
                    previousDayEffort: dayBefore(day.day).flatMap { effortByDay[$0] },
                    efficiency: day.summary.efficiency,
                    debtBeforeNightMinutes: day.need.debtBalanceBeforeNightMinutes)
            }
            let baseline = SleepNeedV2.estimateBaseline(
                history: baselineHistory, userOverrideMinutes: userBaselineOverrideMinutes)
            let need = SleepNeedV2.calculate(.init(
                baseline: baseline, previousDayEffort: previousEffort,
                sleepDebtMinutes: debt, recentNapMinutes: summary.recentNapMinutes))
            let timing = SleepPerformanceV2.SleepTiming(
                onsetMinute: summary.onsetMinuteLocal, wakeMinute: summary.wakeMinuteLocal)
            let priors = history.suffix(SleepPerformanceV2.Config.production.consistencyHistoryNights)
                .map { SleepPerformanceV2.SleepTiming(onsetMinute: $0.summary.onsetMinuteLocal,
                                                       wakeMinute: $0.summary.wakeMinuteLocal) }
            let consistency = SleepPerformanceV2.consistency(current: timing, priorNights: priors)
            let performance = SleepPerformanceV2.score(.init(
                mainSleepMinutes: summary.mainSleepMinutes, need: need,
                efficiency: summary.efficiency, consistency: consistency,
                lowStressQuality: summary.lowStressQuality))
            let debtUpdate = SleepNeedV2.updateDebt(previousBalanceMinutes: debt, need: need,
                                                     mainSleepMinutes: summary.mainSleepMinutes)
            let scored = ScoredSleepDay(day: summary.wakeDay, summary: summary, need: need,
                                        performance: performance, debtAfterNight: debtUpdate)
            history.append(scored); output.append(scored); debt = debtUpdate.newBalanceMinutes
        }
        return output
    }

    private static func dayBefore(_ day: String) -> String? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day),
              let prior = formatter.calendar.date(byAdding: .day, value: -1, to: date) else { return nil }
        return formatter.string(from: prior)
    }
}
