import Foundation
import GRDB
import NoopPhase34Core

/// PR #28 round-3 durable delivery upgrade. This migration runs after v46 so the generation fence exists
/// before the pre-upgrade success history is reconstructed.
public enum PR28V47Migrations {
    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v47-pr28-watermark-backfill-and-sleep-ledger") { db in
            try createSleepLedgerTables(db)
            try backfillSucceededHealthKitWatermarks(db)
            try validate(db)
        }
    }

    private static func createSleepLedgerTables(_ db: Database) throws {
        try db.create(table: "healthKitSleepDayLedger", options: [.ifNotExists]) { table in
            table.column("contextId", .text).notNull()
            table.column("deviceId", .text).notNull()
            table.column("wakeDay", .text).notNull()
            table.column("analysisGeneration", .integer).notNull()
            table.column("updatedAt", .integer).notNull()
            table.primaryKey(["contextId", "wakeDay"])
            table.check(sql: "length(contextId) > 0")
            table.check(sql: "length(deviceId) > 0")
            table.check(sql: "length(wakeDay) = 10")
            table.check(sql: "analysisGeneration > 0")
        }

        try db.create(table: "healthKitSleepKeyLedger", options: [.ifNotExists]) { table in
            table.column("contextId", .text).notNull()
            table.column("deviceId", .text).notNull()
            table.column("wakeDay", .text).notNull()
            table.column("stableStartTimestamp", .integer).notNull()
            table.column("externalUUID", .text).notNull()
            table.column("analysisGeneration", .integer).notNull()
            table.column("updatedAt", .integer).notNull()
            table.primaryKey(["contextId", "wakeDay", "stableStartTimestamp"])
            table.foreignKey(
                ["contextId", "wakeDay"],
                references: "healthKitSleepDayLedger",
                columns: ["contextId", "wakeDay"],
                onDelete: .cascade
            )
            table.check(sql: "stableStartTimestamp >= 0")
            table.check(sql: "length(externalUUID) > 0")
            table.check(sql: "analysisGeneration > 0")
        }

        try db.create(
            index: "idx_healthKitSleepDayLedger_device_day",
            on: "healthKitSleepDayLedger",
            columns: ["deviceId", "wakeDay", "analysisGeneration"],
            options: [.ifNotExists]
        )
        try db.create(
            index: "idx_healthKitSleepKeyLedger_device_day",
            on: "healthKitSleepKeyLedger",
            columns: ["deviceId", "wakeDay", "analysisGeneration"],
            options: [.ifNotExists]
        )
    }

    /// v46 created an empty table. Rebuild the maximum succeeded generation per context/day so an older
    /// delayed row cannot pass the fence after upgrade. Malformed historical side-effect evidence is
    /// quarantined by the shared fail-closed implementation so one obsolete row cannot brick database open.
    private static func backfillSucceededHealthKitWatermarks(_ db: Database) throws {
        try PR28V48Migrations.backfillHealthKitWatermarksFailClosed(db)
    }

    private static func validate(_ db: Database) throws {
        guard try db.tableExists("healthKitMutationWatermark"),
              try db.tableExists("healthKitSleepDayLedger"),
              try db.tableExists("healthKitSleepKeyLedger") else {
            throw PR28V47MigrationError.invalidSchema
        }
        let invalidWatermarks = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM healthKitMutationWatermark
            WHERE length(contextId) = 0 OR length(deviceId) = 0
               OR length(day) != 10 OR analysisGeneration <= 0
            """) ?? 0
        let invalidDays = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM healthKitSleepDayLedger
            WHERE length(contextId) = 0 OR length(deviceId) = 0
               OR length(wakeDay) != 10 OR analysisGeneration <= 0
            """) ?? 0
        let invalidKeys = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM healthKitSleepKeyLedger
            WHERE length(contextId) = 0 OR length(deviceId) = 0
               OR length(wakeDay) != 10 OR stableStartTimestamp < 0
               OR length(externalUUID) = 0 OR analysisGeneration <= 0
            """) ?? 0
        guard invalidWatermarks == 0, invalidDays == 0, invalidKeys == 0 else {
            throw PR28V47MigrationError.invalidSchema
        }

        for day in try String.fetchAll(db, sql: "SELECT day FROM healthKitMutationWatermark") {
            guard (try? CivilDay(key: day)) != nil else { throw PR28V47MigrationError.invalidSchema }
        }
        for day in try String.fetchAll(db, sql: "SELECT wakeDay FROM healthKitSleepDayLedger") {
            guard (try? CivilDay(key: day)) != nil else { throw PR28V47MigrationError.invalidSchema }
        }
        for day in try String.fetchAll(db, sql: "SELECT wakeDay FROM healthKitSleepKeyLedger") {
            guard (try? CivilDay(key: day)) != nil else { throw PR28V47MigrationError.invalidSchema }
        }

        let requiredIndexes = [
            ("healthKitMutationWatermark", "idx_healthKitMutationWatermark_device_day"),
            ("healthKitSleepDayLedger", "idx_healthKitSleepDayLedger_device_day"),
            ("healthKitSleepKeyLedger", "idx_healthKitSleepKeyLedger_device_day"),
        ]
        for (table, index) in requiredIndexes {
            let exists = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'index' AND name = ? AND tbl_name = ?
                """, arguments: [index, table]) ?? 0
            guard exists == 1 else { throw PR28V47MigrationError.invalidSchema }
        }
        let foreignKeyViolations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
        guard foreignKeyViolations == 0 else { throw PR28V47MigrationError.invalidSchema }
    }
}

public enum PR28V47MigrationError: Error {
    case malformedSucceededPayload
    case invalidSchema
}
