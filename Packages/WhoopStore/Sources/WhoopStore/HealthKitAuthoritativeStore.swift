import Foundation
import GRDB

/// Stable local identity for an Apple Health object. HealthKit deletion callbacks contain only the UUID,
/// so retaining the original time window is necessary to re-aggregate historical rows correctly.
public struct HealthKitObjectIdentity: Equatable, Codable, Sendable {
    public let sampleType: String
    public let objectUUID: String
    public let startTs: Int
    public let endTs: Int

    public init(sampleType: String, objectUUID: String, startTs: Int, endTs: Int) {
        self.sampleType = sampleType
        self.objectUUID = objectUUID
        self.startTs = startTs
        self.endTs = max(startTs, endTs)
    }
}

extension WhoopStore {
    private static let appleHealthWorkoutSource = "apple-health"
    /// Leaves headroom below SQLite's host-parameter limit for device/source arguments and future clauses.
    private static let healthKitIdentityQueryChunkSize = 400

    /// Returns the conservative historical window for each requested UUID. A corrected object may have
    /// occupied several windows over time; the index retains their union so replay after a crash can still
    /// retract the original local projection before the correction is applied. Requests are chunked so a
    /// large HealthKit deletion event cannot exceed SQLite's host-parameter limit. Duplicate request UUIDs
    /// intentionally produce duplicate results, allowing the caller's known/unknown count comparison to
    /// remain correct even if an anchored scan reports the same deletion more than once.
    public func healthKitObjectIdentities(
        sampleType: String,
        objectUUIDs: [String],
        deviceId: String
    ) async throws -> [HealthKitObjectIdentity] {
        let requested = objectUUIDs.filter { !$0.isEmpty }
        let identifiers = Array(Set(requested))
        guard !identifiers.isEmpty else { return [] }
        return try syncRead { db in
            var byIdentifier: [String: HealthKitObjectIdentity] = [:]
            byIdentifier.reserveCapacity(identifiers.count)
            for start in stride(
                from: 0,
                to: identifiers.count,
                by: Self.healthKitIdentityQueryChunkSize
            ) {
                let end = min(start + Self.healthKitIdentityQueryChunkSize, identifiers.count)
                let chunk = Array(identifiers[start..<end])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT sampleType, objectUUID, startTs, endTs
                    FROM healthKitObjectIndex
                    WHERE deviceId = ? AND sampleType = ? AND objectUUID IN (\(placeholders))
                    """, arguments: StatementArguments([deviceId, sampleType] + chunk))
                for row in rows {
                    let identity = HealthKitObjectIdentity(
                        sampleType: row["sampleType"],
                        objectUUID: row["objectUUID"],
                        startTs: row["startTs"],
                        endTs: row["endTs"]
                    )
                    byIdentifier[identity.objectUUID] = identity
                }
            }
            return requested.compactMap { byIdentifier[$0] }
        }
    }

    @discardableResult
    public func upsertHealthKitObjectIdentities(
        _ identities: [HealthKitObjectIdentity],
        deviceId: String
    ) async throws -> Int {
        guard !identities.isEmpty else { return 0 }
        return try syncWrite { db in
            var changed = 0
            for identity in identities {
                try db.execute(sql: """
                    INSERT INTO healthKitObjectIndex (deviceId, sampleType, objectUUID, startTs, endTs)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, sampleType, objectUUID) DO UPDATE SET
                        startTs = MIN(healthKitObjectIndex.startTs, excluded.startTs),
                        endTs = MAX(healthKitObjectIndex.endTs, excluded.endTs)
                    WHERE excluded.startTs < healthKitObjectIndex.startTs
                       OR excluded.endTs > healthKitObjectIndex.endTs
                    """, arguments: [deviceId, identity.sampleType, identity.objectUUID,
                                     identity.startTs, identity.endTs])
                changed += db.changesCount
            }
            return changed
        }
    }

    /// The earliest Apple Health-derived row. Unknown historical deletion UUIDs use this as a conservative
    /// re-aggregation start, never an arbitrary recent-month fallback.
    public func earliestAppleHealthTimestamp(deviceId: String) async throws -> Int? {
        try syncRead { db in
            let day = try String.fetchOne(db, sql: """
                SELECT MIN(day) FROM (
                    SELECT day FROM appleDaily WHERE deviceId = ?
                    UNION ALL SELECT day FROM dailyMetric WHERE deviceId = ?
                    UNION ALL SELECT day FROM metricSeries WHERE deviceId = ?
                )
                """, arguments: [deviceId, deviceId, deviceId])
            let workout = try Int.fetchOne(db, sql: """
                SELECT MIN(startTs) FROM workout WHERE deviceId = ? AND source = ?
                """, arguments: [deviceId, Self.appleHealthWorkoutSource])
            let dayTimestamp = day.flatMap { Self.dayTimestamp($0) }
            switch (dayTimestamp, workout) {
            case let (day?, workout?): return min(day, workout)
            case let (day?, nil): return day
            case let (nil, workout?): return workout
            case (nil, nil): return nil
            }
        }
    }

    /// Replaces all Apple Health-derived projections in one transaction. Empty inputs are meaningful: they
    /// delete stale daily, metric, and workout rows after the final HealthKit query finds no survivor.
    public func replaceAppleHealthRange(
        appleDaily: [AppleDaily],
        dailyMetrics: [DailyMetric],
        metricPoints: [MetricPoint],
        workouts: [WorkoutRow],
        deviceId: String,
        fromDay: String,
        toDay: String,
        fromTimestamp: Int,
        toTimestamp: Int,
        workoutSource: String = "apple-health"
    ) async throws {
        try syncWrite { db in
            // `DatabaseWriter.write` already opens the outer transaction. Starting a nested GRDB
            // transaction here would fail on DatabaseQueue, so keep the complete replacement in this
            // one writer closure.
            try db.execute(sql: "DELETE FROM appleDaily WHERE deviceId = ? AND day >= ? AND day <= ?",
                               arguments: [deviceId, fromDay, toDay])
            try db.execute(sql: "DELETE FROM dailyMetric WHERE deviceId = ? AND day >= ? AND day <= ?",
                               arguments: [deviceId, fromDay, toDay])
            try db.execute(sql: "DELETE FROM metricSeries WHERE deviceId = ? AND day >= ? AND day <= ?",
                               arguments: [deviceId, fromDay, toDay])
            try db.execute(sql: """
                    DELETE FROM workout
                    WHERE deviceId = ? AND source = ? AND startTs >= ? AND startTs <= ?
                    """, arguments: [deviceId, workoutSource, fromTimestamp, toTimestamp])

            for row in appleDaily {
                try db.execute(sql: """
                    INSERT INTO appleDaily
                        (deviceId, day, steps, activeKcal, basalKcal, vo2max, avgHr, maxHr, walkingHr, weightKg)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [deviceId, row.day, row.steps, row.activeKcal, row.basalKcal,
                                     row.vo2max, row.avgHr, row.maxHr, row.walkingHr, row.weightKg])
            }
            for row in dailyMetrics {
                try db.execute(sql: """
                    INSERT INTO dailyMetric
                        (deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin,
                         disturbances, restingHr, avgHrv, recovery, strain, exerciseCount,
                         spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst,
                         spo2Red, spo2Ir, strainVersion)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [deviceId, row.day, row.totalSleepMin, row.efficiency, row.deepMin,
                                     row.remMin, row.lightMin, row.disturbances, row.restingHr, row.avgHrv,
                                     row.recovery, row.strain, row.exerciseCount, row.spo2Pct,
                                     row.skinTempDevC, row.respRateBpm, row.steps, row.activeKcalEst,
                                     row.spo2Red, row.spo2Ir, row.strainVersion])
            }
            for point in metricPoints {
                try db.execute(sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?, ?, ?, ?)",
                               arguments: [deviceId, point.day, point.key, point.value])
            }
            for workout in workouts {
                try db.execute(sql: """
                    INSERT INTO workout
                        (deviceId, startTs, endTs, sport, source, durationS, energyKcal,
                         avgHr, maxHr, strain, distanceM, zonesJSON, notes, strainVersion)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [deviceId, workout.startTs, workout.endTs, workout.sport,
                                     workout.source, workout.durationS, workout.energyKcal,
                                     workout.avgHr, workout.maxHr, workout.strain, workout.distanceM,
                                     workout.zonesJSON, workout.notes, workout.strainVersion])
            }
        }
    }

    private static func dayTimestamp(_ day: String) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day).map { Int($0.timeIntervalSince1970) }
    }
}
