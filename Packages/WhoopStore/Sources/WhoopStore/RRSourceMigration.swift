import GRDB
import WhoopProtocol

/// Additive RR provenance/order columns. The existing `rrInterval` table and primary key remain intact;
/// this migration only annotates rows so installs with custom RR schemas keep their data and conflict
/// behavior while new reads can apply `RRReadPolicy`.
public enum RRSourceMigration {
    public static let identifier = "v57-rr-source-order"

    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            let columns = try Set(db.columns(in: "rrInterval").map(\.name))
            if !columns.contains("source") {
                try db.alter(table: "rrInterval") { t in
                    t.add(column: "source", .text).notNull().defaults(to: RRSource.legacy.rawValue)
                }
            }
            if !columns.contains("sourceOrdinal") {
                try db.alter(table: "rrInterval") { t in
                    t.add(column: "sourceOrdinal", .integer)
                }
            }
            // Imported upstream schemas use numeric channel codes. Preserve their
            // explicit provenance; never guess a channel for unlabelled legacy rows.
            if columns.contains("srcChannel") {
                for channel in 1...7 {
                    try db.execute(sql: "UPDATE rrInterval SET source = ? WHERE srcChannel = ? AND source = ?",
                        arguments: [RRSource.legacyChannel(channel).rawValue, channel, RRSource.legacy.rawValue])
                }
            }
            if columns.contains("ord") {
                try db.execute(sql: "UPDATE rrInterval SET sourceOrdinal = ord WHERE sourceOrdinal IS NULL")
            }
            try db.create(
                index: "idx_rrInterval_source_order",
                on: "rrInterval",
                columns: ["deviceId", "source", "ts", "sourceOrdinal", "rrMs"]
            )
        }
    }
}
