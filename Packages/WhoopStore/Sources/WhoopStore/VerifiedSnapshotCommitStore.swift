import Foundation
import GRDB
import NoopPhase34Core

public struct IncompleteVerifiedArtifactRepair: Equatable, Sendable {
    public let contextId: String
    public let deviceId: String
    public let analysisGeneration: Int64
    public let snapshotGeneration: Int64
    public let missingSnapshot: Bool
    public let missingWidgetCore: Bool
}

/// Stable keyset position for the immutable-artifact repair scan. Codable
/// callers may persist this value across process death.
public struct IncompleteVerifiedArtifactRepairCursor: Codable, Equatable, Sendable {
    public let createdAt: Date
    public let contextId: String
    public let analysisGeneration: Int64
}

public struct IncompleteVerifiedArtifactRepairPage: Equatable, Sendable {
    public let repairs: [IncompleteVerifiedArtifactRepair]
    /// Last row returned, or the input cursor for an empty terminal page.
    public let nextCursor: IncompleteVerifiedArtifactRepairCursor?
    public let reachedEnd: Bool
}

extension WhoopStore {
    /// Persist one verified analysis -> snapshot mapping. A retry after process death returns the original
    /// mapping. Compatible replays fill immutable snapshot/Widget artifacts that an older build omitted;
    /// conflicting artifacts fail closed.
    public func recordVerifiedSnapshotCommit(
        _ receipt: SnapshotCommitReceipt,
        now: Date,
        widgetCore: VerifiedWidgetCorePayload? = nil
    ) async throws -> SnapshotCommitReceipt {
        try syncWrite { db in
            let snapshotJSON: Data? = try Data.fetchOne(db, sql: """
                SELECT payload FROM todayHealthSnapshot
                WHERE contextId = ? AND generation = ?
                LIMIT 1
                """, arguments: [receipt.projection.contextId, receipt.snapshotGeneration])

            if let existing = try Self.decodeVerifiedSnapshotCommit(
                contextId: receipt.projection.contextId,
                analysisGeneration: receipt.analysisGeneration,
                in: db
            ) {
                guard existing == receipt else {
                    throw VerifiedSnapshotCommitStoreError.conflictingReplay
                }

                if let widgetCore {
                    let bundle = try VerifiedExternalProjectionBundle(
                        projection: receipt.projection,
                        widgetCore: widgetCore
                    )
                    try Self.persistVerifiedExternalProjectionBundle(bundle, now: now, in: db)
                }

                if let snapshotJSON {
                    let existingJSON: Data? = try Data.fetchOne(db, sql: """
                        SELECT snapshotJSON FROM verifiedSnapshotCommit
                        WHERE contextId = ? AND analysisGeneration = ?
                        """, arguments: [receipt.projection.contextId, receipt.analysisGeneration])
                    if let existingJSON {
                        guard existingJSON == snapshotJSON else {
                            throw VerifiedSnapshotCommitStoreError.conflictingReplay
                        }
                    } else {
                        try db.execute(sql: """
                            UPDATE verifiedSnapshotCommit
                            SET snapshotJSON = ?
                            WHERE contextId = ? AND analysisGeneration = ?
                              AND snapshotJSON IS NULL
                            """, arguments: [
                                snapshotJSON,
                                receipt.projection.contextId,
                                receipt.analysisGeneration,
                            ])
                        guard db.changesCount == 1 else {
                            throw VerifiedSnapshotCommitStoreError.conflictingReplay
                        }
                    }
                }
                return existing
            }

            if let widgetCore {
                let bundle = try VerifiedExternalProjectionBundle(
                    projection: receipt.projection,
                    widgetCore: widgetCore
                )
                try Self.persistVerifiedExternalProjectionBundle(bundle, now: now, in: db)
            } else {
                try Self.persistVerifiedProjection(receipt.projection, now: now, in: db)
            }
            let changedDays = try JSONEncoder().encode(receipt.analyzedDays)
            let healthKitPayload = try receipt.healthKitPayload.map(JSONEncoder().encode)
            try db.execute(sql: """
                INSERT INTO verifiedSnapshotCommit (
                    contextId, deviceId, analysisGeneration, throughReceiptGeneration,
                    snapshotGeneration, changedDaysJSON, recordedTimeZoneIdentifier,
                    healthKitPayloadJSON, snapshotJSON, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    receipt.projection.contextId,
                    receipt.projection.deviceId,
                    receipt.analysisGeneration,
                    receipt.throughReceiptGeneration,
                    receipt.snapshotGeneration,
                    changedDays,
                    receipt.recordedTimeZoneIdentifier,
                    healthKitPayload,
                    snapshotJSON,
                    Int(now.timeIntervalSince1970),
                ])
            return receipt
        }
    }

    public func verifiedSnapshotCommit(
        contextId: String,
        analysisGeneration: Int64
    ) async throws -> SnapshotCommitReceipt? {
        try syncRead { db in
            try Self.decodeVerifiedSnapshotCommit(
                contextId: contextId,
                analysisGeneration: analysisGeneration,
                in: db
            )
        }
    }

    public func verifiedSnapshotCommit(
        contextId: String,
        snapshotGeneration: Int64
    ) async throws -> SnapshotCommitReceipt? {
        try syncRead { db in
            try Self.decodeVerifiedSnapshotCommit(
                contextId: contextId,
                snapshotGeneration: snapshotGeneration,
                in: db
            )
        }
    }

    /// Immutable read-back for resumed publication. Never rebuild a historical
    /// generation from the mutable one-row Today cache.
    public func verifiedTodaySnapshot(
        contextId: String,
        analysisGeneration: Int64
    ) async throws -> TodayHealthSnapshot? {
        try syncRead { db in
            guard let payload: Data = try Data.fetchOne(db, sql: """
                SELECT snapshotJSON FROM verifiedSnapshotCommit
                WHERE contextId = ? AND analysisGeneration = ?
                """, arguments: [contextId, analysisGeneration]) else {
                return nil
            }
            do {
                return try JSONDecoder().decode(TodayHealthSnapshot.self, from: payload)
            } catch {
                throw VerifiedSnapshotCommitStoreError.invalidStoredRow
            }
        }
    }

    /// Insert a new verified commit or repair an exact compatible replay with
    /// caller-supplied immutable artifacts. Existing non-null artifacts are
    /// never replaced. Any payload disagreement rolls back the transaction.
    public func ensureVerifiedArtifacts(
        receipt: SnapshotCommitReceipt,
        snapshot: TodayHealthSnapshot,
        widgetCore: VerifiedWidgetCorePayload,
        now: Date = Date()
    ) async throws -> SnapshotCommitReceipt {
        try Self.validateVerifiedSnapshotArtifact(snapshot, receipt: receipt)
        let snapshotJSON = try JSONEncoder().encode(snapshot)
        return try syncWrite { db in
            try Self.ensureVerifiedArtifacts(
                receipt: receipt,
                snapshot: snapshot,
                snapshotJSON: snapshotJSON,
                widgetCore: widgetCore,
                now: now,
                requireExistingCommit: false,
                in: db
            )
        }
    }

    /// Repair only an existing verified commit discovered by the incomplete
    /// artifact scan. Absence is an error, so repair cannot create new truth.
    public func repairVerifiedArtifacts(
        receipt: SnapshotCommitReceipt,
        snapshot: TodayHealthSnapshot,
        widgetCore: VerifiedWidgetCorePayload,
        now: Date = Date()
    ) async throws -> SnapshotCommitReceipt {
        try Self.validateVerifiedSnapshotArtifact(snapshot, receipt: receipt)
        let snapshotJSON = try JSONEncoder().encode(snapshot)
        return try syncWrite { db in
            try Self.ensureVerifiedArtifacts(
                receipt: receipt,
                snapshot: snapshot,
                snapshotJSON: snapshotJSON,
                widgetCore: widgetCore,
                now: now,
                requireExistingCommit: true,
                in: db
            )
        }
    }

    /// Return a bounded durable repair queue. This reports only missing
    /// artifacts. Corrupt non-null artifacts fail when read and are never
    /// silently treated as replaceable.
    public func incompleteVerifiedArtifactRepairs(
        limit: Int = 100
    ) async throws -> [IncompleteVerifiedArtifactRepair] {
        try await incompleteVerifiedArtifactRepairPage(limit: limit).repairs
    }

    /// Keyset-paginated repair scan. Unlike a repeated oldest-N query, a caller
    /// can advance past an irreparable page and reach later repairable commits.
    public func incompleteVerifiedArtifactRepairPage(
        after cursor: IncompleteVerifiedArtifactRepairCursor? = nil,
        limit: Int = 100
    ) async throws -> IncompleteVerifiedArtifactRepairPage {
        guard (1...5_000).contains(limit) else {
            throw VerifiedSnapshotCommitStoreError.invalidRepairLimit
        }
        let cursorSeconds = try cursor.map(Self.validateArtifactRepairCursor)
        return try syncRead { db in
            let rows: [Row]
            if let cursor, let cursorSeconds {
                rows = try Self.fetchIncompleteVerifiedArtifactRepairRows(
                    after: cursor,
                    cursorSeconds: cursorSeconds,
                    limit: limit + 1,
                    in: db
                )
            } else {
                rows = try Self.fetchIncompleteVerifiedArtifactRepairRows(
                    after: nil,
                    cursorSeconds: nil,
                    limit: limit + 1,
                    in: db
                )
            }
            let reachedEnd = rows.count <= limit
            let pageRows = Array(rows.prefix(limit))
            let repairs = pageRows.map { row in
                IncompleteVerifiedArtifactRepair(
                    contextId: row["contextId"],
                    deviceId: row["deviceId"],
                    analysisGeneration: row["analysisGeneration"],
                    snapshotGeneration: row["snapshotGeneration"],
                    missingSnapshot: (row["snapshotJSON"] as Data?) == nil,
                    missingWidgetCore: (row["widgetCoreJSON"] as Data?) == nil
                )
            }
            let nextCursor = pageRows.last.map(Self.artifactRepairCursor)
                ?? cursor
            return IncompleteVerifiedArtifactRepairPage(
                repairs: repairs,
                nextCursor: nextCursor,
                reachedEnd: reachedEnd
            )
        }
    }

    /// Load one named scan lane. The cursor is durable across relaunches.
    public func incompleteVerifiedArtifactRepairScanCursor(
        lane: String = "verified-artifact-repair"
    ) async throws -> IncompleteVerifiedArtifactRepairCursor? {
        let normalizedLane = try Self.validateArtifactRepairLane(lane)
        return try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT cursorCreatedAt, cursorContextId,
                       cursorAnalysisGeneration
                FROM incompleteVerifiedArtifactRepairScan
                WHERE lane = ?
                """, arguments: [normalizedLane]) else {
                return nil
            }
            let createdAt: Int? = row["cursorCreatedAt"]
            let contextId: String? = row["cursorContextId"]
            let analysisGeneration: Int64? = row["cursorAnalysisGeneration"]
            guard let createdAt, let contextId, let analysisGeneration else {
                throw VerifiedSnapshotCommitStoreError.invalidRepairCursor
            }
            let cursor = IncompleteVerifiedArtifactRepairCursor(
                createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                contextId: contextId,
                analysisGeneration: analysisGeneration
            )
            _ = try Self.validateArtifactRepairCursor(cursor)
            return cursor
        }
    }

