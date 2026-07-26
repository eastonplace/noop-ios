import GRDB

extension WhoopStore {
    /// Focused v31 migration kept next to the feature's store API. It is invoked under
    /// the same process-wide open gate as the main migrator, so concurrent cold launches
    /// cannot race it. GRDB records the identifier in the shared `grdb_migrations` table.
    static func migrateSleepRecoverySchema(_ writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v31-sleep-window-recovery") { db in
            try db.create(table: "sleepRecoveryAttempt") { table in
                table.column("id", .text).primaryKey()
                table.column("deviceId", .text).notNull()
                table.column("source", .text).notNull()
                table.column("requestedStartTs", .integer).notNull()
                table.column("requestedEndTs", .integer).notNull()
                table.column("outcome", .text).notNull()
                table.column("confidence", .double).notNull()
                table.column("reason", .text).notNull()
                table.column("resultStartTs", .integer)
                table.column("resultEndTs", .integer)
                table.column("stagesAvailable", .boolean).notNull().defaults(to: false)
                table.column("restingHr", .integer)
                table.column("avgHrv", .double)
                table.column("algorithmVersion", .text).notNull()
                table.column("createdAt", .integer).notNull()
                table.column("updatedAt", .integer).notNull()
            }
            try db.create(
                index: "idx_sleepRecoveryAttempt_device_updated",
                on: "sleepRecoveryAttempt",
                columns: ["deviceId", "updatedAt"])
            try db.create(
                index: "idx_sleepRecoveryAttempt_device_window",
                on: "sleepRecoveryAttempt",
                columns: ["deviceId", "requestedStartTs", "requestedEndTs"])
        }
        try migrator.migrate(writer)
    }
}
