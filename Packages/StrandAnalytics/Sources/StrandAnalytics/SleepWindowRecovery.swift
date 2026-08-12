import Foundation
import WhoopProtocol

/// Why the user-scoped sleep analysis ran. Raw values are persisted in WhoopStore's
/// audit table so a corrected night remains explainable after later reprocessing.
public enum SleepWindowRecoverySource: String, Codable, Sendable {
    case retry
    case manualWindow = "manual_window"
}

/// The strongest conclusion NOOP can defend from the data inside a user-supplied window.
public enum SleepWindowRecoveryOutcome: String, Codable, Sendable {
    case complete
    case partial
    case insufficientData = "insufficient_data"
    case invalidWindow = "invalid_window"
    case noSleepEvidence = "no_sleep_evidence"
}

/// Machine-readable reason paired with `SleepWindowRecoveryOutcome`.
public enum SleepWindowRecoveryReason: String, Codable, Sendable {
    case boundedReanalysis = "bounded_reanalysis"
    case sparseMotion = "sparse_motion"
    case noPhysiology = "no_physiology"
    case invalidDuration = "invalid_duration"
    case noAsleepEpochs = "no_asleep_epochs"
}

/// Counts and time coverage used to calibrate the result's confidence. These are
/// evidence summaries only; no raw samples leave the local store.
public struct SleepWindowEvidence: Equatable, Sendable {
    public let gravitySamples: Int
    public let hrSamples: Int
    public let rrSamples: Int
    public let respSamples: Int
    public let gravityCoverage: Double
    public let hrCoverage: Double
    public let rrCoverage: Double
    public let respCoverage: Double

    public init(
        gravitySamples: Int,
        hrSamples: Int,
        rrSamples: Int,
        respSamples: Int,
        gravityCoverage: Double,
        hrCoverage: Double,
        rrCoverage: Double,
        respCoverage: Double
    ) {
        self.gravitySamples = gravitySamples
        self.hrSamples = hrSamples
        self.rrSamples = rrSamples
        self.respSamples = respSamples
        self.gravityCoverage = gravityCoverage
        self.hrCoverage = hrCoverage
        self.rrCoverage = rrCoverage
        self.respCoverage = respCoverage
    }
}

/// Result of reprocessing a user-bounded interval. Empty `stages` means staging was
/// not defensible; usable overnight vitals may still be present and can feed Charge.
public struct SleepWindowRecoveryResult: Equatable, Sendable {
    public let source: SleepWindowRecoverySource
    public let outcome: SleepWindowRecoveryOutcome
    public let reason: SleepWindowRecoveryReason
    public let confidence: Double
    public let requestedStart: Int
    public let requestedEnd: Int
    public let stages: [StageSegment]
    public let efficiency: Double?
    public let restingHR: Int?
    public let avgHRV: Double?
    public let evidence: SleepWindowEvidence
    public let algorithmVersion: String

    public init(
        source: SleepWindowRecoverySource,
        outcome: SleepWindowRecoveryOutcome,
        reason: SleepWindowRecoveryReason,
        confidence: Double,
        requestedStart: Int,
        requestedEnd: Int,
        stages: [StageSegment],
        efficiency: Double?,
        restingHR: Int?,
        avgHRV: Double?,
        evidence: SleepWindowEvidence,
        algorithmVersion: String = SleepWindowRecovery.algorithmVersion
    ) {
        self.source = source
        self.outcome = outcome
        self.reason = reason
        self.confidence = min(1, max(0, confidence))
        self.requestedStart = requestedStart
        self.requestedEnd = requestedEnd
        self.stages = stages
        self.efficiency = efficiency
        self.restingHR = restingHR
        self.avgHRV = avgHRV
        self.evidence = evidence
        self.algorithmVersion = algorithmVersion
    }

    public var canPersistSession: Bool {
        outcome == .complete || outcome == .partial
    }

    public var hasDefensibleStages: Bool {
        !stages.isEmpty
    }
}

/// Checked wall-clock arithmetic shared by the bounded recovery path. The raw-store
/// boundary is hostile: a corrupt export can contain either `Int.min` or `Int.max`.
/// Never turn an invalid duration into a wrapped interval that looks like a real night.
enum SleepTimestampMath {
    static func nonnegativeDuration(start: Int, end: Int) -> Int? {
        let (duration, overflow) = end.subtractingReportingOverflow(start)
        guard !overflow, duration >= 0 else { return nil }
        return duration
    }

    static func adding(_ delta: Int, to value: Int) -> Int? {
        let (result, overflow) = value.addingReportingOverflow(delta)
        return overflow ? nil : result
    }

    static func subtracting(_ delta: Int, from value: Int) -> Int? {
        let (result, overflow) = value.subtractingReportingOverflow(delta)
        return overflow ? nil : result
    }
}