    /// Persist progress after one bounded page. `reachedEnd` clears the lane and
    /// wraps the next grant to the oldest unresolved row. The store verifies
    /// that no later row exists before it permits that wrap.
    public func saveIncompleteVerifiedArtifactRepairScanCursor(
        _ cursor: IncompleteVerifiedArtifactRepairCursor?,
        lane: String = "verified-artifact-repair",
        reachedEnd: Bool,
        now: Date = Date()
    ) async throws {
        let normalizedLane = try Self.validateArtifactRepairLane(lane)
        let nowSeconds = now.timeIntervalSince1970
        guard nowSeconds.isFinite, nowSeconds >= 0,
              nowSeconds <= Double(Int.max) else {
            throw VerifiedSnapshotCommitStoreError.invalidRepairCursor
        }
        let cursorSeconds = try cursor.map(Self.validateArtifactRepairCursor)
        try syncWrite { db in
            if reachedEnd {
                let laterRows = try Self.fetchIncompleteVerifiedArtifactRepairRows(
                    after: cursor,
                    cursorSeconds: cursorSeconds,
                    limit: 1,
                    in: db
                )
                guard laterRows.isEmpty else {
                    throw VerifiedSnapshotCommitStoreError.invalidRepairCursor
                }
                try db.execute(
                    sql: "DELETE FROM incompleteVerifiedArtifactRepairScan WHERE lane = ?",
                    arguments: [normalizedLane]
                )
                return
            }

            guard let cursor, let cursorSeconds else {
                throw VerifiedSnapshotCommitStoreError.invalidRepairCursor
            }
            try db.execute(sql: """
                INSERT INTO incompleteVerifiedArtifactRepairScan (
                    lane, cursorCreatedAt, cursorContextId,
                    cursorAnalysisGeneration, updatedAt
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(lane) DO UPDATE SET
                    cursorCreatedAt = excluded.cursorCreatedAt,
                    cursorContextId = excluded.cursorContextId,
                    cursorAnalysisGeneration = excluded.cursorAnalysisGeneration,
                    updatedAt = excluded.updatedAt
                """, arguments: [
                    normalizedLane,
                    cursorSeconds,
                    cursor.contextId,
                    cursor.analysisGeneration,
                    Int(nowSeconds),
                ])
        }
    }

