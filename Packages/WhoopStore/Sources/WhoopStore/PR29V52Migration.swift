import GRDB

/// Durable environmental deferral for privacy cleanup. This forward migration
/// keeps v50 and v51 immutable for databases that already recorded them.
public enum PR29V52Migrations {
    public static let identifier = "v52-pr29-privacy-authorization-deferral"

    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            guard try db.tableExists("sourcePrivacyCleanupWork") else {
                throw PR29V52MigrationError.invalidSchema
            }
            let columns = Set(
                try db.columns(in: "sourcePrivacyCleanupWork").map(\.name)
            )
            if !columns.contains("authorizationBlockedAt") {
                try db.execute(sql: """
                    ALTER TABLE sourcePrivacyCleanupWork
                    ADD COLUMN authorizationBlockedAt INTEGER
                    """)
            }
            try db.create(
                index: "idx_sourcePrivacyCleanupWork_authorization",
                on: "sourcePrivacyCleanupWork",
                columns: ["authorizationBlockedAt", "nextAttemptAt", "updatedAt"],
                options: [.ifNotExists]
            )
            let migratedColumns = Set(
                try db.columns(in: "sourcePrivacyCleanupWork").map(\.name)
            )
            guard migratedColumns.contains("authorizationBlockedAt"),
                  try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
                throw PR29V52MigrationError.invalidSchema
            }
        }
    }
}

public enum PR29V52MigrationError: Error, Equatable, Sendable {
    case invalidSchema
}
