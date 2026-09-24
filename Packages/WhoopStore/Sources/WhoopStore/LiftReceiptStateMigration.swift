import GRDB

/// The ReceiptLiftFeature envelope is owned by the same source/device boundary as Lift Log rows.
/// Keep this identifier separate from the core migration sequence so the RR migration can reserve
/// its next core version without sharing a GRDB migration name.
public enum LiftReceiptStateSchema {
    public static let migrationIdentifier = "v41-lift-receipt-state"
    public static let tableName = "liftReceiptState"
}

enum LiftReceiptStateMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(LiftReceiptStateSchema.migrationIdentifier) { db in
            try db.create(table: LiftReceiptStateSchema.tableName, options: [.ifNotExists]) { t in
                t.column("deviceId", .text).primaryKey()
                t.column("data", .blob).notNull()
            }
        }
    }
}
