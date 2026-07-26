import Foundation
import GRDB

/// The exact sleep/recovery fields a user-recovered night owns on its wake day.
/// Activity and all other daily fields remain owned by the normal analytics pass.
public struct SleepRecoveryDailyOverride: Equatable, Sendable {
    public let day: String
    public let sessionStartTs: Int
    public let totalSleepMin: Double?
    public let efficiency: Double?
    public let deepMin: Double?
    public let remMin: Double?
    public let lightMin: Double?
    public let disturbances: Int?
    public let restingHr: Int?
    public let avgHrv: Double?
    public let recovery: Double?
    public let restScore: Double?
    public let updatedAt: Int

    public init(
        day: String,
        sessionStartTs: Int,
        totalSleepMin: Double?,
        efficiency: Double?,
        deepMin: Double?,
        remMin: Double?,
        lightMin: Double?,
        disturbances: Int?,
        restingHr: Int?,
        avgHrv: Double?,
        recovery: Double?,
        restScore: Double?,
        updatedAt: Int
    ) {
        self.day = day
        self.sessionStartTs = sessionStartTs
        self.totalSleepMin = totalSleepMin
        self.efficiency = efficiency
        self.deepMin = deepMin
        self.remMin = remMin
        self.lightMin = lightMin
        self.disturbances = disturbances
        self.restingHr = restingHr
        self.avgHrv = avgHrv
        self.recovery = recovery
        self.restScore = restScore
        self.updatedAt = updatedAt
    }
}

extension WhoopStore {
    /// Commit a recovered daily overlay and visible rows inside an existing store
    /// transaction. Shared with the session+audit writer so the full recovery is atomic.
    static func persistSleepRecoveryDailyOverride(
        _ db: Database,
        override: SleepRecoveryDailyOverride,
        daily: DailyMetric,
        deviceId: String
    ) throws {
        try db.execute(sql: """
            INSERT INTO sleepRecoveryDailyOverride
                (deviceId, day, sessionStartTs, totalSleepMin, efficiency,
                 deepMin, remMin, lightMin, disturbances, restingHr, avgHrv,
                 recovery, restScore, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(deviceId, day) DO UPDATE SET
                sessionStartTs = excluded.sessionStartTs,
                totalSleepMin = excluded.totalSleepMin,
                efficiency = excluded.efficiency,
                deepMin = excluded.deepMin,
                remMin = excluded.remMin,
                lightMin = excluded.lightMin,
                disturbances = excluded.disturbances,
                restingHr = excluded.restingHr,
                avgHrv = excluded.avgHrv,
                recovery = excluded.recovery,
                restScore = excluded.restScore,
                updatedAt = excluded.updatedAt
            """, arguments: [
                deviceId, override.day, override.sessionStartTs,
                override.totalSleepMin, override.efficiency,
                override.deepMin, override.remMin, override.lightMin,
                override.disturbances, override.restingHr, override.avgHrv,
                override.recovery, override.restScore, override.updatedAt,
            ])

        try db.execute(sql: """
            INSERT INTO dailyMetric
                (deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin,
                 disturbances, restingHr, avgHrv, recovery, strain, exerciseCount,
                 spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst,
                 spo2Red, spo2Ir, strainVersion)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(deviceId, day) DO UPDATE SET
                totalSleepMin = excluded.totalSleepMin,
                efficiency = excluded.efficiency,
                deepMin = excluded.deepMin,
                remMin = excluded.remMin,
                lightMin = excluded.lightMin,
                disturbances = excluded.disturbances,
                restingHr = excluded.restingHr,
                avgHrv = excluded.avgHrv,
                recovery = excluded.recovery,
                strain = excluded.strain,
                exerciseCount = excluded.exerciseCount,
                spo2Pct = excluded.spo2Pct,
                skinTempDevC = excluded.skinTempDevC,
                respRateBpm = excluded.respRateBpm,
                steps = excluded.steps,
                activeKcalEst = excluded.activeKcalEst,
                spo2Red = excluded.spo2Red,
                spo2Ir = excluded.spo2Ir,
                strainVersion = excluded.strainVersion
            """, arguments: [
                deviceId, daily.day, daily.totalSleepMin, daily.efficiency,
                daily.deepMin, daily.remMin, daily.lightMin, daily.disturbances,
                daily.restingHr, daily.avgHrv, daily.recovery, daily.strain,
                daily.exerciseCount, daily.spo2Pct, daily.skinTempDevC,
                daily.respRateBpm, daily.steps, daily.activeKcalEst,
                daily.spo2Red, daily.spo2Ir, daily.strainVersion,
            ])

        if let rest = override.restScore {
            try db.execute(sql: """
                INSERT INTO metricSeries (deviceId, day, key, value)
                VALUES (?, ?, 'sleep_performance', ?)
                ON CONFLICT(deviceId, day, key) DO UPDATE SET value = excluded.value
                """, arguments: [deviceId, override.day, rest])
        } else {
            // Partial data may support real RHR/HRV without defensible stages/Rest.
            // Remove any stale Rest point; the delete trigger deliberately does not
            // restore it when the override's restScore is NULL.
            try db.execute(sql: """
                DELETE FROM metricSeries
                WHERE deviceId = ? AND day = ? AND key = 'sleep_performance'
                """, arguments: [deviceId, override.day])
        }
    }

    /// Standalone writer used by repair/rebuild paths. The main user flow calls the
    /// session+audit overload so all artifacts commit together.
    @discardableResult
    public func persistSleepRecoveryDailyOverride(
        _ override: SleepRecoveryDailyOverride,
        daily: DailyMetric,
        deviceId: String
    ) async throws -> Int {
        try syncWrite { db in
            try Self.persistSleepRecoveryDailyOverride(
                db, override: override, daily: daily, deviceId: deviceId)
            return db.changesCount
        }
    }

    public func sleepRecoveryDailyOverrides(
        deviceId: String,
        from: String = "0000-01-01",
        to: String = "9999-12-31"
    ) async throws -> [SleepRecoveryDailyOverride] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, sessionStartTs, totalSleepMin, efficiency, deepMin, remMin,
                       lightMin, disturbances, restingHr, avgHrv, recovery, restScore, updatedAt
                FROM sleepRecoveryDailyOverride
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day ASC
                """, arguments: [deviceId, from, to]).map { row in
                    SleepRecoveryDailyOverride(
                        day: row["day"],
                        sessionStartTs: row["sessionStartTs"],
                        totalSleepMin: row["totalSleepMin"],
                        efficiency: row["efficiency"],
                        deepMin: row["deepMin"],
                        remMin: row["remMin"],
                        lightMin: row["lightMin"],
                        disturbances: row["disturbances"],
                        restingHr: row["restingHr"],
                        avgHrv: row["avgHrv"],
                        recovery: row["recovery"],
                        restScore: row["restScore"],
                        updatedAt: row["updatedAt"])
                }
        }
    }
}
