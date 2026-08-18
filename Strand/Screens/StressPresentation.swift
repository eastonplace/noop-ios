import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

/// Small owner for Stress availability semantics. It owns presentation coverage only;
/// StressModel and DaytimeStress remain the formula owners.
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

    /// Coverage evidence only; no score is derived here. A prior stored stress point
    /// or prior RHR/HRV row proves this is not a first-time baseline state.
    static func historyAvailable(
        days: [DailyMetric],
        stored: [(day: String, value: Double)]
    ) -> Bool {
        guard let todayDay = days.last?.day else {
            return !stored.isEmpty
        }
        let hasStoredHistory = stored.contains { $0.day < todayDay }
        let hasDailyHistory = days.dropLast().contains {
            $0.restingHr != nil || $0.avgHrv != nil
        }
        return hasStoredHistory || hasDailyHistory
    }
}
