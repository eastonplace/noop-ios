import Foundation
import GRDB
import NoopPhase34Core

public enum HistoricalMaintenanceState: String, Codable, Equatable, Sendable {
    case pending
    case running
    case retryable
    case complete
    case quarantined
}

public struct FullHistoryRepairWork: Codable, Equatable, Sendable {
    public let id: UUID
    public let scope: HistoricalAnalysisScope
    public let throughReceiptGeneration: Int64
    public var recordedTimeZoneIdentifier: String
    public let reasons: Set<String>
    public var nextStartDay: CivilDay?
    public var state: HistoricalMaintenanceState
    public var attemptCount: Int
    public var nextAttemptAt: Date?
    public var leaseOwner: String?
    public var leaseExpiresAt: Date?
    public var lastErrorCode: String?
    public let createdAt: Date
    public var updatedAt: Date
}

public enum FullHistoryRepairMaintenanceError: Error, Equatable, Sendable {
    case invalidWork
    case notIdle
    case leaseLost
}

public struct FullHistoryRepairBatchResult: Equatable, Sendable {
    public let changedDays: Set<CivilDay>
    public let hasMore: Bool

    /// The next oldest day to process. Keeping this cursor in the maintenance row makes a crash or
    /// cancellation resume at the same bounded chronological window instead of replaying the first batch.
    public let nextStartDay: CivilDay?

    public init(
        changedDays: Set<CivilDay>,
        hasMore: Bool,
        nextStartDay: CivilDay? = nil
    ) {
        self.changedDays = changedDays
        self.hasMore = hasMore
        self.nextStartDay = nextStartDay
    }
}

/// Low-priority maintenance owner for evidence that cannot be mapped to exact days. It is deliberately
/// separate from the exact current-day pipeline, so a legacy receipt or broad timestamp repair can never
/// widen morning Recovery publication into a 4,000-day launch scan.
public actor FullHistoryRepairMaintenanceCoordinator {
    public struct Dependencies: Sendable {
        public let isIdle: @Sendable () async -> Bool
        public let leaseNext: @Sendable (_ owner: String, _ now: Date) async throws -> FullHistoryRepairWork?
        public let processNextBatch: @Sendable (_ work: FullHistoryRepairWork) async throws -> FullHistoryRepairBatchResult
        public let markProgress: @Sendable (_ work: FullHistoryRepairWork, _ hasMore: Bool, _ now: Date) async throws -> Void
        public let markProgressWithCursor: (@Sendable (
            _ work: FullHistoryRepairWork,
            _ result: FullHistoryRepairBatchResult,
            _ now: Date
        ) async throws -> Void)?
        public let markFailure: @Sendable (_ work: FullHistoryRepairWork, _ error: any Error, _ now: Date) async throws -> Void
        public let releaseLease: @Sendable (_ work: FullHistoryRepairWork, _ now: Date) async throws -> Void
        public let now: @Sendable () -> Date

        public init(
            isIdle: @escaping @Sendable () async -> Bool,
            leaseNext: @escaping @Sendable (String, Date) async throws -> FullHistoryRepairWork?,
            processNextBatch: @escaping @Sendable (FullHistoryRepairWork) async throws -> FullHistoryRepairBatchResult,
            markProgress: @escaping @Sendable (FullHistoryRepairWork, Bool, Date) async throws -> Void,
            markProgressWithCursor: (@Sendable (
                FullHistoryRepairWork,
                FullHistoryRepairBatchResult,
                Date
            ) async throws -> Void)? = nil,
            markFailure: @escaping @Sendable (FullHistoryRepairWork, any Error, Date) async throws -> Void,
            releaseLease: @escaping @Sendable (FullHistoryRepairWork, Date) async throws -> Void = { _, _ in },
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.isIdle = isIdle
            self.leaseNext = leaseNext
            self.processNextBatch = processNextBatch
            self.markProgress = markProgress
            self.markProgressWithCursor = markProgressWithCursor
            self.markFailure = markFailure
            self.releaseLease = releaseLease
            self.now = now
        }
    }

    private let dependencies: Dependencies
    private let owner = UUID().uuidString
    private var task: Task<Void, Never>?
    private var requested = false
    private var suspended = false

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    public func signal() {
        requested = true
        startDrainIfNeeded()
    }

    /// Close admission before a source lifecycle mutation. Signals received while suspended remain pending,
    /// but no repair can read or enqueue work until the transition explicitly resumes this owner.
    public func suspend() {
        suspended = true
        if task != nil { requested = true }
        task?.cancel()
    }

    public func waitForCancellation() async {
        guard let task else { return }
        await task.value
        self.task = nil
    }

    public func suspendAndCancel() async {
        suspend()
        await waitForCancellation()
    }

    public func resume() {
        suspended = false
        startDrainIfNeeded()
    }

    private func startDrainIfNeeded() {
        guard !suspended, requested, task == nil else { return }
        task = Task { [weak self] in await self?.drain() }
    }

    public func cancelAndWait() async {
        guard let task else { return }
        task.cancel()
        await task.value
        self.task = nil
    }

    private func drain() async {
        defer {
            task = nil
            startDrainIfNeeded()
        }
        while requested && !suspended && !Task.isCancelled {
            requested = false
            guard await dependencies.isIdle() else { return }
            var leasedWork: FullHistoryRepairWork?
            do {
                guard let work = try await dependencies.leaseNext(owner, dependencies.now()) else {
                    return
                }
                leasedWork = work
                try Task.checkCancellation()
                let result = try await dependencies.processNextBatch(work)
                try Task.checkCancellation()
                if let markProgressWithCursor = dependencies.markProgressWithCursor {
                    try await markProgressWithCursor(work, result, dependencies.now())
                } else {
                    try await dependencies.markProgress(work, result.hasMore, dependencies.now())
                }
                if result.hasMore { requested = true }
            } catch {
                if let leasedWork {
                    if Task.isCancelled || error is CancellationError {
                        try? await dependencies.releaseLease(leasedWork, dependencies.now())
                    } else {
                        try? await dependencies.markFailure(leasedWork, error, dependencies.now())
                    }
                }
            }
        }
    }
}

