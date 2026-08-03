import Foundation
import GRDB

public enum HistoricalAnalysisCheckpointError: Error, Equatable, Sendable {
    case invalidConsumerId
    case pendingWorkAlreadyStaged
    case noPendingWork
}

/// Exact identity of the receipt frontier that an analysis consumer is about to process.
public struct HistoricalAnalysisReceiptFrontier: Codable, Equatable, Sendable {
    public let databaseInstanceId: String
    public let scope: HistoricalCursorScope
    public let generation: Int64
    public let trim: Int
    public let receiptId: String
    public let fingerprint: String

    public init(
        databaseInstanceId: String,
        scope: HistoricalCursorScope,
        generation: Int64,
        trim: Int,
        receiptId: String,
        fingerprint: String
    ) {
        self.databaseInstanceId = databaseInstanceId
        self.scope = scope
        self.generation = generation
        self.trim = trim
        self.receiptId = receiptId
        self.fingerprint = fingerprint
    }

    public var watermark: HistoricalDataCommitWatermark {
        HistoricalDataCommitWatermark(
            generation: generation,
            deviceId: scope.deviceId,
            lineage: scope.lineage,
            cursorEpoch: scope.cursorEpoch,
            trimScope: scope.trimScope,
            trim: trim,
            databaseInstanceId: databaseInstanceId
        )
    }
}

/// Durable work that can be resumed after an app relaunch.
public struct HistoricalAnalysisPendingWork: Codable, Equatable, Sendable {
    public let target: HistoricalAnalysisReceiptFrontier
    public let payload: Data

    public init(target: HistoricalAnalysisReceiptFrontier, payload: Data) {
        self.target = target
        self.payload = payload
    }

    public var targetReceiptId: String { target.receiptId }
    public var targetFingerprint: String { target.fingerprint }
    public var targetGeneration: Int64 { target.generation }
    public var targetTrim: Int { target.trim }
}

/// Durable analysis state for one consumer and one database/source scope.
public struct HistoricalAnalysisCheckpoint: Codable, Equatable, Sendable {
    public static let defaultConsumerId = "historical-analysis"

    public let consumerId: String
    public let databaseInstanceId: String
    public let scope: HistoricalCursorScope
    public let throughGeneration: Int64
    public let throughWatermark: HistoricalDataCommitWatermark
    public let pendingWork: HistoricalAnalysisPendingWork?

    public init(
        consumerId: String,
        databaseInstanceId: String,
        scope: HistoricalCursorScope,
        throughGeneration: Int64,
        throughTrim: Int,
        pendingWork: HistoricalAnalysisPendingWork? = nil
    ) {
        self.consumerId = consumerId
        self.databaseInstanceId = databaseInstanceId
        self.scope = scope
        self.throughGeneration = throughGeneration
        self.throughWatermark = HistoricalDataCommitWatermark(
            generation: throughGeneration,
            deviceId: scope.deviceId,
            lineage: scope.lineage,
            cursorEpoch: scope.cursorEpoch,
            trimScope: scope.trimScope,
            trim: throughTrim,
            databaseInstanceId: databaseInstanceId
        )
        self.pendingWork = pendingWork
    }

    public var generation: Int64 { throughGeneration }
    public var watermark: HistoricalDataCommitWatermark { throughWatermark }
    public var checkpointedThroughGeneration: Int64 { throughGeneration }
    public var deviceId: String { scope.deviceId }
    public var lineage: String { scope.lineage }
    public var cursorEpoch: Int { scope.cursorEpoch }
    public var trimScope: String { scope.trimScope }
    public var trim: Int { throughWatermark.trim }
    public var isPending: Bool { pendingWork != nil }
}

/// One current-database source scope with unacknowledged receipts or durable pending work.
public struct HistoricalAnalysisPendingScope: Codable, Equatable, Sendable {
    public let scope: HistoricalCursorScope
    public let checkpoint: HistoricalAnalysisCheckpoint?
    public let highestUnacknowledgedWatermark: HistoricalDataCommitWatermark

    public init(
        scope: HistoricalCursorScope,
        checkpoint: HistoricalAnalysisCheckpoint?,
        highestUnacknowledgedWatermark: HistoricalDataCommitWatermark
    ) {
        self.scope = scope
        self.checkpoint = checkpoint
        self.highestUnacknowledgedWatermark = highestUnacknowledgedWatermark
    }

