import Foundation
import WhoopProtocol

/// Approximate overnight arousal load. This is an inspectable signal-quality
/// model, not a diagnosis and not a reconstruction of WHOOP's private model.
public enum SleepStressV1 {
    public static let modelVersion = "sleep-stress-v1.0"
    public static let windowSeconds = 5 * 60
    public static let minimumCoveredWindows = 6
    public static let hrActivationScaleBPM = 12.0
    public static let rmssdActivationScaleMS = 25.0

    public struct Reference: Equatable, Sendable {
        public let meanSleepingHR: Double?
        public let meanSleepingRMSSD: Double?
        public init(meanSleepingHR: Double?, meanSleepingRMSSD: Double?) {
            self.meanSleepingHR = meanSleepingHR
            self.meanSleepingRMSSD = meanSleepingRMSSD
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let meanStress: Double
        public let lowStressQuality: Double
        public let coveredWindows: Int
        public let modelVersion: String
    }

    /// Scores a selected main-night span. `priorReferences` must contain prior
    /// trusted nights only; the current night is deliberately a separate input.
    public static func score(start: Int, end: Int, hr: [HRSample], rr: [RRInterval],
                             stages: [StageSegment], motion: [Double] = [],
                             priorReferences: [Reference]) -> Result? {
        guard end > start else { return nil }
        let priorHR = priorReferences.compactMap(\.meanSleepingHR)
        let priorRMSSD = priorReferences.compactMap(\.meanSleepingRMSSD)
        let hrRef = median(priorHR)
        let rmssdRef = median(priorRMSSD)
        guard hrRef != nil || rmssdRef != nil else { return nil }

        var stress: [Double] = []
        var t = start
        var motionIndex = 0
        while t < end {
            let hi = min(end, t + windowSeconds)
            let h = hr.filter { $0.ts >= t && $0.ts < hi }
            let r = rr.filter { $0.ts >= t && $0.ts < hi }.map { $0.rrMs }
            let overlap = stages.reduce(0.0) { total, stage in
                guard stage.stage == "wake" else { return total }
                return total + Double(max(0, min(hi, stage.end) - max(t, stage.start)))
            }
            let wakeFraction = overlap / Double(max(1, hi - t))
            var terms: [(Double, Double)] = []
            if let ref = hrRef, h.count >= 3 {
                let bpmTotal = h.reduce(0) { partial, sample in partial + sample.bpm }
                let mean = Double(bpmTotal) / Double(h.count)
                terms.append((max(0, mean - ref) / hrActivationScaleBPM, 0.35))
            }
            if let ref = rmssdRef, r.count >= 3, let rmssd = rmssd(r) {
                terms.append((max(0, ref - rmssd) / rmssdActivationScaleMS, 0.35))
            }
            terms.append((wakeFraction * 3, 0.20))
            if motion.indices.contains(motionIndex) {
                terms.append((max(0, motion[motionIndex]), 0.10))
            }
            motionIndex += 1
            let physiological = terms.contains { $0.1 == 0.35 }
            if physiological {
                let weight = terms.reduce(0) { $0 + $1.1 }
                let value = terms.reduce(0) { $0 + $1.0 * $1.1 } / max(weight, 0.0001)
                stress.append(min(3, max(0, value)))
            }
            t = hi
        }
        guard stress.count >= minimumCoveredWindows else { return nil }
        let mean = stress.reduce(0, +) / Double(stress.count)
        return Result(meanStress: round4(mean), lowStressQuality: round4(1 - mean / 3),
                      coveredWindows: stress.count, modelVersion: modelVersion)
    }

    private static func rmssd(_ intervals: [Int]) -> Double? {
        guard intervals.count >= 3 else { return nil }
        let diffs = zip(intervals.dropFirst(), intervals).map { Double($0 - $1) }
        guard !diffs.isEmpty else { return nil }
        return (diffs.reduce(0) { $0 + $1 * $1 } / Double(diffs.count)).squareRoot()
    }
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
    private static func round4(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
}
