import Foundation
import WhoopStore

public enum SleepScoreSource: Codable, Equatable, Sendable {
    case noopMeasured
    case noopEdited
    case whoopImport
    case appleHealthImport
    case otherImport(String)
}

public struct SleepNightSummary: Codable, Equatable, Sendable {
    public let wakeDay: String
    public let mainSleepStart: Int
    public let mainSleepEnd: Int
    public let mainSleepMinutes: Double
    public let inBedMinutes: Double
    public let efficiency: Double
    public let onsetMinuteLocal: Int
    public let wakeMinuteLocal: Int
    public let recentNapMinutes: Double
    public let lowStressQuality: Double?
    public let source: SleepScoreSource
    public let sourceRowId: String

    public init(wakeDay: String, mainSleepStart: Int, mainSleepEnd: Int,
                mainSleepMinutes: Double, inBedMinutes: Double, efficiency: Double,
                onsetMinuteLocal: Int, wakeMinuteLocal: Int, recentNapMinutes: Double,
                lowStressQuality: Double?, source: SleepScoreSource, sourceRowId: String) {
        self.wakeDay = wakeDay; self.mainSleepStart = mainSleepStart; self.mainSleepEnd = mainSleepEnd
        self.mainSleepMinutes = mainSleepMinutes; self.inBedMinutes = inBedMinutes
        self.efficiency = efficiency; self.onsetMinuteLocal = onsetMinuteLocal
        self.wakeMinuteLocal = wakeMinuteLocal; self.recentNapMinutes = recentNapMinutes
        self.lowStressQuality = lowStressQuality; self.source = source; self.sourceRowId = sourceRowId
    }

    /// Ignore malformed stage spans rather than subtracting externally supplied Int extrema. A non-finite
    /// accumulated value rejects the summary so it cannot publish fabricated sleep time.
    private static func stageAsleepSeconds(from stages: [StageSegment]) -> Double? {
        var total = 0.0
        for stage in stages where stage.stage != "wake" {
            guard let duration = SleepStageTotals.positiveDurationSeconds(start: stage.start, end: stage.end) else {
                continue
            }
            let next = total + Double(duration)
            guard next.isFinite else { return nil }
            total = next
        }
        return total
    }

    private static func localMinute(_ epoch: Int, offsetSeconds: Int) -> Int {
        SleepStageTotals.localSecOfDay(epoch, offsetSec: offsetSeconds) / 60
    }

    /// Uses the existing production selector. Inter-fragment gaps are included in
    /// the outer in-bed span exactly once; non-main sessions are nap credit only.
    public static func select(from sessions: [SleepSession], wakeDay: String,
                              offsetSeconds: Int, previousMainSleepEnd: Int? = nil,
                              habitualMidsleepSec: Int? = nil, lowStressQuality: Double? = nil,
                              source: SleepScoreSource, sourceRowId: String) -> SleepNightSummary? {
        let blocks = sessions.map { SleepStageTotals.NightBlock(start: $0.start, end: $0.end) }
        guard let indices = SleepStageTotals.mainNightGroupIndices(
            blocks, offsetSec: offsetSeconds, habitualMidsleepSec: habitualMidsleepSec) else { return nil }
        let main = indices.compactMap { sessions.indices.contains($0) ? sessions[$0] : nil }
            .sorted { $0.start < $1.start }
        guard let start = main.first?.start, let end = main.last?.end, end > start else { return nil }
        guard let inBedDuration = SleepStageTotals.positiveDurationSeconds(start: start, end: end),
              let asleepSeconds = stageAsleepSeconds(from: main.flatMap(\.stages)) else { return nil }
        let inBedSeconds = Double(inBedDuration)
        guard asleepSeconds > 0 else { return nil }
        let mainSet = Set(indices)
        var napSeconds = 0.0
        for pair in sessions.enumerated() {
            guard !mainSet.contains(pair.offset), pair.element.end <= start,
                  previousMainSleepEnd.map({ pair.element.start >= $0 }) ?? true else { continue }
            guard let seconds = stageAsleepSeconds(from: pair.element.stages) else { return nil }
            let next = napSeconds + seconds
            guard next.isFinite else { return nil }
            napSeconds = next
        }
        return SleepNightSummary(
            wakeDay: wakeDay, mainSleepStart: start, mainSleepEnd: end,
            mainSleepMinutes: asleepSeconds / 60, inBedMinutes: inBedSeconds / 60,
            efficiency: min(1, max(0, asleepSeconds / inBedSeconds)),
            onsetMinuteLocal: localMinute(start, offsetSeconds: offsetSeconds),
            wakeMinuteLocal: localMinute(end, offsetSeconds: offsetSeconds),
            recentNapMinutes: napSeconds / 60, lowStressQuality: lowStressQuality,
            source: source, sourceRowId: sourceRowId)
    }

    /// Store-backed variant used after edit substitution. The already-final daily aggregate supplies
    /// main sleep and efficiency; effective session bounds preserve the user's corrected onset.
    public static func select(from sessions: [CachedSleepSession], wakeDay: String,
                              totalSleepMinutes: Double?, efficiency: Double?, offsetSeconds: Int,
                              habitualMidsleepSec: Int? = nil,
                              lowStressQuality: Double? = nil) -> SleepNightSummary? {
        let blocks = sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) }
        guard let indices = SleepStageTotals.mainNightGroupIndices(
            blocks, offsetSec: offsetSeconds, habitualMidsleepSec: habitualMidsleepSec),
              let start = indices.compactMap({ blocks.indices.contains($0) ? blocks[$0].start : nil }).min(),
              let end = indices.compactMap({ blocks.indices.contains($0) ? blocks[$0].end : nil }).max(),
              end > start, let asleep = totalSleepMinutes, asleep.isFinite, asleep > 0,
              let efficiency, efficiency.isFinite, efficiency > 0 else { return nil }
        let chosen = Set(indices)
        var nap = 0.0
        for pair in sessions.enumerated() {
            guard !chosen.contains(pair.offset), pair.element.endTs <= start else { continue }
            let next = nap + (SleepStageTotals.minutes(fromStagesJSON: pair.element.stagesJSON)?.asleep ?? 0)
            guard next.isFinite else { return nil }
            nap = next
        }
        let inBedMinutes = asleep / efficiency
        guard inBedMinutes.isFinite, inBedMinutes > 0 else { return nil }
        let edited = sessions.contains(where: \.userEdited)
        return SleepNightSummary(
            wakeDay: wakeDay, mainSleepStart: start, mainSleepEnd: end,
            mainSleepMinutes: asleep, inBedMinutes: inBedMinutes,
            efficiency: min(1, efficiency), onsetMinuteLocal: localMinute(start, offsetSeconds: offsetSeconds),
            wakeMinuteLocal: localMinute(end, offsetSeconds: offsetSeconds), recentNapMinutes: nap,
            lowStressQuality: lowStressQuality, source: edited ? .noopEdited : .noopMeasured,
            sourceRowId: indices.compactMap { sessions.indices.contains($0) ? String(sessions[$0].startTs) : nil }
                .joined(separator: ","))
    }
}
