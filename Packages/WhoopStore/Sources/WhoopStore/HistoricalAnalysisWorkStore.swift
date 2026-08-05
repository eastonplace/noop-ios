// Copy into Packages/WhoopStore/Sources/WhoopStore after adding NoopPhase34Core as a package dependency.
// This replaces HistoricalAnalysisCheckpoint as the durable execution state.

import Foundation
import GRDB
import NoopPhase34Core

public struct HistoricalAnalysisWorkLeaseRequest: Sendable {
    public let owner: String
    public let now: Date
    public let leaseDuration: TimeInterval

    public init(owner: String, now: Date, leaseDuration: TimeInterval = 90) {
        self.owner = owner
        self.now = now
        self.leaseDuration = max(15, leaseDuration)
    }
}

extension WhoopStore {
    @discardableResult
    public func resumeBlockedHistoricalAnalysisWork(now: Date) async throws -> Int {
        try syncWrite { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM historicalAnalysisWork WHERE state = 'blocked' AND leaseOwner IS NULL"
            )
            for row in rows {
                var work = try Self.decodeHistoricalAnalysisWork(row)
                try HistoricalAnalysisWorkReducer.apply(.resumeBlocked, to: &work, now: now)
                try Self.updateHistoricalAnalysisWork(work, priority: row["priority"], in: db)
            }
            return rows.count
        }
    }

    /// Insert a new work item or coalesce it into one unleased pending item with the same source fence.
    /// Running work is immutable: receipts that arrive during analysis become a follow-up item, which the
    /// coordinator will prioritize and execute before declaring the pipeline quiescent.
    public func enqueueHistoricalAnalysisWork(
        _ incoming: HistoricalAnalysisWork,
        priority: Int
    ) async throws -> HistoricalAnalysisWork {
        try syncWrite { db in
            let existingRows = try Row.fetchAll(db, sql: """
                SELECT * FROM historicalAnalysisWork
                WHERE databaseInstanceId = ? AND sourceId = ? AND deviceId = ? AND lineage = ?
                  AND cursorEpoch = ? AND trimScope = ?
                  AND recordedTimeZoneIdentifier = ?
                  AND workKindKey = ?
                  AND state IN ('pending', 'retryable')
                  AND leaseOwner IS NULL
                ORDER BY priority DESC, createdAt ASC
                LIMIT ?
                """, arguments: [
                    incoming.scope.databaseInstanceId,
                    incoming.scope.sourceId,
                    incoming.scope.deviceId,
                    incoming.scope.deviceLineageId,
                    incoming.scope.cursorEpoch,
                    incoming.scope.trimScope,
                    incoming.recordedTimeZoneIdentifier,
                    incoming.kind.storageKey,
                    128,
                ])

            // A deep backlog can already contain several bounded exact-day items for one source fence.
            // Try each compatible candidate. If adding `incoming` would exceed the 64-day cap, leave that
            // item unchanged and create another bounded item instead of throwing and stranding admission.
            for row in existingRows {
                var existing = try Self.decodeHistoricalAnalysisWork(row)
                do {
                    try existing.mergePending(incoming, now: incoming.updatedAt)
                } catch HistoricalWorkError.incompatibleMerge {
                    continue
                }
                let existingPriority: Int = row["priority"]
                try Self.updateHistoricalAnalysisWork(
                    existing,
                    priority: max(priority, existingPriority),
                    in: db
                )
                return existing
            }

            try Self.insertHistoricalAnalysisWork(incoming, priority: priority, in: db)
            return incoming
        }
    }

    /// Atomically recover expired leases, select the highest-priority due work, and lease it to one owner.
    public func leaseNextHistoricalAnalysisWork(
        _ request: HistoricalAnalysisWorkLeaseRequest
    ) async throws -> HistoricalAnalysisWork? {
        try syncWrite { db in
            let nowTs = Int(request.now.timeIntervalSince1970)
            let expiredRows = try Row.fetchAll(db, sql: """
                SELECT * FROM historicalAnalysisWork
                WHERE leaseExpiresAt IS NOT NULL AND leaseExpiresAt <= ?
                  AND state NOT IN ('complete', 'quarantined')
                """, arguments: [nowTs])
            for row in expiredRows {
                var work = try Self.decodeHistoricalAnalysisWork(row)
                try HistoricalAnalysisWorkReducer.apply(.leaseExpired, to: &work, now: request.now)
                let existingPriority: Int = row["priority"]
                try Self.updateHistoricalAnalysisWork(work, priority: existingPriority, in: db)
            }

            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM historicalAnalysisWork
                WHERE state IN ('pending', 'retryable')
                  AND leaseOwner IS NULL
                  AND (nextAttemptAt IS NULL OR nextAttemptAt <= ?)
                ORDER BY priority DESC, lastReceiptGeneration ASC, createdAt ASC
                LIMIT ?
                """, arguments: [nowTs, 1]) else {
                return nil
            }

            var work = try Self.decodeHistoricalAnalysisWork(row)
            let expiry = request.now.addingTimeInterval(request.leaseDuration)
            try HistoricalAnalysisWorkReducer.apply(
                .acquireLease(owner: request.owner, expiresAt: expiry),
                to: &work,
                now: request.now
            )
            let existingPriority: Int = row["priority"]
            try Self.updateHistoricalAnalysisWork(work, priority: existingPriority, in: db)
            return work
        }
    }

    public func applyHistoricalAnalysisWorkEvent(
        workId: UUID,
        event: HistoricalWorkEvent,
        now: Date
    ) async throws -> HistoricalAnalysisWork {
        try syncWrite { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM historicalAnalysisWork WHERE workId = ?",
                arguments: [workId.uuidString]
            ) else {
                throw HistoricalWorkStoreError.missingWork
            }
            var work = try Self.decodeHistoricalAnalysisWork(row)
            try HistoricalAnalysisWorkReducer.apply(event, to: &work, now: now)
            let existingPriority: Int = row["priority"]
            try Self.updateHistoricalAnalysisWork(work, priority: existingPriority, in: db)
            return work
        }
    }

    public func historicalAnalysisWork(workId: UUID) async throws -> HistoricalAnalysisWork? {
        try syncRead { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM historicalAnalysisWork WHERE workId = ?",
                arguments: [workId.uuidString]
            ).map(Self.decodeHistoricalAnalysisWork)
        }
    }

    public func pendingHistoricalAnalysisWorkCount() async throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM historicalAnalysisWork
                WHERE state NOT IN ('complete', 'quarantined')
                """) ?? 0
        }
    }

    static func insertHistoricalAnalysisWork(
        _ work: HistoricalAnalysisWork,
        priority: Int,
        in db: Database
    ) throws {
        let encoder = JSONEncoder()
        let days = try encoder.encode(work.affectedDays)
        let destinations = try encoder.encode(work.pendingDestinations)
        let kind = try encoder.encode(work.kind)
        try db.execute(sql: """
            INSERT INTO historicalAnalysisWork (
                workId, databaseInstanceId, sourceId, deviceId, lineage, cursorEpoch, trimScope,
                firstReceiptGeneration, lastReceiptGeneration, minimumTs, maximumTs,
                affectedDaysJSON, recordedTimeZoneIdentifier, workKindKey, workKindJSON,
                priority, state, resumePhase, attemptCount, nextAttemptAt,
                leaseOwner, leaseExpiresAt, analyzedThroughReceiptGeneration, analysisGeneration, snapshotGeneration,
                pendingDestinationsJSON, lastErrorCode, createdAt, updatedAt
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: Self.workArguments(
                work,
                priority: priority,
                affectedDaysJSON: days,
                workKindJSON: kind,
                destinationsJSON: destinations
            ))
    }

    static func updateHistoricalAnalysisWork(
        _ work: HistoricalAnalysisWork,
        priority: Int,
        in db: Database
    ) throws {
        let encoder = JSONEncoder()
        let days = try encoder.encode(work.affectedDays)
        let destinations = try encoder.encode(work.pendingDestinations)
        try db.execute(sql: """
            UPDATE historicalAnalysisWork SET
                firstReceiptGeneration = ?, lastReceiptGeneration = ?, minimumTs = ?, maximumTs = ?,
                affectedDaysJSON = ?, priority = ?, state = ?, resumePhase = ?, attemptCount = ?, nextAttemptAt = ?,
                leaseOwner = ?, leaseExpiresAt = ?, analyzedThroughReceiptGeneration = ?, analysisGeneration = ?, snapshotGeneration = ?,
                pendingDestinationsJSON = ?, lastErrorCode = ?, updatedAt = ?
            WHERE workId = ?
            """, arguments: [
                work.firstReceiptGeneration,
                work.lastReceiptGeneration,
                work.minimumTs,
                work.maximumTs,
                days,
                priority,
                work.state.rawValue,
                work.resumePhase.rawValue,
                work.attemptCount,
                work.nextAttemptAt.map { Int($0.timeIntervalSince1970) },
                work.lease?.owner,
                work.lease.map { Int($0.expiresAt.timeIntervalSince1970) },
                work.analyzedThroughReceiptGeneration,
                work.analysisGeneration,
                work.snapshotGeneration,
                destinations,
                work.lastErrorCode,
                Int(work.updatedAt.timeIntervalSince1970),
                work.id.uuidString,
            ])
        guard db.changesCount == 1 else { throw HistoricalWorkStoreError.missingWork }
    }

    static func workArguments(
        _ work: HistoricalAnalysisWork,
        priority: Int,
        affectedDaysJSON: Data,
        workKindJSON: Data,
        destinationsJSON: Data
    ) -> StatementArguments {
        [
            work.id.uuidString,
            work.scope.databaseInstanceId,
            work.scope.sourceId,
            work.scope.deviceId,
            work.scope.deviceLineageId,
            work.scope.cursorEpoch,
            work.scope.trimScope,
            work.firstReceiptGeneration,
            work.lastReceiptGeneration,
            work.minimumTs,
            work.maximumTs,
            affectedDaysJSON,
            work.recordedTimeZoneIdentifier,
            work.kind.storageKey,
            workKindJSON,
            priority,
            work.state.rawValue,
            work.resumePhase.rawValue,
            work.attemptCount,
            work.nextAttemptAt.map { Int($0.timeIntervalSince1970) },
            work.lease?.owner,
            work.lease.map { Int($0.expiresAt.timeIntervalSince1970) },
            work.analyzedThroughReceiptGeneration,
            work.analysisGeneration,
            work.snapshotGeneration,
            destinationsJSON,
            work.lastErrorCode,
            Int(work.createdAt.timeIntervalSince1970),
            Int(work.updatedAt.timeIntervalSince1970),
        ]
    }

    static func decodeHistoricalAnalysisWork(_ row: Row) throws -> HistoricalAnalysisWork {
        let decoder = JSONDecoder()
        let daysData: Data = row["affectedDaysJSON"]
        let destinationData: Data = row["pendingDestinationsJSON"]
        let days: Set<CivilDay>
        let destinations: Set<DownstreamDestination>
        let kind: HistoricalAnalysisWorkKind
        do {
            days = try decoder.decode(Set<CivilDay>.self, from: daysData)
            destinations = try decoder.decode(Set<DownstreamDestination>.self, from: destinationData)
            let kindData: Data = row["workKindJSON"]
            kind = try decoder.decode(HistoricalAnalysisWorkKind.self, from: kindData)
        } catch {
            throw HistoricalWorkStoreError.invalidRow
        }

        let storedKindKey: String = row["workKindKey"]
        guard storedKindKey == kind.storageKey else {
            throw HistoricalWorkStoreError.invalidRow
        }

        let scope: HistoricalAnalysisScope
        do {
            scope = try HistoricalAnalysisScope(
                databaseInstanceId: row["databaseInstanceId"],
                sourceId: row["sourceId"],
                deviceId: row["deviceId"],
                deviceLineageId: row["lineage"],
                cursorEpoch: row["cursorEpoch"],
                trimScope: row["trimScope"]
            )
        } catch {
            throw HistoricalWorkStoreError.invalidRow
        }

        let workIdString: String = row["workId"]
        guard let workId = UUID(uuidString: workIdString),
              let state = HistoricalAnalysisWorkState(rawValue: row["state"]),
              let resumePhase = HistoricalPipelineResumePhase(rawValue: row["resumePhase"]) else {
            throw HistoricalWorkStoreError.invalidRow
        }

        let createdAt = Date(timeIntervalSince1970: TimeInterval(row["createdAt"] as Int))
        let updatedAt = Date(timeIntervalSince1970: TimeInterval(row["updatedAt"] as Int))
        let attemptCount: Int = row["attemptCount"]
        let nextAttemptAt = (row["nextAttemptAt"] as Int?).map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        let leaseOwner: String? = row["leaseOwner"]
        let leaseExpiryRaw: Int? = row["leaseExpiresAt"]
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              attemptCount >= 0,
              nextAttemptAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              (leaseOwner == nil) == (leaseExpiryRaw == nil) else {
            throw HistoricalWorkStoreError.invalidRow
        }

        var work: HistoricalAnalysisWork
        do {
            work = try HistoricalAnalysisWork(
                id: workId,
                scope: scope,
                firstReceiptGeneration: row["firstReceiptGeneration"],
                lastReceiptGeneration: row["lastReceiptGeneration"],
                minimumTs: row["minimumTs"],
                maximumTs: row["maximumTs"],
                affectedDays: days,
                kind: kind,
                recordedTimeZoneIdentifier: row["recordedTimeZoneIdentifier"],
                createdAt: createdAt
            )
        } catch {
            throw HistoricalWorkStoreError.invalidRow
        }

        work.state = state
        work.resumePhase = resumePhase
        work.attemptCount = attemptCount
        work.nextAttemptAt = nextAttemptAt
        if let owner = leaseOwner, let expiryRaw = leaseExpiryRaw {
            do {
                work.lease = try HistoricalWorkLease(
                    owner: owner,
                    expiresAt: Date(timeIntervalSince1970: TimeInterval(expiryRaw))
                )
            } catch {
                throw HistoricalWorkStoreError.invalidRow
            }
        }
        work.analyzedThroughReceiptGeneration = row["analyzedThroughReceiptGeneration"]
        work.analysisGeneration = row["analysisGeneration"]
        work.snapshotGeneration = row["snapshotGeneration"]
        work.pendingDestinations = destinations
        work.lastErrorCode = row["lastErrorCode"]
        work.updatedAt = updatedAt

        let runningStates: Set<HistoricalAnalysisWorkState> = [
            .analyzing, .verifying, .snapshotCommitted, .repositoryPublished,
        ]
        let terminalStates: Set<HistoricalAnalysisWorkState> = [.complete, .quarantined]
        guard (!runningStates.contains(state) || work.lease != nil),
              (!terminalStates.contains(state) || work.lease == nil) else {
            throw HistoricalWorkStoreError.invalidRow
        }
        if state == .verifying {
            guard work.analyzedThroughReceiptGeneration == work.lastReceiptGeneration,
                  work.analysisGeneration.map({ $0 > 0 }) == true else {
                throw HistoricalWorkStoreError.invalidRow
            }
        }
        if [.snapshotCommitted, .repositoryPublished, .complete].contains(state) {
            guard work.analyzedThroughReceiptGeneration == work.lastReceiptGeneration,
                  work.analysisGeneration.map({ $0 > 0 }) == true,
                  work.snapshotGeneration.map({ $0 > 0 }) == true else {
                throw HistoricalWorkStoreError.invalidRow
            }
        }
        return work
    }

}

public enum HistoricalWorkStoreError: Error {
    case missingWork
    case invalidRow
}
