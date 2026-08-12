// Add to Packages/WhoopStore/Sources/WhoopStore and register after Phase34DatabaseMigrations.

import Foundation
import GRDB

public enum PR28RootFixMigrations {
    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v44-pr28-durable-state-root-fix") { db in
            try addSnapshotCommitColumns(db)
            try rebuildHistoricalAnalysisWork(db)
            try backfillSnapshotTimeZones(db)
            try rebuildExternalPublicationOutbox(db)
        }

        migrator.registerMigration("v45-pr28-durable-state-root-fix-validation") { db in
            try requireColumns(
                ["resumePhase", "state", "recordedTimeZoneIdentifier"],
                table: "historicalAnalysisWork",
                db: db
            )
            try requireColumns(
                ["recordedTimeZoneIdentifier", "healthKitPayloadJSON"],
                table: "verifiedSnapshotCommit",
                db: db
            )
            try requireColumns(
                ["recordedTimeZoneIdentifier", "destinationPayloadJSON", "state"],
                table: "externalPublicationOutbox",
                db: db
            )
            let workSQL = try tableSQL("historicalAnalysisWork", db: db)
            let outboxSQL = try tableSQL("externalPublicationOutbox", db: db)
            guard workSQL.contains("'blocked'"), workSQL.contains("resumephase"),
                  outboxSQL.contains("'blocked'") else {
                throw PR28RootFixMigrationError.invalidRebuiltSchema
            }
        }
    }

    private static func addSnapshotCommitColumns(_ db: Database) throws {
        let columns = Set(try db.columns(in: "verifiedSnapshotCommit").map(\.name))
        if !columns.contains("recordedTimeZoneIdentifier") {
            try db.alter(table: "verifiedSnapshotCommit") { table in
                table.add(column: "recordedTimeZoneIdentifier", .text)
                    .notNull()
                    .defaults(to: "UTC")
            }
        }
        if !columns.contains("healthKitPayloadJSON") {
            try db.alter(table: "verifiedSnapshotCommit") { table in
                table.add(column: "healthKitPayloadJSON", .blob)
            }
        }
    }

    private static func rebuildHistoricalAnalysisWork(_ db: Database) throws {
        let columns = Set(try db.columns(in: "historicalAnalysisWork").map(\.name))
        let sql = try tableSQL("historicalAnalysisWork", db: db)
        if columns.contains("resumePhase"), sql.contains("'blocked'") { return }

        try db.execute(sql: """
            CREATE TABLE historicalAnalysisWork_v44 (
                workId TEXT PRIMARY KEY NOT NULL,
                databaseInstanceId TEXT NOT NULL,
                sourceId TEXT NOT NULL,
                deviceId TEXT NOT NULL,
                lineage TEXT NOT NULL,
                cursorEpoch INTEGER NOT NULL CHECK (cursorEpoch >= 0),
                trimScope TEXT NOT NULL,
                firstReceiptGeneration INTEGER NOT NULL CHECK (firstReceiptGeneration > 0),
                lastReceiptGeneration INTEGER NOT NULL CHECK (lastReceiptGeneration >= firstReceiptGeneration),
                minimumTs INTEGER,
                maximumTs INTEGER,
                affectedDaysJSON BLOB NOT NULL,
                recordedTimeZoneIdentifier TEXT NOT NULL,
                workKindKey TEXT NOT NULL CHECK (length(workKindKey) > 0),
                workKindJSON BLOB NOT NULL,
                priority INTEGER NOT NULL DEFAULT 0,
                state TEXT NOT NULL CHECK (
                    state IN ('pending','analyzing','verifying','snapshotCommitted',
                              'repositoryPublished','complete','retryable','blocked','quarantined')
                ),
                resumePhase TEXT NOT NULL CHECK (
                    resumePhase IN ('analysis','verification','repositoryPublication','outboxCommit','done')
                ),
                attemptCount INTEGER NOT NULL DEFAULT 0 CHECK (attemptCount >= 0),
                nextAttemptAt INTEGER,
                leaseOwner TEXT,
                leaseExpiresAt INTEGER,
                analyzedThroughReceiptGeneration INTEGER,
                analysisGeneration INTEGER,
                snapshotGeneration INTEGER,
                pendingDestinationsJSON BLOB NOT NULL,
                lastErrorCode TEXT,
                createdAt INTEGER NOT NULL,
                updatedAt INTEGER NOT NULL,
                CHECK (minimumTs IS NULL OR maximumTs IS NULL OR minimumTs <= maximumTs),
                CHECK ((leaseOwner IS NULL) = (leaseExpiresAt IS NULL))
            )
            """)

        // v41 could not persist resumePhase. Infer the safest restart point. A retry after a committed
        // snapshot resumes at repository publication; this may repeat one idempotent cache publication once,
        // but never repeats scoring or skips the outbox.
        try db.execute(sql: """
            INSERT INTO historicalAnalysisWork_v44 (
                workId, databaseInstanceId, sourceId, deviceId, lineage, cursorEpoch, trimScope,
                firstReceiptGeneration, lastReceiptGeneration, minimumTs, maximumTs,
                affectedDaysJSON, recordedTimeZoneIdentifier, workKindKey, workKindJSON,
                priority, state, resumePhase, attemptCount, nextAttemptAt,
                leaseOwner, leaseExpiresAt, analyzedThroughReceiptGeneration, analysisGeneration,
                snapshotGeneration, pendingDestinationsJSON, lastErrorCode, createdAt, updatedAt
            )
            SELECT
                workId, databaseInstanceId, sourceId, deviceId, lineage, cursorEpoch, trimScope,
                firstReceiptGeneration, lastReceiptGeneration, minimumTs, maximumTs,
                affectedDaysJSON, recordedTimeZoneIdentifier, workKindKey, workKindJSON,
                priority, state,
                CASE
                    WHEN state IN ('complete','quarantined') THEN 'done'
                    WHEN state = 'repositoryPublished' THEN 'outboxCommit'
                    WHEN snapshotGeneration IS NOT NULL THEN 'repositoryPublication'
                    WHEN analysisGeneration IS NOT NULL OR state = 'verifying' THEN 'verification'
                    ELSE 'analysis'
                END,
                attemptCount, nextAttemptAt, leaseOwner, leaseExpiresAt,
                analyzedThroughReceiptGeneration, analysisGeneration, snapshotGeneration,
                pendingDestinationsJSON, lastErrorCode, createdAt, updatedAt
            FROM historicalAnalysisWork
            """)
        try db.execute(sql: "DROP TABLE historicalAnalysisWork")
        try db.execute(sql: "ALTER TABLE historicalAnalysisWork_v44 RENAME TO historicalAnalysisWork")
        try db.execute(sql: """
            CREATE INDEX idx_historicalAnalysisWork_ready
            ON historicalAnalysisWork (state, nextAttemptAt, priority, createdAt)
            """)
        try db.execute(sql: """
            CREATE INDEX idx_historicalAnalysisWork_scope_kind_generation
            ON historicalAnalysisWork (
                databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope,
                recordedTimeZoneIdentifier, workKindKey, lastReceiptGeneration
            )
            """)
    }

    private static func backfillSnapshotTimeZones(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE verifiedSnapshotCommit
            SET recordedTimeZoneIdentifier = COALESCE((
                SELECT w.recordedTimeZoneIdentifier
                FROM analysisMutationJournal m
                JOIN historicalAnalysisWork w ON w.workId = m.workId
                WHERE m.generation = verifiedSnapshotCommit.analysisGeneration
                LIMIT 1
            ), recordedTimeZoneIdentifier, 'UTC')
            """)
    }

    private static func rebuildExternalPublicationOutbox(_ db: Database) throws {
        let columns = Set(try db.columns(in: "externalPublicationOutbox").map(\.name))
        let sql = try tableSQL("externalPublicationOutbox", db: db)
        if columns.isSuperset(of: ["recordedTimeZoneIdentifier", "destinationPayloadJSON"]),
           sql.contains("'blocked'") { return }

        try db.execute(sql: """
            CREATE TABLE externalPublicationOutbox_v44 (
                idempotencyKey TEXT PRIMARY KEY NOT NULL,
                contextId TEXT NOT NULL,
                deviceId TEXT NOT NULL,
                snapshotGeneration INTEGER NOT NULL CHECK (snapshotGeneration > 0),
                analysisGeneration INTEGER NOT NULL CHECK (analysisGeneration > 0),
                changedDaysJSON BLOB NOT NULL,
                recordedTimeZoneIdentifier TEXT NOT NULL,
                destinationPayloadJSON BLOB,
                destination TEXT NOT NULL CHECK (
                    destination IN ('widget','liveActivity','healthKit','watch')
                ),
                state TEXT NOT NULL CHECK (
                    state IN ('pending','inFlight','retryable','blocked','succeeded','superseded','quarantined')
                ),
                attemptCount INTEGER NOT NULL DEFAULT 0 CHECK (attemptCount >= 0),
                nextAttemptAt INTEGER,
                leaseOwner TEXT,
                leaseExpiresAt INTEGER,
                lastErrorCode TEXT,
                createdAt INTEGER NOT NULL,
                updatedAt INTEGER NOT NULL,
                FOREIGN KEY (contextId, snapshotGeneration)
                    REFERENCES verifiedHealthProjection(contextId, snapshotGeneration)
                    ON DELETE CASCADE,
                CHECK ((leaseOwner IS NULL) = (leaseExpiresAt IS NULL))
            )
            """)

        let hasZone = columns.contains("recordedTimeZoneIdentifier")
        let hasPayload = columns.contains("destinationPayloadJSON")
        let zoneExpr = hasZone
            ? "o.recordedTimeZoneIdentifier"
            : "COALESCE(c.recordedTimeZoneIdentifier, 'UTC')"
        let payloadExpr = hasPayload ? "o.destinationPayloadJSON" : "NULL"
        try db.execute(sql: """
            INSERT INTO externalPublicationOutbox_v44 (
                idempotencyKey, contextId, deviceId, snapshotGeneration, analysisGeneration,
                changedDaysJSON, recordedTimeZoneIdentifier, destinationPayloadJSON,
                destination, state, attemptCount, nextAttemptAt, leaseOwner, leaseExpiresAt,
                lastErrorCode, createdAt, updatedAt
            )
            SELECT o.idempotencyKey, o.contextId, o.deviceId, o.snapshotGeneration,
                   o.analysisGeneration, o.changedDaysJSON, \(zoneExpr), \(payloadExpr),
                   o.destination,
                   CASE
                       WHEN o.destination = 'healthKit'
                            AND \(payloadExpr) IS NULL
                            AND o.state IN ('pending','inFlight','retryable')
                           THEN 'blocked'
                       ELSE o.state
                   END,
                   o.attemptCount, o.nextAttemptAt, NULL, NULL,
                   CASE
                       WHEN o.destination = 'healthKit'
                            AND \(payloadExpr) IS NULL
                            AND o.state IN ('pending','inFlight','retryable')
                           THEN 'legacy_healthkit_payload_requires_repair'
                       ELSE o.lastErrorCode
                   END,
                   o.createdAt, o.updatedAt
            FROM externalPublicationOutbox o
            LEFT JOIN verifiedSnapshotCommit c
              ON c.contextId = o.contextId
             AND c.analysisGeneration = o.analysisGeneration
            """)
        try db.execute(sql: "DROP TABLE externalPublicationOutbox")
        try db.execute(sql: "ALTER TABLE externalPublicationOutbox_v44 RENAME TO externalPublicationOutbox")
        try db.execute(sql: """
            CREATE INDEX idx_externalPublicationOutbox_ready
            ON externalPublicationOutbox (
                state, nextAttemptAt, destination, snapshotGeneration, analysisGeneration, createdAt
            )
            """)
        try db.execute(sql: """
            CREATE INDEX idx_externalPublicationOutbox_device
            ON externalPublicationOutbox (deviceId, contextId, snapshotGeneration)
            """)
    }

    private static func tableSQL(_ table: String, db: Database) throws -> String {
        (try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ) ?? "").lowercased()
    }

    private static func requireColumns(_ required: Set<String>, table: String, db: Database) throws {
        let actual = Set(try db.columns(in: table).map(\.name))
        guard required.isSubset(of: actual) else {
            throw PR28RootFixMigrationError.invalidRebuiltSchema
        }
    }
}

public enum PR28RootFixMigrationError: Error {
    case invalidRebuiltSchema
}
