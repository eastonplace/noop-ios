import Foundation
import GRDB
import WhoopProtocol

public enum HistoricalRawMaterializationPolicy {
    /// A separate fail-closed ceiling for raw bytes awaiting successful materialization. When reached,
    /// the commit fails before its receipt/cursor/ACK, so the strap remains the source of truth.
    public static let maxProtectedBytes = 64 * 1_024 * 1_024
    public static let maxCompletedBytes = 64 * 1_024 * 1_024
    public static let completedRetentionSeconds = 30 * 86_400
    public static let defaultJobLimit = 4
    public static let leaseSeconds = 5 * 60
    public static let maxAttempts = 5
    public static let baseRetrySeconds = 30
    public static let maxRetrySeconds = 60 * 60

    static func retryDelay(attempt: Int) -> Int {
        let exponent = min(max(0, attempt - 1), 16)
        return min(maxRetrySeconds, baseRetrySeconds * (1 << exponent))
    }
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
    let databaseInstanceId: String
    let rawBatchId: String
    let deviceId: String
    let lineage: String
    let cursorEpoch: Int
    let trimScope: String
    let selectionMode: String
    let originalFrameIndexes: [Int]
    let attemptCount: Int
    let leaseOwner: String
}

private struct HistoricalMaterializedFrame: Sendable {
    let originalFrameIndex: Int
    let rawFrameOffset: Int
    let version: Int
    let unix: Int
    let exactFrame: Data
}

private enum HistoricalMaterializationError: Error, Equatable, Sendable {
    case invalidIndexes
    case missingRawBatch
    case invalidEnvelope
    case unsupportedLayout