    public var highestUnacknowledgedGeneration: Int64 {
        highestUnacknowledgedWatermark.generation
    }

    public var pendingWork: HistoricalAnalysisPendingWork? {
        checkpoint?.pendingWork
    }

    public var generation: Int64 { highestUnacknowledgedGeneration }
    public var watermark: HistoricalDataCommitWatermark { highestUnacknowledgedWatermark }
}

extension WhoopStore {
    /// Read one consumer's durable analysis state for one exact source scope.
    public func historicalAnalysisCheckpoint(
        consumerId: String = HistoricalAnalysisCheckpoint.defaultConsumerId,
        for scope: HistoricalCursorScope
    ) async throws -> HistoricalAnalysisCheckpoint? {
        try validateHistoricalAnalysisConsumer(consumerId)
        return try syncRead { db in
            try WhoopStore.historicalAnalysisCheckpoint(consumerId: consumerId, for: scope, in: db)
        }
    }

    /// Return every current-database scope with unacknowledged receipts or durable pending work.
    ///
    /// Receipt and checkpoint rows are read from one SQLite snapshot. The query does not read or seed
    /// from `historicalCursor` or a process-local finalization watermark, so relaunch discovery resumes
    /// the exact staged payload and target edge.
    public func pendingHistoricalAnalysisScopes(
        consumerId: String = HistoricalAnalysisCheckpoint.defaultConsumerId
    ) async throws -> [HistoricalAnalysisPendingScope] {
        try validateHistoricalAnalysisConsumer(consumerId)
        return try syncRead { db in
            let databaseInstanceId = try WhoopStore.databaseInstanceId(in: db)
            var latestReceiptWatermarks: [HistoricalCursorScope: HistoricalDataCommitWatermark] = [:]
            let latestRows = try Row.fetchAll(db, sql: """
                SELECT current.deviceId, current.lineage, current.cursorEpoch, current.trimScope,
                       current.generation, current.trim
                FROM historicalDataCommitJournal AS current
                WHERE current.databaseInstanceId = ?
                  AND NOT EXISTS (
                      SELECT 1
                      FROM historicalDataCommitJournal AS newer
                      WHERE newer.databaseInstanceId = current.databaseInstanceId
                        AND newer.deviceId = current.deviceId
                        AND newer.lineage = current.lineage
                        AND newer.cursorEpoch = current.cursorEpoch
                        AND newer.trimScope = current.trimScope
                        AND newer.generation > current.generation
                  )
                """, arguments: [databaseInstanceId])
            for row in latestRows {
                let scope = HistoricalCursorScope(
                    deviceId: row["deviceId"],
                    lineage: row["lineage"],
                    cursorEpoch: row["cursorEpoch"],
                    trimScope: row["trimScope"]
                )
                latestReceiptWatermarks[scope] = HistoricalDataCommitWatermark(
                    generation: row["generation"],
                    deviceId: scope.deviceId,
                    lineage: scope.lineage,
                    cursorEpoch: scope.cursorEpoch,
                    trimScope: scope.trimScope,
                    trim: row["trim"],
                    databaseInstanceId: databaseInstanceId
                )
            }

            var checkpoints: [HistoricalCursorScope: HistoricalAnalysisCheckpoint] = [:]
            let checkpointRows = try Row.fetchAll(db, sql: """
                SELECT databaseInstanceId, consumerId, deviceId, lineage, cursorEpoch, trimScope,
                       throughGeneration, throughTrim, pendingGeneration, pendingTrim,
                       pendingReceiptId, pendingFingerprint, pendingPayload
                FROM historicalAnalysisCheckpoint
                WHERE databaseInstanceId = ? AND consumerId = ?
                """, arguments: [databaseInstanceId, consumerId])
            for row in checkpointRows {
                let checkpoint = try WhoopStore.decodeHistoricalAnalysisCheckpoint(row)
                checkpoints[checkpoint.scope] = checkpoint
            }

            let candidates = Set(latestReceiptWatermarks.keys).union(checkpoints.keys)
            return candidates
                .sorted(by: WhoopStore.historicalAnalysisScopeComesFirst)
                .compactMap { scope in
                    let checkpoint = checkpoints[scope]
                    let latest = latestReceiptWatermarks[scope]
                    let throughGeneration = checkpoint?.throughGeneration ?? 0
                    let hasUnacknowledgedReceipt = latest.map {
                        $0.generation > throughGeneration
                    } ?? false
                    guard hasUnacknowledgedReceipt || checkpoint?.pendingWork != nil else {
                        return nil
                    }
                    let highestWatermark = hasUnacknowledgedReceipt
                        ? latest!
                        : checkpoint!.pendingWork!.target.watermark
                    return HistoricalAnalysisPendingScope(
                        scope: scope,
                        checkpoint: checkpoint,
                        highestUnacknowledgedWatermark: highestWatermark
                    )
                }
        }
    }