    private static func fetchIncompleteVerifiedArtifactRepairRows(
        after cursor: IncompleteVerifiedArtifactRepairCursor?,
        cursorSeconds: Int?,
        limit: Int,
        in db: Database
    ) throws -> [Row] {
        if let cursor, let cursorSeconds {
            return try Row.fetchAll(db, sql: """
                SELECT c.contextId, c.deviceId, c.analysisGeneration,
                       c.snapshotGeneration, c.snapshotJSON,
                       c.createdAt, p.widgetCoreJSON
                FROM verifiedSnapshotCommit c
                JOIN verifiedHealthProjection p
                  ON p.contextId = c.contextId
                 AND p.snapshotGeneration = c.snapshotGeneration
                WHERE (c.snapshotJSON IS NULL OR p.widgetCoreJSON IS NULL)
                  AND (
                    c.createdAt > ?
                    OR (c.createdAt = ? AND c.contextId > ?)
                    OR (c.createdAt = ? AND c.contextId = ?
                        AND c.analysisGeneration > ?)
                  )
                ORDER BY c.createdAt ASC, c.contextId ASC,
                         c.analysisGeneration ASC
                LIMIT ?
                """, arguments: [
                    cursorSeconds,
                    cursorSeconds,
                    cursor.contextId,
                    cursorSeconds,
                    cursor.contextId,
                    cursor.analysisGeneration,
                    limit,
                ])
        }
        return try Row.fetchAll(db, sql: """
            SELECT c.contextId, c.deviceId, c.analysisGeneration,
                   c.snapshotGeneration, c.snapshotJSON,
                   c.createdAt, p.widgetCoreJSON
            FROM verifiedSnapshotCommit c
            JOIN verifiedHealthProjection p
              ON p.contextId = c.contextId
             AND p.snapshotGeneration = c.snapshotGeneration
            WHERE c.snapshotJSON IS NULL OR p.widgetCoreJSON IS NULL
            ORDER BY c.createdAt ASC, c.contextId ASC,
                     c.analysisGeneration ASC
            LIMIT ?
            """, arguments: [limit])
    }

