// Add to Packages/WhoopStore/Sources/WhoopStore.
// One GRDB read transaction supplies the Repository generation used by Today, Sleep, and Trends.

import Foundation
import GRDB

public struct StoredSourcedDailyMetric: Equatable, Sendable {
    public let sourceId: String
    /// Higher values win when several source namespaces contain the same model/day.
    public let sourcePriority: Int
    public let metric: DailyMetric
}

public struct StoredSourcedSleepSession: Equatable, Sendable {
    public let sourceId: String
    public let sourcePriority: Int
    public let session: CachedSleepSession
}

public struct StoredSourcedMetricPoint: Equatable, Sendable {
    public let sourceId: String
    public let sourcePriority: Int
    public let key: String
    public let day: String
    public let value: Double
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
                sleepThroughTs: sleepThroughTs
            )],
            metricKeys: metricKeys
        )
    }

    /// Read all sparse exact windows from one WAL snapshot. Several async calls are not equivalent because a
    /// scorer can commit between them and create one UI generation from mixed database generations.
    public func canonicalHealthSurfaceSnapshot(
        sourceIds: [String],
        windows: [CanonicalHealthSurfaceReadWindow],
        metricKeys: [String]
    ) async throws -> CanonicalHealthSurfaceStoreSnapshot {
        var seen = Set<String>()
        let ids = sourceIds.filter { !$0.isEmpty && seen.insert($0).inserted }
        let keys = Array(Set(metricKeys.filter { !$0.isEmpty })).sorted()
        guard !ids.isEmpty, !windows.isEmpty,
              windows.allSatisfy({ $0.fromDay <= $0.throughDay && $0.sleepFromTs <= $0.sleepThroughTs }) else {
            throw CanonicalHealthSurfaceStoreError.invalidRequest
        }
        let sourcePriority = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            // First source has highest authority.
            (id, ids.count - index)
        })

        return try syncRead { db in
            let databaseId = try WhoopStore.databaseInstanceId(in: db)
            let idPlaceholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let keyPlaceholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
            var dailyByKey: [String: StoredSourcedDailyMetric] = [:]
            var sleepByKey: [String: StoredSourcedSleepSession] = [:]
            var metricByKey: [String: StoredSourcedMetricPoint] = [:]
            var appleByKey: [String: StoredAppleDailyPoint] = [:]

            for window in windows {
                for row in try Row.fetchAll(db, sql: """
                    SELECT deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin,
                           disturbances, restingHr, avgHrv, recovery, strain, exerciseCount,
                           spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst,
                           spo2Red, spo2Ir, strainVersion
                    FROM dailyMetric
                    WHERE deviceId IN (\(idPlaceholders)) AND day >= ? AND day <= ?
                    ORDER BY day ASC, deviceId ASC
                    """, arguments: StatementArguments(ids + [window.fromDay, window.throughDay])) {
                    let sourceId: String = row["deviceId"]
                    let stored = StoredSourcedDailyMetric(
                        sourceId: sourceId,
                        sourcePriority: sourcePriority[sourceId] ?? 0,
                        metric: DailyMetric(
                            day: row["day"], totalSleepMin: row["totalSleepMin"],
                            efficiency: row["efficiency"], deepMin: row["deepMin"],
                            remMin: row["remMin"], lightMin: row["lightMin"],
                            disturbances: row["disturbances"], restingHr: row["restingHr"],
                            avgHrv: row["avgHrv"], recovery: row["recovery"],
                            strain: row["strain"], exerciseCount: row["exerciseCount"],
                            spo2Pct: row["spo2Pct"], skinTempDevC: row["skinTempDevC"],
                            respRateBpm: row["respRateBpm"], steps: row["steps"],
                            activeKcalEst: row["activeKcalEst"], spo2Red: row["spo2Red"],
                            spo2Ir: row["spo2Ir"], strainVersion: row["strainVersion"]
                        )
                    )
                    dailyByKey["\(sourceId)|\(stored.metric.day)"] = stored
                }

                for row in try Row.fetchAll(db, sql: """
                    SELECT deviceId, startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON,
                           userEdited, startTsAdjusted
                    FROM sleepSession
                    WHERE deviceId IN (\(idPlaceholders))
                      AND COALESCE(startTsAdjusted, startTs) <= ?
                      AND endTs > ?
                    ORDER BY COALESCE(startTsAdjusted, startTs) ASC, deviceId ASC
                    """, arguments: StatementArguments(ids + [window.sleepThroughTs, window.sleepFromTs])) {
                    let sourceId: String = row["deviceId"]
                    let stored = StoredSourcedSleepSession(
                        sourceId: sourceId,
                        sourcePriority: sourcePriority[sourceId] ?? 0,
                        session: CachedSleepSession(
                            startTs: row["startTs"], endTs: row["endTs"],
                            efficiency: row["efficiency"], restingHr: row["restingHr"],
                            avgHrv: row["avgHrv"], stagesJSON: row["stagesJSON"],
                            userEdited: row["userEdited"], startTsAdjusted: row["startTsAdjusted"]
                        )
                    )
                    sleepByKey["\(sourceId)|\(stored.session.startTs)"] = stored
                }

                if !keys.isEmpty {
                    for row in try Row.fetchAll(db, sql: """
                        SELECT deviceId, day, key, value
                        FROM metricSeries
                        WHERE deviceId IN (\(idPlaceholders))
                          AND key IN (\(keyPlaceholders))
                          AND day >= ? AND day <= ?
                        ORDER BY day ASC, key ASC, deviceId ASC
                        """, arguments: StatementArguments(ids + keys + [window.fromDay, window.throughDay])) {
                        let sourceId: String = row["deviceId"]
                        let stored = StoredSourcedMetricPoint(
                            sourceId: sourceId,
                            sourcePriority: sourcePriority[sourceId] ?? 0,
                            key: row["key"], day: row["day"], value: row["value"]
                        )
                        metricByKey["\(sourceId)|\(stored.day)|\(stored.key)"] = stored
                    }
                }

                for row in try Row.fetchAll(db, sql: """
                    SELECT deviceId, day, steps, activeKcal, basalKcal, vo2max,
                           avgHr, maxHr, walkingHr, weightKg
                    FROM appleDaily
                    WHERE deviceId IN (\(idPlaceholders)) AND day >= ? AND day <= ?
                    ORDER BY day ASC, deviceId ASC
                    """, arguments: StatementArguments(ids + [window.fromDay, window.throughDay])) {
                    let sourceId: String = row["deviceId"]
                    let stored = StoredAppleDailyPoint(
                        sourceId: sourceId,
                        sourcePriority: sourcePriority[sourceId] ?? 0,
                        day: row["day"],
                        steps: row["steps"], activeKcal: row["activeKcal"],
                        basalKcal: row["basalKcal"], vo2max: row["vo2max"],
                        avgHr: row["avgHr"], maxHr: row["maxHr"],
                        walkingHr: row["walkingHr"], weightKg: row["weightKg"]
                    )
                    appleByKey["\(sourceId)|\(stored.day)"] = stored
                }
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
                }
            )
        }
    }
}

public enum CanonicalHealthSurfaceStoreError: Error {
    case invalidRequest
}
