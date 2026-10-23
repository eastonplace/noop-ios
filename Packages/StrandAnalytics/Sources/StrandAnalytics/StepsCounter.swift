import Foundation
import WhoopProtocol

/// Wrap-aware motion ticks shared by daily, physiological-cycle and workout estimates. Calibration is
/// applied by callers. The strap's counter and activity classes remain estimates, not validated steps.
public enum StepsCounter {
    public static let maxStepDelta = 512
    public static let maxTicksPerSecond = 4

    /// Classified records count only walking/running. Fully unclassified legacy windows retain the
    /// counter estimate, with the same rate/reset safeguards. Invalid or conflicting records never join
    /// two independent counter runs. An empty or entirely stationary window retains the existing nil API.
    public static func stepsInWindow(_ samples: [StepSample]) -> Int? {
        var total = 0
        forEachIncrement(in: samples) { _, ticks, _ in total += ticks }
        return total > 0 ? total : nil
    }

    public static func shouldCountDelta(activityClass: Int?, hasActivityClasses: Bool) -> Bool {
        !hasActivityClasses || activityClass == 1 || activityClass == 2
    }

    public static func isPlausibleDelta(previousTs: Int, currentTs: Int, delta: Int) -> Bool {
        guard delta > 0, delta < maxStepDelta, currentTs > previousTs else { return false }
        let (elapsed, overflow) = currentTs.subtractingReportingOverflow(previousTs)
        guard !overflow else { return false }
        // Clamp before multiplication so malformed dates cannot overflow the rate guard.
        return delta <= min(elapsed, maxStepDelta) * maxTicksPerSecond
    }

    /// One canonical pass for ordinary and sleep-aware totals. `newRun` also breaks a pending sleep
    /// gait bout after an invalid counter, reset, conflicting duplicate, or non-locomotion record.
    static func forEachIncrement(in samples: [StepSample],
                                 _ visit: (_ timestamp: Int, _ ticks: Int, _ newRun: Bool) -> Void) {
        let sorted = samples.sorted { $0.ts < $1.ts }
        let hasClasses = sorted.contains { (0...65_535).contains($0.counter) && $0.activityClass != nil }
        var previous: StepSample?
        var newRun = true
        var index = 0
        while index < sorted.count {
            var end = index + 1
            while end < sorted.count, sorted[end].ts == sorted[index].ts { end += 1 }
            let group = sorted[index..<end]
            index = end
            let first = group.first!
            guard (0...65_535).contains(first.counter), group.allSatisfy({ $0.counter == first.counter }) else {
                previous = nil
                newRun = true
                continue
            }
            // Equal-counter duplicates resolve independently of order. A known non-gait class wins a
            // contradictory same-second annotation instead of inventing locomotion.
            let classes = group.compactMap(\.activityClass)
            let activity = classes.filter { $0 != 1 && $0 != 2 }.min() ?? classes.min()
            let current = StepSample(ts: first.ts, counter: first.counter, activityClass: activity)
            let prior = previous
            previous = current
            guard let prior else { continue }
            guard shouldCountDelta(activityClass: current.activityClass, hasActivityClasses: hasClasses) else {
                newRun = true
                continue
            }
            let delta = (current.counter - prior.counter) & 0xffff
            if delta == 0 { continue }
            guard isPlausibleDelta(previousTs: prior.ts, currentTs: current.ts, delta: delta) else {
                newRun = true
                continue
            }
            visit(current.ts, delta, newRun)
            newRun = false
        }
    }
}
