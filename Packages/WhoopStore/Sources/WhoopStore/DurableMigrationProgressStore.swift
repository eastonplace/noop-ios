import Foundation
import GRDB

public enum DurableMigrationProgressState: String, Codable, Equatable, Sendable {
    case pending
    case complete
}

public struct DurableMigrationProgress: Codable, Equatable, Sendable {
    public let key: String
    public let nextOffset: Int
    public let state: DurableMigrationProgressState
    public let updatedAt: Date
}

public enum DurableMigrationProgressStoreError: Error, Equatable, Sendable {
    case invalidProgress
    case invalidRow
}

extension WhoopStore {
    public func durableMigrationProgress(
        key: String
    ) async throws -> DurableMigrationProgress? {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw DurableMigrationProgressStoreError.invalidProgress
        }
        return try syncRead { db in
            try Row.fetchOne(
                db,
                sql: "SELECT key, nextOffset, state, updatedAt FROM durableMigrationProgress WHERE key = ?",
                arguments: [normalized]
            ).map(Self.decodeDurableMigrationProgress)
        }
    }

    /// Persist the next bounded offset. A completed migration cannot move back
    /// to pending without a new migration key.
    public func saveDurableMigrationProgress(
        key: String,
        nextOffset: Int,
        now: Date = Date()
    ) async throws -> DurableMigrationProgress {
        try await persistDurableMigrationProgress(
            key: key,
            nextOffset: nextOffset,
            state: .pending,
            now: now
        )
    }

    public func markDurableMigrationComplete(
        key: String,
        nextOffset: Int,
        now: Date = Date()
    ) async throws -> DurableMigrationProgress {
        try await persistDurableMigrationProgress(
            key: key,
            nextOffset: nextOffset,
            state: .complete,
            now: now
        )
    }

    private func persistDurableMigrationProgress(
        key: String,
        nextOffset: Int,
        state: DurableMigrationProgressState,
        now: Date
    ) async throws -> DurableMigrationProgress {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, nextOffset >= 0,
              now.timeIntervalSinceReferenceDate.isFinite else {
            throw DurableMigrationProgressStoreError.invalidProgress
        }
        return try syncWrite { db in
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT key, nextOffset, state, updatedAt FROM durableMigrationProgress WHERE key = ?",
                arguments: [normalized]
            ) {
                let existing = try Self.decodeDurableMigrationProgress(row)
                guard existing.state != .complete || state == .complete else {
                    throw DurableMigrationProgressStoreError.invalidProgress
                }
                guard nextOffset >= existing.nextOffset else {
                    throw DurableMigrationProgressStoreError.invalidProgress
                }
            }
            try db.execute(sql: """
                INSERT INTO durableMigrationProgress (key, nextOffset, state, updatedAt)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    nextOffset = excluded.nextOffset,
                    state = excluded.state,
                    updatedAt = excluded.updatedAt
                """, arguments: [
                    normalized,
                    nextOffset,
                    state.rawValue,
                    Int(now.timeIntervalSince1970),
                ])
            return DurableMigrationProgress(
                key: normalized,
                nextOffset: nextOffset,
                state: state,
                updatedAt: now
            )
        }
    }

    private static func decodeDurableMigrationProgress(
        _ row: Row
    ) throws -> DurableMigrationProgress {
        let key: String = row["key"]
        let nextOffset: Int = row["nextOffset"]
        let updatedAtSeconds: Int = row["updatedAt"]
        guard !key.isEmpty, nextOffset >= 0,
              let state = DurableMigrationProgressState(rawValue: row["state"]),
              updatedAtSeconds >= 0 else {
            throw DurableMigrationProgressStoreError.invalidRow
        }
        return DurableMigrationProgress(
            key: key,
            nextOffset: nextOffset,
            state: state,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAtSeconds))
        )
    }
}
