// Copy into Packages/WhoopStore/Sources/WhoopStore after adding NoopPhase34Core.
// This creates a monotonic analysis-generation domain. Receipt, analysis, Repository, and snapshot
// generations remain separate and must never be compared numerically across domains.

import Foundation
import GRDB
import NoopPhase34Core

public struct DurableAnalysisMutationRecord: Codable, Equatable, Sendable {
    public let generation: Int64
    public let workId: UUID
    public let scope: HistoricalAnalysisScope
    public let throughReceiptGeneration: Int64
    public let analyzedDays: Set<CivilDay>
    public let rawFrontierTs: Int?
    public let algorithmBundleVersion: String
    public let createdAt: Date

    public init(
        generation: Int64,
        workId: UUID,
        scope: HistoricalAnalysisScope,
        throughReceiptGeneration: Int64,
        analyzedDays: Set<CivilDay>,
        rawFrontierTs: Int?,
        algorithmBundleVersion: String,
        createdAt: Date
    ) throws {
        guard generation > 0,
              throughReceiptGeneration > 0,
              !analyzedDays.isEmpty,
              rawFrontierTs.map({ $0 >= 0 }) ?? true,
              !algorithmBundleVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AnalysisMutationJournalError.invalidRecord
        }
        self.generation = generation
        self.workId = workId
        self.scope = scope
        self.throughReceiptGeneration = throughReceiptGeneration
        self.analyzedDays = analyzedDays
        self.rawFrontierTs = rawFrontierTs
        self.algorithmBundleVersion = algorithmBundleVersion
        self.createdAt = createdAt
    }

    fileprivate func hasSameMutation(
        work: HistoricalAnalysisWork,
        analyzedDays: Set<CivilDay>,
        rawFrontierTs: Int?,
        algorithmBundleVersion: String
    ) -> Bool {
        workId == work.id
            && scope == work.scope
            && throughReceiptGeneration == work.lastReceiptGeneration
            && self.analyzedDays == analyzedDays
            && self.rawFrontierTs == rawFrontierTs
            && self.algorithmBundleVersion == algorithmBundleVersion
    }
}

public enum AnalysisMutationJournalError: Error, Equatable, Sendable {
    case invalidRecord
    case databaseChanged
    case leaseOrScopeChanged
    case conflictingReplay
    case invalidStoredRow
}

