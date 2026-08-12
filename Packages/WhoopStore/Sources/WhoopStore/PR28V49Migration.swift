import Foundation
import GRDB

/// Round-5 durable artifacts. Registered by `PR28V48Migrations.register` so the
/// existing Database migrator remains the single schema entry point.
public enum PR28V49Migrations {
    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v49-pr28-immutable-artifacts-and-checkpoints") { db in
            try addImmutableSnapshotPayload(db)
            try createLatestStateCheckpoint(db)
            try createDurableMaintenanceCadence(db)
            try createIndexes(db)
            try validate(db)
        }
    }

    private static func addImmutableSnapshotPayload(_ db: Database) throws {
        guard try db.tableExists("verifiedSnapshotCommit") else {
            throw PR28V49MigrationError.invalidSchema
        }
        let columns = Set(try db.columns(in: "verifiedSnapshotCommit").map(\.name))
        if !columns.contains("snapshotJSON") {
            try db.alter(table: "verifiedSnapshotCommit") { table in
                table.add(column: "snapshotJSON", .blob)
            }
        }
    }

    private static func createLatestStateCheckpoint(_ db: Database) throws {
        try db.create(table: "latestStateDeliveryCheckpoint", options: [.ifNotExists]) { table in
            table.column("contextId", .text).primaryKey()
            table.column("deviceId", .text).notNull()
            table.column("snapshotGeneration", .integer).notNull()
            table.column("presentationJSON", .blob).notNull()
            table.column("widgetCoreJSON", .blob).notNull()
            table.column("logicalDay", .text).notNull()
            table.column("deliveredAt", .integer).notNull()
            table.check(sql: "length(contextId) > 0")
            table.check(sql: "length(deviceId) > 0")
            table.check(sql: "snapshotGeneration > 0")
            table.check(sql: "length(logicalDay) = 10")
        }
    }

    private static func createDurableMaintenanceCadence(_ db: Database) throws {
        try db.create(table: "durableMaintenanceCadence", options: [.ifNotExists]) { table in
            table.column("key", .text).primaryKey()
            table.column("lastRunAt", .integer).notNull()
            table.check(sql: "length(key) > 0")
        }
    }

    private static func createIndexes(_ db: Database) throws {
        try db.create(
            index: "idx_latestStateDeliveryCheckpoint_device_generation",
            on: "latestStateDeliveryCheckpoint",
            columns: ["deviceId", "snapshotGeneration"],
            options: [.ifNotExists]
        )
    }

    private static func validate(_ db: Database) throws {
        let verifiedColumns = Set(try db.columns(in: "verifiedSnapshotCommit").map(\.name))
        guard verifiedColumns.contains("snapshotJSON"),
              try db.tableExists("latestStateDeliveryCheckpoint"),
              try db.tableExists("durableMaintenanceCadence"),
              try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
            throw PR28V49MigrationError.invalidSchema
        }
    }
}

public enum PR28V49MigrationError: Error, Equatable, Sendable {
    case invalidSchema
}
