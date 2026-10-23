import GRDB

/// Native free-text day notes are not behavior answers. This additive table never rewrites
/// imported journal history or the notes already attached to individual answers.
enum JournalDayNoteMigration {
    static let identifier = "v62-native-journal-day-note"

    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            try db.create(table: "journalDayNote") { table in
                table.column("deviceId", .text).notNull()
                table.column("day", .text).notNull()
                table.column("note", .text).notNull()
                table.primaryKey(["deviceId", "day"])
            }
        }
    }
}
