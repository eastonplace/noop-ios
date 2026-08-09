import Foundation
import GRDB

public struct DurablePruningCadence: Sendable {
    public static let key = "pr28.pipeline.prune"
    public static let minimumInterval: TimeInterval = 24 * 60 * 60

    public static func isDue(lastRunAt: Date?, now: Date) -> Bool {
        isDue(lastRunAt: lastRunAt, now: now, minimumInterval: minimumInterval)
    }

    public static func isDue(
        lastRunAt: Date?,
        now: Date,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard let lastRunAt else { return true }
        let elapsed = now.timeIntervalSince(lastRunAt)
        return elapsed < 0 || elapsed >= minimumInterval
    }
}

public struct DurableMaintenanceLease: Equatable, Sendable {
    public let key: String
    public let owner: String
    public let expiresAt: Date
}

extension WhoopStore {
    public func maintenanceLastRunAt(key: String) async throws -> Date? {
        try syncRead { db in
            guard let seconds = try Int.fetchOne(
                db,
                sql: "SELECT lastRunAt FROM durableMaintenanceCadence WHERE key = ?",
                arguments: [key]
            ) else { return nil }
            guard seconds >= 0 else { throw DurableMaintenanceCadenceStoreError.invalidRow }
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
    }

    /// Advance cadence only after the maintenance transaction succeeds.
    public func recordMaintenanceRun(key: String, at date: Date) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, date.timeIntervalSince1970 >= 0 else {
            throw DurableMaintenanceCadenceStoreError.invalidRow
        }
        try syncWrite { db in
            let timestamp = Int(date.timeIntervalSince1970)
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT leaseOwner, leaseExpiresAt FROM durableMaintenanceCadence WHERE key = ?",
                arguments: [trimmed]
            ) {
                let leaseOwner: String? = row["leaseOwner"]
                let leaseExpiresAt: Int? = row["leaseExpiresAt"]
                guard leaseOwner == nil || leaseExpiresAt.map({ $0 <= timestamp }) == true else {
                    throw DurableMaintenanceCadenceStoreError.leaseHeld
                }
            }
            try db.execute(sql: """
                INSERT INTO durableMaintenanceCadence (
                    key, lastRunAt, leaseOwner, leaseExpiresAt
                ) VALUES (?, ?, NULL, NULL)
                ON CONFLICT(key) DO UPDATE SET
                    lastRunAt = MAX(durableMaintenanceCadence.lastRunAt, excluded.lastRunAt),
                    leaseOwner = NULL,
                    leaseExpiresAt = NULL
                """, arguments: [trimmed, timestamp])
        }
    }

    /// Atomically claim one due cadence row. Competing callers observe the
    /// persisted lease and only one caller receives work.
    public func claimMaintenanceLease(
        key: String,
        owner: String,
        now: Date = Date(),
        minimumInterval: TimeInterval,
        leaseDuration: TimeInterval = 5 * 60
    ) async throws -> DurableMaintenanceLease? {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty, !normalizedOwner.isEmpty,
              now.timeIntervalSince1970 >= 0,
              minimumInterval.isFinite, minimumInterval >= 0,
              leaseDuration.isFinite, leaseDuration > 0 else {
            throw DurableMaintenanceCadenceStoreError.invalidRow
        }
        let boundedLeaseDuration = min(30 * 60, max(15, leaseDuration))
        let nowSeconds = Int(now.timeIntervalSince1970)
        let expiresAt = now.addingTimeInterval(boundedLeaseDuration)
        let expiresAtSeconds = Int(expiresAt.timeIntervalSince1970)
        return try syncWrite { db -> DurableMaintenanceLease? in
            if let row = try Row.fetchOne(db, sql: """
                SELECT lastRunAt, leaseOwner, leaseExpiresAt
                FROM durableMaintenanceCadence WHERE key = ?
                """, arguments: [normalizedKey]) {
                let lastRunAtSeconds: Int = row["lastRunAt"]
                let leaseOwner: String? = row["leaseOwner"]
                let leaseExpiresAt: Int? = row["leaseExpiresAt"]
                guard lastRunAtSeconds >= 0,
                      (leaseOwner == nil) == (leaseExpiresAt == nil) else {
                    throw DurableMaintenanceCadenceStoreError.invalidRow
                }
                if let leaseOwner, let leaseExpiresAt, leaseExpiresAt > nowSeconds {
                    if leaseOwner == normalizedOwner {
                        return DurableMaintenanceLease(
                            key: normalizedKey,
                            owner: normalizedOwner,
                            expiresAt: Date(timeIntervalSince1970: TimeInterval(leaseExpiresAt))
                        )
                    }
                    return nil
                }
                let lastRunAt = lastRunAtSeconds == 0
                    ? nil
                    : Date(timeIntervalSince1970: TimeInterval(lastRunAtSeconds))
                guard DurablePruningCadence.isDue(
                    lastRunAt: lastRunAt,
                    now: now,
                    minimumInterval: minimumInterval
                ) else { return nil }
                try db.execute(sql: """
                    UPDATE durableMaintenanceCadence
                    SET leaseOwner = ?, leaseExpiresAt = ?
                    WHERE key = ?
                      AND (leaseOwner IS NULL OR leaseExpiresAt <= ?)
                    """, arguments: [
                        normalizedOwner, expiresAtSeconds, normalizedKey, nowSeconds,
                    ])
                guard db.changesCount == 1 else { return nil }
            } else {
                try db.execute(sql: """
                    INSERT INTO durableMaintenanceCadence (
                        key, lastRunAt, leaseOwner, leaseExpiresAt
                    ) VALUES (?, 0, ?, ?)
                    """, arguments: [normalizedKey, normalizedOwner, expiresAtSeconds])
            }
            return DurableMaintenanceLease(
                key: normalizedKey,
                owner: normalizedOwner,
                expiresAt: expiresAt
            )
        }
    }

    /// Advance cadence and release the lease only after maintenance succeeds.
    public func completeMaintenanceLease(
        _ lease: DurableMaintenanceLease,
        at date: Date = Date()
    ) async throws {
        guard date.timeIntervalSince1970 >= 0 else {
            throw DurableMaintenanceCadenceStoreError.invalidRow
        }
        let timestamp = Int(date.timeIntervalSince1970)
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE durableMaintenanceCadence
                SET lastRunAt = MAX(lastRunAt, ?),
                    leaseOwner = NULL, leaseExpiresAt = NULL
                WHERE key = ? AND leaseOwner = ? AND leaseExpiresAt > ?
                """, arguments: [timestamp, lease.key, lease.owner, timestamp])
            guard db.changesCount == 1 else {
                throw DurableMaintenanceCadenceStoreError.leaseLost
            }
        }
    }

    /// Release a failed or cancelled claim without advancing cadence.
    @discardableResult
    public func releaseMaintenanceLease(
        _ lease: DurableMaintenanceLease
    ) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE durableMaintenanceCadence
                SET leaseOwner = NULL, leaseExpiresAt = NULL
                WHERE key = ? AND leaseOwner = ?
                """, arguments: [lease.key, lease.owner])
            return db.changesCount == 1
        }
    }
}

public enum DurableMaintenanceCadenceStoreError: Error, Equatable, Sendable {
    case invalidRow
    case leaseHeld
    case leaseLost
}
