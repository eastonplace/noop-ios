import Foundation
import GRDB

public struct DurablePruningCadence: Sendable {
    public static let key = "pr28.pipeline.prune"
    public static let minimumInterval: TimeInterval = 24 * 60 * 60

    public static func isDue(lastRunAt: Date?, now: Date) -> Bool {
        guard let lastRunAt else { return true }
        let elapsed = now.timeIntervalSince(lastRunAt)
        return elapsed < 0 || elapsed >= minimumInterval
    }
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
            try db.execute(sql: """
                INSERT INTO durableMaintenanceCadence (key, lastRunAt)
                VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    lastRunAt = MAX(durableMaintenanceCadence.lastRunAt, excluded.lastRunAt)
                """, arguments: [trimmed, Int(date.timeIntervalSince1970)])
        }
    }
}

public enum DurableMaintenanceCadenceStoreError: Error, Equatable, Sendable {
    case invalidRow
}
