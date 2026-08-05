import Foundation
import NoopPhase34Core
import WhoopStore

/// The winning stored row and the source namespace that actually supplied it. Never reconstruct this source
/// from `importedReadIds.first`; a fallback namespace can win an equal-day merge.
struct ExactSourcedDailyWinner: Equatable, Sendable {
    let sourceId: String
    let sourcePriority: Int
    let metric: DailyMetric
}

enum RepositoryExactAuthoritativeMerge {
    static func authoritativeDayKeys(_ exactDays: Set<CivilDay>) -> Set<String> {
        Set(exactDays.map(\.key))
    }

    static func bestRowsPreservingSource(
        _ rows: [StoredSourcedDailyMetric]
    ) -> [String: ExactSourcedDailyWinner] {
        Dictionary(grouping: rows, by: { $0.metric.day }).compactMapValues { candidates in
            candidates.max {
                ($0.sourcePriority, $0.sourceId) < ($1.sourcePriority, $1.sourceId)
            }.map {
                ExactSourcedDailyWinner(
                    sourceId: $0.sourceId,
                    sourcePriority: $0.sourcePriority,
                    metric: $0.metric)
            }
        }
    }

    static func exactSleepRows(
        _ rows: [StoredSourcedSleepSession],
        importedSourceIds: Set<String>,
        computedSourceIds: Set<String>,
        authoritativeDayKeys: Set<String>,
        timeZoneIdentifier: String
    ) throws -> (imported: [CachedSleepSession], computed: [CachedSleepSession]) {
        let calendar = try HealthCalendar(timeZoneIdentifier: timeZoneIdentifier)
        var imported: [Int: StoredSourcedSleepSession] = [:]
        var computed: [Int: StoredSourcedSleepSession] = [:]
        for row in rows {
            guard importedSourceIds.contains(row.sourceId) || computedSourceIds.contains(row.sourceId),
                  let wakeDay = try? calendar.civilDay(
                      containing: Date(timeIntervalSince1970: TimeInterval(row.session.endTs))),
                  authoritativeDayKeys.contains(wakeDay.key) else { continue }
            if importedSourceIds.contains(row.sourceId) {
                if imported[row.session.startTs].map({
                    ($0.sourcePriority, $0.sourceId) < (row.sourcePriority, row.sourceId)
                }) ?? true {
                    imported[row.session.startTs] = row
                }
            } else if computed[ row.session.startTs].map({
                ($0.sourcePriority, $0.sourceId) < (row.sourcePriority, row.sourceId)
            }) ?? true {
                computed[row.session.startTs] = row
            }
        }
        return (
            imported.values.sorted { $0.session.effectiveStartTs < $1.session.effectiveStartTs }
                .map(\.session),
            computed.values.sorted { $0.session.effectiveStartTs < $1.session.effectiveStartTs }
                .map(\.session)
        )
    }

    static func replaceAuthoritative<Value>(
        existing: [Value],
        incoming: [Value],
        authoritativeKeys: Set<String>,
        key: (Value) -> String,
        areInIncreasingOrder: (Value, Value) -> Bool
    ) -> [Value] {
        (existing.filter { !authoritativeKeys.contains(key($0)) } + incoming)
            .sorted(by: areInIncreasingOrder)
    }

    static func replaceAuthoritative<Value>(
        existing: [String: Value],
        incoming: [String: Value],
        authoritativeKeys: Set<String>
    ) -> [String: Value] {
        existing.filter { !authoritativeKeys.contains($0.key) }
            .merging(incoming) { _, new in new }
    }
}