    /// Persist the exact receipt edge and opaque analysis payload before analysis starts.
    ///
    /// A second stage of the same target and payload is idempotent. A different target cannot replace
    /// staged work that may already be running after a relaunch.
    public func stageHistoricalAnalysis(
        consumerId: String = HistoricalAnalysisCheckpoint.defaultConsumerId,
        for scope: HistoricalCursorScope,
        through receipt: HistoricalDataCommitReceipt,
        payload: Data
    ) async throws -> HistoricalAnalysisCheckpoint {
        try validateHistoricalAnalysisConsumer(consumerId)
        return try syncWrite { db in
            try WhoopStore.stageHistoricalAnalysis(
                consumerId: consumerId,
                scope: scope,
                receipt: receipt,
                payload: payload,
                in: db
            )
        }
    }

    /// Acknowledge the staged target only after analysis succeeds. This receipt-typed API validates the
    /// caller's receipt id and fingerprint against the staged target, then clears pending atomically.
    /// against the staged target, which closes a stale or rewound edge even when generation is reused.
    public func acknowledgeHistoricalAnalysis(
        consumerId: String = HistoricalAnalysisCheckpoint.defaultConsumerId,
        through receipt: HistoricalDataCommitReceipt
    ) async throws -> HistoricalAnalysisCheckpoint {
        try validateHistoricalAnalysisConsumer(consumerId)
        let scope = HistoricalCursorScope(
            deviceId: receipt.deviceId,
            lineage: receipt.lineage,
            cursorEpoch: receipt.cursorEpoch,
            trimScope: receipt.trimScope
        )
        return try syncWrite { db in
            try WhoopStore.acknowledgeHistoricalAnalysis(
                consumerId: consumerId,
                throughGeneration: receipt.generation,
                scope: scope,
                expectedReceipt: receipt,
                in: db
            )
        }
    }

    private static func historicalAnalysisCheckpoint(
        consumerId: String,
        for scope: HistoricalCursorScope,
        in db: Database
    ) throws -> HistoricalAnalysisCheckpoint? {
        try validateHistoricalAnalysisScope(scope)
        let databaseInstanceId = try databaseInstanceId(in: db)
        guard let row = try checkpointRow(
            databaseInstanceId: databaseInstanceId,
            consumerId: consumerId,
            scope: scope,
            in: db
        ) else {
            return nil
        }
        return try decodeHistoricalAnalysisCheckpoint(row)
    }