/// Bounded fallback for a detector miss. The user provides only the search interval;
/// NOOP still derives stages and vitals from recorded physiology inside that interval.
public enum SleepWindowRecovery {
    public static let algorithmVersion = "sleep-window-recovery-v1"
    public static let minWindowSeconds = 30 * 60
    public static let maxWindowSeconds = SleepStager.maxMainSleepSpanS

    public static func analyze(
        start: Int,
        end: Int,
        source: SleepWindowRecoverySource = .manualWindow,
        hr: [HRSample] = [],
        rr: [RRInterval] = [],
        resp: [RespSample] = [],
        gravity: [GravitySample] = [],
        useSleepStagerV2: Bool = false
    ) -> SleepWindowRecoveryResult {
        guard let duration = SleepTimestampMath.nonnegativeDuration(start: start, end: end),
              duration >= minWindowSeconds,
              duration <= maxWindowSeconds
        else {
            return result(
                source: source,
                outcome: .invalidWindow,
                reason: .invalidDuration,
                confidence: 0,
                start: start,
                end: end,
                evidence: SleepWindowEvidence(
                    gravitySamples: 0,
                    hrSamples: 0,
                    rrSamples: 0,
                    respSamples: 0,
                    gravityCoverage: 0,
                    hrCoverage: 0,
                    rrCoverage: 0,
                    respCoverage: 0))
        }
        let hrWindow = hr.filter { $0.ts >= start && $0.ts <= end }.sorted { $0.ts < $1.ts }
        let rrWindow = rr.filter { $0.ts >= start && $0.ts <= end }.sorted { $0.ts < $1.ts }
        let respWindow = resp.filter { $0.ts >= start && $0.ts <= end }.sorted { $0.ts < $1.ts }
        let gravityWindow = gravity.filter { $0.ts >= start && $0.ts <= end }.sorted { $0.ts < $1.ts }

        let evidence = SleepWindowEvidence(
            gravitySamples: gravityWindow.count,
            hrSamples: hrWindow.count,
            rrSamples: rrWindow.count,
            respSamples: respWindow.count,
            gravityCoverage: coverageFraction(gravityWindow.map(\.ts), start: start, end: end),
            hrCoverage: coverageFraction(hrWindow.map(\.ts), start: start, end: end),
            rrCoverage: coverageFraction(rrWindow.map(\.ts), start: start, end: end),
            respCoverage: coverageFraction(respWindow.map(\.ts), start: start, end: end)
        )

        // Gravity alone is not evidence that the strap was worn: an off-wrist device can
        // be perfectly still for hours. Require at least one physiological stream before
        // the user's bounds may create a session. Motion remains the staging signal, not
        // the wear proof.
        guard !hrWindow.isEmpty || !rrWindow.isEmpty || !respWindow.isEmpty else {
            return result(
                source: source, outcome: .insufficientData, reason: .noPhysiology,
                confidence: 0, start: start, end: end, evidence: evidence)
        }

        let restingHR = SleepStager.sessionRestingHR(start: start, end: end, hr: hrWindow)
        let avgHRV = SleepStager.sessionAvgHRV(start: start, end: end, rr: rrWindow)

        // Match the existing edit/re-stage density floor while also requiring samples
        // to cover meaningfully different portions of the window. This prevents the
        // stager's intentionally permissive all-light sparse fallback from becoming
        // fabricated stage certainty in a manual recovery.
        let minimumGravitySamples = max(20, duration / 120)
        let canDefendStages = gravityWindow.count >= minimumGravitySamples
            && evidence.gravityCoverage >= 0.35

        guard canDefendStages else {
            let hasVitals = restingHR != nil || avgHRV != nil
            return result(
                source: source,
                outcome: hasVitals ? .partial : .insufficientData,
                reason: hasVitals ? .sparseMotion : .noPhysiology,
                confidence: hasVitals ? partialConfidence(evidence) : 0,
                start: start,
                end: end,
                stages: [],
                efficiency: nil,
                restingHR: restingHR,
                avgHRV: avgHRV,
                evidence: evidence)
        }

        let stages = useSleepStagerV2
            ? SleepStagerV2.stageSession(
                start: start, end: end, grav: gravityWindow,
                hr: hrWindow, rr: rrWindow, resp: respWindow)
            : SleepStager.stageSession(
                start: start, end: end, grav: gravityWindow,
                hr: hrWindow, rr: rrWindow, resp: respWindow)

        guard let asleepSeconds = asleepSeconds(in: stages, start: start, end: end) else {
            let hasVitals = restingHR != nil || avgHRV != nil
            return result(
                source: source,
                outcome: hasVitals ? .partial : .noSleepEvidence,
                reason: .noAsleepEpochs,
                confidence: hasVitals ? partialConfidence(evidence) : 0.15,
                start: start,
                end: end,
                stages: [],
                efficiency: nil,
                restingHR: restingHR,
                avgHRV: avgHRV,
                evidence: evidence)
        }
        guard asleepSeconds >= 20 * 60 else {
            let hasVitals = restingHR != nil || avgHRV != nil
            return result(
                source: source,
                outcome: hasVitals ? .partial : .noSleepEvidence,
                reason: .noAsleepEpochs,
                confidence: hasVitals ? partialConfidence(evidence) : 0.15,
                start: start,
                end: end,
                stages: [],
                efficiency: nil,
                restingHR: restingHR,
                avgHRV: avgHRV,
                evidence: evidence)
        }

        let efficiency = SleepStager.efficiency(start: start, end: end, stages: stages)
        let confidence = completeConfidence(evidence, efficiency: efficiency)
        return result(
            source: source,
            outcome: .complete,
            reason: .boundedReanalysis,
            confidence: confidence,
            start: start,
            end: end,
            stages: stages,
            efficiency: efficiency,
            restingHR: restingHR,
            avgHRV: avgHRV,
            evidence: evidence)
    }

