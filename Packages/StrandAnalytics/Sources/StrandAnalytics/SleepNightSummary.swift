import Foundation

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
        let asleepSeconds = main.flatMap(\.stages).filter { $0.stage != "wake" }
            .reduce(0.0) { $0 + Double(max(0, $1.end - $1.start)) }
        let inBedSeconds = Double(end - start)
        guard asleepSeconds > 0 else { return nil }
        let mainSet = Set(indices)
        let napSeconds = sessions.enumerated().reduce(0.0) { total, pair in
            guard !mainSet.contains(pair.offset), pair.element.end <= start,
                  previousMainSleepEnd.map({ pair.element.start >= $0 }) ?? true else { return total }
            return total + pair.element.stages.filter { $0.stage != "wake" }
                .reduce(0.0) { $0 + Double(max(0, $1.end - $1.start)) }
        }
        func localMinute(_ epoch: Int) -> Int {
            (((epoch + offsetSeconds) % 86_400 + 86_400) % 86_400) / 60
        }
        return SleepNightSummary(
            wakeDay: wakeDay, mainSleepStart: start, mainSleepEnd: end,
            mainSleepMinutes: asleepSeconds / 60, inBedMinutes: inBedSeconds / 60,
            efficiency: min(1, max(0, asleepSeconds / inBedSeconds)),
            onsetMinuteLocal: localMinute(start), wakeMinuteLocal: localMinute(end),
            recentNapMinutes: napSeconds / 60, lowStressQuality: lowStressQuality,
            source: source, sourceRowId: sourceRowId)
    }
}
