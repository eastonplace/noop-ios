import Foundation
import WhoopProtocol

/// The personal daytime lens follows ryanbr/noop's P10-of-hourly-means / rolling-EWMA definition.
/// It never feeds the daily Stress score, Recovery, Strain, or stored raw data.
public extension DaytimeStress {
    static let daytimeHRAggregatePercentile = 0.10
    static let daytimeRMSSDAggregatePercentile = 0.50

    struct DaytimeDayStreams: Equatable, Sendable {
        public let hr: [HRSample]
        public let rr: [RRInterval]
        public let tzOffsetSeconds: Int

        public init(hr: [HRSample], rr: [RRInterval], tzOffsetSeconds: Int) {
            self.hr = hr
            self.rr = rr
            self.tzOffsetSeconds = tzOffsetSeconds
        }
    }

    /// P10 across covered waking-hour HR means. The store can supply these small aggregates without
    /// materializing thirty days of raw samples; both paths share this one reduction.
    static func daytimeHRAggregate(hourlyMeans: [Double]) -> Double? {
        let valid = hourlyMeans.filter { $0.isFinite && (30...240).contains($0) }.sorted()
        return valid.isEmpty ? nil : quantile(valid, daytimeHRAggregatePercentile)
    }

    static func dayDaytimeAggregate(
        hr: [HRSample], rr: [RRInterval], tzOffsetSeconds: Int
    ) -> (hr: Double?, rmssd: Double?) {
        var hrByHour: [Int: [Double]] = [:]
        for sample in hr where HRValidity.isPlausible(sample.bpm) {
            let bucket = floorDiv(sample.ts + tzOffsetSeconds, bucketSeconds) * bucketSeconds
            guard isWakingHour(bucket) else { continue }
            hrByHour[bucket, default: []].append(Double(sample.bpm))
        }
        var rrByHour: [Int: [Double]] = [:]
        for sample in rr {
            let bucket = floorDiv(sample.ts + tzOffsetSeconds, bucketSeconds) * bucketSeconds
            guard isWakingHour(bucket) else { continue }
            rrByHour[bucket, default: []].append(Double(sample.rrMs))
        }
        var means: [Double] = []
        var rmssds: [Double] = []
        for (hour, values) in hrByHour where values.count >= minHourHRSamples {
            if let value = mean(values) { means.append(value) }
            if let value = HRVAnalyzer.analyze(rawRR: rrByHour[hour] ?? []).rmssd { rmssds.append(value) }
        }
        return (daytimeHRAggregate(hourlyMeans: means),
                rmssds.isEmpty ? nil : quantile(rmssds.sorted(), daytimeRMSSDAggregatePercentile))
    }

    /// One entry per local day, oldest first, including nil for missing days. Skipping empty dates
    /// would stop the existing staleness counter from aging a baseline when the strap is not worn.
    static func foldAggregates(_ aggregates: [(hr: Double?, rmssd: Double?)])
        -> (hr: BaselineState, rmssd: BaselineState?) {
        let hr = Baselines.foldHistory(aggregates.map(\.hr), cfg: Baselines.daytimeHRCfg)
        let rmssd = Baselines.foldHistory(aggregates.map(\.rmssd), cfg: Baselines.daytimeRMSSDCfg)
        return (hr, rmssd.usable ? rmssd : nil)
    }

    static func foldDaytimeBaselines(days: [DaytimeDayStreams])
        -> (hr: BaselineState, rmssd: BaselineState?) {
        foldAggregates(days.map {
            dayDaytimeAggregate(hr: $0.hr, rr: $0.rr, tzOffsetSeconds: $0.tzOffsetSeconds)
        })
    }

    static func scoringModeFromAggregates(_ aggregates: [(hr: Double?, rmssd: Double?)]) -> ScoringMode {
        let baselines = foldAggregates(aggregates)
        guard baselines.hr.usable else { return .dayRelative }
        return .baselineRelative(
            hr: baselines.hr, rmssd: daytimeRMSSDScoringEnabled ? baselines.rmssd : nil)
    }
}
