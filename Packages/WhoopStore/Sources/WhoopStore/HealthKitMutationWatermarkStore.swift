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

public enum HealthKitWatermarkStoreError: Error, Equatable, Sendable {
    case invalidIdentity
    case conflictingDevice
}

extension WhoopStore {
    /// Indexed privacy-deletion lookup. This is evidence of exact HealthKit days already delivered for one
    /// source, including deletion-only mutations that may no longer have a current dailyMetric row.
    public func healthKitMutationWatermarkDays(deviceId: String) async throws -> Set<CivilDay> {
        let source = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return [] }
        return try syncRead { db in
            let rows = try String.fetchAll(
                db,
                sql: "SELECT day FROM healthKitMutationWatermark WHERE deviceId = ? ORDER BY day",
                arguments: [source]
            )
            return try Set(rows.map(CivilDay.init(key:)))
        }
    }

    /// One indexed lookup for the complete exact mutation. A conflicting device is a durable identity error;
    /// silently treating it as an empty fence would allow one source to overwrite another source's HealthKit.
    public func eligibleHealthKitMutationDaysBatched(
        contextId: String,
        deviceId: String,
        days: Set<CivilDay>,
        analysisGeneration: Int64
    ) async throws -> Set<CivilDay> {
        guard !contextId.isEmpty,
              !deviceId.isEmpty,
              !days.isEmpty,
              days.count <= HistoricalAnalysisWork.maximumExactDayCount,
              analysisGeneration > 0 else {
            throw HealthKitWatermarkStoreError.invalidIdentity
        }

        return try syncRead { db in
            let ordered = days.sorted()
            let placeholders = Array(repeating: "?", count: ordered.count).joined(separator: ",")
            var arguments: [DatabaseValueConvertible] = [contextId]
            arguments.append(contentsOf: ordered.map(\.key))
            let rows = try Row.fetchAll(db, sql: """
                SELECT deviceId, day, analysisGeneration
                FROM healthKitMutationWatermark
                WHERE contextId = ? AND day IN (\(placeholders))
                """, arguments: StatementArguments(arguments))
            var currentByDay: [String: Int64] = [:]
            for row in rows {
                let storedDeviceId: String = row["deviceId"]
                guard storedDeviceId == deviceId else {
                    throw HealthKitWatermarkStoreError.conflictingDevice
                }
                currentByDay[row["day"]] = row["analysisGeneration"]
            }
            return Set(ordered.filter { day in
                PR28HealthKitGenerationPolicy.accepts(
                    incoming: analysisGeneration, current: currentByDay[day.key])
            })
        }
    }

    /// One multi-row UPSERT after the HealthKit sink has completed. MAX makes equal-generation replay and
    /// concurrent retries idempotent without lowering a newer per-day fence.
    public func recordHealthKitMutationDeliveryBatched(
        contextId: String,
        deviceId: String,
        days: Set<CivilDay>,
        analysisGeneration: Int64,
        now: Date
    ) async throws {
        guard !contextId.isEmpty,
              !deviceId.isEmpty,
              !days.isEmpty,
              days.count <= HistoricalAnalysisWork.maximumExactDayCount,
              analysisGeneration > 0,
              now.timeIntervalSinceReferenceDate.isFinite else {
            throw HealthKitWatermarkStoreError.invalidIdentity
        }
        try syncWrite { db in
            let ordered = days.sorted()
            let valuesSQL = ordered.map { _ in "(?, ?, ?, ?, ?)" }.joined(separator: ",")
            var values: [DatabaseValueConvertible] = []
            values.reserveCapacity(ordered.count * 5)
            let timestamp = Int(now.timeIntervalSince1970)
            for day in ordered {
                values += [contextId, deviceId, day.key, analysisGeneration, timestamp]
            }
            try db.execute(sql: """
                INSERT INTO healthKitMutationWatermark
                    (contextId, deviceId, day, analysisGeneration, updatedAt)
                VALUES \(valuesSQL)
                ON CONFLICT(contextId, day) DO UPDATE SET
                    deviceId = excluded.deviceId,
                    analysisGeneration = MAX(
                        healthKitMutationWatermark.analysisGeneration,
                        excluded.analysisGeneration
                    ),
                    updatedAt = MAX(healthKitMutationWatermark.updatedAt, excluded.updatedAt)
                """, arguments: StatementArguments(values))
        }
    }

    public func eligibleHealthKitMutationDays(
        contextId: String,
        deviceId: String,
        days: Set<CivilDay>,
        analysisGeneration: Int64
    ) async throws -> Set<CivilDay> {
        guard !days.isEmpty else { return [] }
        return try await eligibleHealthKitMutationDaysBatched(
            contextId: contextId,
            deviceId: deviceId,
            days: days,
            analysisGeneration: analysisGeneration)
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
        guard !days.isEmpty else { return }
        try await recordHealthKitMutationDeliveryBatched(
            contextId: contextId,
            deviceId: deviceId,
            days: days,
            analysisGeneration: analysisGeneration,
            now: now)
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
