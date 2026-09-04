import Foundation
import WhoopProtocol
import WhoopStore

/// Opt-in, descriptive pre-sleep heart-rate feedback. It makes no causal or medical inference.
public enum PreSleepHeartRateFeedback {
    public static let enabledKey = "preSleepHeartRateFeedbackEnabled"
    public static let meanMetricKey = "pre_sleep_hr_mean"
    public static let validSamplesMetricKey = "pre_sleep_hr_valid_samples"
    public static let totalSamplesMetricKey = "pre_sleep_hr_total_samples"
    public static let primarySleepStartMetricKey = "pre_sleep_hr_primary_start_ts"
    public static let primarySleepEndMetricKey = "pre_sleep_hr_primary_end_ts"
    public static let metricKeys = [
        meanMetricKey,
        validSamplesMetricKey,
        totalSamplesMetricKey,
        primarySleepStartMetricKey,
        primarySleepEndMetricKey,
    ]
    public static let baselineCfg = MetricCfg(
        minVal: SleepHeartRateContrast.validMinBpm,
        maxVal: SleepHeartRateContrast.validMaxBpm,
        floorSpread: 2,
        halfLifeB: 14,
        halfLifeS: 21
    )
    public static let defaultPreSleepWindowSeconds = 30 * 60
    public static let defaultMinimumValidSamples = 10
    public static let minimumBaselineNights = Baselines.minNightsSeed

    public struct HistoricalReading: Equatable, Sendable {
        public let day: String
        public let meanBpm: Double
        public init(day: String, meanBpm: Double) { self.day = day; self.meanBpm = meanBpm }
    }

    public enum Eligibility: Equatable, Sendable {
        case disabled
        case invalidDay
        case invalidWindow
        case missingPrimarySleep
        case insufficientPreSleepSamples(valid: Int, required: Int)
        case insufficientBaseline(validNights: Int, required: Int)
        case staleBaseline(daysSinceUpdate: Int)
        case eligible
    }

    public struct Observation: Equatable, Sendable {
        public let primarySleepStartTs: Int
        public let primarySleepEndTs: Int
        public let windowStartTs: Int
        public let windowEndTs: Int
        public let meanBpm: Double
        public let validSamples: Int
        public let totalTimestampSamples: Int

        public init(primarySleepStartTs: Int, primarySleepEndTs: Int,
                    windowStartTs: Int, windowEndTs: Int, meanBpm: Double,
                    validSamples: Int, totalTimestampSamples: Int) {
            self.primarySleepStartTs = primarySleepStartTs
            self.primarySleepEndTs = primarySleepEndTs
            self.windowStartTs = windowStartTs
            self.windowEndTs = windowEndTs
            self.meanBpm = meanBpm
            self.validSamples = validSamples
            self.totalTimestampSamples = totalTimestampSamples
        }
    }

    public struct Comparison: Equatable, Sendable {
        public let baselineBpm: Double
        public let deltaBpm: Double
        public let baselineNights: Int
        public let baselineStatus: BaselineStatus
    }

    public enum Uncertainty: Equatable, Sendable {
        case provisionalBaseline
        case noPersonalComparison
        case staleBaseline(daysSinceUpdate: Int)
    }

    public enum Inference: Equatable, Sendable { case notEstablished }
    public enum Recommendation: Equatable, Sendable { case unsupported }

    public struct JournalFact: Equatable, Sendable {
        public let day: String
        public let question: String
        public let answeredYes: Bool
        public let numericValue: Double?
    }

    public struct Feedback: Equatable, Sendable {
        public let eligibility: Eligibility
        public let observation: Observation?
        public let comparison: Comparison?
        public let uncertainty: [Uncertainty]
        public let inference: Inference
        public let recommendation: Recommendation
        public let journalContext: [JournalFact]
    }

    public static func evaluate(
        enabled: Bool,
        sessions: [SleepSession],
        hr: [HRSample],
        history: [HistoricalReading],
        journalEntries: [JournalEntry],
        day: String,
        dayWindow: Range<Int>,
        habitualMidsleepSec: Int? = nil,
        timeZoneOffsetSeconds: Int = 0,
        minimumValidSamples: Int = defaultMinimumValidSamples,
        preSleepWindowSeconds: Int = defaultPreSleepWindowSeconds
    ) -> Feedback {
        guard enabled else { return result(.disabled) }
        guard canonicalDay(day) != nil else { return result(.invalidDay) }
        guard minimumValidSamples > 0, preSleepWindowSeconds > 0,
              dayWindow.lowerBound < dayWindow.upperBound else { return result(.invalidWindow) }

        let matched = sessions.filter {
            $0.end >= dayWindow.lowerBound && $0.end < dayWindow.upperBound && $0.start < $0.end
        }
        let indices = SleepStageTotals.mainNightGroupIndices(
            matched.map { SleepStageTotals.NightBlock(start: $0.start, end: $0.end) },
            offsetSec: timeZoneOffsetSeconds,
            habitualMidsleepSec: habitualMidsleepSec
        ) ?? []
        guard let primaryStart = indices.map({ matched[$0].start }).min(),
              let primaryEnd = indices.map({ matched[$0].end }).max(),
              primaryStart < primaryEnd else { return result(.missingPrimarySleep) }

        let (windowStart, overflow) = primaryStart.subtractingReportingOverflow(preSleepWindowSeconds)
        guard !overflow else { return result(.invalidWindow) }
        var seenTimestamps = Set<Int>()
        let inWindow = hr.filter {
            seenTimestamps.insert($0.ts).inserted && $0.ts >= windowStart && $0.ts < primaryStart
        }
        let valid = inWindow.filter {
            baselineCfg.minVal <= Double($0.bpm) && Double($0.bpm) <= baselineCfg.maxVal
        }
        guard valid.count >= minimumValidSamples else {
            return result(.insufficientPreSleepSamples(valid: valid.count, required: minimumValidSamples))
        }

        let mean = Double(valid.reduce(0) { $0 + $1.bpm }) / Double(valid.count)
        let observation = Observation(
            primarySleepStartTs: primaryStart,
            primarySleepEndTs: primaryEnd,
            windowStartTs: windowStart,
            windowEndTs: primaryStart,
            meanBpm: mean,
            validSamples: valid.count,
            totalTimestampSamples: inWindow.count
        )

        return evaluate(observation: observation, history: history,
                        journalEntries: journalEntries, day: day)
    }

