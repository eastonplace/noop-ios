import Foundation
import GRDB
import NoopPhase34Core

public struct StoredSourcedDailyMetric: Equatable, Sendable {
    public let sourceId: String
    public let sourcePriority: Int
    public let metric: DailyMetric

    public init(sourceId: String, sourcePriority: Int, metric: DailyMetric) {
        self.sourceId = sourceId
        self.sourcePriority = sourcePriority
        self.metric = metric
    }
}

public struct StoredSourcedSleepSession: Equatable, Sendable {
    public let sourceId: String
    public let sourcePriority: Int
    public let session: CachedSleepSession

    public init(sourceId: String, sourcePriority: Int, session: CachedSleepSession) {
        self.sourceId = sourceId
        self.sourcePriority = sourcePriority
        self.session = session
    }
}

public struct StoredSourcedMetricPoint: Equatable, Sendable {
    public let sourceId: String
    public let sourcePriority: Int
    public let key: String
    public let day: String
    public let value: Double

    public init(sourceId: String, sourcePriority: Int, key: String, day: String, value: Double) {
        self.sourceId = sourceId
        self.sourcePriority = sourcePriority
        self.key = key
        self.day = day
        self.value = value
    }
}

public struct StoredAppleDailyPoint: Equatable, Sendable {
    public let sourceId: String
    public let sourcePriority: Int
    public let day: String
    public let steps: Int?
    public let activeKcal: Double?
    public let basalKcal: Double?
    public let vo2max: Double?
    public let avgHr: Int?
    public let maxHr: Int?
    public let walkingHr: Int?
    public let weightKg: Double?

    public init(
        sourceId: String,
        sourcePriority: Int,
        day: String,
        steps: Int?,
        activeKcal: Double?,
        basalKcal: Double?,
        vo2max: Double?,
        avgHr: Int?,
        maxHr: Int?,
        walkingHr: Int?,
        weightKg: Double?
    ) {
        self.sourceId = sourceId
        self.sourcePriority = sourcePriority
        self.day = day
        self.steps = steps
        self.activeKcal = activeKcal
        self.basalKcal = basalKcal
        self.vo2max = vo2max
        self.avgHr = avgHr
        self.maxHr = maxHr
        self.walkingHr = walkingHr
        self.weightKg = weightKg
    }
}

public struct CanonicalHealthSurfaceReadWindow: Equatable, Sendable {
    public let fromDay: String
    public let throughDay: String
    public let sleepFromTs: Int
    public let sleepThroughTs: Int

    public init(fromDay: String, throughDay: String, sleepFromTs: Int, sleepThroughTs: Int) {
        self.fromDay = fromDay
        self.throughDay = throughDay
        self.sleepFromTs = sleepFromTs
        self.sleepThroughTs = sleepThroughTs
    }
}

public struct CanonicalHealthSurfaceStoreSnapshot: Equatable, Sendable {
    public let databaseInstanceId: String
    public let dailyRows: [StoredSourcedDailyMetric]
    public let sleepRows: [StoredSourcedSleepSession]
    public let metricRows: [StoredSourcedMetricPoint]
    public let appleDailyRows: [StoredAppleDailyPoint]
}

extension WhoopStore {
    public func canonicalHealthSurfaceSnapshot(
        sourceIds: [String],
        fromDay: String,
        throughDay: String,
        sleepFromTs: Int,
        sleepThroughTs: Int,
        metricKeys: [String]
    ) async throws -> CanonicalHealthSurfaceStoreSnapshot {
        try await canonicalHealthSurfaceSnapshot(
            sourceIds: sourceIds,
            windows: [CanonicalHealthSurfaceReadWindow(
                fromDay: fromDay,
                throughDay: throughDay,
                sleepFromTs: sleepFromTs,
                sleepThroughTs: sleepThroughTs)],
            metricKeys: metricKeys)
    }