    /// Occupied five-minute buckets divided by all buckets in the requested interval.
    /// This is robust to 1 Hz and sparse streams and avoids rewarding a clump of samples.
    static func coverageFraction(_ timestamps: [Int], start: Int, end: Int) -> Double {
        guard let duration = SleepTimestampMath.nonnegativeDuration(start: start, end: end),
              duration > 0
        else { return 0 }
        let bucketSeconds = 5 * 60
        let bucketCount = duration / bucketSeconds
            + (duration.isMultiple(of: bucketSeconds) ? 0 : 1)
        let occupied = Set(timestamps.compactMap { ts -> Int? in
            guard ts >= start, ts <= end else { return nil }
            guard let offset = SleepTimestampMath.nonnegativeDuration(start: start, end: ts) else {
                return nil
            }
            return min(bucketCount - 1, offset / bucketSeconds)
        }).count
        return min(1, Double(occupied) / Double(bucketCount))
    }

    /// Sum only defensible asleep segments inside the requested interval. A malformed
    /// segment fails the recovery closed rather than being clipped into fabricated sleep.
    static func asleepSeconds(in stages: [StageSegment], start: Int, end: Int) -> Int? {
        guard SleepTimestampMath.nonnegativeDuration(start: start, end: end) != nil else {
            return nil
        }

        var total = 0
        for segment in stages where segment.stage != "wake" {
            guard SleepTimestampMath.nonnegativeDuration(
                start: segment.start,
                end: segment.end
            ) != nil else {
                return nil
            }
            let clippedStart = max(start, segment.start)
            let clippedEnd = min(end, segment.end)
            guard clippedEnd > clippedStart else { continue }
            guard let duration = SleepTimestampMath.nonnegativeDuration(
                start: clippedStart,
                end: clippedEnd
            ) else {
                return nil
            }
            let (nextTotal, overflow) = total.addingReportingOverflow(duration)
            guard !overflow else { return nil }
            total = nextTotal
        }
        return total
    }

    private static func partialConfidence(_ evidence: SleepWindowEvidence) -> Double {
        let physiology = 0.55 * evidence.hrCoverage
            + 0.30 * evidence.rrCoverage
            + 0.15 * evidence.respCoverage
        return min(0.64, 0.2 + 0.44 * physiology)
    }

    private static func completeConfidence(
        _ evidence: SleepWindowEvidence,
        efficiency: Double
    ) -> Double {
        let coverage = 0.55 * evidence.gravityCoverage
            + 0.20 * evidence.hrCoverage
            + 0.15 * evidence.rrCoverage
            + 0.10 * evidence.respCoverage
        let plausibility = min(1, max(0, efficiency))
        return min(0.99, 0.45 + 0.40 * coverage + 0.14 * plausibility)
    }

    private static func result(
        source: SleepWindowRecoverySource,
        outcome: SleepWindowRecoveryOutcome,
        reason: SleepWindowRecoveryReason,
        confidence: Double,
        start: Int,
        end: Int,
        stages: [StageSegment] = [],
        efficiency: Double? = nil,
        restingHR: Int? = nil,
        avgHRV: Double? = nil,
        evidence: SleepWindowEvidence
    ) -> SleepWindowRecoveryResult {
        SleepWindowRecoveryResult(
            source: source,
            outcome: outcome,
            reason: reason,
            confidence: confidence,
            requestedStart: start,
            requestedEnd: end,
            stages: stages,
            efficiency: efficiency,
            restingHR: restingHR,
            avgHRV: avgHRV,
            evidence: evidence)
    }
}
