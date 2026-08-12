import Foundation
import GRDB

/// Forward-only repair for databases that recorded the evolving v50 migration
/// before its maintenance-lease columns existed. It also adds bounded recovery
/// metadata without changing the shipped v50 migration body.
public enum PR29V51Migrations {
    public static let identifier = "v51-pr29-bounded-recovery"

    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            try repairDurableMaintenanceCadence(db)
            try extendSourcePrivacyCleanupWork(db)
            try createIncompleteVerifiedArtifactRepairScan(db)
            try createIndexes(db)
            try validate(db)
        }
    }

    private static func repairDurableMaintenanceCadence(_ db: Database) throws {
        guard try db.tableExists("durableMaintenanceCadence") else {
            throw PR29V51MigrationError.invalidSchema
        }
        var columns = Set(try db.columns(in: "durableMaintenanceCadence").map(\.name))
        if !columns.contains("leaseOwner") {
            try db.execute(sql: """
                ALTER TABLE durableMaintenanceCadence
                ADD COLUMN leaseOwner TEXT
                """)
            columns.insert("leaseOwner")
        }
        if !columns.contains("leaseExpiresAt") {
            try db.execute(sql: """
                ALTER TABLE durableMaintenanceCadence
                ADD COLUMN leaseExpiresAt INTEGER
                """)
        }
    }

    private static func extendSourcePrivacyCleanupWork(_ db: Database) throws {
        guard try db.tableExists("sourcePrivacyCleanupWork") else {
            throw PR29V51MigrationError.invalidSchema
        }
        var columns = Set(try db.columns(in: "sourcePrivacyCleanupWork").map(\.name))
        if !columns.contains("rearmCount") {
            try db.execute(sql: """
                ALTER TABLE sourcePrivacyCleanupWork
                ADD COLUMN rearmCount INTEGER NOT NULL DEFAULT 0
                """)
            columns.insert("rearmCount")
        }
        if !columns.contains("lastRearmedAt") {
            try db.execute(sql: """
                ALTER TABLE sourcePrivacyCleanupWork
                ADD COLUMN lastRearmedAt INTEGER
                """)
        }
    }

    private static func createIncompleteVerifiedArtifactRepairScan(
        _ db: Database
    ) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS incompleteVerifiedArtifactRepairScan (
                lane TEXT PRIMARY KEY NOT NULL,
                cursorCreatedAt INTEGER,
                cursorContextId TEXT,
                cursorAnalysisGeneration INTEGER,
                updatedAt INTEGER NOT NULL,
                CHECK (length(lane) > 0),
                CHECK (updatedAt >= 0),
                CHECK (
                    (cursorCreatedAt IS NULL
                     AND cursorContextId IS NULL
                     AND cursorAnalysisGeneration IS NULL)
                    OR
                    (cursorCreatedAt >= 0
                     AND length(cursorContextId) > 0
                     AND cursorAnalysisGeneration > 0)
                )
            )
            """)
    }

    private static func createIndexes(_ db: Database) throws {
        try db.create(
            index: "idx_sourcePrivacyCleanupWork_unresolved",
            on: "sourcePrivacyCleanupWork",
            columns: ["state", "createdAt", "cleanupWorkId"],
            options: [.ifNotExists]
        )
        try db.create(
            index: "idx_incompleteVerifiedArtifactRepair_keyset",
            on: "verifiedSnapshotCommit",
            columns: ["createdAt", "contextId", "analysisGeneration"],
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
        let cadenceColumns = Set(
            try db.columns(in: "durableMaintenanceCadence").map(\.name)
        )
        let cleanupColumns = Set(
            try db.columns(in: "sourcePrivacyCleanupWork").map(\.name)
        )
        guard cadenceColumns.isSuperset(of: ["leaseOwner", "leaseExpiresAt"]),
              cleanupColumns.isSuperset(of: ["rearmCount", "lastRearmedAt"]),
              try db.tableExists("incompleteVerifiedArtifactRepairScan"),
              try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
            throw PR29V51MigrationError.invalidSchema
        }
    }
}

public enum PR29V51MigrationError: Error, Equatable, Sendable {
    case invalidSchema
}