    private static func stageHistoricalAnalysis(
        consumerId: String,
        scope: HistoricalCursorScope,
        receipt: HistoricalDataCommitReceipt,
        payload: Data,
        in db: Database
    ) throws -> HistoricalAnalysisCheckpoint {
        try validateHistoricalAnalysisScope(scope)
        guard receipt.databaseInstanceId.isEmpty == false,
              receipt.deviceId == scope.deviceId,
              receipt.lineage == scope.lineage,
              receipt.cursorEpoch == scope.cursorEpoch,
              receipt.trimScope == scope.trimScope else {
            throw HistoricalDataCommitJournalError.invalidReceipt
        }

        let databaseInstanceId = try databaseInstanceId(in: db)
        guard receipt.databaseInstanceId == databaseInstanceId else {
            throw HistoricalDataCommitJournalError.invalidReceipt
        }
        let storedReceipt = try exactReceiptSummary(
            databaseInstanceId: databaseInstanceId,
            scope: scope,
            generation: receipt.generation,
            in: db
        )
        guard let storedReceipt,
              storedReceipt.receiptId == receipt.receiptId,
              storedReceipt.fingerprint == receipt.fingerprint,
              storedReceipt.trim == receipt.trim else {
            throw HistoricalDataCommitJournalError.invalidReceipt
        }

        let target = HistoricalAnalysisReceiptFrontier(
            databaseInstanceId: databaseInstanceId,
            scope: scope,
            generation: storedReceipt.generation,
            trim: storedReceipt.trim,
            receiptId: storedReceipt.receiptId,
            fingerprint: storedReceipt.fingerprint
        )
        let pendingWork = HistoricalAnalysisPendingWork(target: target, payload: payload)
        let existingRow = try checkpointRow(
            databaseInstanceId: databaseInstanceId,
            consumerId: consumerId,
            scope: scope,
            in: db
        )
        if let existingRow {
            let existing = try decodeHistoricalAnalysisCheckpoint(existingRow)
            if let existingPending = existing.pendingWork {
                guard existingPending == pendingWork else {
                    throw HistoricalAnalysisCheckpointError.pendingWorkAlreadyStaged
                }
                return existing
            }
            if target.generation <= existing.throughGeneration {
                return existing
            }
            try db.execute(sql: """
                UPDATE historicalAnalysisCheckpoint
                SET pendingGeneration = ?, pendingTrim = ?, pendingReceiptId = ?,
                    pendingFingerprint = ?, pendingPayload = ?
                WHERE databaseInstanceId = ? AND consumerId = ? AND deviceId = ?
                  AND lineage = ? AND cursorEpoch = ? AND trimScope = ?
                """, arguments: [
                    target.generation, target.trim, target.receiptId, target.fingerprint, payload,
                    databaseInstanceId, consumerId, scope.deviceId, scope.lineage,
                    scope.cursorEpoch, scope.trimScope,
                ])
        } else {
            try db.execute(sql: """
                INSERT INTO historicalAnalysisCheckpoint
                    (databaseInstanceId, consumerId, deviceId, lineage, cursorEpoch, trimScope,
                     throughGeneration, throughTrim, pendingGeneration, pendingTrim,
                     pendingReceiptId, pendingFingerprint, pendingPayload)
                VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?, ?, ?)
                """, arguments: [
                    databaseInstanceId, consumerId, scope.deviceId, scope.lineage, scope.cursorEpoch,
                    scope.trimScope, target.generation, target.trim, target.receiptId,
                    target.fingerprint, payload,
                ])
        }
        let throughGeneration: Int64
        let throughTrim: Int
        if let existingRow {
            throughGeneration = existingRow["throughGeneration"]
            throughTrim = existingRow["throughTrim"]
        } else {
            throughGeneration = 0
            throughTrim = 0
        }
        return HistoricalAnalysisCheckpoint(
            consumerId: consumerId,
            databaseInstanceId: databaseInstanceId,
            scope: scope,
            throughGeneration: throughGeneration,
            throughTrim: throughTrim,
            pendingWork: pendingWork
        )
    }

