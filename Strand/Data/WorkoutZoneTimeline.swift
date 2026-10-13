import Foundation
import StrandAnalytics
import WhoopProtocol

/// Where each heart-rate zone fell in a session, built from the recorded stream outside SwiftUI's body: the stretches in
/// each zone, the time in each (gaps are not credited to any), the time below the first zone and the time without readings.
struct WorkoutZoneTimeline: Sendable {
    struct Interval: Identifiable, Sendable {
        let start: Int
        var end: Int
        let zone: Int
        var id: Int { start }
    }
    let intervals: [Interval]
    let minutes: [Double]
    let belowZoneMinutes: Double
    let unobservedSeconds: Double

    /// The stretches spent in one zone, as seconds from `start`, for marking them on a curve. A stretch is at least a
    /// second wide.
    func spans(inZone zone: Int, from start: Int) -> [ClosedRange<Double>] {
        intervals.filter { $0.zone == zone }
            .map { Double($0.start - start)...Double(max($0.end, $0.start + 1) - start) }
    }

    static func make(samples: [HRSample], start: Int, end: Int, maxHR: Double) -> Self {
        guard end > start, maxHR.isFinite, maxHR > 0 else {
            return .init(intervals: [], minutes: Array(repeating: 0, count: 5),
                         belowZoneMinutes: 0, unobservedSeconds: 0)
        }
        var byTime: [Int: HRSample] = [:]
        for sample in samples where sample.ts >= start && sample.ts < end && (30...240).contains(sample.bpm) {
            byTime[sample.ts] = sample
        }
        let sorted = byTime.values.sorted { $0.ts < $1.ts }
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.ts - $0.ts }.filter { $0 > 0 && $0 <= 10 }.sorted()
        let cadence = gaps.isEmpty ? 1 : gaps[gaps.count / 2]
        let zoneSet = HRZones.zones(maxHR: maxHR)
        var intervals: [Interval] = []
        var seconds = Array(repeating: 0.0, count: 6)
        for (index, sample) in sorted.enumerated() {
            let next = index + 1 < sorted.count ? sorted[index + 1].ts : end
            let stop = min(end, min(next, sample.ts + cadence))
            guard stop > sample.ts else { continue }
            let zone = zoneSet.zoneNumber(forBPM: Double(sample.bpm))
            seconds[zone] += Double(stop - sample.ts)
            if let last = intervals.last, last.zone == zone && last.end == sample.ts {
                intervals[intervals.count - 1].end = stop
            } else {
                intervals.append(.init(start: sample.ts, end: stop, zone: zone))
            }
        }
        return .init(intervals: intervals, minutes: Array(seconds.dropFirst()).map { $0 / 60 },
                     belowZoneMinutes: seconds[0] / 60,
                     unobservedSeconds: max(0, Double(end - start) - seconds.reduce(0, +)))
    }
}
