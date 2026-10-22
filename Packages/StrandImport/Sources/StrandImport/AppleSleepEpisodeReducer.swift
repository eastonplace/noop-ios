import Foundation

/// Common XML/live-HealthKit sleep policy. Durations use absolute instants. A gap of at most
/// 30 minutes keeps stages in one episode; gaps add no sleep. Separate naps remain separate episodes
/// and contribute to their wake day's daily total. This does not alter any stored raw evidence.
public enum AppleSleepEpisodeReducer {
    public static let maximumStageGap: TimeInterval = 30 * 60

    public struct Episode: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let wakeDay: String
        /// Distinguishes a measured zero (sleep evidence overridden by awake) from in-bed-only input.
        public let hasAsleepEvidence: Bool
        public let asleep: Double
        public let deep: Double
        public let rem: Double
        public let core: Double
        public let awake: Double
        /// Union of in-bed envelopes. This companion metric may overlap sleep; it is never added to it.
        public let inBed: Double
    }

    /// Keeps only an unfinished episode across bounded HealthKit query chunks. Overlap queries can
    /// repeat objects; exact interval/source/identity duplicates do not change the result.
    public struct Accumulator {
        private var pending: [SleepStageInterval] = []
        public init() {}

        public mutating func ingest(_ intervals: [SleepStageInterval], through boundary: Date) -> [Episode] {
            let groups = AppleSleepEpisodeReducer.groups(pending + intervals)
            var complete: [Episode] = []
            pending = []
            for group in groups {
                if group.map(\.end).max()!.addingTimeInterval(maximumStageGap) <= boundary {
                    complete.append(AppleSleepEpisodeReducer.reduceGroup(group))
                } else {
                    pending.append(contentsOf: group)
                }
            }
            return complete
        }

        public mutating func finish() -> [Episode] {
            let result = AppleSleepEpisodeReducer.reduce(pending)
            pending = []
            return result
        }
    }

    public static func reduce(_ intervals: [SleepStageInterval]) -> [Episode] {
        groups(intervals).map(reduceGroup)
    }

    private static func groups(_ intervals: [SleepStageInterval]) -> [[SleepStageInterval]] {
        let valid = Set(intervals.filter {
            let duration = $0.end.timeIntervalSince($0.start)
            return $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite
                && duration > 0 && duration <= 24 * 60 * 60 && $0.stage != .unknown
        }).sorted(by: chronologicalOrder)
        // In-bed envelopes are a companion stream, never proof that two separate sleep nights
        // form one episode. A broad third-party bed envelope must not move both nights to its end.
        return (partition(valid.filter { $0.stage != .inBed })
                + partition(valid.filter { $0.stage == .inBed }))
            .sorted { chronologicalOrder($0[0], $1[0]) }
    }

    private static func partition(_ intervals: [SleepStageInterval]) -> [[SleepStageInterval]] {
        var groups: [[SleepStageInterval]] = []
        var current: [SleepStageInterval] = []
        var end = Date.distantPast
        for interval in intervals {
            if !current.isEmpty && interval.start.timeIntervalSince(end) > maximumStageGap {
                groups.append(current)
                current = []
            }
            current.append(interval)
            end = current.count == 1 ? interval.end : max(end, interval.end)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private static func chronologicalOrder(_ lhs: SleepStageInterval, _ rhs: SleepStageInterval) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        if sourceKey(lhs) != sourceKey(rhs) { return sourceKey(lhs) < sourceKey(rhs) }
        if lhs.stage != rhs.stage { return lhs.stage.rawValue < rhs.stage.rawValue }
        if lhs.tzOffsetMin != rhs.tzOffsetMin { return lhs.tzOffsetMin < rhs.tzOffsetMin }
        return (lhs.sampleID ?? "") < (rhs.sampleID ?? "")
    }

    private static func sourceKey(_ interval: SleepStageInterval) -> String {
        (interval.sourceName ?? "") + "\u{0}" + (interval.sourceIdentifier ?? "")
    }

    private static func rank(_ stage: SleepStage) -> Int {
        switch stage {
        case .asleepCore, .asleepDeep, .asleepREM, .awake: return 2
        case .asleepUnspecified: return 1
        case .inBed, .unknown: return 0
        }
    }

    private static func reduceGroup(_ intervals: [SleepStageInterval]) -> Episode {
        let start = intervals.map(\.start).min()!
        let end = intervals.map(\.end).max()!
        // At a tied final instant, detailed evidence wins, then stable source/interval order. The
        // chosen final interval supplies the recorded wake offset, including DST and travel changes.
        let wake = intervals.sorted {
            if $0.end != $1.end { return $0.end > $1.end }
            if rank($0.stage) != rank($1.stage) { return rank($0.stage) > rank($1.stage) }
            return chronologicalOrder($0, $1)
        }.first!
        var totals: [SleepStage: Double] = [:]
        var inBed = 0.0
        let boundaries = Array(Set(intervals.flatMap { [$0.start, $0.end] })).sorted()
        // Prefer detailed stages to unspecified summaries. If detailed sources disagree, choose
        // the source with most detailed coverage in this episode, then its stable source identity.
        // This is deterministic arbitration, not a claim that one device measures sleep better.
        let detailed = Dictionary(grouping: intervals.filter { rank($0.stage) == 2 }, by: sourceKey)
        let sourceCoverage = detailed.mapValues { values -> TimeInterval in
            var duration = 0.0
            var lastEnd = Date.distantPast
            for interval in values.sorted(by: chronologicalOrder) {
                duration += max(0, interval.end.timeIntervalSince(max(interval.start, lastEnd)))
                lastEnd = max(lastEnd, interval.end)
            }
            return duration
        }
        struct Event { let instant: Date; let index: Int; let isStart: Bool }
        let events = intervals.enumerated().flatMap { index, interval in
            [Event(instant: interval.start, index: index, isStart: true),
             Event(instant: interval.end, index: index, isStart: false)]
        }.sorted { $0.instant < $1.instant }
        var active: Set<Int> = []
        var eventIndex = 0
        for (left, right) in zip(boundaries, boundaries.dropFirst()) {
            while eventIndex < events.count && events[eventIndex].instant <= left {
                let event = events[eventIndex]
                if event.isStart { active.insert(event.index) } else { active.remove(event.index) }
                eventIndex += 1
            }
            let minutes = right.timeIntervalSince(left) / 60
            if active.contains(where: { intervals[$0].stage == .inBed }) { inBed += minutes }
            let selected = active.map { intervals[$0] }.filter { rank($0.stage) > 0 }.sorted {
                if rank($0.stage) != rank($1.stage) { return rank($0.stage) > rank($1.stage) }
                let lCoverage = sourceCoverage[sourceKey($0)] ?? 0
                let rCoverage = sourceCoverage[sourceKey($1)] ?? 0
                if lCoverage != rCoverage { return lCoverage > rCoverage }
                if sourceKey($0) != sourceKey($1) { return sourceKey($0) < sourceKey($1) }
                return chronologicalOrder($0, $1)
            }.first
            if let selected { totals[selected.stage, default: 0] += minutes }
        }
        let core = totals[.asleepCore] ?? 0, deep = totals[.asleepDeep] ?? 0, rem = totals[.asleepREM] ?? 0
        return Episode(start: start, end: end,
                       wakeDay: AppleHealthAggregator.localDay(end, tzOffsetMin: wake.tzOffsetMin),
                       hasAsleepEvidence: intervals.contains { interval in
                           switch interval.stage {
                           case .asleepCore, .asleepDeep, .asleepREM, .asleepUnspecified: return true
                           default: return false
                           }
                       },
                       asleep: core + deep + rem + (totals[.asleepUnspecified] ?? 0),
                       deep: deep, rem: rem, core: core, awake: totals[.awake] ?? 0, inBed: inBed)
    }
}
