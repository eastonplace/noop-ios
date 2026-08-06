import Foundation
import GRDB
import NoopPhase34Core

public enum HealthKitWatermarkConflict: Error, Equatable, Sendable {
    case deviceIdentityChanged(
        contextId: String,
        day: CivilDay,
        existing: String,
        incoming: String
    )
}

public enum HealthKitWatermarkIdentityPolicy {
    public static func accepts(
        contextId: String,
        day: CivilDay,
        existingDeviceId: String?,
        existingGeneration: Int64?,
        incomingDeviceId: String,
        incomingGeneration: Int64
    ) throws -> Bool {
        if let existingDeviceId, existingDeviceId != incomingDeviceId {
            throw HealthKitWatermarkConflict.deviceIdentityChanged(
                contextId: contextId,
                day: day,
                existing: existingDeviceId,
                incoming: incomingDeviceId
            )
        }
        guard let existingGeneration else { return true }
        return incomingGeneration >= existingGeneration
    }
}

public struct HealthKitSleepRepairWindow: Equatable, Sendable {
    public let first: CivilDay
    public let last: CivilDay
}

public enum HealthKitSleepRepairPlanner {
    public static func contiguousWindows(
        days: Set<CivilDay>,
        timeZoneIdentifier: String,
        maximumDaysPerWindow: Int = 14
    ) throws -> [HealthKitSleepRepairWindow] {
        guard maximumDaysPerWindow > 0 else { return [] }
        let calendar = try HealthCalendar(timeZoneIdentifier: timeZoneIdentifier)
        let sorted = days.sorted()
        guard var first = sorted.first else { return [] }
        var last = first
        var count = 1
        var result: [HealthKitSleepRepairWindow] = []

        for day in sorted.dropFirst() {
            let contiguous = try calendar.adding(days: 1, to: last) == day
            if contiguous && count < maximumDaysPerWindow {
                last = day
                count += 1
            } else {
                result.append(.init(first: first, last: last))
                first = day
                last = day
                count = 1
            }
        }
        result.append(.init(first: first, last: last))
        return result
    }
}