    private static func acknowledgeHistoricalAnalysis(
        consumerId: String,
        throughGeneration generation: Int64,
        scope: HistoricalCursorScope,
        expectedReceipt: HistoricalDataCommitReceipt?,
        in db: Database
    ) throws -> HistoricalAnalysisCheckpoint {
        try validateHistoricalAnalysisScope(scope)
        guard generation > 0 else {
            throw HistoricalDataCommitJournalError.invalidReceipt
        }
        let databaseInstanceId = try databaseInstanceId(in: db)
        guard let row = try checkpointRow(
            databaseInstanceId: databaseInstanceId,
            consumerId: consumerId,
            scope: scope,
            in: db
        ) else {
            throw HistoricalAnalysisCheckpointError.noPendingWork
        }
        let checkpoint = try decodeHistoricalAnalysisCheckpoint(row)
        guard let pending = checkpoint.pendingWork else {
            guard generation <= checkpoint.throughGeneration,
                  let storedReceipt = try exactReceiptSummary(
                      databaseInstanceId: databaseInstanceId,
                      scope: scope,
                      generation: generation,
                      in: db
                  ) else {
                throw HistoricalAnalysisCheckpointError.noPendingWork
            }
            if let expectedReceipt {
                guard expectedReceipt.databaseInstanceId == databaseInstanceId,
                      expectedReceipt.deviceId == scope.deviceId,
                      expectedReceipt.lineage == scope.lineage,
                      expectedReceipt.cursorEpoch == scope.cursorEpoch,
                      expectedReceipt.trimScope == scope.trimScope,
                      expectedReceipt.generation == storedReceipt.generation,
                      expectedReceipt.trim == storedReceipt.trim,
                      expectedReceipt.receiptId == storedReceipt.receiptId,
                      expectedReceipt.fingerprint == storedReceipt.fingerprint else {
                    throw HistoricalDataCommitJournalError.invalidReceipt
                }
            }
            return checkpoint
        }
        guard pending.target.generation == generation else {
            throw HistoricalDataCommitJournalError.invalidReceipt
        }
        if let expectedReceipt {
            guard expectedReceipt.databaseInstanceId == databaseInstanceId,
                  expectedReceipt.deviceId == scope.deviceId,
                  expectedReceipt.lineage == scope.lineage,
                  expectedReceipt.cursorEpoch == scope.cursorEpoch,
                  expectedReceipt.trimScope == scope.trimScope,
                  expectedReceipt.generation == pending.target.generation,
                  expectedReceipt.trim == pending.target.trim,
                  expectedReceipt.receiptId == pending.target.receiptId,
                  expectedReceipt.fingerprint == pending.target.fingerprint else {
                throw HistoricalDataCommitJournalError.invalidReceipt
            }
        }

        guard let storedReceipt = try exactReceiptSummary(
            databaseInstanceId: databaseInstanceId,
            scope: scope,
            generation: pending.target.generation,
            in: db
        ),
        storedReceipt.receiptId == pending.target.receiptId,
        storedReceipt.fingerprint == pending.target.fingerprint,
        storedReceipt.generation == pending.target.generation,
        storedReceipt.trim == pending.target.trim else {
            throw HistoricalDataCommitJournalError.invalidReceipt
        }

        try db.execute(sql: """
            UPDATE historicalAnalysisCheckpoint
            SET throughGeneration = pendingGeneration,
                throughTrim = pendingTrim,
                pendingGeneration = NULL,
                pendingTrim = NULL,
                pendingReceiptId = NULL,
                pendingFingerprint = NULL,
                pendingPayload = NULL
            WHERE databaseInstanceId = ? AND consumerId = ? AND deviceId = ?
              AND lineage = ? AND cursorEpoch = ? AND trimScope = ?
              AND pendingGeneration = ? AND pendingTrim = ?
              AND pendingReceiptId = ? AND pendingFingerprint = ?
            """, arguments: [
                databaseInstanceId, consumerId, scope.deviceId, scope.lineage, scope.cursorEpoch,
                scope.trimScope, pending.target.generation, pending.target.trim,
                pending.target.receiptId, pending.target.fingerprint,
            ])
        guard let acknowledgedRow = try checkpointRow(
            databaseInstanceId: databaseInstanceId,
            consumerId: consumerId,
            scope: scope,
            in: db
        ) else {
            throw HistoricalDataCommitJournalError.invalidReceipt
        }
        return try decodeHistoricalAnalysisCheckpoint(acknowledgedRow)
    }

    private static func checkpointRow(
        databaseInstanceId: String,
        consumerId: String,
        scope: HistoricalCursorScope,
        in db: Database
    ) throws -> Row? {
        try Row.fetchOne(db, sql: """
            SELECT databaseInstanceId, consumerId, deviceId, lineage, cursorEpoch, trimScope,
                   throughGeneration, throughTrim, pendingGeneration, pendingTrim,
                   pendingReceiptId, pendingFingerprint, pendingPayload
            FROM historicalAnalysisCheckpoint
            WHERE databaseInstanceId = ? AND consumerId = ? AND deviceId = ?
              AND lineage = ? AND cursorEpoch = ? AND trimScope = ?
            """, arguments: [
                databaseInstanceId, consumerId, scope.deviceId, scope.lineage,
                scope.cursorEpoch, scope.trimScope,
            ])
    }

