import Foundation
import GRDB

/// One daily score to promote from the V2 shadow series into the canonical computed row.
public struct DailyStrainV2Update: Equatable, Sendable {
    public let day: String
    public let strain: Double

    public init(day: String, strain: Double) {
        self.day = day
        self.strain = strain
    }
}

/// One workout score to mark canonical under Strain V2.
public struct WorkoutStrainV2Update: Equatable, Sendable {
    public let startTs: Int
    public let sport: String
    public let strain: Double

    public init(startTs: Int, sport: String, strain: Double) {
        self.startTs = startTs
        self.sport = sport
        self.strain = strain
    }
}

public struct StrainV2CutoverResult: Equatable, Sendable {
    public let dailyRows: Int
    public let workoutRows: Int
    public let shadowRowsRemoved: Int
}

public enum StrainV2StoreError: Error, Equatable {
    /// Cutover is intentionally unavailable for imported source IDs. NOOP's derived sibling is
    /// always `<source>-noop`; requiring that suffix makes imported WHOOP scores storage-safe.
    case computedSourceRequired
}

extension WhoopStore {
    public static let strainV2ShadowKey = "strain_v2_shadow"
    public static let strainV2Version = 2

    /// Persist daily V2 candidates without changing the canonical dailyMetric row.
    /// The metricSeries natural key makes repeated shadow passes idempotent.
    @discardableResult
    public func upsertStrainV2Shadow(_ rows: [DailyStrainV2Update],
                                     deviceId: String) async throws -> Int {
        try syncWrite { db in
            var count = 0
            for row in rows {
                try db.execute(sql: """
                    INSERT INTO metricSeries (deviceId, day, key, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET value = excluded.value
                    """, arguments: [deviceId, row.day, Self.strainV2ShadowKey, row.strain])
                count += db.changesCount
            }
            return count
        }
    }

    /// Atomically promote V2 scores on existing NOOP-computed rows and remove promoted daily
    /// shadows. Missing raw-data-backed rows are left absent, imported sources are rejected, and
    /// repeating the same batch produces the same final state.
    @discardableResult
    public func cutoverStrainV2(deviceId: String,
                                daily: [DailyStrainV2Update],
                                workouts: [WorkoutStrainV2Update]) async throws -> StrainV2CutoverResult {
        guard deviceId.hasSuffix("-noop") else { throw StrainV2StoreError.computedSourceRequired }
        return try syncWrite { db in
            var dailyCount = 0
            var workoutCount = 0
            var removedCount = 0

            for row in daily {
                try db.execute(sql: """
                    UPDATE dailyMetric
                    SET strain = ?, strainVersion = ?
                    WHERE deviceId = ? AND day = ?
                    """, arguments: [row.strain, Self.strainV2Version, deviceId, row.day])
                let changed = db.changesCount
                dailyCount += changed
                if changed > 0 {
                    try db.execute(sql: """
                        DELETE FROM metricSeries
                        WHERE deviceId = ? AND day = ? AND key = ?
                        """, arguments: [deviceId, row.day, Self.strainV2ShadowKey])
                    removedCount += db.changesCount
                }
            }

            for row in workouts {
                try db.execute(sql: """
                    UPDATE workout
                    SET strain = ?, strainVersion = ?
                    WHERE deviceId = ? AND startTs = ? AND sport = ?
                    """, arguments: [row.strain, Self.strainV2Version,
                                      deviceId, row.startTs, row.sport])
                workoutCount += db.changesCount
            }

            return StrainV2CutoverResult(dailyRows: dailyCount,
                                         workoutRows: workoutCount,
                                         shadowRowsRemoved: removedCount)
        }
    }
}
