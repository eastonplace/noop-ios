import Foundation
import StrandAnalytics
import WhoopProtocol

/// One bounded rendering projection built from the recorded stream, outside SwiftUI's body.
struct WorkoutZoneTimeline: Sendable {
    struct Point: Identifiable, Sendable {
        let ts: Int
        let bpm: Int
        let segment: Int
        var id: Int { ts }
    }
    struct Interval: Identifiable, Sendable {
        let start: Int
        var end: Int
        let zone: Int
        var id: Int { start }
    }
    let points: [Point]
    let intervals: [Interval]
    let minutes: [Double]
    let belowZoneMinutes: Double
    let unobservedSeconds: Double

    static func make(samples: [HRSample], start: Int, end: Int, maxHR: Double) -> Self {
        guard end > start, maxHR.isFinite, maxHR > 0 else {
            return .init(points: [], intervals: [], minutes: Array(repeating: 0, count: 5),
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
        var rawPoints: [Point] = []
        var segment = 0
        for (index, sample) in sorted.enumerated() {
            if index > 0 && sample.ts - sorted[index - 1].ts > cadence * 2 { segment += 1 }
            rawPoints.append(.init(ts: sample.ts, bpm: sample.bpm, segment: segment))
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
        // Retain endpoints and extrema in each bucket. Never join separate recording segments.
        let bucket = max(1, Int(ceil(Double(rawPoints.count) / 400)))
        var points: [Point] = []
        for offset in stride(from: 0, to: rawPoints.count, by: bucket) {
            let slice = rawPoints[offset..<min(rawPoints.count, offset + bucket)]
            let groups = Dictionary(grouping: slice, by: \.segment)
            for key in groups.keys.sorted() {
                guard let group = groups[key], let first = group.first, let last = group.last,
                      let low = group.min(by: { $0.bpm < $1.bpm }),
                      let high = group.max(by: { $0.bpm < $1.bpm }) else { continue }
                var unique: [Int: Point] = [:]
                for point in [first, low, high, last] { unique[point.ts] = point }
                points.append(contentsOf: unique.values.sorted { $0.ts < $1.ts })
            }
        }
        return .init(points: points, intervals: intervals, minutes: Array(seconds.dropFirst()).map { $0 / 60 },
                     belowZoneMinutes: seconds[0] / 60,
                     unobservedSeconds: max(0, Double(end - start) - seconds.reduce(0, +)))
    }
}
