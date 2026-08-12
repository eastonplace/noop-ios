import Foundation
import GRDB
import NoopPhase34Core

public struct HealthKitSleepLedgerEntry: Equatable, Sendable {
    public let wakeDay: CivilDay
    public let stableStartTimestamp: Int
    public let externalUUID: String

    public init(wakeDay: CivilDay, stableStartTimestamp: Int, externalUUID: String) {
        self.wakeDay = wakeDay
        self.stableStartTimestamp = stableStartTimestamp
        self.externalUUID = externalUUID
    }
}

public struct HealthKitSleepLedgerSnapshot: Equatable, Sendable {
    public let coveredDays: Set<CivilDay>
    public let entries: [HealthKitSleepLedgerEntry]

    public var keys: Set<String> { Set(entries.map(\.externalUUID)) }
}

extension WhoopStore {
    /// Indexed privacy-deletion lookup for every exact sleep key still owned by one source.
    public func healthKitSleepLedgerEntries(deviceId: String) async throws -> [HealthKitSleepLedgerEntry] {
        let source = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return [] }
        return try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT wakeDay, stableStartTimestamp, externalUUID
                FROM healthKitSleepKeyLedger
                WHERE deviceId = ?
                ORDER BY wakeDay, stableStartTimestamp
                """, arguments: [source]).map { row in
                    HealthKitSleepLedgerEntry(
                        wakeDay: try CivilDay(key: row["wakeDay"]),
                        stableStartTimestamp: row["stableStartTimestamp"],
                        externalUUID: row["externalUUID"])
                }
        }
    }

    public func healthKitSleepLedger(
        contextId: String,
        deviceId: String,
        days: Set<CivilDay>
    ) async throws -> HealthKitSleepLedgerSnapshot {
        guard !contextId.isEmpty, !deviceId.isEmpty, !days.isEmpty else {
            return HealthKitSleepLedgerSnapshot(coveredDays: [], entries: [])
        }
        return try syncRead { db in
            let ordered = days.sorted()
            let placeholders = Array(repeating: "?", count: ordered.count).joined(separator: ",")
            var arguments: [DatabaseValueConvertible] = [contextId, deviceId]
            arguments.append(contentsOf: ordered.map(\.key))
            let coveredRows = try Row.fetchAll(db, sql: """
                SELECT wakeDay FROM healthKitSleepDayLedger
                WHERE contextId = ? AND deviceId = ?
                  AND wakeDay IN (\(placeholders))
                """, arguments: StatementArguments(arguments))
            let covered = try Set(coveredRows.map { try CivilDay(key: $0["wakeDay"]) })

            let keyRows = try Row.fetchAll(db, sql: """
                SELECT wakeDay, stableStartTimestamp, externalUUID
                FROM healthKitSleepKeyLedger
                WHERE contextId = ? AND deviceId = ?
                  AND wakeDay IN (\(placeholders))
                ORDER BY wakeDay, stableStartTimestamp
                """, arguments: StatementArguments(arguments))
            let entries = try keyRows.map { row in
                HealthKitSleepLedgerEntry(
                    wakeDay: try CivilDay(key: row["wakeDay"]),
                    stableStartTimestamp: row["stableStartTimestamp"],
                    externalUUID: row["externalUUID"])
            }
            return HealthKitSleepLedgerSnapshot(coveredDays: covered, entries: entries)
        }
    }

    /// Replace coverage only after HealthKit deletion/save succeeds. A zero-session day is still marked
    /// covered, so a later deletion-only replay performs no HealthKit discovery scan.
    public func replaceHealthKitSleepLedger(
        contextId: String,
        deviceId: String,
        days: Set<CivilDay>,
        entries: [HealthKitSleepLedgerEntry],
        analysisGeneration: Int64,
        now: Date
    ) async throws {
        guard !contextId.isEmpty, !deviceId.isEmpty, !days.isEmpty, analysisGeneration > 0 else { return }
        try syncWrite { db in
            let ordered = days.sorted()
            let placeholders = Array(repeating: "?", count: ordered.count).joined(separator: ",")
            var deleteArguments: [DatabaseValueConvertible] = [contextId]
            deleteArguments.append(contentsOf: ordered.map(\.key))
            try db.execute(sql: """
                DELETE FROM healthKitSleepDayLedger
                WHERE contextId = ? AND wakeDay IN (\(placeholders))
                """, arguments: StatementArguments(deleteArguments))

            let timestamp = Int(now.timeIntervalSince1970)
            let daySQL = ordered.map { _ in "(?, ?, ?, ?, ?)" }.joined(separator: ",")
            var dayArguments: [DatabaseValueConvertible] = []
            dayArguments.reserveCapacity(ordered.count * 5)
            for day in ordered {
                dayArguments += [contextId, deviceId, day.key, analysisGeneration, timestamp]
            }
            try db.execute(sql: """
                INSERT INTO healthKitSleepDayLedger
                    (contextId, deviceId, wakeDay, analysisGeneration, updatedAt)
                VALUES \(daySQL)
                """, arguments: StatementArguments(dayArguments))

            let admitted = entries.filter { days.contains($0.wakeDay) }
            guard !admitted.isEmpty else { return }
            let keySQL = admitted.map { _ in "(?, ?, ?, ?, ?, ?, ?)" }.joined(separator: ",")
            var keyArguments: [DatabaseValueConvertible] = []
            keyArguments.reserveCapacity(admitted.count * 7)
            for entry in admitted {
                keyArguments += [
                    contextId, deviceId, entry.wakeDay.key, entry.stableStartTimestamp,
                    entry.externalUUID, analysisGeneration, timestamp,
                ]
            }
            try db.execute(sql: """
                INSERT INTO healthKitSleepKeyLedger
                    (contextId, deviceId, wakeDay, stableStartTimestamp,
                     externalUUID, analysisGeneration, updatedAt)
                VALUES \(keySQL)
                """, arguments: StatementArguments(keyArguments))
        }
    }
}
