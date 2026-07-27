import Foundation
import WhoopProtocol

/// Heart-rate recovery after a sufficiently intense workout.
///
/// This RyanBR NOOP v9.1-compatible engine works only from the locally recorded HR stream. It requires
/// sustained Zone-3-or-higher effort near exercise cessation, takes the highest recorded HR in the final
/// 30 seconds as the cessation value, and compares it with robust median readings around 1, 2, and 5
/// minutes after the workout ends.
///
/// Missing post-workout coverage remains nil. The engine never interpolates across a gap, never turns a
/// missing reading into zero, and does not feed NOOP iOS's authoritative Strain or Sleep formulas.
public enum HeartRateRecovery {
    public struct Result: Equatable, Sendable {
        public let endHR: Int
        public let after1Minute: Int?
        public let after2Minutes: Int?
        public let after5Minutes: Int?

        public init(endHR: Int, after1Minute: Int?, after2Minutes: Int?, after5Minutes: Int?) {
            self.endHR = endHR
            self.after1Minute = after1Minute
            self.after2Minutes = after2Minutes
            self.after5Minutes = after5Minutes
        }

        public var hasMeasurement: Bool {
            after1Minute != nil || after2Minutes != nil || after5Minutes != nil
        }
    }

    /// Zone 3 starts at 70% HRmax in NOOP's display-zone model.
    public static let eligibilityFractionOfMaxHR = 0.70
    /// The high-intensity effort must be one continuous run, not a sum of disconnected optical fragments.
    public static let minimumHighIntensitySeconds = 120
    /// Eligibility is tied to the end of the workout; a long cool-down must not own the recovery clock.
    public static let eligibilityLookbackSeconds = 300
    public static let cessationWindowSeconds = 30
    public static let measurementToleranceSeconds = 15
    public static let minimumSamplesPerReading = 3
    public static let maximumContinuousGapSeconds = 10
    public static let plausibleMaxHeartRateRange = 30.0...300.0

    public static func calculate(
        samples: [HRSample],
        workoutStart: Int,
        workoutEnd: Int,
        maxHR: Double
    ) -> Result? {
        guard workoutStart > 0,
              workoutEnd > workoutStart,
              maxHR.isFinite,
              plausibleMaxHeartRateRange.contains(maxHR),
              let eligibilityFloor = subtracting(eligibilityLookbackSeconds, from: workoutEnd),
              let upperBound = adding(5 * 60 + measurementToleranceSeconds, to: workoutEnd),
              let cessationFloor = subtracting(cessationWindowSeconds, from: workoutEnd)
        else { return nil }

        let lowerBound = max(workoutStart, eligibilityFloor)
        let canonical = canonicalSeconds(
            samples.filter {
                $0.ts >= lowerBound
                    && $0.ts <= upperBound
                    && (30...250).contains($0.bpm)
            }
        )
        guard canonical.count >= minimumSamplesPerReading else { return nil }

        let beforeEnd = canonical.filter { $0.ts <= workoutEnd }
        let threshold = maxHR * eligibilityFractionOfMaxHR
        guard longestSustainedSeconds(atOrAbove: threshold, in: beforeEnd) >= minimumHighIntensitySeconds else {
            return nil
        }

        let cessation = beforeEnd
            .filter { $0.ts >= cessationFloor }
            .map(\.bpm)
        guard cessation.count >= minimumSamplesPerReading,
              let endHR = cessation.max()
        else { return nil }

        func recovery(at minutes: Int) -> Int? {
            guard let target = Self.adding(minutes * 60, to: workoutEnd) else { return nil }
            let values = canonical
                .filter {
                    guard let distance = absoluteDistance($0.ts, target) else { return false }
                    return distance <= measurementToleranceSeconds
                }
                .map(\.bpm)
            guard values.count >= minimumSamplesPerReading,
                  let reading = median(values)
            else { return nil }
            return endHR - reading
        }

        let result = Result(
            endHR: endHR,
            after1Minute: recovery(at: 1),
            after2Minutes: recovery(at: 2),
            after5Minutes: recovery(at: 5)
        )
        return result.hasMeasurement ? result : nil
    }

    /// Keep one deterministic reading per stored second. Callback duplicates must not satisfy the
    /// coverage gate or overweight a median. The higher value wins only for a duplicate timestamp, matching
    /// the conservative cessation-peak policy while leaving ordinary one-Hz streams unchanged.
    private static func canonicalSeconds(_ samples: [HRSample]) -> [HRSample] {
        var output: [HRSample] = []
        output.reserveCapacity(samples.count)
        for sample in samples.sorted(by: {
            $0.ts == $1.ts ? $0.bpm < $1.bpm : $0.ts < $1.ts
        }) {
            if output.last?.ts == sample.ts {
                output[output.count - 1] = sample
            } else {
                output.append(sample)
            }
        }
        return output
    }

    /// Length of the single longest continuous high-intensity run. A low endpoint or a gap larger than the
    /// continuity allowance resets the run; separated bursts can never add together to satisfy eligibility.
    private static func longestSustainedSeconds(atOrAbove threshold: Double, in samples: [HRSample]) -> Int {
        guard samples.count >= 2 else { return 0 }
        var currentRun = 0
        var longestRun = 0
        for index in 0..<(samples.count - 1) {
            let current = samples[index]
            let next = samples[index + 1]
            let (gap, overflow) = next.ts.subtractingReportingOverflow(current.ts)
            guard !overflow,
                  gap > 0,
                  gap <= maximumContinuousGapSeconds,
                  Double(current.bpm) >= threshold,
                  Double(next.bpm) >= threshold
            else {
                currentRun = 0
                continue
            }
            let (extendedRun, runOverflow) = currentRun.addingReportingOverflow(gap)
            guard !runOverflow else {
                currentRun = 0
                continue
            }
            currentRun = extendedRun
            longestRun = max(longestRun, currentRun)
        }
        return longestRun
    }

    private static func adding(_ delta: Int, to value: Int) -> Int? {
        let (result, overflow) = value.addingReportingOverflow(delta)
        return overflow ? nil : result
    }

    private static func subtracting(_ delta: Int, from value: Int) -> Int? {
        let (result, overflow) = value.subtractingReportingOverflow(delta)
        return overflow ? nil : result
    }

    private static func absoluteDistance(_ lhs: Int, _ rhs: Int) -> Int? {
        if lhs >= rhs {
            let (distance, overflow) = lhs.subtractingReportingOverflow(rhs)
            return overflow ? nil : distance
        }
        let (distance, overflow) = rhs.subtractingReportingOverflow(lhs)
        return overflow ? nil : distance
    }

    private static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            let lower = Double(sorted[middle - 1])
            let upper = Double(sorted[middle])
            return Int(((lower + upper) / 2.0).rounded())
        }
        return sorted[middle]
    }
}