extension WhoopStore {
    /// Admit a maintenance-only repair request from an app-level storage heal. The caller supplies the
    /// current scoped receipt fence so this row remains ordered with exact work, while the repair itself
    /// stays in the bounded idle-only maintenance lane.
    public func enqueueFullHistoryRepairMaintenance(
        scope: HistoricalAnalysisScope,
        throughReceiptGeneration: Int64,
        reason: String,
        recordedTimeZoneIdentifier: String,
        now: Date = Date()
    ) async throws {
        try syncWrite { db in
            try Self.upsertFullHistoryRepairMaintenance(
                scope: scope,
                throughReceiptGeneration: throughReceiptGeneration,
                reasons: [reason],
                recordedTimeZoneIdentifier: recordedTimeZoneIdentifier,
                now: now,
                in: db)
        }
    }

    /// Admit broad evidence into the durable maintenance table. The exact-pipeline table never receives
    /// full-history-repair work.
    static func upsertFullHistoryRepairMaintenance(
        scope: HistoricalAnalysisScope,
        throughReceiptGeneration: Int64,
        reasons: Set<String>,
        recordedTimeZoneIdentifier: String = "UTC",
        now: Date,
        in db: Database
    ) throws {
        guard throughReceiptGeneration > 0, !reasons.isEmpty,
              TimeZone(identifier: recordedTimeZoneIdentifier) != nil else {
            throw FullHistoryRepairMaintenanceError.invalidWork
        }
        let lifecycleState: String? = try String.fetchOne(db, sql: """
            SELECT state FROM historicalReceiptScopeLifecycle
            WHERE databaseInstanceId = ? AND deviceId = ? AND lineage = ?
              AND cursorEpoch = ? AND trimScope = ?
            """, arguments: [
                scope.databaseInstanceId, scope.deviceId, scope.deviceLineageId,
                scope.cursorEpoch, scope.trimScope,
            ])
        guard lifecycleState == nil || lifecycleState == HistoricalScopeLifecycleState.open.rawValue else {
            return
        }
        guard let source = try Row.fetchOne(db, sql: """
            SELECT status, historyLineage, historyCursorEpoch
            FROM pairedDevice WHERE id = ?
            """, arguments: [scope.deviceId]) else {
            return
        }
        let status: String = source["status"]
        let lineage: String = source["historyLineage"]
        let cursorEpoch: Int = source["historyCursorEpoch"]
        guard status == DeviceStatus.active.rawValue,
              lineage == scope.deviceLineageId,
              cursorEpoch == scope.cursorEpoch else {
            return
        }
        let payload = try JSONEncoder().encode(reasons)
        let existing = try Row.fetchOne(db, sql: """
            SELECT workId, throughReceiptGeneration, reasonsJSON
            FROM historicalMaintenanceWork
            WHERE databaseInstanceId = ? AND deviceId = ? AND lineage = ?
              AND cursorEpoch = ? AND trimScope = ?
              AND state IN ('pending','retryable') AND leaseOwner IS NULL
            ORDER BY updatedAt DESC LIMIT 1
            """, arguments: [
                scope.databaseInstanceId, scope.deviceId, scope.deviceLineageId,
                scope.cursorEpoch, scope.trimScope,
            ])
        if let existing {
            let workId: String = existing["workId"]
            let oldGeneration: Int64 = existing["throughReceiptGeneration"]
            let oldPayload: Data = existing["reasonsJSON"]
            let oldReasons = (try? JSONDecoder().decode(Set<String>.self, from: oldPayload)) ?? []
            try db.execute(sql: """
                UPDATE historicalMaintenanceWork
                SET throughReceiptGeneration = ?, recordedTimeZoneIdentifier = ?,
                    reasonsJSON = ?, updatedAt = ?
                WHERE workId = ?
                """, arguments: [
                    max(oldGeneration, throughReceiptGeneration),
                    recordedTimeZoneIdentifier,
                    try JSONEncoder().encode(oldReasons.union(reasons)),
                    Int(now.timeIntervalSince1970), workId,
                ])
            return
        }
        try db.execute(sql: """
            INSERT INTO historicalMaintenanceWork (
                workId, databaseInstanceId, sourceId, deviceId, lineage,
                cursorEpoch, trimScope, throughReceiptGeneration, recordedTimeZoneIdentifier, reasonsJSON,
                state, attemptCount, createdAt, updatedAt
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)
            """, arguments: [
                UUID().uuidString, scope.databaseInstanceId, scope.sourceId,
                scope.deviceId, scope.deviceLineageId, scope.cursorEpoch,
                scope.trimScope, throughReceiptGeneration, recordedTimeZoneIdentifier, payload,
                Int(now.timeIntervalSince1970), Int(now.timeIntervalSince1970),
            ])
    }

