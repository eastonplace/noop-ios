import Foundation
import GRDB

public struct DailyStrainV2Update: Equatable, Sendable {
    public let day: String
    public let strain: Double
    public init(day: String, strain: Double) { self.day = day; self.strain = strain }
}

public struct WorkoutStrainV2Update: Equatable, Sendable {
    public let startTs: Int
    public let sport: String
    public let strain: Double
    public init(startTs: Int, sport: String, strain: Double) {
        self.startTs = startTs; self.sport = sport; self.strain = strain
    }
}

public struct StrainV2CutoverResult: Equatable, Sendable {
    public let dailyRows: Int
    public let workoutRows: Int
    public let shadowRowsRemoved: Int
    public init(dailyRows: Int, workoutRows: Int, shadowRowsRemoved: Int) {
        self.dailyRows = dailyRows; self.workoutRows = workoutRows
        self.shadowRowsRemoved = shadowRowsRemoved
    }
}

public enum StrainV2StoreError: Error, Equatable {
    case computedSourceRequired
}

extension WhoopStore {
    private static func requireComputedSource(_ deviceId: String) throws {
        guard deviceId.hasSuffix("-noop") else { throw StrainV2StoreError.computedSourceRequired }
    }

    @discardableResult
    public func upsertStrainV2Shadow(_ rows: [DailyStrainV2Update], deviceId: String) async throws -> Int {
        try Self.requireComputedSource(deviceId)
        return try syncWrite { db in
            var changed = 0
            for row in rows {
                try db.execute(sql: """
                    INSERT INTO strainV2Shadow (deviceId, day, strain) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, day) DO UPDATE SET strain = excluded.strain
                    WHERE strainV2Shadow.strain IS NOT excluded.strain
                    """, arguments: [deviceId, row.day, row.strain])
                changed += db.changesCount
            }
            return changed
        }
    }

    /// Atomically promotes one bounded V2 batch. Targeted updates preserve every unrelated metric,
    /// including raw SpO2 channels; imported rows live under other source IDs and are rejected here.
    public func cutoverStrainV2(
        deviceId: String,
        daily: [DailyStrainV2Update],
        workouts: [WorkoutStrainV2Update]
    ) async throws -> StrainV2CutoverResult {
        try Self.requireComputedSource(deviceId)
        return try syncWrite { db in
            var dailyChanged = 0, workoutChanged = 0, shadowRemoved = 0
            for row in daily {
                try db.execute(sql: """
                    UPDATE dailyMetric SET strain = ?, strainVersion = 2
                    WHERE deviceId = ? AND day = ?
                      AND (strain IS NOT ? OR strainVersion IS NOT 2)
                    """, arguments: [row.strain, deviceId, row.day, row.strain])
                dailyChanged += db.changesCount
                try db.execute(sql: "DELETE FROM strainV2Shadow WHERE deviceId = ? AND day = ?",
                               arguments: [deviceId, row.day])
                shadowRemoved += db.changesCount
            }
            for row in workouts {
                try db.execute(sql: """
                    UPDATE workout SET strain = ?, strainVersion = 2
                    WHERE deviceId = ? AND startTs = ? AND sport = ?
                      AND (strain IS NOT ? OR strainVersion IS NOT 2)
                    """, arguments: [row.strain, deviceId, row.startTs, row.sport, row.strain])
                workoutChanged += db.changesCount
            }
            return StrainV2CutoverResult(dailyRows: dailyChanged,
                                         workoutRows: workoutChanged,
                                         shadowRowsRemoved: shadowRemoved)
        }
    }
}