    private static func artifactRepairCursor(
        _ row: Row
    ) -> IncompleteVerifiedArtifactRepairCursor {
        let createdAt: Int = row["createdAt"]
        return IncompleteVerifiedArtifactRepairCursor(
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            contextId: row["contextId"],
            analysisGeneration: row["analysisGeneration"]
        )
    }

    private static func validateArtifactRepairLane(_ lane: String) throws -> String {
        let normalized = lane.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 128 else {
            throw VerifiedSnapshotCommitStoreError.invalidRepairCursor
        }
        return normalized
    }

    private static func validateArtifactRepairCursor(
        _ cursor: IncompleteVerifiedArtifactRepairCursor
    ) throws -> Int {
        let seconds = cursor.createdAt.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0,
              seconds <= Double(Int.max),
              seconds.rounded(.towardZero) == seconds,
              !cursor.contextId.isEmpty,
              cursor.contextId.count <= 1_024,
              cursor.analysisGeneration > 0 else {
            throw VerifiedSnapshotCommitStoreError.invalidRepairCursor
        }
        return Int(seconds)
    }

    static func validateVerifiedSnapshotArtifact(
        _ snapshot: TodayHealthSnapshot,
        receipt: SnapshotCommitReceipt
    ) throws {
        guard snapshot.context?.identifier == receipt.projection.contextId,
              snapshot.generation == receipt.snapshotGeneration,
              snapshot.logicalDay == receipt.projection.logicalDay.key else {
            throw VerifiedSnapshotCommitStoreError.conflictingReplay
        }
    }