    var code: String {
        switch self {
        case .invalidIndexes: return "invalidIndexes"
        case .missingRawBatch: return "missingRawBatch"
        case .invalidEnvelope: return "invalidEnvelope"
        case .unsupportedLayout: return "unsupportedLayout"
        }
    }
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
        databaseInstanceId: String,
        trimScope: String,
        selectionMode: String,
        rawMeta: RawBatchMeta,
        trustedMappedProgressRange: ClosedRange<Int>?,
        originalFrameIndexes: [Int],
        createdAt: Int,
        in db: Database
    ) throws {
        let encodedIndexes = try JSONEncoder().encode(originalFrameIndexes)
        try db.execute(sql: """
            INSERT INTO historicalMaterializationJob
                (receiptId, databaseInstanceId, rawBatchId, deviceId, lineage, cursorEpoch,
                 trimScope, selectionMode, state, originalFrameIndexesJSON,
                 protectedByteCount, mappedRawMinTs, mappedRawMaxTs, attemptCount,
                 createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, 0, ?, ?)
            """, arguments: [
                receiptId, databaseInstanceId, rawMeta.batchId, rawMeta.deviceId,
                rawMeta.lineage, rawMeta.cursorEpoch, trimScope, selectionMode, encodedIndexes,
                rawMeta.byteSize, trustedMappedProgressRange?.lowerBound,
                trustedMappedProgressRange?.upperBound, createdAt, createdAt,
            ])
    }

    public func isHistoricalMaterializationDue(
        receiptId: String,
        now: Int = Int(Date().timeIntervalSince1970)
    ) async throws -> Bool {
        try syncRead { db in
            (try Int.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM historicalMaterializationJob
                    WHERE receiptId = ?
                      AND (state = 'pending'
                        OR (state = 'retryable' AND COALESCE(nextAttemptAt, 0) <= ?)
                        OR (state = 'running' AND COALESCE(leaseExpiresAt, 0) <= ?))
                )
                """, arguments: [receiptId, now, now]) ?? 0) == 1
        }
    }

    public func nextHistoricalMaterializationAttemptAt() async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT MIN(nextAttemptAt) FROM historicalMaterializationJob
                WHERE state = 'retryable' AND nextAttemptAt IS NOT NULL
                """)
        }
    }

    public func latestHistoricalDurableFrontier(
        databaseInstanceId: String,
        scope: HistoricalCursorScope
    ) async throws -> HistoricalDurableFrontier {
        try syncRead { db in
            guard try WhoopStore.databaseInstanceId(in: db) == databaseInstanceId else {
                return HistoricalDurableFrontier(normalizedMaxTs: nil, mappedRawMaxTs: nil)
            }
            let normalized = try Int.fetchOne(db, sql: """
                SELECT MAX(maxDecodedTs) FROM historicalDataCommitJournal
                WHERE databaseInstanceId = ? AND deviceId = ? AND lineage = ?
                  AND cursorEpoch = ? AND trimScope = ?
                """, arguments: [databaseInstanceId, scope.deviceId, scope.lineage,
                    scope.cursorEpoch, scope.trimScope])
            let mapped = try Int.fetchOne(db, sql: """
                SELECT MAX(mappedRawMaxTs) FROM historicalMaterializationJob
                WHERE databaseInstanceId = ? AND deviceId = ? AND lineage = ?
                  AND cursorEpoch = ? AND trimScope = ?
                  AND state IN ('pending', 'running', 'retryable', 'completed')
                """, arguments: [databaseInstanceId, scope.deviceId, scope.lineage,
                    scope.cursorEpoch, scope.trimScope])
            return HistoricalDurableFrontier(normalizedMaxTs: normalized, mappedRawMaxTs: mapped)
        }
    }

    /// The newest timestamp that has crossed the durable receipt boundary. Mapped-raw timestamps are
    /// independent of normalized HR so V20/V21-only history can advance a continuation decision.
    public func latestHistoricalDurableFrontier(deviceId: String) async throws -> HistoricalDurableFrontier {
        try syncRead { db in
            let databaseInstanceId = try WhoopStore.databaseInstanceId(in: db)
            let scope = try WhoopStore.historicalCursorScope(
                deviceId: deviceId,
                trimScope: HistoricalCursorScope.defaultTrimScope,
                in: db
            )
            let normalized = try Int.fetchOne(
                db,
                sql: """
                    SELECT MAX(maxDecodedTs)
                    FROM historicalDataCommitJournal
                    WHERE databaseInstanceId = ? AND deviceId = ? AND lineage = ?
                      AND cursorEpoch = ? AND trimScope = ?
                    """,
                arguments: [
                    databaseInstanceId, scope.deviceId, scope.lineage,
                    scope.cursorEpoch, scope.trimScope,
                ]
            )
            let mapped = try Int.fetchOne(db, sql: """
                SELECT MAX(mappedRawMaxTs)
                FROM historicalMaterializationJob
                WHERE databaseInstanceId = ? AND deviceId = ? AND lineage = ?
                  AND cursorEpoch = ? AND trimScope = ?
                  AND state IN ('pending', 'running', 'retryable', 'completed')
                """, arguments: [
                    databaseInstanceId, scope.deviceId, scope.lineage,
                    scope.cursorEpoch, scope.trimScope,
                ])
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
                SELECT receiptId, databaseInstanceId, rawBatchId, deviceId, lineage, cursorEpoch,
                       trimScope, selectionMode, originalFrameIndexesJSON, attemptCount
                FROM historicalMaterializationJob
                WHERE state = 'pending'
                   OR (state = 'retryable' AND COALESCE(nextAttemptAt, 0) <= ?)
                   OR (state = 'running' AND COALESCE(leaseExpiresAt, 0) <= ?)
                -- New pending work must not sit behind an older retryable job that keeps failing.
                -- Each external wake may retry old work, but it always claims pending receipts first.
                ORDER BY CASE WHEN state = 'pending' THEN 0 ELSE 1 END, createdAt, receiptId
                LIMIT ?
                """, arguments: [now, now, limit])
            var output: [HistoricalMaterializationClaim] = []
            output.reserveCapacity(rows.count)
            for row in rows {
                let receiptId: String = row["receiptId"]
                let data: Data = row["originalFrameIndexesJSON"]
                guard let indexes = try? JSONDecoder().decode([Int].self, from: data),
                      !indexes.isEmpty,
                      Set(indexes).count == indexes.count,
                      indexes.allSatisfy({ $0 >= 0 }),
                      zip(indexes, indexes.dropFirst()).allSatisfy(<) else {
                    try db.execute(sql: """
                        UPDATE historicalMaterializationJob
                        SET state = 'quarantined', nextAttemptAt = NULL,
                            leaseOwner = NULL, leaseExpiresAt = NULL,
                            lastErrorCode = 'invalidIndexes',
                            lastError = 'invalidIndexes', updatedAt = ?
                        WHERE receiptId = ? AND state IN ('pending', 'retryable', 'running')
                        """, arguments: [now, receiptId])
                    continue
                }
                try db.execute(sql: """
                    UPDATE historicalMaterializationJob
                    SET state = 'running', leaseOwner = ?, leaseExpiresAt = ?,
                        nextAttemptAt = NULL, attemptCount = attemptCount + 1,
                        updatedAt = ?, lastErrorCode = NULL, lastError = NULL
                    WHERE receiptId = ?
                      AND (state = 'pending'
                        OR (state = 'retryable' AND COALESCE(nextAttemptAt, 0) <= ?)
                        OR (state = 'running' AND COALESCE(leaseExpiresAt, 0) <= ?))
                    """, arguments: [
                        leaseOwner, now + HistoricalRawMaterializationPolicy.leaseSeconds, now,
                        receiptId, now, now,
                    ])
                guard db.changesCount == 1 else { continue }
                let previousAttempt: Int = row["attemptCount"]
                output.append(HistoricalMaterializationClaim(
                    receiptId: receiptId,
                    databaseInstanceId: row["databaseInstanceId"],
                    rawBatchId: row["rawBatchId"],
                    deviceId: row["deviceId"],
                    lineage: row["lineage"],
                    cursorEpoch: row["cursorEpoch"],
                    trimScope: row["trimScope"],
                    selectionMode: row["selectionMode"],
                    originalFrameIndexes: indexes,
                    attemptCount: previousAttempt + 1,
                    leaseOwner: leaseOwner
                ))
                // Lease only one job at a time. This keeps a later claim from expiring while CPU and
                // SQLite work for an earlier claim are still in progress.
                break
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
                        originalFrameIndexes: claim.originalFrameIndexes,
                        selectionMode: claim.selectionMode
                    )
                }.value
                let didComplete = try syncWrite { db -> Bool in
                    guard try String.fetchOne(
                        db,
                        sql: "SELECT leaseOwner FROM historicalMaterializationJob WHERE receiptId = ? AND state = 'running'",
                        arguments: [claim.receiptId]
                    ) == claim.leaseOwner else { return false }
                    for frame in materialized {
                        try db.execute(sql: """
                            INSERT INTO historicalMappedRawFrame
                                (receiptId, databaseInstanceId, rawBatchId, deviceId, lineage,
                                 cursorEpoch, trimScope, originalFrameIndex, rawFrameOffset,
                                 version, unix, exactByteCount, materializedAt)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(receiptId, originalFrameIndex) DO UPDATE SET
                                databaseInstanceId = excluded.databaseInstanceId,
                                rawBatchId = excluded.rawBatchId,
                                deviceId = excluded.deviceId,
                                lineage = excluded.lineage,
                                cursorEpoch = excluded.cursorEpoch,
                                trimScope = excluded.trimScope,
                                rawFrameOffset = excluded.rawFrameOffset,
                                version = excluded.version,
                                unix = excluded.unix,
                                exactByteCount = excluded.exactByteCount,
                                materializedAt = excluded.materializedAt
                            """, arguments: [
                                claim.receiptId, claim.databaseInstanceId, claim.rawBatchId,
                                claim.deviceId, claim.lineage, claim.cursorEpoch, claim.trimScope,
                                frame.originalFrameIndex, frame.rawFrameOffset, frame.version,
                                frame.unix, frame.exactFrame.count, now,
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
                        SET state = 'completed', nextAttemptAt = NULL,
                            leaseOwner = NULL, leaseExpiresAt = NULL,
                            updatedAt = ?, completedAt = ?, lastErrorCode = NULL, lastError = NULL
                        WHERE receiptId = ? AND leaseOwner = ? AND state = 'running'
                        """, arguments: [now, now, claim.receiptId, claim.leaseOwner])
                    return db.changesCount == 1
                }
                if didComplete { completed += 1 }
            } catch let error as HistoricalMaterializationError {
                try markHistoricalMaterializationFailure(
                    claim: claim,
                    state: .quarantined,
                    errorCode: error.code,
                    error: String(describing: error),
                    now: now
                )
                quarantined += 1
            } catch {
                let terminal = claim.attemptCount >= HistoricalRawMaterializationPolicy.maxAttempts
                try markHistoricalMaterializationFailure(
                    claim: claim,
                    state: terminal ? .quarantined : .retryable,
                    errorCode: terminal ? "maxAttemptsExceeded" : "transientFailure",
                    error: String(describing: error),
                    now: now
                )
                if terminal { quarantined += 1 } else { retryable += 1 }
            }
        }
        try pruneCompletedHistoricalRaw(now: now)
        return HistoricalMaterializationRunSummary(
            claimed: claims.count,
            completed: completed,
            retryable: retryable,
            quarantined: quarantined
        )
    }

    private static func materializeHistoricalFrames(
        _ frames: [[UInt8]],
        originalFrameIndexes: [Int],
        selectionMode: String
    ) throws -> [HistoricalMaterializedFrame] {
        guard frames.count == originalFrameIndexes.count,
              Set(originalFrameIndexes).count == originalFrameIndexes.count,
              zip(originalFrameIndexes, originalFrameIndexes.dropFirst()).allSatisfy(<) else {
            throw HistoricalMaterializationError.invalidIndexes
        }
        let mapped = try zip(originalFrameIndexes, frames).enumerated().compactMap {
            rawFrameOffset, pair
            -> HistoricalMaterializedFrame? in
            let (originalIndex, frame) = pair
            let isMappedCandidate = frame.count > 9
                && frame[8] == 0x2F
                && (frame[9] == 20 || frame[9] == 21)
            if selectionMode == "legacyFullCapture", !isMappedCandidate {
                return nil
            }
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
                rawFrameOffset: rawFrameOffset,
                version: version,
                unix: unix,
                exactFrame: Data(frame)
            )
        }
        guard !mapped.isEmpty else { throw HistoricalMaterializationError.unsupportedLayout }
        if selectionMode == "selectiveMapped", mapped.count != frames.count {
            throw HistoricalMaterializationError.unsupportedLayout
        }
        return mapped
    }

    /// Keep completed exact raw representations for a bounded time and byte budget. Eviction only
    /// removes the derived mapping; `pruneRaw` deletes the compressed raw batch in its normal pass.
    private func pruneCompletedHistoricalRaw(
        now: Int,
        retentionSeconds: Int = HistoricalRawMaterializationPolicy.completedRetentionSeconds,
        maxBytes: Int = HistoricalRawMaterializationPolicy.maxCompletedBytes
    ) throws {
        try syncWrite { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT receiptId, protectedByteCount, completedAt
                FROM historicalMaterializationJob
                WHERE state = 'completed' AND evictedAt IS NULL
                ORDER BY completedAt DESC, receiptId DESC
                """)
            let cutoff = now - max(0, retentionSeconds)
            var retainedBytes = 0
            var evict: [String] = []
            for row in rows {
                let receiptId: String = row["receiptId"]
                let bytes: Int = row["protectedByteCount"]
                let completedAt: Int = row["completedAt"]
                let (nextBytes, overflow) = retainedBytes.addingReportingOverflow(bytes)
                if completedAt < cutoff || overflow || nextBytes > max(0, maxBytes) {
                    evict.append(receiptId)
                } else {
                    retainedBytes = nextBytes
                }
            }
            for receiptId in evict {
                try db.execute(
                    sql: "DELETE FROM historicalMappedRawFrame WHERE receiptId = ?",
                    arguments: [receiptId]
                )
                try db.execute(sql: """
                    UPDATE historicalMaterializationJob
                    SET evictedAt = ?, updatedAt = ?
                    WHERE receiptId = ? AND state = 'completed' AND evictedAt IS NULL
                    """, arguments: [now, now, receiptId])
            }
        }
    }

    private func markHistoricalMaterializationFailure(
        claim: HistoricalMaterializationClaim,
        state: HistoricalMaterializationJobState,
        errorCode: String,
        error: String,
        now: Int
    ) throws {
        let boundedError = String(error.prefix(512))
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE historicalMaterializationJob
                SET state = ?, nextAttemptAt = ?, leaseOwner = NULL, leaseExpiresAt = NULL,
                    updatedAt = ?, lastErrorCode = ?, lastError = ?
                WHERE receiptId = ? AND leaseOwner = ? AND state = 'running'
                """, arguments: [
                    state.rawValue,
                    state == .retryable
                        ? now + HistoricalRawMaterializationPolicy.retryDelay(attempt: claim.attemptCount)
                        : nil,
                    now, errorCode, boundedError, claim.receiptId, claim.leaseOwner,
                ])
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
        let rows: [Row] = try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT rawBatchId, deviceId, lineage, cursorEpoch, rawFrameOffset
                FROM historicalMappedRawFrame
                WHERE receiptId = ?
                ORDER BY originalFrameIndex
                """, arguments: [receiptId])
        }
        guard let first = rows.first else { return [] }
        let batchId: String = first["rawBatchId"]
        let deviceId: String = first["deviceId"]
        let lineage: String = first["lineage"]
        let cursorEpoch: Int = first["cursorEpoch"]
        let frames = try await rawFrames(
            batchId: batchId,
            deviceId: deviceId,
            lineage: lineage,
            cursorEpoch: cursorEpoch
        )
        return try rows.map { row in
            let offset: Int = row["rawFrameOffset"]
            guard frames.indices.contains(offset) else {
                throw HistoricalMaterializationError.invalidIndexes
            }
            return Data(frames[offset])
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
                SET state = ?, nextAttemptAt = NULL,
                    leaseOwner = NULL, leaseExpiresAt = NULL, updatedAt = ?
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

    func pruneCompletedHistoricalRawForTest(now: Int, retentionSeconds: Int, maxBytes: Int) throws {
        try pruneCompletedHistoricalRaw(
            now: now,
            retentionSeconds: retentionSeconds,
            maxBytes: maxBytes
        )
    }
}
