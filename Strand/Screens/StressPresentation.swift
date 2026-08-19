import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

/// Small owner for Stress availability and day-scope semantics. It owns presentation
/// coverage only; StressModel and DaytimeStress remain the formula owners.
struct StressPresentation {
    let daily: StressModel?
    let intraday: DaytimeStress.Result
    let historyAvailable: Bool
    let mode: StressPresentationMode

    init(
        daily: StressModel?,
        intraday: DaytimeStress.Result?,
        historyAvailable: Bool
    ) {
        self.daily = daily
        self.intraday = intraday ?? .empty
        self.historyAvailable = historyAvailable
        self.mode = Self.mode(
            dailyAvailable: daily != nil,
            intraday: intraday,
            historyAvailable: historyAvailable
        )
    }

    /// The daily score remains the authoritative headline. Intraday is an honest
    /// fallback only when a daily score is unavailable.
    var headlineScore: Double? {
        daily?.score ?? intraday.scored.last?.level ?? intraday.dayMean
    }

    static func mode(
        dailyAvailable: Bool,
        intraday: DaytimeStress.Result?,
        historyAvailable: Bool
    ) -> StressPresentationMode {
        let hasIntraday = !(intraday?.hours.isEmpty ?? true)
        switch (dailyAvailable, hasIntraday, historyAvailable) {
        case (true, true, _): return .combined
        case (false, true, _): return .intradayOnly
        case (true, false, _): return .dailyOnly
        case (false, false, true): return .empty
        case (false, false, false): return .baselineCalibration
        }
    }

    static func headlineScore(
        dailyScore: Double?,
        intraday: DaytimeStress.Result?
    ) -> Double? {
        dailyScore ?? intraday?.scored.last?.level ?? intraday?.dayMean
    }

    /// Resolve the daily Stress value for one requested day. An exact persisted
    /// point wins. Otherwise the existing StressModel derives only when the selected
    /// day has a DailyMetric row; a later row can never leak backward into a past day.
    static func dailyScore(
        for targetDay: String,
        days: [DailyMetric],
        stored: [(day: String, value: Double)]
    ) -> Double? {
        if let persisted = stored.last(where: { $0.day == targetDay })?.value {
            return min(max(persisted, 0), 3)
        }

        let scopedDays = days.filter { $0.day <= targetDay }
        guard scopedDays.last?.day == targetDay else { return nil }
        let scopedStored = stored.filter { $0.day <= targetDay }
        return StressModel(days: scopedDays, stored: scopedStored)?.score
    }

    /// Coverage evidence relative to the requested day. Future daily or stored rows
    /// do not make a past day look calibrated.
    static func historyAvailable(
        for targetDay: String,
        days: [DailyMetric],
        stored: [(day: String, value: Double)]
    ) -> Bool {
        let hasStoredHistory = stored.contains { $0.day < targetDay }
        let hasDailyHistory = days.contains {
            $0.day < targetDay && ($0.restingHr != nil || $0.avgHrv != nil)
        }
        return hasStoredHistory || hasDailyHistory
    }

    /// Convenience for callers whose final daily row is the requested day.
    static func historyAvailable(
        days: [DailyMetric],
        stored: [(day: String, value: Double)]
    ) -> Bool {
        guard let targetDay = days.last?.day ?? stored.last?.day else {
            return false
        }
        return historyAvailable(for: targetDay, days: days, stored: stored)
    }
}
