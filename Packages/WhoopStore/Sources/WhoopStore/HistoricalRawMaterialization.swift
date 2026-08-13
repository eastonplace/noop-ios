import Foundation
import GRDB
import WhoopProtocol

public enum HistoricalRawMaterializationPolicy {
    /// A separate fail-closed ceiling for raw bytes awaiting successful materialization. When reached,
    /// the commit fails before its receipt/cursor/ACK, so the strap remains the source of truth.
    public static let maxProtectedBytes = 64 * 1_024 * 1_024
    public static let defaultJobLimit = 4
    public static let leaseSeconds = 5 * 60
}

public enum HistoricalMaterializationJobState: String, Codable, Equatable, Sendable {
    case pending
    case running
    case retryable
    case completed
    case quarantined
}

public struct HistoricalMaterializationRunSummary: Equatable, Sendable {
    public let claimed: Int
    public let completed: Int
    public let retryable: Int
    public let quarantined: Int

    public init(claimed: Int = 0, completed: Int = 0, retryable: Int = 0, quarantined: Int = 0) {
        self.claimed = claimed
        self.completed = completed
        self.retryable = retryable
        self.quarantined = quarantined
    }
}

public struct HistoricalDurableFrontier: Equatable, Sendable {
    public let normalizedMaxTs: Int?
    public let mappedRawMaxTs: Int?

    public init(normalizedMaxTs: Int?, mappedRawMaxTs: Int?) {
        self.normalizedMaxTs = normalizedMaxTs
        self.mappedRawMaxTs = mappedRawMaxTs
    }

    public var maxTs: Int? {
        [normalizedMaxTs, mappedRawMaxTs].compactMap { $0 }.max()
    }
}

private struct HistoricalMaterializationClaim: Sendable {
    let receiptId: String
    let rawBatchId: String
    let deviceId: String
    let lineage: String
    let cursorEpoch: Int
    let originalFrameIndexes: [Int]
    let leaseOwner: String
}

private struct HistoricalMaterializedFrame: Sendable {
    let originalFrameIndex: Int
    let version: Int
    let unix: Int
    let exactFrame: Data
}

private enum HistoricalMaterializationError: Error, Equatable, Sendable {
    case invalidIndexes
    case missingRawBatch
    case invalidEnvelope
    case unsupportedLayout
}

extension WhoopStore {
    static func assertHistoricalProtectedRawCapacity(
        incomingBytes: Int,
        limit: Int = HistoricalRawMaterializationPolicy.maxProtectedBytes,
        in db: Database
    ) throws {
        guard incomingBytes >= 0, limit >= 0 else {
            throw HistoricalDataCommitJournalError.invalidReceipt
        }
        let protectedBytes = try Int.fetchOne(db, sql: """
            SELECT COALESCE(SUM(protectedByteCount), 0)
            FROM historicalMaterializationJob
            WHERE state != 'completed'
            """) ?? 0
        let (attempted, overflow) = protectedBytes.addingReportingOverflow(incomingBytes)
        guard !overflow, attempted <= limit else {
            throw HistoricalDataCommitJournalError.protectedRawByteCeilingExceeded(
                limit: limit,
                attempted: overflow ? Int.max : attempted
            )
        }
    }

    static func insertHistoricalMaterializationJob(
        receiptId: String,
        rawMeta: RawBatchMeta,
        originalFrameIndexes: [Int],
        createdAt: Int,
        in db: Database
    ) throws {
        let encodedIndexes = try JSONEncoder().encode(originalFrameIndexes)
        try db.execute(sql: """
            INSERT INTO historicalMaterializationJob
                (receiptId, rawBatchId, deviceId, lineage, cursorEpoch, state,
                 originalFrameIndexesJSON, protectedByteCount, attemptCount,
                 createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, 0, ?, ?)
            """, arguments: [
                receiptId, rawMeta.batchId, rawMeta.deviceId, rawMeta.lineage, rawMeta.cursorEpoch,
                encodedIndexes, rawMeta.byteSize, createdAt, createdAt,
            ])
    }

    /// The newest timestamp that has crossed the durable receipt boundary. Mapped-raw timestamps are
    /// independent of normalized HR so V20/V21-only history can advance a continuation decision.
    public func latestHistoricalDurableFrontier(deviceId: String) async throws -> HistoricalDurableFrontier {
        try syncRead { db in
            let normalized = try Int.fetchOne(
                db,
                sql: "SELECT MAX(maxDecodedTs) FROM historicalDataCommitJournal WHERE deviceId = ?",
                arguments: [deviceId]
            )
            let rows = try Row.fetchAll(db, sql: """
                SELECT rawRangeJSON
                FROM historicalDataCommitJournal
                WHERE deviceId = ? AND rawStatus = 'materializationRequired'
                """, arguments: [deviceId])
            let mapped = try rows.compactMap { row -> Int? in
                let data: Data = row["rawRangeJSON"]
                guard let evidence = try? JSONDecoder().decode(HistoricalRawRangeEvidence.self, from: data)
                else { throw HistoricalDataCommitJournalError.invalidReceipt }
                return evidence.maxReceivedTs
            }.max()
            return HistoricalDurableFrontier(normalizedMaxTs: normalized, mappedRawMaxTs: mapped)
        }
    }

