import Foundation
import GRDB
import NoopPhase34Core

public struct HealthKitMutationWatermark: Equatable, Sendable {
    public let contextId: String
    public let deviceId: String
    public let day: CivilDay
    public let analysisGeneration: Int64
    public let updatedAt: Date
}

public enum PR28HealthKitGenerationPolicy {
    /// Equal-generation retries are idempotent. A strictly older mutation must never
    /// delete or replace a newer value at the HealthKit day boundary.
    public static func accepts(incoming: Int64, current: Int64?) -> Bool {
        guard let current else { return true }
        return incoming >= current
    }
}

extension WhoopStore {
    public func eligibleHealthKitMutationDays(
        contextId: String,
        deviceId: String,
        days: Set<CivilDay>,
        analysisGeneration: Int64
    ) async throws -> Set<CivilDay> {
        guard !days.isEmpty, analysisGeneration > 0 else { return [] }
        return try syncRead { db in
            let result = try days.reduce(into: Set<CivilDay>()) { result, day in
                let current: Int64? = try Int64.fetchOne(db, sql: """
                    SELECT analysisGeneration
                    FROM healthKitMutationWatermark
                    WHERE contextId = ? AND day = ?
                    """, arguments: [contextId, day.key])
                if PR28HealthKitGenerationPolicy.accepts(
                    incoming: analysisGeneration,
                    current: current
                ) {
                    result.insert(day)
                }
            }
            return result
        }
    }

    /// Record only after the HealthKit sink has completed. MAX protects a
    /// concurrent equal-generation replay from lowering the durable fence.
    public func recordHealthKitMutationDelivery(
        contextId: String,
        deviceId: String,
        days: Set<CivilDay>,
        analysisGeneration: Int64,
        now: Date
    ) async throws {
        guard !days.isEmpty, analysisGeneration > 0 else { return }
        try syncWrite { db in
            for day in days {
                try db.execute(sql: """
                    INSERT INTO healthKitMutationWatermark
                        (contextId, deviceId, day, analysisGeneration, updatedAt)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(contextId, day) DO UPDATE SET
                        deviceId = excluded.deviceId,
                        analysisGeneration = MAX(
                            healthKitMutationWatermark.analysisGeneration,
                            excluded.analysisGeneration
                        ),
                        updatedAt = excluded.updatedAt
                    """, arguments: [
                        contextId,
                        deviceId,
                        day.key,
                        analysisGeneration,
                        Int(now.timeIntervalSince1970),
                    ])
            }
        }
    }

    public func deleteHealthKitMutationWatermarks(deviceId: String) async throws {
        try syncWrite { db in
            guard try db.tableExists("healthKitMutationWatermark") else { return }
            try db.execute(
                sql: "DELETE FROM healthKitMutationWatermark WHERE deviceId = ?",
                arguments: [deviceId]
            )
        }
    }
}
