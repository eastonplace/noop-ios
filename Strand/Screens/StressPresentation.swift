import Foundation
import StrandAnalytics
import StrandDesign

/// Small owner for Stress availability semantics. It owns presentation coverage only;
/// StressModel and DaytimeStress remain the formula owners.
struct StressPresentation {
    let daily: StressModel?
    let intraday: DaytimeStress.Result
    let mode: StressPresentationMode

    init(daily: StressModel?, intraday: DaytimeStress.Result?) {
        self.daily = daily
        self.intraday = intraday ?? .empty
        self.mode = Self.mode(dailyAvailable: daily != nil, intraday: intraday)
    }

    var headlineScore: Double? {
        intraday.scored.last?.level ?? intraday.dayMean ?? daily?.score
    }

    static func mode(
        dailyAvailable: Bool,
        intraday: DaytimeStress.Result?
    ) -> StressPresentationMode {
        let hasIntraday = !(intraday?.hours.isEmpty ?? true)
        switch (dailyAvailable, hasIntraday) {
        case (true, true): return .combined
        case (false, true): return .intradayOnly
        case (true, false): return .dailyOnly
        case (false, false): return .baselineCalibration
        }
    }

    static func headlineScore(
        dailyScore: Double?,
        intraday: DaytimeStress.Result?
    ) -> Double? {
        intraday?.scored.last?.level ?? intraday?.dayMean ?? dailyScore
    }
}