    private static func exactReceiptSummary(
        databaseInstanceId: String,
        scope: HistoricalCursorScope,
        generation: Int64,
        in db: Database
    ) throws -> (generation: Int64, trim: Int, receiptId: String, fingerprint: String)? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT generation, trim, receiptId, fingerprint
            FROM historicalDataCommitJournal
            WHERE databaseInstanceId = ? AND deviceId = ? AND lineage = ?
              AND cursorEpoch = ? AND trimScope = ? AND generation = ?
            """, arguments: [
                databaseInstanceId, scope.deviceId, scope.lineage, scope.cursorEpoch,
                scope.trimScope, generation,
            ]) else {
            return nil
        }
        return (
            generation: row["generation"],
            trim: row["trim"],
            receiptId: row["receiptId"],
            fingerprint: row["fingerprint"]
        )
    }

    private static func decodeHistoricalAnalysisCheckpoint(
        _ row: Row
    ) throws -> HistoricalAnalysisCheckpoint {
        let scope = HistoricalCursorScope(
            deviceId: row["deviceId"],
            lineage: row["lineage"],
            cursorEpoch: row["cursorEpoch"],
            trimScope: row["trimScope"]
        )
        try validateHistoricalAnalysisScope(scope)
        let throughGeneration: Int64 = row["throughGeneration"]
        let pendingGeneration: Int64? = row["pendingGeneration"]
        let pendingTrim: Int? = row["pendingTrim"]
        let pendingReceiptId: String? = row["pendingReceiptId"]
        let pendingFingerprint: String? = row["pendingFingerprint"]
        let pendingPayload: Data? = row["pendingPayload"]
        let pendingWork: HistoricalAnalysisPendingWork?
        if pendingGeneration == nil,
           pendingTrim == nil,
           pendingReceiptId == nil,
           pendingFingerprint == nil,
           pendingPayload == nil {
            pendingWork = nil
        } else {
            guard let pendingGeneration,
                  let pendingTrim,
                  let pendingReceiptId,
                  let pendingFingerprint,
                  let pendingPayload,
                  !pendingReceiptId.isEmpty,
                  !pendingFingerprint.isEmpty,
                  pendingGeneration > throughGeneration,
                  pendingTrim >= 0 else {
                throw HistoricalDataCommitJournalError.invalidReceipt
            }
            let target = HistoricalAnalysisReceiptFrontier(
                databaseInstanceId: row["databaseInstanceId"],
                scope: scope,
                generation: pendingGeneration,
                trim: pendingTrim,
                receiptId: pendingReceiptId,
                fingerprint: pendingFingerprint
            )
            pendingWork = HistoricalAnalysisPendingWork(target: target, payload: pendingPayload)
        }
        return HistoricalAnalysisCheckpoint(
            consumerId: row["consumerId"],
            databaseInstanceId: row["databaseInstanceId"],
            scope: scope,
            throughGeneration: throughGeneration,
            throughTrim: row["throughTrim"],
            pendingWork: pendingWork
        )
    }

    private static func historicalAnalysisScopeComesFirst(
        _ lhs: HistoricalCursorScope,
        _ rhs: HistoricalCursorScope
    ) -> Bool {
        if lhs.deviceId != rhs.deviceId { return lhs.deviceId < rhs.deviceId }
        if lhs.lineage != rhs.lineage { return lhs.lineage < rhs.lineage }
        if lhs.cursorEpoch != rhs.cursorEpoch { return lhs.cursorEpoch < rhs.cursorEpoch }
        return lhs.trimScope < rhs.trimScope
    }

    private static func validateHistoricalAnalysisScope(
        _ scope: HistoricalCursorScope
    ) throws {
        guard !scope.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !scope.lineage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !scope.trimScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              scope.cursorEpoch >= 0 else {
            throw HistoricalDataCommitJournalError.invalidCursorScope
        }
    }

    private func validateHistoricalAnalysisConsumer(
        _ consumerId: String
    ) throws {
        guard !consumerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HistoricalAnalysisCheckpointError.invalidConsumerId
        }
    }
}