extension WhoopStore {
    /// Record the exact persisted scorer result after its score transaction commits. Replaying the same work
    /// edge is idempotent only when every semantic field matches. The returned generation is the sole value
    /// used as `HistoricalWorkEvent.analysisSucceeded.analysisGeneration`.
    public func recordAnalysisMutation(
        work: HistoricalAnalysisWork,
        analyzedDays: Set<CivilDay>,
        rawFrontierTs: Int?,
        algorithmBundleVersion: String,
        now: Date
    ) async throws -> DurableAnalysisMutationRecord {
        guard work.lastReceiptGeneration > 0,
              !analyzedDays.isEmpty,
              work.acceptsAnalyzedDays(analyzedDays),
              rawFrontierTs.map({ $0 >= 0 }) ?? true,
              !algorithmBundleVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              now.timeIntervalSinceReferenceDate.isFinite else {
            throw AnalysisMutationJournalError.invalidRecord
        }

        return try syncWrite { db in
            let currentDatabaseInstanceId = try WhoopStore.databaseInstanceId(in: db)
            guard currentDatabaseInstanceId == work.scope.databaseInstanceId else {
                throw AnalysisMutationJournalError.databaseChanged
            }

            // Score rows are written before this receipt. Re-check the durable execution edge in the same
            // transaction so a worker that crossed a source transition cannot publish an old-lineage mutation.
            // The in-memory `work` value is only a proposal; the current row is authoritative.
            guard let current = try Row.fetchOne(
                db,
                sql: """
                    SELECT state, leaseOwner, leaseExpiresAt, databaseInstanceId, sourceId, deviceId,
                           lineage, cursorEpoch, trimScope, lastReceiptGeneration
                    FROM historicalAnalysisWork
                    WHERE workId = ?
                    LIMIT 1
                    """,
                arguments: [work.id.uuidString]
            ),
            let expectedOwner = work.lease?.owner,
            !expectedOwner.isEmpty else {
                throw AnalysisMutationJournalError.leaseOrScopeChanged
            }
            let currentState: String = current["state"]
            let currentOwner: String? = current["leaseOwner"]
            let currentLeaseExpiry: Int? = current["leaseExpiresAt"]
            let rowDatabaseInstanceId: String = current["databaseInstanceId"]
            let currentSourceId: String = current["sourceId"]
            let currentDeviceId: String = current["deviceId"]
            let currentLineage: String = current["lineage"]
            let currentCursorEpoch: Int = current["cursorEpoch"]
            let currentTrimScope: String = current["trimScope"]
            let currentLastReceiptGeneration: Int64 = current["lastReceiptGeneration"]
            guard !["complete", "quarantined"].contains(currentState),
                  currentOwner == expectedOwner,
                  currentLeaseExpiry.map({ $0 > Int(now.timeIntervalSince1970) }) ?? false,
                  rowDatabaseInstanceId == work.scope.databaseInstanceId,
                  currentSourceId == work.scope.sourceId,
                  currentDeviceId == work.scope.deviceId,
                  currentLineage == work.scope.deviceLineageId,
                  currentCursorEpoch == work.scope.cursorEpoch,
                  currentTrimScope == work.scope.trimScope,
                  currentLastReceiptGeneration == work.lastReceiptGeneration else {
                throw AnalysisMutationJournalError.leaseOrScopeChanged
            }

            if let row = try Row.fetchOne(db, sql: """
                SELECT * FROM analysisMutationJournal
                WHERE workId = ? AND throughReceiptGeneration = ?
                LIMIT 1
                """, arguments: [work.id.uuidString, work.lastReceiptGeneration]) {
                let existing = try Self.decodeAnalysisMutation(row)
                guard existing.hasSameMutation(
                    work: work,
                    analyzedDays: analyzedDays,
                    rawFrontierTs: rawFrontierTs,
                    algorithmBundleVersion: algorithmBundleVersion
                ) else {
                    throw AnalysisMutationJournalError.conflictingReplay
                }
                return existing
            }

            let encodedDays = try JSONEncoder().encode(analyzedDays)
            try db.execute(sql: """
                INSERT INTO analysisMutationJournal (
                    workId, databaseInstanceId, sourceId, deviceId, lineage, cursorEpoch, trimScope,
                    throughReceiptGeneration, analyzedDaysJSON, rawFrontierTs,
                    algorithmBundleVersion, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    work.id.uuidString,
                    work.scope.databaseInstanceId,
                    work.scope.sourceId,
                    work.scope.deviceId,
                    work.scope.deviceLineageId,
                    work.scope.cursorEpoch,
                    work.scope.trimScope,
                    work.lastReceiptGeneration,
                    encodedDays,
                    rawFrontierTs,
                    algorithmBundleVersion,
                    Int(now.timeIntervalSince1970),
                ])
            let generation = db.lastInsertedRowID
            return try DurableAnalysisMutationRecord(
                generation: generation,
                workId: work.id,
                scope: work.scope,
                throughReceiptGeneration: work.lastReceiptGeneration,
                analyzedDays: analyzedDays,
                rawFrontierTs: rawFrontierTs,
                algorithmBundleVersion: algorithmBundleVersion,
                createdAt: now
            )
        }
    }

    public func analysisMutation(
        workId: UUID,
        throughReceiptGeneration: Int64
    ) async throws -> DurableAnalysisMutationRecord? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM analysisMutationJournal
                WHERE workId = ? AND throughReceiptGeneration = ?
                LIMIT 1
                """, arguments: [workId.uuidString, throughReceiptGeneration])
                .map(Self.decodeAnalysisMutation)
        }
    }

    public func deleteAnalysisMutationState(deviceId: String) async throws {
        try syncWrite { db in
            try db.execute(
                sql: "DELETE FROM analysisMutationJournal WHERE deviceId = ?",
                arguments: [deviceId]
            )
        }
    }

    private static func decodeAnalysisMutation(_ row: Row) throws -> DurableAnalysisMutationRecord {
        let workIdString: String = row["workId"]
        guard let workId = UUID(uuidString: workIdString) else {
            throw AnalysisMutationJournalError.invalidStoredRow
        }
        let daysData: Data = row["analyzedDaysJSON"]
        let days: Set<CivilDay>
        do {
            days = try JSONDecoder().decode(Set<CivilDay>.self, from: daysData)
        } catch {
            throw AnalysisMutationJournalError.invalidStoredRow
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
            throw AnalysisMutationJournalError.invalidStoredRow
        }
        do {
            return try DurableAnalysisMutationRecord(
                generation: row["generation"],
                workId: workId,
                scope: scope,
                throughReceiptGeneration: row["throughReceiptGeneration"],
                analyzedDays: days,
                rawFrontierTs: row["rawFrontierTs"],
                algorithmBundleVersion: row["algorithmBundleVersion"],
                createdAt: Date(timeIntervalSince1970: TimeInterval(row["createdAt"] as Int))
            )
        } catch {
            throw AnalysisMutationJournalError.invalidStoredRow
        }
    }
}