    /// Claim and materialize a bounded number of restart-safe V20/V21 jobs. Claims are leased so a
    /// process death is recoverable; invalid durable bytes are quarantined and remain protected.
    @discardableResult
    public func materializePendingHistoricalRaw(
        limit: Int = HistoricalRawMaterializationPolicy.defaultJobLimit,
        now: Int = Int(Date().timeIntervalSince1970)
    ) async throws -> HistoricalMaterializationRunSummary {
        guard limit > 0 else { return HistoricalMaterializationRunSummary() }
        let leaseOwner = UUID().uuidString
        let claims: [HistoricalMaterializationClaim] = try syncWrite { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT receiptId, rawBatchId, deviceId, lineage, cursorEpoch,
                       originalFrameIndexesJSON
                FROM historicalMaterializationJob
                WHERE state IN ('pending', 'retryable')
                   OR (state = 'running' AND COALESCE(leaseExpiresAt, 0) <= ?)
                -- New pending work must not sit behind an older retryable job that keeps failing.
                -- Each external wake may retry old work, but it always claims pending receipts first.
                ORDER BY CASE WHEN state = 'pending' THEN 0 ELSE 1 END, createdAt, receiptId
                LIMIT ?
                """, arguments: [now, limit])
            var output: [HistoricalMaterializationClaim] = []
            output.reserveCapacity(rows.count)
            for row in rows {
                let data: Data = row["originalFrameIndexesJSON"]
                guard let indexes = try? JSONDecoder().decode([Int].self, from: data) else {
                    throw HistoricalMaterializationError.invalidIndexes
                }
                let receiptId: String = row["receiptId"]
                try db.execute(sql: """
                    UPDATE historicalMaterializationJob
                    SET state = 'running', leaseOwner = ?, leaseExpiresAt = ?,
                        attemptCount = attemptCount + 1, updatedAt = ?, lastError = NULL
                    WHERE receiptId = ?
                    """, arguments: [
                        leaseOwner, now + HistoricalRawMaterializationPolicy.leaseSeconds, now, receiptId,
                    ])
                output.append(HistoricalMaterializationClaim(
                    receiptId: receiptId,
                    rawBatchId: row["rawBatchId"],
                    deviceId: row["deviceId"],
                    lineage: row["lineage"],
                    cursorEpoch: row["cursorEpoch"],
                    originalFrameIndexes: indexes,
                    leaseOwner: leaseOwner
                ))
            }
            return output
        }

        var completed = 0
        var retryable = 0
        var quarantined = 0
        for claim in claims {
            do {
                let rawFrames = try await rawFrames(
                    batchId: claim.rawBatchId,
                    deviceId: claim.deviceId,
                    lineage: claim.lineage,
                    cursorEpoch: claim.cursorEpoch
                )
                guard !rawFrames.isEmpty else { throw HistoricalMaterializationError.missingRawBatch }
                let materialized = try await Task.detached(priority: .utility) {
                    try WhoopStore.materializeHistoricalFrames(
                        rawFrames,
                        originalFrameIndexes: claim.originalFrameIndexes
                    )
                }.value
                try syncWrite { db in
                    guard try String.fetchOne(
                        db,
                        sql: "SELECT leaseOwner FROM historicalMaterializationJob WHERE receiptId = ? AND state = 'running'",
                        arguments: [claim.receiptId]
                    ) == claim.leaseOwner else { return }
                    for frame in materialized {
                        try db.execute(sql: """
                            INSERT INTO historicalMappedRawFrame
                                (receiptId, originalFrameIndex, version, unix, exactFrame,
                                 frameByteCount, materializedAt)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(receiptId, originalFrameIndex) DO UPDATE SET
                                version = excluded.version,
                                unix = excluded.unix,
                                exactFrame = excluded.exactFrame,
                                frameByteCount = excluded.frameByteCount,
                                materializedAt = excluded.materializedAt
                            """, arguments: [
                                claim.receiptId, frame.originalFrameIndex, frame.version, frame.unix,
                                frame.exactFrame, frame.exactFrame.count, now,
                            ])
                    }
                    let stored = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM historicalMappedRawFrame WHERE receiptId = ?",
                        arguments: [claim.receiptId]
                    ) ?? 0
                    guard stored == materialized.count else {
                        throw HistoricalMaterializationError.invalidIndexes
                    }
                    try db.execute(sql: """
                        UPDATE historicalMaterializationJob
                        SET state = 'completed', leaseOwner = NULL, leaseExpiresAt = NULL,
                            updatedAt = ?, completedAt = ?, lastError = NULL
                        WHERE receiptId = ? AND leaseOwner = ? AND state = 'running'
                        """, arguments: [now, now, claim.receiptId, claim.leaseOwner])
                }
                completed += 1
            } catch let error as HistoricalMaterializationError {
                try markHistoricalMaterializationFailure(
                    claim: claim,
                    state: .quarantined,
                    error: String(describing: error),
                    now: now
                )
                quarantined += 1
            } catch {
                try markHistoricalMaterializationFailure(
                    claim: claim,
                    state: .retryable,
                    error: String(describing: error),
                    now: now
                )
                retryable += 1
            }
        }
        return HistoricalMaterializationRunSummary(
            claimed: claims.count,
            completed: completed,
            retryable: retryable,
            quarantined: quarantined
        )
    }

    private static func materializeHistoricalFrames(
        _ frames: [[UInt8]],
        originalFrameIndexes: [Int]
    ) throws -> [HistoricalMaterializedFrame] {
        guard frames.count == originalFrameIndexes.count,
              Set(originalFrameIndexes).count == originalFrameIndexes.count,
              zip(originalFrameIndexes, originalFrameIndexes.dropFirst()).allSatisfy(<) else {
            throw HistoricalMaterializationError.invalidIndexes
        }
        let mapped = try zip(originalFrameIndexes, frames).compactMap { originalIndex, frame
            -> HistoricalMaterializedFrame? in
            let parsed = parseFrame(frame, family: .whoop5)
            guard parsed.ok, parsed.envelopeOK,
                  parsed.headerCRCOK == true, parsed.payloadCRCOK == true,
                  frame.count >= 12 else {
                throw HistoricalMaterializationError.invalidEnvelope
            }
            let disposition = historicalRecordDisposition(
                parsed: parsed,
                rawFrame: frame,
                family: .whoop5
            )
            guard case .mappedRaw(let version) = disposition else { return nil }
            guard (version == 20 || version == 21),
                  let unix = parsed.parsed["unix"]?.intValue else {
                throw HistoricalMaterializationError.unsupportedLayout
            }
            return HistoricalMaterializedFrame(
                originalFrameIndex: originalIndex,
                version: version,
                unix: unix,
                exactFrame: Data(frame)
            )
        }
        guard !mapped.isEmpty else { throw HistoricalMaterializationError.unsupportedLayout }
        return mapped
    }

    private func markHistoricalMaterializationFailure(
        claim: HistoricalMaterializationClaim,
        state: HistoricalMaterializationJobState,
        error: String,
        now: Int
    ) throws {
        let boundedError = String(error.prefix(512))
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE historicalMaterializationJob
                SET state = ?, leaseOwner = NULL, leaseExpiresAt = NULL,
                    updatedAt = ?, lastError = ?
                WHERE receiptId = ? AND leaseOwner = ? AND state = 'running'
                """, arguments: [state.rawValue, now, boundedError, claim.receiptId, claim.leaseOwner])
        }
    }

    // MARK: Test support

    func historicalMaterializationJobStateForTest(receiptId: String) async throws -> HistoricalMaterializationJobState? {
        try syncRead { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM historicalMaterializationJob WHERE receiptId = ?",
                arguments: [receiptId]
            ).flatMap(HistoricalMaterializationJobState.init(rawValue:))
        }
    }

    func historicalMaterializedFrameIndexesForTest(receiptId: String) async throws -> [Int] {
        try syncRead { db in
            try Int.fetchAll(
                db,
                sql: "SELECT originalFrameIndex FROM historicalMappedRawFrame WHERE receiptId = ? ORDER BY originalFrameIndex",
                arguments: [receiptId]
            )
        }
    }

    func historicalMaterializedFramesForTest(receiptId: String) async throws -> [Data] {
        try syncRead { db in
            try Data.fetchAll(
                db,
                sql: "SELECT exactFrame FROM historicalMappedRawFrame WHERE receiptId = ? ORDER BY originalFrameIndex",
                arguments: [receiptId]
            )
        }
    }

    func setHistoricalMaterializationJobStateForTest(
        receiptId: String,
        state: HistoricalMaterializationJobState,
        updatedAt: Int
    ) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE historicalMaterializationJob
                SET state = ?, leaseOwner = NULL, leaseExpiresAt = NULL, updatedAt = ?
                WHERE receiptId = ?
                """, arguments: [state.rawValue, updatedAt, receiptId])
        }
    }

    func assertHistoricalProtectedRawCapacityForTest(incomingBytes: Int, limit: Int) async throws {
        try syncRead { db in
            try WhoopStore.assertHistoricalProtectedRawCapacity(
                incomingBytes: incomingBytes,
                limit: limit,
                in: db
            )
        }
    }
}