    static func ensureVerifiedArtifacts(
        receipt: SnapshotCommitReceipt,
        snapshot: TodayHealthSnapshot,
        snapshotJSON: Data,
        widgetCore: VerifiedWidgetCorePayload,
        now: Date,
        requireExistingCommit: Bool,
        in db: Database
    ) throws -> SnapshotCommitReceipt {
        let existing = try decodeVerifiedSnapshotCommit(
            contextId: receipt.projection.contextId,
            analysisGeneration: receipt.analysisGeneration,
            in: db
        )
        if requireExistingCommit, existing == nil {
            throw VerifiedSnapshotCommitStoreError.missingVerifiedCommit
        }
        if let existing {
            guard existing == receipt else {
                throw VerifiedSnapshotCommitStoreError.conflictingReplay
            }
        }

        let bundle: VerifiedExternalProjectionBundle
        do {
            bundle = try VerifiedExternalProjectionBundle(
                projection: receipt.projection,
                widgetCore: widgetCore
            )
            try persistVerifiedExternalProjectionBundle(bundle, now: now, in: db)
        } catch is VerifiedExternalProjectionBundleStoreError {
            throw VerifiedSnapshotCommitStoreError.conflictingReplay
        }

        if existing != nil {
            let existingSnapshotData: Data? = try Data.fetchOne(db, sql: """
                SELECT snapshotJSON FROM verifiedSnapshotCommit
                WHERE contextId = ? AND analysisGeneration = ?
                """, arguments: [
                    receipt.projection.contextId,
                    receipt.analysisGeneration,
                ])
            if let existingSnapshotData {
                guard let decoded = try? JSONDecoder().decode(
                    TodayHealthSnapshot.self,
                    from: existingSnapshotData
                ), decoded == snapshot else {
                    throw VerifiedSnapshotCommitStoreError.conflictingReplay
                }
            } else {
                try db.execute(sql: """
                    UPDATE verifiedSnapshotCommit
                    SET snapshotJSON = ?
                    WHERE contextId = ? AND analysisGeneration = ?
                      AND snapshotJSON IS NULL
                    """, arguments: [
                        snapshotJSON,
                        receipt.projection.contextId,
                        receipt.analysisGeneration,
                    ])
                guard db.changesCount == 1 else {
                    throw VerifiedSnapshotCommitStoreError.conflictingReplay
                }
            }
            return receipt
        }

        let changedDays = try JSONEncoder().encode(receipt.analyzedDays)
        let healthKitPayload = try receipt.healthKitPayload.map(JSONEncoder().encode)
        try db.execute(sql: """
            INSERT INTO verifiedSnapshotCommit (
                contextId, deviceId, analysisGeneration,
                throughReceiptGeneration, snapshotGeneration,
                changedDaysJSON, recordedTimeZoneIdentifier,
                healthKitPayloadJSON, snapshotJSON, createdAt
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                receipt.projection.contextId,
                receipt.projection.deviceId,
                receipt.analysisGeneration,
                receipt.throughReceiptGeneration,
                receipt.snapshotGeneration,
                changedDays,
                receipt.recordedTimeZoneIdentifier,
                healthKitPayload,
                snapshotJSON,
                Int(now.timeIntervalSince1970),
            ])
        return receipt
    }

    private static func decodeVerifiedSnapshotCommit(
        contextId: String,
        analysisGeneration: Int64? = nil,
        snapshotGeneration: Int64? = nil,
        in db: Database
    ) throws -> SnapshotCommitReceipt? {
        let predicate: String
        let argument: Int64
        if let analysisGeneration {
            predicate = "c.analysisGeneration = ?"
            argument = analysisGeneration
        } else if let snapshotGeneration {
            predicate = "c.snapshotGeneration = ?"
            argument = snapshotGeneration
        } else {
            return nil
        }
        guard let row = try Row.fetchOne(db, sql: """
            SELECT c.*, p.projectionJSON
            FROM verifiedSnapshotCommit c
            JOIN verifiedHealthProjection p
              ON p.contextId = c.contextId
             AND p.snapshotGeneration = c.snapshotGeneration
            WHERE c.contextId = ? AND \(predicate)
            LIMIT 1
            """, arguments: [contextId, argument]) else {
            return nil
        }
        let daysData: Data = row["changedDaysJSON"]
        let projectionData: Data = row["projectionJSON"]
        let payloadData: Data? = row["healthKitPayloadJSON"]
        let days: Set<CivilDay>
        let projection: VerifiedHealthProjection
        do {
            days = try JSONDecoder().decode(Set<CivilDay>.self, from: daysData)
            projection = try JSONDecoder().decode(VerifiedHealthProjection.self, from: projectionData)
        } catch {
            throw VerifiedSnapshotCommitStoreError.invalidStoredRow
        }
        let payload: HistoricalHealthKitMutationPayload?
        do {
            payload = try payloadData.map {
                try JSONDecoder().decode(HistoricalHealthKitMutationPayload.self, from: $0)
            }
        } catch {
            throw VerifiedSnapshotCommitStoreError.invalidStoredRow
        }
        guard projection.contextId == contextId,
              projection.deviceId == (row["deviceId"] as String),
              projection.generation == (row["snapshotGeneration"] as Int64) else {
            throw VerifiedSnapshotCommitStoreError.invalidStoredRow
        }
        do {
            return try SnapshotCommitReceipt(
                throughReceiptGeneration: row["throughReceiptGeneration"],
                analysisGeneration: row["analysisGeneration"],
                snapshotGeneration: row["snapshotGeneration"],
                analyzedDays: days,
                recordedTimeZoneIdentifier: row["recordedTimeZoneIdentifier"],
                healthKitPayload: payload,
                projection: projection
            )
        } catch {
            throw VerifiedSnapshotCommitStoreError.invalidStoredRow
        }
    }
}

public enum VerifiedSnapshotCommitStoreError: Error {
    case conflictingReplay
    case invalidStoredRow
    case missingVerifiedCommit
    case invalidRepairLimit
    case invalidRepairCursor
}