    /// Apply the same baseline and uncertainty policy to a persisted observation. This keeps display
    /// reads pure and prevents a UI from loading raw HR a second time.
    public static func evaluate(
        observation: Observation,
        history: [HistoricalReading],
        journalEntries: [JournalEntry],
        day: String
    ) -> Feedback {
        guard let evaluationDate = canonicalDay(day) else { return result(.invalidDay) }
        guard observation.primarySleepStartTs < observation.primarySleepEndTs,
              observation.windowStartTs < observation.windowEndTs,
              observation.windowEndTs == observation.primarySleepStartTs,
              observation.meanBpm.isFinite,
              baselineCfg.minVal <= observation.meanBpm,
              observation.meanBpm <= baselineCfg.maxVal,
              observation.validSamples > 0,
              observation.totalTimestampSamples >= observation.validSamples else {
            return result(.invalidWindow)
        }

        let historyByDay = Dictionary(grouping: history, by: \.day)
        let priorHistory = historyByDay.compactMap { _, readings -> (HistoricalReading, Date)? in
            // Ambiguous duplicate days are excluded independent of input order.
            guard readings.count == 1, let reading = readings.first,
                  let date = canonicalDay(reading.day), date < evaluationDate else { return nil }
            return (reading, date)
        }.sorted { $0.1 < $1.1 }
        let rolling = Baselines.rollingMeanSD(priorHistory.map { $0.0.meanBpm }, cfg: baselineCfg)
        let latestValidDate = priorHistory.last {
            baselineCfg.minVal <= $0.0.meanBpm && $0.0.meanBpm <= baselineCfg.maxVal
        }?.1
        let daysSinceUpdate = latestValidDate.flatMap {
            gregorianUTC.dateComponents([.day], from: $0, to: evaluationDate).day
        }.map { max(0, $0) } ?? 0
        let baseline = BaselineState(
            baseline: rolling.baseline,
            spread: rolling.spread,
            nValid: rolling.nValid,
            nightsSinceUpdate: daysSinceUpdate,
            status: Baselines.computeStatus(nValid: rolling.nValid, nightsSinceUpdate: daysSinceUpdate)
        )
        let context = journalEntries.filter { $0.day == day }.map {
            JournalFact(day: $0.day, question: $0.question, answeredYes: $0.answeredYes,
                        numericValue: $0.numericValue)
        }
        guard baseline.nValid >= minimumBaselineNights else {
            return result(.insufficientBaseline(validNights: baseline.nValid, required: minimumBaselineNights),
                          observation: observation, uncertainty: [.noPersonalComparison], context: context)
        }
        guard baseline.usable else {
            return result(.staleBaseline(daysSinceUpdate: baseline.nightsSinceUpdate),
                          observation: observation,
                          uncertainty: [.staleBaseline(daysSinceUpdate: baseline.nightsSinceUpdate)],
                          context: context)
        }
        let comparison = Comparison(
            baselineBpm: baseline.baseline,
            deltaBpm: observation.meanBpm - baseline.baseline,
            baselineNights: baseline.nValid,
            baselineStatus: baseline.status
        )
        return result(.eligible, observation: observation, comparison: comparison,
                      uncertainty: baseline.status == .trusted ? [] : [.provisionalBaseline], context: context)
    }

    private static func result(
        _ eligibility: Eligibility,
        observation: Observation? = nil,
        comparison: Comparison? = nil,
        uncertainty: [Uncertainty] = [],
        context: [JournalFact] = []
    ) -> Feedback {
        Feedback(eligibility: eligibility, observation: observation, comparison: comparison,
                 uncertainty: uncertainty, inference: .notEstablished, recommendation: .unsupported,
                 journalContext: context)
    }

    private static let gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func canonicalDay(_ day: String) -> Date? {
        let bytes = Array(day.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return nil }
        let digits = [0, 1, 2, 3, 5, 6, 8, 9]
        guard digits.allSatisfy({ (48...57).contains(bytes[$0]) }) else { return nil }
        let year = Int(bytes[0] - 48) * 1_000 + Int(bytes[1] - 48) * 100
            + Int(bytes[2] - 48) * 10 + Int(bytes[3] - 48)
        let month = Int(bytes[5] - 48) * 10 + Int(bytes[6] - 48)
        let dayOfMonth = Int(bytes[8] - 48) * 10 + Int(bytes[9] - 48)
        guard let date = gregorianUTC.date(from: DateComponents(year: year, month: month, day: dayOfMonth)) else {
            return nil
        }
        let parts = gregorianUTC.dateComponents([.era, .year, .month, .day], from: date)
        guard parts.era == 1, parts.year == year, parts.month == month, parts.day == dayOfMonth else { return nil }
        return date
    }
}
