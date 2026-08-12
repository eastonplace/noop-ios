// Replace the range-query internals of CanonicalHealthSurfaceStore.swift.
// The requested range CTE is deliberately the OUTER loop. CROSS JOIN prevents
// SQLite from reordering the large health table ahead of the tiny VALUES CTE.

import Foundation
import GRDB

public enum CanonicalHealthIndexedRangePlanner {
    public struct DayRange: Equatable, Sendable {
        public let from: String
        public let through: String
    }

    public struct TimestampRange: Equatable, Sendable {
        public let fromExclusive: Int
        public let throughInclusive: Int
    }

    public static func dayRanges(
        _ windows: [CanonicalHealthSurfaceReadWindow]
    ) throws -> [DayRange] {
        let sorted = windows.map { DayRange(from: $0.fromDay, through: $0.throughDay) }
            .sorted { ($0.from, $0.through) < ($1.from, $1.through) }
        guard sorted.allSatisfy({ $0.from <= $0.through }) else {
            throw CanonicalHealthSurfaceStoreError.invalidRequest
        }
        var result: [DayRange] = []
        for range in sorted {
            guard let last = result.last else {
                result.append(range)
                continue
            }
            if range.from <= last.through {
                result[result.count - 1] = DayRange(
                    from: last.from,
                    through: max(last.through, range.through)
                )
            } else {
                result.append(range)
            }
        }
        return result
    }

    public static func sleepRanges(
        _ windows: [CanonicalHealthSurfaceReadWindow]
    ) throws -> [TimestampRange] {
        let sorted = windows.map {
            TimestampRange(
                fromExclusive: $0.sleepFromTs,
                throughInclusive: $0.sleepThroughTs
            )
        }.sorted {
            ($0.fromExclusive, $0.throughInclusive)
                < ($1.fromExclusive, $1.throughInclusive)
        }
        guard sorted.allSatisfy({ $0.fromExclusive <= $0.throughInclusive }) else {
            throw CanonicalHealthSurfaceStoreError.invalidRequest
        }
        var result: [TimestampRange] = []
        for range in sorted {
            guard let last = result.last else {
                result.append(range)
                continue
            }
            if range.fromExclusive <= last.throughInclusive {
                result[result.count - 1] = TimestampRange(
                    fromExclusive: min(last.fromExclusive, range.fromExclusive),
                    throughInclusive: max(last.throughInclusive, range.throughInclusive)
                )
            } else {
                result.append(range)
            }
        }
        return result
    }

    public static func valuesClause(rowCount: Int, columns: Int = 2) throws -> String {
        guard rowCount > 0, rowCount <= 256, columns > 0 else {
            throw CanonicalHealthSurfaceStoreError.invalidRequest
        }
        let row = "(" + Array(repeating: "?", count: columns).joined(separator: ",") + ")"
        return Array(repeating: row, count: rowCount).joined(separator: ",")
    }

    public static func dayArguments(_ ranges: [DayRange]) -> [DatabaseValueConvertible] {
        ranges.flatMap { [$0.from, $0.through] }
    }

    public static func timestampArguments(
        _ ranges: [TimestampRange]
    ) -> [DatabaseValueConvertible] {
        ranges.flatMap { [$0.fromExclusive, $0.throughInclusive] }
    }
}

extension WhoopStore {
    /// Repository-adaptable replacement for the current correlated-EXISTS implementation.
    /// Keep the existing decode/dedup blocks; replace only the four Row.fetchAll query bodies
    /// with these range-driven statements.
    static func indexedCanonicalDailySQL(
        sourceCount: Int,
        rangeCount: Int
    ) throws -> String {
        let ids = Array(repeating: "?", count: sourceCount).joined(separator: ",")
        let ranges = try CanonicalHealthIndexedRangePlanner.valuesClause(rowCount: rangeCount)
        return """
            WITH requestedDays(fromDay, throughDay) AS (VALUES \(ranges))
            SELECT d.deviceId, d.day, d.totalSleepMin, d.efficiency, d.deepMin,
                   d.remMin, d.lightMin, d.disturbances, d.restingHr, d.avgHrv,
                   d.recovery, d.strain, d.exerciseCount, d.spo2Pct,
                   d.skinTempDevC, d.respRateBpm, d.steps, d.activeKcalEst,
                   d.spo2Red, d.spo2Ir, d.strainVersion
            FROM requestedDays AS r
            CROSS JOIN dailyMetric AS d
            WHERE d.deviceId IN (\(ids))
              AND d.day >= r.fromDay
              AND d.day <= r.throughDay
            ORDER BY d.day ASC, d.deviceId ASC
            """
    }

