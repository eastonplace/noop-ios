import Foundation
import GRDB

/// PR #29 replay and source-privacy durability. This migration is intentionally
/// separate from v49. Shipped v49 databases must advance without rewriting the
/// recorded v49 migration body.
public enum PR29V50Migrations {
    public static let identifier = "v50-pr29-replay-and-privacy-durability"

    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            try rebuildSourceTransitionJournal(db)
            try createSourcePrivacyCleanupWork(db)
            try rebuildLatestStateDeliveryCheckpoint(db)
            try createDurableMigrationProgress(db)
            try rebuildDurableMaintenanceCadence(db)
            try createIndexes(db)
            try validate(db)
        }
    }

    private static func rebuildSourceTransitionJournal(_ db: Database) throws {
        guard try db.tableExists("sourceTransitionJournal") else {
            throw PR29V50MigrationError.invalidSchema
        }
        let columns = Set(try db.columns(in: "sourceTransitionJournal").map(\.name))
        let required = Set([
            "version", "previousActiveDeviceId", "previousSinkContextId",
            "previousSinkEpoch", "contributorIdsJSON", "transitionScope",
            "cleanupWorkId",
        ])
        if columns.isSuperset(of: required) { return }

        let legacyRows = try Row.fetchAll(db, sql: "SELECT * FROM sourceTransitionJournal")
        try db.execute(sql: "DROP INDEX IF EXISTS idx_sourceTransitionJournal_incomplete")
        try db.execute(sql: "ALTER TABLE sourceTransitionJournal RENAME TO sourceTransitionJournal_v49")
        try createSourceTransitionJournalV50(db)

        let encoder = JSONEncoder()
        for row in legacyRows {
            let sourceDeviceId: String = row["sourceDeviceId"]
            let contributorsJSON = try encoder.encode(Set([sourceDeviceId]))
            // v48/v49 did not persist enough information to prove a global
            // active-projection transition. Preserve the row as target-only.
            try db.execute(sql: """
                INSERT INTO sourceTransitionJournal (
                    transitionId, version, mutationKind, sourceDeviceId,
                    targetDeviceId, previousActiveDeviceId,
                    previousSinkContextId, previousSinkEpoch,
                    contributorIdsJSON, transitionScope, cleanupWorkId,
                    historicalEpoch, externalEpoch, sinkEpoch, stage,
                    commitJSON, lastErrorCode, createdAt, updatedAt
                ) VALUES (?, 1, ?, ?, ?, NULL, NULL, NULL, ?, 'targetOnly',
                          NULL, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    row["transitionId"] as String,
                    row["mutationKind"] as String,
                    sourceDeviceId,
                    row["targetDeviceId"] as String?,
                    contributorsJSON,
                    row["historicalEpoch"] as Int64,
                    row["externalEpoch"] as Int64,
                    row["sinkEpoch"] as Int64,
                    row["stage"] as String,
                    row["commitJSON"] as Data?,
                    row["lastErrorCode"] as String?,
                    row["createdAt"] as Int,
                    row["updatedAt"] as Int,
                ])
        }
        try db.execute(sql: "DROP TABLE sourceTransitionJournal_v49")
    }

    private static func createSourceTransitionJournalV50(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE sourceTransitionJournal (
                transitionId TEXT PRIMARY KEY NOT NULL,
                version INTEGER NOT NULL,
                mutationKind TEXT NOT NULL,
                sourceDeviceId TEXT NOT NULL,
                targetDeviceId TEXT,
                previousActiveDeviceId TEXT,
                previousSinkContextId TEXT,
                previousSinkEpoch INTEGER,
                contributorIdsJSON BLOB NOT NULL,
                transitionScope TEXT NOT NULL,
                cleanupWorkId TEXT,
                historicalEpoch INTEGER,
                externalEpoch INTEGER,
                sinkEpoch INTEGER,
                stage TEXT NOT NULL,
                commitJSON BLOB,
                lastErrorCode TEXT,
                createdAt INTEGER NOT NULL,
                updatedAt INTEGER NOT NULL,
                CHECK (version > 0),
                CHECK (length(transitionId) > 0),
                CHECK (length(sourceDeviceId) > 0),
                CHECK (previousSinkEpoch IS NULL OR previousSinkEpoch >= 0),
                CHECK (transitionScope IN ('targetOnly','activeProjection')),
                CHECK (cleanupWorkId IS NULL OR length(cleanupWorkId) > 0),
                CHECK (stage IN (
                    'planned','prepared','storeCommitted','sinkActivated',
                    'workersResumed','complete','aborted'
                )),
                CHECK (
                    stage IN ('planned','aborted') OR
                    (historicalEpoch > 0 AND externalEpoch > 0 AND sinkEpoch > 0)
                )
            )
            """)
    }

    private static func createSourcePrivacyCleanupWork(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS sourcePrivacyCleanupWork (
                cleanupWorkId TEXT NOT NULL,
                transitionId TEXT NOT NULL,
                sourceDeviceId TEXT NOT NULL,
                category TEXT NOT NULL,
                remainingImportedIdsJSON BLOB NOT NULL,
                remainingComputedIdsJSON BLOB NOT NULL,
                firstDay TEXT NOT NULL,
                throughDay TEXT NOT NULL,
                recordedTimeZoneIdentifier TEXT NOT NULL,
                scanCursorJSON BLOB,
                cleanupCursorJSON BLOB,
                state TEXT NOT NULL,
                attemptCount INTEGER NOT NULL DEFAULT 0,
                nextAttemptAt INTEGER,
                leaseOwner TEXT,
                leaseExpiresAt INTEGER,
                lastErrorCode TEXT,
                createdAt INTEGER NOT NULL,
                updatedAt INTEGER NOT NULL,
                PRIMARY KEY (cleanupWorkId, category),
                UNIQUE (transitionId, category),
                FOREIGN KEY (transitionId)
                    REFERENCES sourceTransitionJournal(transitionId)
                    ON DELETE RESTRICT,
                CHECK (length(cleanupWorkId) > 0),
                CHECK (length(transitionId) > 0),
                CHECK (length(sourceDeviceId) > 0),
                CHECK (length(firstDay) = 10),
                CHECK (length(throughDay) = 10),
                CHECK (firstDay <= throughDay),
                CHECK (length(recordedTimeZoneIdentifier) > 0),
                CHECK (category IN ('vitals','sleep','workouts','heartRate')),
                CHECK (state IN (
                    'pending','running','retryable','complete','quarantined'
                )),
                CHECK (attemptCount >= 0),
                CHECK ((leaseOwner IS NULL) = (leaseExpiresAt IS NULL)),
                CHECK (state != 'running' OR leaseOwner IS NOT NULL),
                CHECK (state NOT IN ('complete','quarantined') OR leaseOwner IS NULL)
            )
            """)
    }

    private static func rebuildLatestStateDeliveryCheckpoint(_ db: Database) throws {
        guard try db.tableExists("latestStateDeliveryCheckpoint") else {
            throw PR29V50MigrationError.invalidSchema
        }
        let columns = Set(try db.columns(in: "latestStateDeliveryCheckpoint").map(\.name))
        if columns.contains("destination") { return }

        try db.execute(sql: "DROP INDEX IF EXISTS idx_latestStateDeliveryCheckpoint_device_generation")
        try db.execute(sql: "ALTER TABLE latestStateDeliveryCheckpoint RENAME TO latestStateDeliveryCheckpoint_v49")
        try db.execute(sql: """
            CREATE TABLE latestStateDeliveryCheckpoint (
                contextId TEXT NOT NULL,
                destination TEXT NOT NULL,
                deviceId TEXT NOT NULL,
                snapshotGeneration INTEGER NOT NULL,
                presentationJSON BLOB NOT NULL,
                widgetCoreJSON BLOB,
                logicalDay TEXT NOT NULL,
                deliveredAt INTEGER NOT NULL,
                PRIMARY KEY (contextId, destination),
                CHECK (length(contextId) > 0),
                CHECK (destination IN ('widget','liveActivity','watch')),
                CHECK (length(deviceId) > 0),
                CHECK (snapshotGeneration > 0),
                CHECK (length(logicalDay) = 10),
                CHECK (destination != 'widget' OR widgetCoreJSON IS NOT NULL)
            )
            """)
        // A v49 row proves only Widget delivery. It is not evidence that Live
        // Activity succeeded. Live Activity therefore starts with no row.
        try db.execute(sql: """
            INSERT INTO latestStateDeliveryCheckpoint (
                contextId, destination, deviceId, snapshotGeneration,
                presentationJSON, widgetCoreJSON, logicalDay, deliveredAt
            )
            SELECT contextId, 'widget', deviceId, snapshotGeneration,
                   presentationJSON, widgetCoreJSON, logicalDay, deliveredAt
            FROM latestStateDeliveryCheckpoint_v49
            """)
        try db.execute(sql: "DROP TABLE latestStateDeliveryCheckpoint_v49")
    }

    private static func createDurableMigrationProgress(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS durableMigrationProgress (
                key TEXT PRIMARY KEY NOT NULL,
                nextOffset INTEGER NOT NULL,
                state TEXT NOT NULL,
                updatedAt INTEGER NOT NULL,
                CHECK (length(key) > 0),
                CHECK (nextOffset >= 0),
                CHECK (state IN ('pending','complete'))
            )
            """)
    }

    private static func rebuildDurableMaintenanceCadence(_ db: Database) throws {
        guard try db.tableExists("durableMaintenanceCadence") else {
            throw PR29V50MigrationError.invalidSchema
        }
        let columns = Set(try db.columns(in: "durableMaintenanceCadence").map(\.name))
        if columns.isSuperset(of: ["leaseOwner", "leaseExpiresAt"]) { return }

        try db.execute(sql: "ALTER TABLE durableMaintenanceCadence RENAME TO durableMaintenanceCadence_v49")
        try db.execute(sql: """
            CREATE TABLE durableMaintenanceCadence (
                key TEXT PRIMARY KEY NOT NULL,
                lastRunAt INTEGER NOT NULL,
                leaseOwner TEXT,
                leaseExpiresAt INTEGER,
                CHECK (length(key) > 0),
                CHECK (lastRunAt >= 0),
                CHECK ((leaseOwner IS NULL) = (leaseExpiresAt IS NULL)),
                CHECK (leaseOwner IS NULL OR length(leaseOwner) > 0),
                CHECK (leaseExpiresAt IS NULL OR leaseExpiresAt >= 0)
            )
            """)
        try db.execute(sql: """
            INSERT INTO durableMaintenanceCadence (
                key, lastRunAt, leaseOwner, leaseExpiresAt
            )
            SELECT key, MAX(lastRunAt, 0), NULL, NULL
            FROM durableMaintenanceCadence_v49
            """)
        try db.execute(sql: "DROP TABLE durableMaintenanceCadence_v49")
    }

    private static func createIndexes(_ db: Database) throws {
        try db.create(
            index: "idx_sourceTransitionJournal_incomplete",
            on: "sourceTransitionJournal",
            columns: ["stage", "updatedAt"],
            options: [.ifNotExists]
        )
        try db.create(
            index: "idx_sourcePrivacyCleanupWork_ready",
            on: "sourcePrivacyCleanupWork",
            columns: ["state", "nextAttemptAt", "leaseExpiresAt", "updatedAt"],
            options: [.ifNotExists]
        )
        try db.create(
            index: "idx_sourcePrivacyCleanupWork_group",
            on: "sourcePrivacyCleanupWork",
            columns: ["cleanupWorkId", "state", "category"],
            options: [.ifNotExists]
        )
        try db.create(
            index: "idx_latestStateDeliveryCheckpoint_device_generation",
            on: "latestStateDeliveryCheckpoint",
            columns: ["deviceId", "destination", "snapshotGeneration"],
            options: [.ifNotExists]
        )
        try db.create(
            index: "idx_durableMaintenanceCadence_lease",
            on: "durableMaintenanceCadence",
            columns: ["leaseExpiresAt", "key"],
            options: [.ifNotExists]
        )
    }

    private static func validate(_ db: Database) throws {
        let transitionColumns = Set(try db.columns(in: "sourceTransitionJournal").map(\.name))
        let cleanupColumns = Set(try db.columns(in: "sourcePrivacyCleanupWork").map(\.name))
        let checkpointColumns = Set(try db.columns(in: "latestStateDeliveryCheckpoint").map(\.name))
        let cadenceColumns = Set(try db.columns(in: "durableMaintenanceCadence").map(\.name))
        guard transitionColumns.isSuperset(of: [
            "version", "previousActiveDeviceId", "previousSinkContextId",
            "previousSinkEpoch", "contributorIdsJSON", "transitionScope",
            "cleanupWorkId",
        ]), cleanupColumns.isSuperset(of: [
            "cleanupWorkId", "transitionId", "sourceDeviceId", "category",
            "remainingImportedIdsJSON", "remainingComputedIdsJSON",
            "firstDay", "throughDay", "recordedTimeZoneIdentifier",
            "scanCursorJSON", "cleanupCursorJSON", "state", "attemptCount",
            "nextAttemptAt", "leaseOwner", "leaseExpiresAt", "lastErrorCode",
        ]), checkpointColumns.contains("destination"),
        cadenceColumns.isSuperset(of: ["leaseOwner", "leaseExpiresAt"]),
        try db.tableExists("durableMigrationProgress"),
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
            throw PR29V50MigrationError.invalidSchema
        }
    }
}

public enum PR29V50MigrationError: Error, Equatable, Sendable {
    case invalidSchema
}
