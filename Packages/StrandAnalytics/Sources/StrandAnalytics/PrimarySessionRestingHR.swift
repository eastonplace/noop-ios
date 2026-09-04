import Foundation
import WhoopProtocol

/// Shadow-only resting-HR definition: arithmetic mean of valid samples in the longest sleep session.
/// It is deliberately separate from the shipped resting-HR floor and must not feed scoring.
public enum PrimarySessionRestingHR {
    public static let defaultValidBpm: ClosedRange<Int> = 30...220
    public static let defaultMinValidSamples = 30
    public static let meanMetricKey = "rhr_primary_session"
    public static let validSamplesMetricKey = "rhr_primary_session_valid_samples"
    public static let durationMetricKey = "rhr_primary_session_duration_s"
    public static let metricKeys = [meanMetricKey, validSamplesMetricKey, durationMetricKey]

    public struct Session: Equatable, Sendable {
        public let durationSec: Double
        public let bpm: [Int]

        public init(durationSec: Double, bpm: [Int]) {
            self.durationSec = durationSec
            self.bpm = bpm
        }
    }

    public struct Coverage: Equatable, Sendable {
        public let validSamples: Int
        public let durationSec: Double

        public init(validSamples: Int, durationSec: Double) {
            self.validSamples = validSamples
            self.durationSec = durationSec
        }
    }

    public struct Measurement: Equatable, Sendable {
        public let meanHR: Double
        public let coverage: Coverage

        public init(meanHR: Double, coverage: Coverage) {
            self.meanHR = meanHR
            self.coverage = coverage
        }
    }

    public static func measure(
        sessions: [Session],
        validBpm: ClosedRange<Int> = defaultValidBpm,
        minValidSamples: Int = defaultMinValidSamples
    ) -> Measurement? {
        guard minValidSamples > 0 else { return nil }
        var primary: Session?
        for session in sessions where session.durationSec.isFinite && session.durationSec > 0 {
            if let current = primary {
                if session.durationSec > current.durationSec { primary = session }
            } else {
                primary = session
            }
        }
        guard let primary else { return nil }
        var validCount = 0
        var mean = 0.0
        for bpm in primary.bpm where validBpm.contains(bpm) {
            validCount += 1
            mean += (Double(bpm) - mean) / Double(validCount)
        }
        guard validCount >= minValidSamples else { return nil }
        return Measurement(
            meanHR: mean,
            coverage: Coverage(validSamples: validCount, durationSec: primary.durationSec)
        )
    }

    public static func meanHR(
        sessions: [Session],
        validBpm: ClosedRange<Int> = defaultValidBpm,
        minValidSamples: Int = defaultMinValidSamples
    ) -> Double? {
        measure(sessions: sessions, validBpm: validBpm, minValidSamples: minValidSamples)?.meanHR
    }

    public static func coverage(
        sessions: [Session],
        validBpm: ClosedRange<Int> = defaultValidBpm,
        minValidSamples: Int = defaultMinValidSamples
    ) -> Coverage? {
        measure(sessions: sessions, validBpm: validBpm, minValidSamples: minValidSamples)?.coverage
    }
}

public extension AnalyticsEngine {
    /// Windows HR once for the primary session and returns the shadow mean plus its raw coverage inputs.
    static func primarySessionRestingHRWithCoverage(
        sessions: [SleepSession],
        hr: [HRSample],
        validBpm: ClosedRange<Int> = PrimarySessionRestingHR.defaultValidBpm,
        minValidSamples: Int = PrimarySessionRestingHR.defaultMinValidSamples
    ) -> PrimarySessionRestingHR.Measurement? {
        var primary: SleepSession?
        var primaryDuration = 0
        for session in sessions {
            let (duration, overflow) = session.end.subtractingReportingOverflow(session.start)
            guard !overflow, duration > 0 else { continue }
            if primary == nil || duration > primaryDuration {
                primary = session
                primaryDuration = duration
            }
        }
        guard let primary else { return nil }

        var validCount = 0
        var mean = 0.0
        for sample in hr where sample.ts >= primary.start && sample.ts < primary.end
            && validBpm.contains(sample.bpm) {
            validCount += 1
            mean += (Double(sample.bpm) - mean) / Double(validCount)
        }
        guard validCount >= minValidSamples else { return nil }
        return .init(meanHR: mean, coverage: .init(
            validSamples: validCount,
            durationSec: Double(primaryDuration)
        ))
    }
}
