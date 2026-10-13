import GRDB

/// DL-13 / DL-15 index hygiene.
///
/// - `metricSeries(key, day)`: the global key/day deletes run on every sleep edit. Both earlier metricSeries
///   indexes lead with `deviceId`, so without statistics SQLite scanned the whole table inside the write
///   transaction.
/// - `idx_historicalDataCommitJournal_scope_generation_v40` duplicated
///   `idx_historicalDataCommitJournal_scope_generation` column for column, so every journal commit
///   maintained the same B-tree twice. New installs no longer create it; existing installs drop it here.
public enum StoreIndexHygieneMigration {
    public static let identifier = "v58-store-index-hygiene"

    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            try db.create(
                index: "idx_metricSeries_key_day",
                on: "metricSeries",
                columns: ["key", "day"],
                options: [.ifNotExists]
            )
            try db.execute(sql: "DROP INDEX IF EXISTS idx_historicalDataCommitJournal_scope_generation_v40")
        }
    }
}