extension WhoopStore {
    /// Replacement for the watermark UPSERT. Preflight identity in the same
    /// transaction; an older/equal replay may not rewrite `deviceId`.
    public func recordHealthKitMutationDeliveryIdentitySafe(
        contextId: String,
        deviceId: String,
        days: Set<CivilDay>,
        analysisGeneration: Int64,
        now: Date
    ) async throws {
        guard !contextId.isEmpty, !deviceId.isEmpty,
              !days.isEmpty, analysisGeneration > 0 else { return }
        try syncWrite { db in
            let sorted = days.sorted()
            let placeholders = Array(repeating: "?", count: sorted.count)
                .joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT day, deviceId, analysisGeneration
                FROM healthKitMutationWatermark
                WHERE contextId = ? AND day IN (\(placeholders))
                """, arguments: StatementArguments([contextId] + sorted.map(\.key)))
            let existing = Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["day"] as String,
                 (device: row["deviceId"] as String,
                  generation: row["analysisGeneration"] as Int64))
            })
            for day in sorted {
                let prior = existing[day.key]
                guard try HealthKitWatermarkIdentityPolicy.accepts(
                    contextId: contextId,
                    day: day,
                    existingDeviceId: prior?.device,
                    existingGeneration: prior?.generation,
                    incomingDeviceId: deviceId,
                    incomingGeneration: analysisGeneration
                ) else { continue }

                try db.execute(sql: """
                    INSERT INTO healthKitMutationWatermark
                        (contextId, deviceId, day, analysisGeneration, updatedAt)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(contextId, day) DO UPDATE SET
                        analysisGeneration = excluded.analysisGeneration,
                        updatedAt = MAX(
                            healthKitMutationWatermark.updatedAt,
                            excluded.updatedAt
                        )
                    WHERE healthKitMutationWatermark.deviceId = excluded.deviceId
                      AND excluded.analysisGeneration >=
                          healthKitMutationWatermark.analysisGeneration
                    """, arguments: [
                        contextId, deviceId, day.key, analysisGeneration,
                        Int(now.timeIntervalSince1970),
                    ])
            }
        }
    }

    /// Chunk the key ledger under SQLite's bind-variable limit while preserving
    /// one all-or-nothing transaction. 100 rows × 7 values stays below 999.
    public func replaceHealthKitSleepLedgerChunked(
        contextId: String,
        deviceId: String,
        wakeDay: CivilDay,
        analysisGeneration: Int64,
        keys: [(stableStartTimestamp: Int, externalUUID: String)],
        now: Date,
        maximumRowsPerStatement: Int = 100
    ) async throws {
        let chunkSize = max(1, min(100, maximumRowsPerStatement))
        guard !contextId.isEmpty, !deviceId.isEmpty, analysisGeneration > 0 else { return }
        try syncWrite { db in
            if let existing = try Row.fetchOne(db, sql: """
                SELECT deviceId, analysisGeneration
                FROM healthKitSleepDayLedger
                WHERE contextId = ? AND wakeDay = ?
                """, arguments: [contextId, wakeDay.key]) {
                let existingDevice: String = existing["deviceId"]
                let existingGeneration: Int64 = existing["analysisGeneration"]
                guard existingDevice == deviceId else {
                    throw HealthKitWatermarkConflict.deviceIdentityChanged(
                        contextId: contextId,
                        day: wakeDay,
                        existing: existingDevice,
                        incoming: deviceId
                    )
                }
                guard analysisGeneration >= existingGeneration else { return }
            }
            try db.execute(sql: """
                INSERT INTO healthKitSleepDayLedger
                    (contextId, deviceId, wakeDay, analysisGeneration, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(contextId, wakeDay) DO UPDATE SET
                    analysisGeneration = excluded.analysisGeneration,
                    updatedAt = MAX(healthKitSleepDayLedger.updatedAt, excluded.updatedAt)
                WHERE healthKitSleepDayLedger.deviceId = excluded.deviceId
                  AND excluded.analysisGeneration >= healthKitSleepDayLedger.analysisGeneration
                """, arguments: [
                    contextId, deviceId, wakeDay.key, analysisGeneration,
                    Int(now.timeIntervalSince1970),
                ])
            try db.execute(sql: """
                DELETE FROM healthKitSleepKeyLedger
                WHERE contextId = ? AND wakeDay = ?
                """, arguments: [contextId, wakeDay.key])

            for chunk in keys.chunked(into: chunkSize) {
                let values = Array(repeating: "(?,?,?,?,?,?,?)", count: chunk.count)
                    .joined(separator: ",")
                var arguments: [DatabaseValueConvertible] = []
                for key in chunk {
                    arguments.append(contextId)
                    arguments.append(deviceId)
                    arguments.append(wakeDay.key)
                    arguments.append(key.stableStartTimestamp)
                    arguments.append(key.externalUUID)
                    arguments.append(analysisGeneration)
                    arguments.append(Int(now.timeIntervalSince1970))
                }
                try db.execute(sql: """
                    INSERT INTO healthKitSleepKeyLedger
                        (contextId, deviceId, wakeDay, stableStartTimestamp,
                         externalUUID, analysisGeneration, updatedAt)
                    VALUES \(values)
                    """, arguments: StatementArguments(arguments))
            }
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

/*
HealthKitBridge repair integration:

- Compute `repairDays` from missing/invalid ledger rows.
- Call `HealthKitSleepRepairPlanner.contiguousWindows`.
- Run one HKSampleQuery per returned bounded window, not one min...max query.
- Group discovered NOOP keys by wake day in the payload's recorded calendar.
- Persist each day through `replaceHealthKitSleepLedgerChunked`.
- Steady-state delivery with a valid ledger performs zero discovery queries.
*/
