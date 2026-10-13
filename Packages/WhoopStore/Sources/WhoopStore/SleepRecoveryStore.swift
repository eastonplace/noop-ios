import Foundation
import GRDB
import WhoopProtocol

/// Durable provenance for a detector retry or a user-bounded sleep reprocessing attempt.
/// It stores only summary metadata; the raw physiological samples remain in their source tables.
public struct SleepRecoveryAuditRecord: Equatable, Sendable {
    public let id: String
    public let source: String
    public let requestedStartTs: Int
    public let requestedEndTs: Int
    public let outcome: String
    public let confidence: Double
    public let reason: String
    public let resultStartTs: Int?
    public let resultEndTs: Int?
    public let stagesAvailable: Bool
    public let restingHr: Int?
    public let avgHrv: Double?
    public let algorithmVersion: String
    public let createdAt: Int
    public let updatedAt: Int

    public init(
        id: String,
        source: String,
        requestedStartTs: Int,
        requestedEndTs: Int,
        outcome: String,
        confidence: Double,
        reason: String,
        resultStartTs: Int?,
        resultEndTs: Int?,
        stagesAvailable: Bool,
        restingHr: Int?,
        avgHrv: Double?,
        algorithmVersion: String,
        createdAt: Int,
        updatedAt: Int
    ) {
        self.id = id
        self.source = source
        self.requestedStartTs = requestedStartTs
        self.requestedEndTs = requestedEndTs
        self.outcome = outcome
        self.confidence = min(1, max(0, confidence))
        self.reason = reason
        self.resultStartTs = resultStartTs
        self.resultEndTs = resultEndTs
        self.stagesAvailable = stagesAvailable
        self.restingHr = restingHr
        self.avgHrv = avgHrv
        self.algorithmVersion = algorithmVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ManualSleepRecoveryWriteResult: Equatable, Sendable {
    case inserted(removedAutomaticSessions: Int)
    case updated(removedAutomaticSessions: Int)
    case conflict(CachedSleepSession)
}

enum SleepRecoveryStoreError: Error, Equatable {
    case incompleteDailyOverride
    case invalidSleepWindow
}

extension WhoopStore {
    /// Atomically replaces overlapping auto-detected computed rows with one user-bounded
    /// session and banks its audit record. When supplied, the corrected daily row and
    /// Rest/Charge override commit in the SAME SQLite transaction. An overlapping
    /// user-edited row is never silently overwritten.
    ///
    /// `replacingStartTs` is the immutable key of the same recovered session before an
    /// edit moved its onset. That one edited row may be re-keyed atomically; every other
    /// overlapping edited row remains a hard conflict.
    public func replaceWithManualSleepRecovery(
        _ session: CachedSleepSession,
        deviceId: String,
        audit: SleepRecoveryAuditRecord,
        dailyOverride: SleepRecoveryDailyOverride? = nil,
        daily: DailyMetric? = nil,
        replacingStartTs: Int? = nil
    ) async throws -> ManualSleepRecoveryWriteResult {
        guard SleepSessionWindow.isValid(start: session.effectiveStartTs, end: session.endTs) else {
            throw SleepRecoveryStoreError.invalidSleepWindow
        }
        // A daily row without its durable overlay (or vice versa) would be erased by
        // the next analytics pass. Reject the programmer error before opening a write.
        guard (dailyOverride == nil) == (daily == nil) else {
            throw SleepRecoveryStoreError.incompleteDailyOverride
        }

        return try syncWrite { db in
            let overlaps = try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON,
                       userEdited, startTsAdjusted
                FROM sleepSession
                WHERE deviceId = ?
                  AND COALESCE(startTsAdjusted, startTs) < ?
                  AND ? < endTs
                  AND endTs - COALESCE(startTsAdjusted, startTs) BETWEEN ? AND ?
                ORDER BY COALESCE(startTsAdjusted, startTs) ASC
                """, arguments: [
                    deviceId, session.endTs, session.effectiveStartTs,
                    SleepSessionWindow.minimumDurationSeconds,
                    SleepSessionWindow.maximumDurationSeconds,
                ])

            if let conflictRow = overlaps.first(where: { row in
                let start: Int = row["startTs"]
                let edited: Bool = row["userEdited"]
                return edited
                    && start != session.startTs
                    && start != replacingStartTs
            }) {
                let conflict = Self.decodeSleepRecoverySession(conflictRow)
                try Self.upsertSleepRecoveryAudit(
                    db, deviceId: deviceId, audit: audit,
                    outcomeOverride: "overlap_conflict",
                    reasonOverride: "overlapping_user_edited_session")
                return .conflict(conflict)
            }

            let existedAtNewKey = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM sleepSession WHERE deviceId = ? AND startTs = ?
                )
                """, arguments: [deviceId, session.startTs]) ?? false
            let existedAtOldKey: Bool
            if let replacingStartTs, replacingStartTs != session.startTs {
                existedAtOldKey = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM sleepSession
                        WHERE deviceId = ? AND startTs = ? AND userEdited = 1
                    )
                    """, arguments: [deviceId, replacingStartTs]) ?? false
            } else {
                existedAtOldKey = false
            }
            let existed = existedAtNewKey || existedAtOldKey

            // A recovered edit may move the immutable key. Delete only the explicitly
            // named old recovered row; its invalidation trigger clears the prior daily
            // overlay inside this same transaction before the new one is written below.
            if existedAtOldKey, let replacingStartTs {
                try db.execute(sql: """
                    DELETE FROM sleepSession
                    WHERE deviceId = ? AND startTs = ? AND userEdited = 1
                    """, arguments: [deviceId, replacingStartTs])
            }

            try db.execute(sql: """
                DELETE FROM sleepSession
                WHERE deviceId = ?
                  AND userEdited = 0
                  AND COALESCE(startTsAdjusted, startTs) < ?
                  AND ? < endTs
                  AND endTs - COALESCE(startTsAdjusted, startTs) BETWEEN ? AND ?
                  AND startTs != ?
                """, arguments: [
                    deviceId, session.endTs, session.effectiveStartTs,
                    SleepSessionWindow.minimumDurationSeconds,
                    SleepSessionWindow.maximumDurationSeconds,
                    session.startTs,
                ])
            let removed = db.changesCount

            try db.execute(sql: """
                INSERT INTO sleepSession
                    (deviceId, startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON,
                     userEdited, startTsAdjusted)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)
                ON CONFLICT(deviceId, startTs) DO UPDATE SET
                    endTs = excluded.endTs,
                    efficiency = excluded.efficiency,
                    restingHr = excluded.restingHr,
                    avgHrv = excluded.avgHrv,
                    stagesJSON = excluded.stagesJSON,
                    userEdited = 1,
                    startTsAdjusted = excluded.startTsAdjusted
                """, arguments: [
                    deviceId, session.startTs, session.endTs, session.efficiency,
                    session.restingHr, session.avgHrv, session.stagesJSON,
                    session.startTsAdjusted,
                ])

            try Self.upsertSleepRecoveryAudit(db, deviceId: deviceId, audit: audit)

            if let override = dailyOverride, let dailyRow = daily {
                try Self.persistSleepRecoveryDailyOverride(
                    db, override: override, daily: dailyRow, deviceId: deviceId)
            }

            return existed
                ? .updated(removedAutomaticSessions: removed)
                : .inserted(removedAutomaticSessions: removed)
        }
    }

    /// Bank an attempt that did not write a session, such as Retry Detection finding
    /// no acceptable block. Idempotent by the caller-provided stable audit id.
    @discardableResult
    public func recordSleepRecoveryAttempt(
        _ audit: SleepRecoveryAuditRecord,
        deviceId: String
    ) async throws -> Int {
        try syncWrite { db in
            try Self.upsertSleepRecoveryAudit(db, deviceId: deviceId, audit: audit)
            return db.changesCount
        }
    }

    /// Record rejected revalidation and clear unsupported values only for the same saved window.
    /// Keep its bounds and nullable override so later raw data can refresh the correction.
    @discardableResult
    public func recordRejectedSleepRecovery(
        _ audit: SleepRecoveryAuditRecord,
        deviceId: String,
        revalidatingSessionStartTs: Int
    ) async throws -> Bool {
        try syncWrite { db in
            try Self.upsertSleepRecoveryAudit(db, deviceId: deviceId, audit: audit)
            guard audit.source == "manual_window",
                  audit.outcome == "insufficient_data" || audit.outcome == "no_sleep_evidence",
                  let day = try String.fetchOne(db, sql: """
                    SELECT o.day FROM sleepRecoveryDailyOverride o
                    JOIN sleepSession s
                      ON s.deviceId = o.deviceId AND s.startTs = o.sessionStartTs
                    WHERE s.deviceId = ? AND s.startTs = ? AND s.userEdited = 1
                      AND COALESCE(s.startTsAdjusted, s.startTs) = ? AND s.endTs = ?
                    """, arguments: [
                        deviceId, revalidatingSessionStartTs, audit.requestedStartTs, audit.requestedEndTs
                    ]) else { return false }

            // Clear the overlay first so its protection triggers cannot restore stale values.
            try db.execute(sql: """
                UPDATE sleepRecoveryDailyOverride
                SET totalSleepMin = NULL, efficiency = NULL, deepMin = NULL, remMin = NULL,
                    lightMin = NULL, disturbances = NULL, restingHr = NULL, avgHrv = NULL,
                    recovery = NULL, restScore = NULL, chargeWeightedSumWithoutSleep = NULL,
                    chargeWeightWithoutSleep = NULL, chargeBaselineUsable = 0, updatedAt = ?
                WHERE deviceId = ? AND day = ? AND sessionStartTs = ?
                """, arguments: [audit.updatedAt, deviceId, day, revalidatingSessionStartTs])
            try db.execute(sql: """
                UPDATE sleepSession
                SET efficiency = NULL, restingHr = NULL, avgHrv = NULL, stagesJSON = NULL
                WHERE deviceId = ? AND startTs = ?
                """, arguments: [deviceId, revalidatingSessionStartTs])
            try db.execute(sql: """
                UPDATE dailyMetric
                SET totalSleepMin = NULL, efficiency = NULL, deepMin = NULL, remMin = NULL,
                    lightMin = NULL, disturbances = NULL, restingHr = NULL, avgHrv = NULL,
                    recovery = NULL
                WHERE deviceId = ? AND day = ?
                """, arguments: [deviceId, day])
            try db.execute(sql: """
                DELETE FROM metricSeries
                WHERE deviceId = ? AND day = ? AND key IN (
                    'sleep_performance',
                    'noop_sleep_performance_v2',
                    'noop_sleep_performance_v2_model',
                    'noop_sleep_performance_v2_source'
                )
                """, arguments: [deviceId, day])
            return true
        }
    }

    public func sleepRecoveryAttempts(
        deviceId: String,
        from: Int = 0,
        to: Int = 4_102_444_800,
        limit: Int = 100
    ) async throws -> [SleepRecoveryAuditRecord] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT id, source, requestedStartTs, requestedEndTs, outcome, confidence,
                       reason, resultStartTs, resultEndTs, stagesAvailable, restingHr,
                       avgHrv, algorithmVersion, createdAt, updatedAt
                FROM sleepRecoveryAttempt
                WHERE deviceId = ? AND requestedEndTs >= ? AND requestedStartTs <= ?
                ORDER BY updatedAt DESC
                LIMIT ?
                """, arguments: [deviceId, from, to, limit]).map(Self.decodeSleepRecoveryAudit)
        }
    }

    private static func upsertSleepRecoveryAudit(
        _ db: Database,
        deviceId: String,
        audit: SleepRecoveryAuditRecord,
        outcomeOverride: String? = nil,
        reasonOverride: String? = nil
    ) throws {
        try db.execute(sql: """
            INSERT INTO sleepRecoveryAttempt
                (id, deviceId, source, requestedStartTs, requestedEndTs, outcome,
                 confidence, reason, resultStartTs, resultEndTs, stagesAvailable,
                 restingHr, avgHrv, algorithmVersion, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                source = excluded.source,
                requestedStartTs = excluded.requestedStartTs,
                requestedEndTs = excluded.requestedEndTs,
                outcome = excluded.outcome,
                confidence = excluded.confidence,
                reason = excluded.reason,
                resultStartTs = excluded.resultStartTs,
                resultEndTs = excluded.resultEndTs,
                stagesAvailable = excluded.stagesAvailable,
                restingHr = excluded.restingHr,
                avgHrv = excluded.avgHrv,
                algorithmVersion = excluded.algorithmVersion,
                updatedAt = excluded.updatedAt
            """, arguments: [
                audit.id, deviceId, audit.source,
                audit.requestedStartTs, audit.requestedEndTs,
                outcomeOverride ?? audit.outcome, audit.confidence,
                reasonOverride ?? audit.reason,
                audit.resultStartTs, audit.resultEndTs,
                audit.stagesAvailable, audit.restingHr, audit.avgHrv,
                audit.algorithmVersion, audit.createdAt, audit.updatedAt,
            ])
    }

    private static func decodeSleepRecoverySession(_ row: Row) -> CachedSleepSession {
        CachedSleepSession(
            startTs: row["startTs"],
            endTs: row["endTs"],
            efficiency: row["efficiency"],
            restingHr: row["restingHr"],
            avgHrv: row["avgHrv"],
            stagesJSON: row["stagesJSON"],
            userEdited: row["userEdited"],
            startTsAdjusted: row["startTsAdjusted"])
    }

    private static func decodeSleepRecoveryAudit(_ row: Row) -> SleepRecoveryAuditRecord {
        SleepRecoveryAuditRecord(
            id: row["id"],
            source: row["source"],
            requestedStartTs: row["requestedStartTs"],
            requestedEndTs: row["requestedEndTs"],
            outcome: row["outcome"],
            confidence: row["confidence"],
            reason: row["reason"],
            resultStartTs: row["resultStartTs"],
            resultEndTs: row["resultEndTs"],
            stagesAvailable: row["stagesAvailable"],
            restingHr: row["restingHr"],
            avgHrv: row["avgHrv"],
            algorithmVersion: row["algorithmVersion"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"])
    }
}
