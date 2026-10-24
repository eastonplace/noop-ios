import Foundation
import GRDB
import WhoopProtocol

/// Exact stored state for one sleep row. Created by the store, so a transient undo can restore its
/// original namespace, auxiliary tracks and every protected recovery overlay together.
public struct StoredSleepSessionSnapshot: Equatable, Sendable {
    public let session: CachedSleepSession
    public let ownerDeviceId: String
    public let databaseInstanceId: String
    public let recoveryOverrides: [SleepRecoveryDailyOverride]
    let motionJSON: String?
    let sleepStateJSON: String?

    public var endTs: Int { session.endTs }
    public var recoveryOverride: SleepRecoveryDailyOverride? { recoveryOverrides.first }
    public var motion: [Double]? {
        motionJSON?.data(using: .utf8).flatMap { try? JSONDecoder().decode([Double].self, from: $0) }
    }
    public var sleepState: [Int]? {
        sleepStateJSON?.data(using: .utf8).flatMap { try? JSONDecoder().decode([Int].self, from: $0) }
    }
}

public enum SleepSessionRestoreResult: Equatable, Sendable {
    case restored
    /// A replacement database, existing session key, or newer recovery owns this state. Nothing changed.
    case conflict
}

extension WhoopStore {
    /// Resolve the immutable natural key in caller-supplied source precedence. An adjusted onset may
    /// no longer overlap its original start second, so interval reads cannot serve this lookup.
    public func sleepSessionSnapshot(deviceIds: [String], startTs: Int) async throws -> StoredSleepSessionSnapshot? {
        try syncRead { db in
            try Self.sleepSessionSnapshot(in: db, deviceIds: deviceIds, startTs: startTs)
        }
    }

    /// Capture the complete undo value and delete its row in one transaction. Nil means no row existed;
    /// an error means no deletion committed. Callers must only add a tombstone after a returned snapshot.
    public func snapshotAndDeleteSleepSession(
        deviceIds: [String], startTs: Int
    ) async throws -> StoredSleepSessionSnapshot? {
        try syncWrite { db in
            guard let snapshot = try Self.sleepSessionSnapshot(in: db, deviceIds: deviceIds, startTs: startTs) else {
                return nil
            }
            try db.execute(sql: "DELETE FROM sleepSession WHERE deviceId = ? AND startTs = ?",
                           arguments: [snapshot.ownerDeviceId, startTs])
            guard db.changesCount == 1 else { return nil }
            return snapshot
        }
    }

    /// Edit only the row whose saved bounds/stages were used for the reclip. A concurrent replacement
    /// during raw staging must not be overwritten by an older editor result.
    public func applySleepEdit(
        to snapshot: StoredSleepSessionSnapshot, newStartTs: Int, newEndTs: Int, stagesJSON: String?
    ) async throws -> Bool {
        guard SleepSessionWindow.isValid(start: newStartTs, end: newEndTs) else { return false }
        return try syncWrite { db in
            guard try Self.sleepSessionSnapshot(in: db, deviceIds: [snapshot.ownerDeviceId],
                                                startTs: snapshot.session.startTs) == snapshot else {
                return false
            }
            try db.execute(sql: """
                UPDATE sleepSession
                SET startTsAdjusted = ?, endTs = ?, stagesJSON = COALESCE(?, stagesJSON), userEdited = 1
                WHERE deviceId = ? AND startTs = ?
                """, arguments: [newStartTs, newEndTs, stagesJSON, snapshot.ownerDeviceId, snapshot.session.startTs])
            return db.changesCount == 1
        }
    }

    /// Restore all saved sleep evidence atomically. Never overwrite a newer row or another recovery;
    /// keep the tombstone on conflict/error. Daily activity is read in this transaction so an undo does
    /// not roll back Strain, steps or other non-sleep fields that advanced after the deletion.
    public func restoreDeletedSleepSession(_ snapshot: StoredSleepSessionSnapshot) async throws -> SleepSessionRestoreResult {
        try syncWrite { db in
            guard try Self.databaseInstanceId(in: db) == snapshot.databaseInstanceId else { return .conflict }
            let session = snapshot.session
            let owner = snapshot.ownerDeviceId
            let exists = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM sleepSession WHERE deviceId = ? AND startTs = ?)
                """, arguments: [owner, session.startTs]) ?? false
            guard !exists else { return .conflict }
            for override in snapshot.recoveryOverrides {
                let occupiedDay = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM sleepRecoveryDailyOverride WHERE deviceId = ? AND day = ?)
                    """, arguments: [owner, override.day]) ?? false
                guard !occupiedDay else { return .conflict }
            }

            try db.execute(sql: """
                INSERT INTO sleepSession
                    (deviceId, startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON,
                     userEdited, startTsAdjusted, motionJSON, sleepStateJSON)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [owner, session.startTs, session.endTs, session.efficiency,
                                  session.restingHr, session.avgHrv, session.stagesJSON,
                                  session.userEdited, session.startTsAdjusted,
                                  snapshot.motionJSON, snapshot.sleepStateJSON])

            for override in snapshot.recoveryOverrides {
                let activity = try Row.fetchOne(db, sql: "SELECT * FROM dailyMetric WHERE deviceId = ? AND day = ?",
                                                arguments: [owner, override.day])
                let daily = DailyMetric(
                    day: override.day, totalSleepMin: override.totalSleepMin, efficiency: override.efficiency,
                    deepMin: override.deepMin, remMin: override.remMin, lightMin: override.lightMin,
                    disturbances: override.disturbances, restingHr: override.restingHr, avgHrv: override.avgHrv,
                    recovery: override.recovery, strain: activity?["strain"], exerciseCount: activity?["exerciseCount"],
                    spo2Pct: activity?["spo2Pct"], skinTempDevC: activity?["skinTempDevC"],
                    respRateBpm: activity?["respRateBpm"], steps: activity?["steps"],
                    activeKcalEst: activity?["activeKcalEst"], spo2Red: activity?["spo2Red"],
                    spo2Ir: activity?["spo2Ir"], strainVersion: activity?["strainVersion"])
                try Self.persistSleepRecoveryDailyOverride(db, override: override, daily: daily, deviceId: owner)
            }
            return .restored
        }
    }

    private static func sleepSessionSnapshot(
        in db: Database, deviceIds: [String], startTs: Int
    ) throws -> StoredSleepSessionSnapshot? {
        var seen = Set<String>()
        for owner in deviceIds where seen.insert(owner).inserted {
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sleepSession WHERE deviceId = ? AND startTs = ?",
                                            arguments: [owner, startTs]) else { continue }
            let session = CachedSleepSession(
                startTs: row["startTs"], endTs: row["endTs"], efficiency: row["efficiency"],
                restingHr: row["restingHr"], avgHrv: row["avgHrv"], stagesJSON: row["stagesJSON"],
                userEdited: row["userEdited"], startTsAdjusted: row["startTsAdjusted"])
            let overrides = try Row.fetchAll(db, sql: """
                SELECT * FROM sleepRecoveryDailyOverride
                WHERE deviceId = ? AND sessionStartTs = ? ORDER BY day
                """, arguments: [owner, startTs]).map(Self.decodeSleepRecoveryDailyOverride)
            return StoredSleepSessionSnapshot(
                session: session, ownerDeviceId: owner, databaseInstanceId: try Self.databaseInstanceId(in: db),
                recoveryOverrides: overrides, motionJSON: row["motionJSON"], sleepStateJSON: row["sleepStateJSON"])
        }
        return nil
    }
}