    /// Terminalize broad repair for a scope that lost presentation authority. Exact receipt work remains
    /// untouched and can still drain through its own verified lifecycle.
    @discardableResult
    static func cancelFullHistoryRepairMaintenance(
        scope: HistoricalCursorScope,
        reason: String,
        now: Date,
        in db: Database
    ) throws -> Int {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.deviceId.isEmpty, !scope.lineage.isEmpty,
              scope.cursorEpoch >= 0, !scope.trimScope.isEmpty,
              !trimmedReason.isEmpty else {
            throw FullHistoryRepairMaintenanceError.invalidWork
        }
        try db.execute(sql: """
            UPDATE historicalMaintenanceWork
            SET state = 'quarantined', nextAttemptAt = NULL,
                leaseOwner = NULL, leaseExpiresAt = NULL,
                lastErrorCode = ?, updatedAt = ?
            WHERE databaseInstanceId = ? AND deviceId = ? AND lineage = ?
              AND cursorEpoch = ? AND trimScope = ?
              AND state NOT IN ('complete','quarantined')
            """, arguments: [
                trimmedReason,
                Int(now.timeIntervalSince1970),
                try WhoopStore.databaseInstanceId(in: db),
                scope.deviceId,
                scope.lineage,
                scope.cursorEpoch,
                scope.trimScope,
            ])
        return db.changesCount
    }

