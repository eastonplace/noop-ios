import Foundation
import GRDB

/// Store-local recalculation for a bounded recovery after the existing editor has
/// re-staged new bounds from raw data. It consumes only the corrected stage JSON,
/// the session's already-recorded overnight vitals, and the persisted baseline-
/// normalized Charge context. No raw sample or personal history is duplicated here.
extension WhoopStore {
    static func recalculateSleepRecoveryAfterEdit(
        _ db: Database,
        deviceId: String,
        sessionStartTs: Int
    ) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT o.day AS overrideDay,
                   o.chargeWeightedSumWithoutSleep,
                   o.chargeWeightWithoutSleep,
                   o.chargeBaselineUsable,
                   o.sleepNeedHours,
                   o.sleepConsistency,
                   s.startTs,
                   COALESCE(s.startTsAdjusted, s.startTs) AS effectiveStartTs,
                   s.endTs,
                   s.stagesJSON,
                   s.restingHr,
                   s.avgHrv
            FROM sleepRecoveryDailyOverride o
            JOIN sleepSession s
              ON s.deviceId = o.deviceId AND s.startTs = o.sessionStartTs
            WHERE o.deviceId = ? AND o.sessionStartTs = ?
            LIMIT 1
            """, arguments: [deviceId, sessionStartTs]) else { return }

        let oldDay: String = row["overrideDay"]
        let effectiveStart: Int = row["effectiveStartTs"]
        let end: Int = row["endTs"]
        let stagesJSON: String? = row["stagesJSON"]
        let restingHr: Int? = row["restingHr"]
        let avgHrv: Double? = row["avgHrv"]
        let sleepNeedHours: Double = row["sleepNeedHours"]
        let sleepConsistency: Double? = row["sleepConsistency"]
        let chargeWeightedSum: Double? = row["chargeWeightedSumWithoutSleep"]
        let chargeWeight: Double? = row["chargeWeightWithoutSleep"]
        let chargeBaselineUsable: Bool = row["chargeBaselineUsable"]

        let summary = Self.recoveredStageSummary(
            stagesJSON: stagesJSON,
            start: effectiveStart,
            end: end)
        let restScore = summary.map {
            Self.recoveredRestScore(
                totalSleepSeconds: $0.totalSleepMin * 60.0,
                efficiency: $0.efficiency,
                deepSeconds: $0.deepMin * 60.0,
                remSeconds: $0.remMin * 60.0,
                sleepNeedHours: sleepNeedHours,
                consistency: sleepConsistency)
        }
        let recovery = Self.recoveredChargeScore(
            weightedSumWithoutSleep: chargeWeightedSum,
            weightWithoutSleep: chargeWeight,
            baselineUsable: chargeBaselineUsable,
            restScore: restScore)
        let newDay = Self.localDayKey(end)
        let updatedAt = Int(Date().timeIntervalSince1970)

        if newDay != oldDay {
            // Disable the old overlay's protection before clearing its visible values.
            try db.execute(sql: """
                UPDATE sleepRecoveryDailyOverride
                SET totalSleepMin = NULL, efficiency = NULL, deepMin = NULL,
                    remMin = NULL, lightMin = NULL, disturbances = NULL,
                    restingHr = NULL, avgHrv = NULL, recovery = NULL,
                    restScore = NULL, updatedAt = ?
                WHERE deviceId = ? AND day = ?
                """, arguments: [updatedAt, deviceId, oldDay])
            try db.execute(sql: """
                UPDATE dailyMetric
                SET totalSleepMin = NULL, efficiency = NULL, deepMin = NULL,
                    remMin = NULL, lightMin = NULL, disturbances = NULL,
                    restingHr = NULL, avgHrv = NULL, recovery = NULL
                WHERE deviceId = ? AND day = ?
                """, arguments: [deviceId, oldDay])
            try db.execute(sql: """
                DELETE FROM metricSeries
                WHERE deviceId = ? AND day = ? AND key = 'sleep_performance'
                """, arguments: [deviceId, oldDay])
            try db.execute(sql: """
                DELETE FROM sleepRecoveryDailyOverride
                WHERE deviceId = ? AND day = ?
                """, arguments: [deviceId, oldDay])
        }

        try db.execute(sql: """
            INSERT INTO sleepRecoveryDailyOverride
                (deviceId, day, sessionStartTs, totalSleepMin, efficiency,
                 deepMin, remMin, lightMin, disturbances, restingHr, avgHrv,
                 recovery, restScore, chargeWeightedSumWithoutSleep,
                 chargeWeightWithoutSleep, chargeBaselineUsable,
                 sleepNeedHours, sleepConsistency, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                chargeWeightedSumWithoutSleep = excluded.chargeWeightedSumWithoutSleep,
                chargeWeightWithoutSleep = excluded.chargeWeightWithoutSleep,
                chargeBaselineUsable = excluded.chargeBaselineUsable,
                sleepNeedHours = excluded.sleepNeedHours,
                sleepConsistency = excluded.sleepConsistency,
                updatedAt = excluded.updatedAt
            """, arguments: [
                deviceId, newDay, sessionStartTs,
                summary?.totalSleepMin, summary?.efficiency,
                summary?.deepMin, summary?.remMin, summary?.lightMin,
                summary?.disturbances, restingHr, avgHrv,
                recovery, restScore, chargeWeightedSum, chargeWeight,
                chargeBaselineUsable, sleepNeedHours, sleepConsistency, updatedAt,
            ])

        // Insert only the fields this correction owns. Existing activity/health fields
        // remain untouched on conflict and can be filled later when no row existed yet.
        try db.execute(sql: """
            INSERT INTO dailyMetric
                (deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin,
                 disturbances, restingHr, avgHrv, recovery)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(deviceId, day) DO UPDATE SET
                totalSleepMin = excluded.totalSleepMin,
                efficiency = excluded.efficiency,
                deepMin = excluded.deepMin,
                remMin = excluded.remMin,
                lightMin = excluded.lightMin,
                disturbances = excluded.disturbances,
                restingHr = excluded.restingHr,
                avgHrv = excluded.avgHrv,
                recovery = excluded.recovery
            """, arguments: [
                deviceId, newDay, summary?.totalSleepMin, summary?.efficiency,
                summary?.deepMin, summary?.remMin, summary?.lightMin,
                summary?.disturbances, restingHr, avgHrv, recovery,
            ])

        if let restScore {
            try db.execute(sql: """
                INSERT INTO metricSeries (deviceId, day, key, value)
                VALUES (?, ?, 'sleep_performance', ?)
                ON CONFLICT(deviceId, day, key) DO UPDATE SET value = excluded.value
                """, arguments: [deviceId, newDay, restScore])
        } else {
            try db.execute(sql: """
                DELETE FROM metricSeries
                WHERE deviceId = ? AND day = ? AND key = 'sleep_performance'
                """, arguments: [deviceId, newDay])
        }

        try db.execute(sql: """
            UPDATE sleepSession SET efficiency = ?
            WHERE deviceId = ? AND startTs = ?
            """, arguments: [summary?.efficiency, deviceId, sessionStartTs])
    }

    private struct StoredRecoveryStage: Decodable {
        let start: Int
        let end: Int
        let stage: String
    }

    private struct RecoveredStageSummary {
        let totalSleepMin: Double
        let efficiency: Double
        let deepMin: Double
        let remMin: Double
        let lightMin: Double
        let disturbances: Int
    }

    private static func recoveredStageSummary(
        stagesJSON: String?,
        start: Int,
        end: Int
    ) -> RecoveredStageSummary? {
        guard end > start,
              let stagesJSON,
              let data = stagesJSON.data(using: .utf8),
              let stages = try? JSONDecoder().decode([StoredRecoveryStage].self, from: data),
              !stages.isEmpty else { return nil }

        var deep = 0.0
        var rem = 0.0
        var light = 0.0
        var asleep = 0.0
        var disturbances = 0
        var hasSeenSleep = false
        var priorWasWake = true

        for segment in stages.sorted(by: { $0.start < $1.start }) {
            let lo = max(start, segment.start)
            let hi = min(end, segment.end)
            guard hi > lo else { continue }
            let seconds = Double(hi - lo)
            let normalized = segment.stage.lowercased()
            let isWake = normalized == "wake" || normalized == "awake"
            if isWake {
                if hasSeenSleep && !priorWasWake { disturbances += 1 }
            } else {
                hasSeenSleep = true
                asleep += seconds
                switch normalized {
                case "deep": deep += seconds
                case "rem": rem += seconds
                default: light += seconds
                }
            }
            priorWasWake = isWake
        }

        guard asleep > 0 else { return nil }
        let inBed = Double(end - start)
        return RecoveredStageSummary(
            totalSleepMin: asleep / 60.0,
            efficiency: min(1, max(0, asleep / inBed)),
            deepMin: deep / 60.0,
            remMin: rem / 60.0,
            lightMin: light / 60.0,
            disturbances: disturbances)
    }

    /// Byte-for-byte constants and rounding from AnalyticsEngine.Rest.composite.
    private static func recoveredRestScore(
        totalSleepSeconds: Double,
        efficiency: Double,
        deepSeconds: Double,
        remSeconds: Double,
        sleepNeedHours: Double,
        consistency: Double?
    ) -> Double {
        func clamp01(_ value: Double) -> Double { min(1, max(0, value)) }
        let durationScore = clamp01(totalSleepSeconds / (max(sleepNeedHours, 0.1) * 3_600.0))
        let efficiencyScore = clamp01(efficiency)
        let deepAdequacy = totalSleepSeconds > 0
            ? clamp01((deepSeconds / totalSleepSeconds) / 0.13)
            : 0
        let deepFactor = 0.5 + 0.5 * deepAdequacy
        let restorativeSeconds = deepSeconds + remSeconds
        let restorativeScore = totalSleepSeconds > 0
            ? clamp01((restorativeSeconds / totalSleepSeconds) / 0.50) * deepFactor
            : 0
        let consistencyScore = clamp01(consistency ?? 0.5)
        let weighted = 0.50 * durationScore
            + 0.20 * efficiencyScore
            + 0.20 * restorativeScore
            + 0.10 * consistencyScore
        return (weighted * 10_000.0).rounded() / 100.0
    }

    /// Re-add the Rest term to the persisted non-sleep Charge context. Constants
    /// mirror RecoveryScorer.recovery exactly.
    private static func recoveredChargeScore(
        weightedSumWithoutSleep: Double?,
        weightWithoutSleep: Double?,
        baselineUsable: Bool,
        restScore: Double?
    ) -> Double? {
        guard baselineUsable,
              var weightedSum = weightedSumWithoutSleep,
              var weight = weightWithoutSleep,
              weight > 0 else { return nil }
        if let restScore {
            let restZ = (restScore / 100.0 - 0.85) / 0.12
            weightedSum += restZ * 0.15
            weight += 0.15
        }
        let z = weightedSum / weight
        let score = 100.0 / (1.0 + exp(-1.6 * (z - (-0.20))))
        return min(100, max(0, score))
    }

    private static func localDayKey(_ timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}
