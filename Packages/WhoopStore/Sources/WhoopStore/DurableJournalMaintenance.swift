import Foundation
import GRDB

public struct DurableJournalMaintenanceResult: Equatable, Sendable {
    public var outboxRows = 0
    public var workRows = 0
    public var mutationRows = 0
    public var snapshotRows = 0
    public var receiptRows = 0
}

extension WhoopStore {
    /// Low-priority, referentially-safe maintenance. Invoke only after a drain is
    /// quiescent and never before Today first paint. A persisted last-run marker
    /// should cap this to roughly once per day.
    public func pruneDurablePipelineHistory(
        terminalRetention: TimeInterval = 14 * 86_400,
        receiptRetention: TimeInterval = 30 * 86_400,
        now: Date = Date()
    ) async throws -> DurableJournalMaintenanceResult {
        let terminalCutoff = Int(now.addingTimeInterval(-terminalRetention).timeIntervalSince1970)
        let receiptCutoff = Int(now.addingTimeInterval(-receiptRetention).timeIntervalSince1970)

        return try syncWrite { db in
            var result = DurableJournalMaintenanceResult()

            if try db.tableExists("externalPublicationOutbox") {
                try db.execute(sql: """
                    DELETE FROM externalPublicationOutbox
                    WHERE state IN ('succeeded', 'superseded')
                      AND updatedAt < ?
                      AND leaseOwner IS NULL
                    """, arguments: [terminalCutoff])
                result.outboxRows = db.changesCount

                // Keep only a bounded tail of quarantined diagnostics per context.
                try db.execute(sql: """
                    DELETE FROM externalPublicationOutbox
                    WHERE state = 'quarantined'
                      AND idempotencyKey IN (
                        SELECT idempotencyKey FROM (
                          SELECT idempotencyKey,
                                 ROW_NUMBER() OVER (
                                   PARTITION BY contextId, destination, lastErrorCode
                                   ORDER BY updatedAt DESC
                                 ) AS rn
                          FROM externalPublicationOutbox
                          WHERE state = 'quarantined'
                        ) WHERE rn > 25
                      )
                    """)
                result.outboxRows += db.changesCount
            }

            if try db.tableExists("historicalAnalysisWork") {
                try db.execute(sql: """
                    DELETE FROM historicalAnalysisWork AS w
                    WHERE w.state = 'complete'
                      AND w.updatedAt < ?
                      AND NOT EXISTS (
                        SELECT 1 FROM externalPublicationOutbox o
                        WHERE o.analysisGeneration = w.analysisGeneration
                          AND o.state NOT IN ('succeeded','superseded','quarantined')
                      )
                    """, arguments: [terminalCutoff])
                result.workRows = db.changesCount
            }

            if try db.tableExists("analysisMutationJournal") {
                try db.execute(sql: """
                    DELETE FROM analysisMutationJournal AS m
                    WHERE m.createdAt < ?
                      AND NOT EXISTS (
                        SELECT 1 FROM historicalAnalysisWork w
                        WHERE w.workId = m.workId
                      )
                      AND NOT EXISTS (
                        SELECT 1 FROM verifiedSnapshotCommit s
                        WHERE s.analysisGeneration = m.generation
                      )
                      AND NOT EXISTS (
                        SELECT 1 FROM externalPublicationOutbox o
                        WHERE o.analysisGeneration = m.generation
                      )
                    """, arguments: [terminalCutoff])
                result.mutationRows = db.changesCount
            }

            if try db.tableExists("verifiedSnapshotCommit") {
                try db.execute(sql: """
                    DELETE FROM verifiedSnapshotCommit AS s
                    WHERE s.createdAt < ?
                      AND s.snapshotGeneration < COALESCE((
                        SELECT MAX(latest.snapshotGeneration)
                        FROM verifiedSnapshotCommit latest
                        WHERE latest.contextId = s.contextId
                      ), s.snapshotGeneration)
                      AND NOT EXISTS (
                        SELECT 1 FROM externalPublicationOutbox o
                        WHERE o.contextId = s.contextId
                          AND (o.analysisGeneration = s.analysisGeneration
                            OR o.snapshotGeneration = s.snapshotGeneration)
                      )
                      AND NOT EXISTS (
                        SELECT 1 FROM historicalAnalysisWork w
                        WHERE w.analysisGeneration = s.analysisGeneration
                          AND w.state NOT IN ('complete','quarantined')
                      )
                    """, arguments: [terminalCutoff])
                result.snapshotRows = db.changesCount
            }

            if try db.tableExists("historicalAnalysisWork") {
                try db.execute(sql: """
                    DELETE FROM historicalAnalysisWork
                    WHERE state = 'quarantined' AND workId IN (
                        SELECT workId FROM (
                            SELECT workId,
                                   ROW_NUMBER() OVER (
                                     PARTITION BY databaseInstanceId, deviceId, lastErrorCode
                                     ORDER BY updatedAt DESC
                                   ) AS rn
                            FROM historicalAnalysisWork
                            WHERE state = 'quarantined'
                        ) WHERE rn > 25
                    )
                    """)
                result.workRows += db.changesCount
            }

            if try db.tableExists("historicalMaintenanceWork") {
                try db.execute(sql: """
                    DELETE FROM historicalMaintenanceWork
                    WHERE state = 'complete' AND updatedAt < ?
                      AND leaseOwner IS NULL
                    """, arguments: [terminalCutoff])
                result.workRows += db.changesCount
                try db.execute(sql: """
                    DELETE FROM historicalMaintenanceWork
                    WHERE state = 'quarantined' AND workId IN (
                        SELECT workId FROM (
                            SELECT workId,
                                   ROW_NUMBER() OVER (
                                     PARTITION BY databaseInstanceId, deviceId, lastErrorCode
                                     ORDER BY updatedAt DESC
                                   ) AS rn
                            FROM historicalMaintenanceWork
                            WHERE state = 'quarantined'
                        ) WHERE rn > 25
                    )
                    """)
                result.workRows += db.changesCount
            }

            if try db.tableExists("historicalDataCommitJournal"),
               try db.tableExists("historicalReceiptConsumer") {
                try db.execute(sql: """
                    DELETE FROM historicalDataCommitJournal AS r
                    WHERE r.committedAt < ?
                      AND r.generation <= COALESCE((
                        SELECT MIN(c.throughGeneration)
                        FROM historicalReceiptConsumer c
                        WHERE c.databaseInstanceId = r.databaseInstanceId
                          AND c.deviceId = r.deviceId
                          AND c.lineage = r.lineage
                          AND c.cursorEpoch = r.cursorEpoch
                          AND c.trimScope = r.trimScope
                      ), 0)
                      AND NOT EXISTS (
                        SELECT 1 FROM historicalAnalysisWork w
                        WHERE w.databaseInstanceId = r.databaseInstanceId
                          AND w.deviceId = r.deviceId
                          AND w.lineage = r.lineage
                          AND w.cursorEpoch = r.cursorEpoch
                          AND w.trimScope = r.trimScope
                          AND r.generation BETWEEN
                              w.firstReceiptGeneration AND w.lastReceiptGeneration
                      )
                    """, arguments: [receiptCutoff])
                result.receiptRows = db.changesCount
            }

            return result
        }
    }
}

/*
Operational integration:

- Run after HistoricalPipelineRuntime and ExternalPublicationWorker both report
  no pending ready work.
- Persist last successful maintenance time; skip when <24 h.
- Run at utility priority.
- Add indexes from v48 before enabling maintenance.
- Keep immutable raw health/sample tables completely outside this method.
*/