    /// Lease one broad-repair item only after the caller has established the idle/Today-first-paint gate.
    /// Expired leases become retryable in this same transaction, so cancellation never waits for a later
    /// process restart to make the item eligible.
    public func leaseNextFullHistoryRepair(
        owner: String,
        now: Date = Date(),
        leaseDuration: TimeInterval = 90,
        scope: HistoricalCursorScope? = nil
    ) async throws -> FullHistoryRepairWork? {
        guard !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FullHistoryRepairMaintenanceError.invalidWork
        }
        let nowSeconds = Int(now.timeIntervalSince1970)
        let expiry = Int(now.addingTimeInterval(max(15, leaseDuration)).timeIntervalSince1970)
        return try syncWrite { db in
            try db.execute(sql: """
                UPDATE historicalMaintenanceWork
                SET state = 'retryable', leaseOwner = NULL, leaseExpiresAt = NULL,
                    nextAttemptAt = ?, updatedAt = ?
                WHERE state = 'running' AND leaseExpiresAt IS NOT NULL AND leaseExpiresAt <= ?
                """, arguments: [nowSeconds, nowSeconds, nowSeconds])
            let row: Row?
            if let scope {
                row = try Row.fetchOne(db, sql: """
                    SELECT work.* FROM historicalMaintenanceWork AS work
                    JOIN pairedDevice AS source
                      ON source.id = work.deviceId
                     AND source.status = 'active'
                     AND source.historyLineage = work.lineage
                     AND source.historyCursorEpoch = work.cursorEpoch
                    WHERE work.state IN ('pending','retryable')
                      AND (work.nextAttemptAt IS NULL OR work.nextAttemptAt <= ?)
                      AND work.leaseOwner IS NULL
                      AND work.databaseInstanceId = ? AND work.deviceId = ? AND work.lineage = ?
                      AND work.cursorEpoch = ? AND work.trimScope = ?
                    ORDER BY work.nextAttemptAt IS NOT NULL, work.nextAttemptAt ASC, work.updatedAt ASC
                    LIMIT 1
                    """, arguments: [
                        nowSeconds, try WhoopStore.databaseInstanceId(in: db), scope.deviceId,
                        scope.lineage, scope.cursorEpoch, scope.trimScope,
                    ])
            } else {
                row = try Row.fetchOne(db, sql: """
                    SELECT work.* FROM historicalMaintenanceWork AS work
                    JOIN pairedDevice AS source
                      ON source.id = work.deviceId
                     AND source.status = 'active'
                     AND source.historyLineage = work.lineage
                     AND source.historyCursorEpoch = work.cursorEpoch
                    WHERE work.state IN ('pending','retryable')
                      AND (work.nextAttemptAt IS NULL OR work.nextAttemptAt <= ?)
                      AND work.leaseOwner IS NULL
                    ORDER BY work.nextAttemptAt IS NOT NULL, work.nextAttemptAt ASC, work.updatedAt ASC
                    LIMIT 1
                    """, arguments: [nowSeconds])
            }
            guard let row else { return nil }
            let workId: String = row["workId"]
            try db.execute(sql: """
                UPDATE historicalMaintenanceWork
                SET state = 'running', leaseOwner = ?, leaseExpiresAt = ?, updatedAt = ?
                WHERE workId = ? AND state IN ('pending','retryable') AND leaseOwner IS NULL
                """, arguments: [owner, expiry, nowSeconds, workId])
            guard db.changesCount == 1 else { return nil }
            return try Self.decodeFullHistoryRepairWork(row: try Row.fetchOne(
                db, sql: "SELECT * FROM historicalMaintenanceWork WHERE workId = ?", arguments: [workId]
            ))
        }
    }

    /// Complete a bounded chronological batch or return the item to the ready queue without consuming an
    /// attempt. The durable work row remains the single retry/lease authority.
    public func markFullHistoryRepairProgress(
        _ work: FullHistoryRepairWork,
        owner: String,
        hasMore: Bool,
        now: Date = Date()
    ) async throws {
        try await markFullHistoryRepairProgress(
            work,
            owner: owner,
            hasMore: hasMore,
            nextStartDay: nil,
            now: now
        )
    }

    /// Advance the chronological maintenance cursor and release the lease in one durable update.
    public func markFullHistoryRepairProgress(
        _ work: FullHistoryRepairWork,
        owner: String,
        hasMore: Bool,
        nextStartDay: CivilDay?,
        now: Date = Date()
    ) async throws {
        guard !hasMore || nextStartDay != nil else {
            throw FullHistoryRepairMaintenanceError.invalidWork
        }
        let nowSeconds = Int(now.timeIntervalSince1970)
        let state: String = hasMore ? "retryable" : "complete"
        let nextAttempt: Int? = hasMore ? nowSeconds : nil
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE historicalMaintenanceWork
                SET state = ?, nextAttemptAt = ?, nextStartDay = ?,
                    leaseOwner = NULL, leaseExpiresAt = NULL,
                    lastErrorCode = NULL, updatedAt = ?
                WHERE workId = ? AND state = 'running' AND leaseOwner = ?
                """, arguments: [
                    state, nextAttempt, nextStartDay?.key, nowSeconds, work.id.uuidString, owner,
                ])
            guard db.changesCount == 1 else { throw FullHistoryRepairMaintenanceError.leaseLost }
        }
    }

    /// Cancellation is not a failure. It releases the owner immediately, preserves the attempt count, and
    /// makes the item retryable for the next idle signal.
    public func cancelFullHistoryRepairLease(
        _ work: FullHistoryRepairWork,
        owner: String,
        now: Date = Date()
    ) async throws {
        let nowSeconds = Int(now.timeIntervalSince1970)
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE historicalMaintenanceWork
                SET state = 'retryable', nextAttemptAt = NULL, leaseOwner = NULL,
                    leaseExpiresAt = NULL, lastErrorCode = 'owner_cancelled', updatedAt = ?
                WHERE workId = ? AND state = 'running' AND leaseOwner = ?
                """, arguments: [nowSeconds, work.id.uuidString, owner])
            guard db.changesCount == 1 else { throw FullHistoryRepairMaintenanceError.leaseLost }
        }
    }

    /// Apply bounded backoff to a failed batch. The item remains diagnosable after the automatic retry cap.
    public func markFullHistoryRepairFailure(
        _ work: FullHistoryRepairWork,
        owner: String,
        error: any Error,
        now: Date = Date(),
        maximumAttempts: Int = 12
    ) async throws {
        let nowSeconds = Int(now.timeIntervalSince1970)
        let backoff = min(6 * 60 * 60, pow(2.0, Double(min(work.attemptCount, 8))) * 30)
        let nextAttempt = Int(now.addingTimeInterval(backoff).timeIntervalSince1970)
        let state = work.attemptCount + 1 >= max(1, maximumAttempts) ? "quarantined" : "retryable"
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE historicalMaintenanceWork
                SET state = ?, attemptCount = attemptCount + 1,
                    nextAttemptAt = ?, leaseOwner = NULL, leaseExpiresAt = NULL,
                    lastErrorCode = ?, updatedAt = ?
                WHERE workId = ? AND state = 'running' AND leaseOwner = ?
                """, arguments: [state, state == "quarantined" ? nil : nextAttempt,
                                  String(describing: error), nowSeconds, work.id.uuidString, owner])
            guard db.changesCount == 1 else { throw FullHistoryRepairMaintenanceError.leaseLost }
        }
    }

    private static func decodeFullHistoryRepairWork(row: Row?) throws -> FullHistoryRepairWork {
        guard let row,
              let id = UUID(uuidString: row["workId"] as String),
              let state = HistoricalMaintenanceState(rawValue: row["state"] as String) else {
            throw FullHistoryRepairMaintenanceError.invalidWork
        }
        let scope = try HistoricalAnalysisScope(
            databaseInstanceId: row["databaseInstanceId"],
            sourceId: row["sourceId"],
            deviceId: row["deviceId"],
            deviceLineageId: row["lineage"],
            cursorEpoch: row["cursorEpoch"],
            trimScope: row["trimScope"]
        )
        let reasons = (try? JSONDecoder().decode(
            Set<String>.self, from: row["reasonsJSON"] as Data)) ?? []
        guard !reasons.isEmpty else { throw FullHistoryRepairMaintenanceError.invalidWork }
        let createdAt: Int = row["createdAt"]
        let updatedAt: Int = row["updatedAt"]
        let nextAttempt: Int? = row["nextAttemptAt"]
        let leaseOwner: String? = row["leaseOwner"]
        let leaseExpiry: Int? = row["leaseExpiresAt"]
        let nextStartDay: CivilDay?
        if let key = row["nextStartDay"] as String? {
            nextStartDay = try CivilDay(key: key)
        } else {
            nextStartDay = nil
        }
        return FullHistoryRepairWork(
            id: id,
            scope: scope,
            throughReceiptGeneration: row["throughReceiptGeneration"],
            recordedTimeZoneIdentifier: row["recordedTimeZoneIdentifier"],
            reasons: reasons,
            nextStartDay: nextStartDay,
            state: state,
            attemptCount: row["attemptCount"],
            nextAttemptAt: nextAttempt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            leaseOwner: leaseOwner,
            leaseExpiresAt: leaseExpiry.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastErrorCode: row["lastErrorCode"],
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt)))
    }
}

/*
Integration:

- In HistoricalReceiptAdmissionStore, route `.fullHistoryRepair` evidence to
  `upsertFullHistoryRepairMaintenance`; do not insert HistoricalAnalysisWork(kind: .fullHistoryRepair).
- Maintenance `isIdle` requires: Today first paint published, app inactive or explicitly idle, no import,
  no backfill, no active workout, and no current-day exact work.
- Process bounded chronological batches (for example 14–30 days). Publish each changed batch through exact
  Repository publication; never perform one 4,000-day cache hydration.
- Existing unsupported full-history-repair rows from drafts can be migrated into this table.
*/