    static func indexedCanonicalMetricSQL(
        sourceCount: Int,
        keyCount: Int,
        rangeCount: Int
    ) throws -> String {
        let ids = Array(repeating: "?", count: sourceCount).joined(separator: ",")
        let keys = Array(repeating: "?", count: keyCount).joined(separator: ",")
        let ranges = try CanonicalHealthIndexedRangePlanner.valuesClause(rowCount: rangeCount)
        return """
            WITH requestedDays(fromDay, throughDay) AS (VALUES \(ranges))
            SELECT m.deviceId, m.day, m.key, m.value
            FROM requestedDays AS r
            CROSS JOIN metricSeries AS m
            WHERE m.deviceId IN (\(ids))
              AND m.key IN (\(keys))
              AND m.day >= r.fromDay
              AND m.day <= r.throughDay
            ORDER BY m.day ASC, m.key ASC, m.deviceId ASC
            """
    }

    static func indexedCanonicalAppleSQL(
        sourceCount: Int,
        rangeCount: Int
    ) throws -> String {
        let ids = Array(repeating: "?", count: sourceCount).joined(separator: ",")
        let ranges = try CanonicalHealthIndexedRangePlanner.valuesClause(rowCount: rangeCount)
        return """
            WITH requestedDays(fromDay, throughDay) AS (VALUES \(ranges))
            SELECT a.deviceId, a.day, a.steps, a.activeKcal, a.basalKcal,
                   a.vo2max, a.avgHr, a.maxHr, a.walkingHr, a.weightKg
            FROM requestedDays AS r
            CROSS JOIN appleDaily AS a
            WHERE a.deviceId IN (\(ids))
              AND a.day >= r.fromDay
              AND a.day <= r.throughDay
            ORDER BY a.day ASC, a.deviceId ASC
            """
    }

    static func indexedCanonicalSleepSQL(
        sourceCount: Int,
        rangeCount: Int
    ) throws -> String {
        let ids = Array(repeating: "?", count: sourceCount).joined(separator: ",")
        let ranges = try CanonicalHealthIndexedRangePlanner.valuesClause(rowCount: rangeCount)
        return """
            WITH requestedSleep(fromTs, throughTs) AS (VALUES \(ranges))
            SELECT s.deviceId, s.startTs, s.endTs, s.efficiency, s.restingHr,
                   s.avgHrv, s.stagesJSON, s.userEdited, s.startTsAdjusted
            FROM requestedSleep AS r
            CROSS JOIN sleepSession AS s
            WHERE s.deviceId IN (\(ids))
              AND s.endTs > r.fromTs
              AND s.endTs <= r.throughTs
            ORDER BY s.endTs ASC, s.deviceId ASC, s.startTs ASC
            """
    }

    /// Argument order must match the SQL: range CTE values first, then source IDs,
    /// then metric keys where applicable.
    static func canonicalDailyArguments(
        ranges: [CanonicalHealthIndexedRangePlanner.DayRange],
        sourceIds: [String]
    ) -> StatementArguments {
        StatementArguments(
            CanonicalHealthIndexedRangePlanner.dayArguments(ranges) + sourceIds
        )
    }

    static func canonicalMetricArguments(
        ranges: [CanonicalHealthIndexedRangePlanner.DayRange],
        sourceIds: [String],
        metricKeys: [String]
    ) -> StatementArguments {
        StatementArguments(
            CanonicalHealthIndexedRangePlanner.dayArguments(ranges)
                + sourceIds
                + metricKeys
        )
    }

    static func canonicalSleepArguments(
        ranges: [CanonicalHealthIndexedRangePlanner.TimestampRange],
        sourceIds: [String]
    ) -> StatementArguments {
        StatementArguments(
            CanonicalHealthIndexedRangePlanner.timestampArguments(ranges) + sourceIds
        )
    }
}

/*
Integration notes:

1. Build `dayRanges` and `sleepRanges` once before `syncRead`.
2. Execute exactly four Row.fetchAll statements in one `syncRead` transaction.
3. Deduplicate by existing source/day/session keys because overlapping ranges may
   return the same row more than once.
4. Do not use correlated `EXISTS` for range filtering.
5. In the v48 migration create:

   CREATE INDEX IF NOT EXISTS idx_sleepSession_device_end
       ON sleepSession(deviceId, endTs);

6. Query-plan tests must reject a plan that says only `(deviceId=?)` for daily or
   `(deviceId=? AND key=?)` for metricSeries. The detail must also include a day range.
*/