    /// Read all normalized windows from one WAL generation. Each table is queried once, even when exact work
    /// is sparse or contains several overlapping current/history windows.
    public func canonicalHealthSurfaceSnapshot(
        sourceIds: [String],
        windows: [CanonicalHealthSurfaceReadWindow],
        metricKeys: [String]
    ) async throws -> CanonicalHealthSurfaceStoreSnapshot {
        var seen = Set<String>()
        let ids = sourceIds.filter { !$0.isEmpty && seen.insert($0).inserted }
        let keys = Array(Set(metricKeys.filter { !$0.isEmpty })).sorted()
        let normalized = try Self.normalizedWindows(windows)
        guard !ids.isEmpty else { throw CanonicalHealthSurfaceStoreError.invalidRequest }
        let sourcePriority = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, ids.count - index)
        })

        return try syncRead { db in
            let databaseId = try WhoopStore.databaseInstanceId(in: db)
            let idPlaceholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let dayCTE = Self.dayCTE(normalized)
            let sleepCTE = Self.sleepCTE(normalized)
            var dailyByKey: [String: StoredSourcedDailyMetric] = [:]
            var sleepByKey: [String: StoredSourcedSleepSession] = [:]
            var metricByKey: [String: StoredSourcedMetricPoint] = [:]
            var appleByKey: [String: StoredAppleDailyPoint] = [:]

            var dailyArguments = dayCTE.arguments
            dailyArguments.append(contentsOf: ids)
            let dailyRows = try Row.fetchAll(db, sql: """
                WITH \(dayCTE.sql)
                SELECT deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin,
                       disturbances, restingHr, avgHrv, recovery, strain, exerciseCount,
                       spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst,
                       spo2Red, spo2Ir, strainVersion
                FROM dailyMetric
                WHERE deviceId IN (\(idPlaceholders))
                  AND EXISTS (
                      SELECT 1 FROM requestedDays r
                      WHERE dailyMetric.day >= r.fromDay AND dailyMetric.day <= r.throughDay
                  )
                ORDER BY day ASC, deviceId ASC
                """, arguments: StatementArguments(dailyArguments))
            for row in dailyRows {
                let sourceId: String = row["deviceId"]
                let metric = DailyMetric(
                    day: row["day"], totalSleepMin: row["totalSleepMin"],
                    efficiency: row["efficiency"], deepMin: row["deepMin"],
                    remMin: row["remMin"], lightMin: row["lightMin"],
                    disturbances: row["disturbances"], restingHr: row["restingHr"],
                    avgHrv: row["avgHrv"], recovery: row["recovery"],
                    strain: row["strain"], exerciseCount: row["exerciseCount"],
                    spo2Pct: row["spo2Pct"], skinTempDevC: row["skinTempDevC"],
                    respRateBpm: row["respRateBpm"], steps: row["steps"],
                    activeKcalEst: row["activeKcalEst"], spo2Red: row["spo2Red"],
                    spo2Ir: row["spo2Ir"], strainVersion: row["strainVersion"])
                dailyByKey["\(sourceId)|\(metric.day)"] = StoredSourcedDailyMetric(
                    sourceId: sourceId,
                    sourcePriority: sourcePriority[sourceId] ?? 0,
                    metric: metric)
            }

            var sleepArguments = sleepCTE.arguments
            sleepArguments.append(contentsOf: ids)
            let sleepRows = try Row.fetchAll(db, sql: """
                WITH \(sleepCTE.sql)
                SELECT deviceId, startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON,
                       userEdited, startTsAdjusted
                FROM sleepSession
                WHERE deviceId IN (\(idPlaceholders))
                  AND EXISTS (
                      SELECT 1 FROM requestedSleep r
                      WHERE COALESCE(sleepSession.startTsAdjusted, sleepSession.startTs) <= r.throughTs
                        AND sleepSession.endTs > r.fromTs
                  )
                ORDER BY COALESCE(startTsAdjusted, startTs) ASC, deviceId ASC
                """, arguments: StatementArguments(sleepArguments))
            for row in sleepRows {
                let sourceId: String = row["deviceId"]
                let session = CachedSleepSession(
                    startTs: row["startTs"], endTs: row["endTs"],
                    efficiency: row["efficiency"], restingHr: row["restingHr"],
                    avgHrv: row["avgHrv"], stagesJSON: row["stagesJSON"],
                    userEdited: row["userEdited"], startTsAdjusted: row["startTsAdjusted"])
                sleepByKey["\(sourceId)|\(session.startTs)"] = StoredSourcedSleepSession(
                    sourceId: sourceId,
                    sourcePriority: sourcePriority[sourceId] ?? 0,
                    session: session)
            }

            if !keys.isEmpty {
                let keyPlaceholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
                var metricArguments = dayCTE.arguments
                metricArguments.append(contentsOf: ids)
                metricArguments.append(contentsOf: keys)
                let metricRows = try Row.fetchAll(db, sql: """
                    WITH \(dayCTE.sql)
                    SELECT deviceId, day, key, value
                    FROM metricSeries
                    WHERE deviceId IN (\(idPlaceholders))
                      AND key IN (\(keyPlaceholders))
                      AND EXISTS (
                          SELECT 1 FROM requestedDays r
                          WHERE metricSeries.day >= r.fromDay AND metricSeries.day <= r.throughDay
                      )
                    ORDER BY day ASC, key ASC, deviceId ASC
                    """, arguments: StatementArguments(metricArguments))
                for row in metricRows {
                    let sourceId: String = row["deviceId"]
                    let point = StoredSourcedMetricPoint(
                        sourceId: sourceId,
                        sourcePriority: sourcePriority[sourceId] ?? 0,
                        key: row["key"], day: row["day"], value: row["value"])
                    metricByKey["\(sourceId)|\(point.day)|\(point.key)"] = point
                }
            }

            var appleArguments = dayCTE.arguments
            appleArguments.append(contentsOf: ids)
            let appleRows = try Row.fetchAll(db, sql: """
                WITH \(dayCTE.sql)
                SELECT deviceId, day, steps, activeKcal, basalKcal, vo2max,
                       avgHr, maxHr, walkingHr, weightKg
                FROM appleDaily
                WHERE deviceId IN (\(idPlaceholders))
                  AND EXISTS (
                      SELECT 1 FROM requestedDays r
                      WHERE appleDaily.day >= r.fromDay AND appleDaily.day <= r.throughDay
                  )
                ORDER BY day ASC, deviceId ASC
                """, arguments: StatementArguments(appleArguments))
            for row in appleRows {
                let sourceId: String = row["deviceId"]
                let point = StoredAppleDailyPoint(
                    sourceId: sourceId,
                    sourcePriority: sourcePriority[sourceId] ?? 0,
                    day: row["day"], steps: row["steps"],
                    activeKcal: row["activeKcal"], basalKcal: row["basalKcal"],
                    vo2max: row["vo2max"], avgHr: row["avgHr"], maxHr: row["maxHr"],
                    walkingHr: row["walkingHr"], weightKg: row["weightKg"])
                appleByKey["\(sourceId)|\(point.day)"] = point
            }

            return CanonicalHealthSurfaceStoreSnapshot(
                databaseInstanceId: databaseId,
                dailyRows: dailyByKey.values.sorted {
                    ($0.metric.day, -$0.sourcePriority, $0.sourceId)
                        < ($1.metric.day, -$1.sourcePriority, $1.sourceId)
                },
                sleepRows: sleepByKey.values.sorted {
                    ($0.session.effectiveStartTs, -$0.sourcePriority, $0.sourceId)
                        < ($1.session.effectiveStartTs, -$1.sourcePriority, $1.sourceId)
                },
                metricRows: metricByKey.values.sorted {
                    ($0.day, $0.key, -$0.sourcePriority, $0.sourceId)
                        < ($1.day, $1.key, -$1.sourcePriority, $1.sourceId)
                },
                appleDailyRows: appleByKey.values.sorted {
                    ($0.day, -$0.sourcePriority, $0.sourceId)
                        < ($1.day, -$1.sourcePriority, $1.sourceId)
                })
        }
    }

    private static func normalizedWindows(
        _ windows: [CanonicalHealthSurfaceReadWindow]
    ) throws -> [CanonicalHealthSurfaceReadWindow] {
        guard !windows.isEmpty,
              windows.allSatisfy({
                  $0.fromDay <= $0.throughDay && $0.sleepFromTs <= $0.sleepThroughTs
              }) else {
            throw CanonicalHealthSurfaceStoreError.invalidRequest
        }
        let sorted = windows.sorted {
            ($0.fromDay, $0.throughDay, $0.sleepFromTs, $0.sleepThroughTs)
                < ($1.fromDay, $1.throughDay, $1.sleepFromTs, $1.sleepThroughTs)
        }
        guard var current = sorted.first else { return [] }
        var result: [CanonicalHealthSurfaceReadWindow] = []
        for next in sorted.dropFirst() {
            if next.fromDay <= dayAfter(current.throughDay),
               next.sleepFromTs <= current.sleepThroughTs {
                current = CanonicalHealthSurfaceReadWindow(
                    fromDay: min(current.fromDay, next.fromDay),
                    throughDay: max(current.throughDay, next.throughDay),
                    sleepFromTs: min(current.sleepFromTs, next.sleepFromTs),
                    sleepThroughTs: max(current.sleepThroughTs, next.sleepThroughTs))
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    private static func dayAfter(_ key: String) -> String {
        guard let day = try? CivilDay(key: key) else { return key }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = try? day.date(in: calendar),
              let next = calendar.date(byAdding: .day, value: 1, to: date) else { return key }
        let components = calendar.dateComponents([.year, .month, .day], from: next)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private static func dayCTE(
        _ windows: [CanonicalHealthSurfaceReadWindow]
    ) -> (sql: String, arguments: [DatabaseValueConvertible]) {
        let values = windows.map { _ in "(?, ?)" }.joined(separator: ", ")
        var arguments: [DatabaseValueConvertible] = []
        arguments.reserveCapacity(windows.count * 2)
        for window in windows {
            arguments += [window.fromDay, window.throughDay]
        }
        return ("requestedDays(fromDay, throughDay) AS (VALUES \(values))", arguments)
    }

    private static func sleepCTE(
        _ windows: [CanonicalHealthSurfaceReadWindow]
    ) -> (sql: String, arguments: [DatabaseValueConvertible]) {
        let values = windows.map { _ in "(?, ?)" }.joined(separator: ", ")
        var arguments: [DatabaseValueConvertible] = []
        arguments.reserveCapacity(windows.count * 2)
        for window in windows {
            arguments += [window.sleepFromTs, window.sleepThroughTs]
        }
        return ("requestedSleep(fromTs, throughTs) AS (VALUES \(values))", arguments)
    }
}

public enum CanonicalHealthSurfaceStoreError: Error {
    case invalidRequest
}
