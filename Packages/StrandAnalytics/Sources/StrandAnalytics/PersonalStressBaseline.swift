import Foundation
import WhoopStore

/// Availability and local-date windows for the opt-in daytime scoring reference.
public enum PersonalStressBaseline {
    public static let historyDays = 30

    public struct DayWindow: Equatable, Sendable {
        public let startTs: Int
        public let endTs: Int
        public let hours: [StressBaselineHourWindow]
    }

    public enum Resolution: Equatable, Sendable {
        case disabled
        case history(BaselineState)
        case unavailable

        public var mode: DaytimeStress.ScoringMode {
            guard case .history(let baseline) = self, baseline.usable else { return .dayRelative }
            // HR-only, matching the upstream live gate. The daily Stress score still uses its own HRV.
            return .baselineRelative(hr: baseline, rmssd: nil)
        }

        public var isPersonal: Bool {
            if case .baselineRelative = mode { return true }
            return false
        }
    }

    /// The preceding 30 complete LOCAL days; today never contributes to its own baseline.
    /// Re-anchor every day and enumerate actual calendar hours so spring/fall DST and midnight
    /// transitions cannot shift a window into the adjacent date or use yesterday's UTC offset.
    public static func windows(before now: Date, calendar: Calendar) -> [DayWindow] {
        let today = calendar.startOfDay(for: now)
        return stride(from: historyDays, through: 1, by: -1).compactMap { daysBack in
            guard let rawStart = calendar.date(byAdding: .day, value: -daysBack, to: today) else { return nil }
            let start = calendar.startOfDay(for: rawStart)
            guard let rawEnd = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let end = calendar.startOfDay(for: rawEnd)
            guard start < end, end <= today else { return nil }
            var cursor = start
            var hours: [StressBaselineHourWindow] = []
            while cursor < end {
                guard let interval = calendar.dateInterval(of: .hour, for: cursor),
                      interval.end > cursor else { break }
                let hour = calendar.component(.hour, from: cursor)
                if (DaytimeStress.wakingStartHour..<DaytimeStress.wakingEndHour).contains(hour) {
                    hours.append(StressBaselineHourWindow(
                        startTs: Int(max(start, interval.start).timeIntervalSince1970),
                        endTs: Int(min(end, interval.end).timeIntervalSince1970)))
                }
                cursor = interval.end
            }
            return DayWindow(startTs: Int(start.timeIntervalSince1970),
                             endTs: Int(end.timeIntervalSince1970), hours: hours)
        }
    }

    public static func aggregate(_ hours: [StressBaselineHourSummary]) -> Double? {
        DaytimeStress.daytimeHRAggregate(hourlyMeans: hours.compactMap {
            $0.sampleCount >= DaytimeStress.minHourHRSamples ? $0.meanHR : nil
        })
    }

    /// `dailyHR` has one entry per window, including nil for dates without enough recorded HR.
    public static func resolve(dailyHR: [Double?]) -> Resolution {
        .history(Baselines.foldHistory(dailyHR, cfg: Baselines.daytimeHRCfg))
    }
}
