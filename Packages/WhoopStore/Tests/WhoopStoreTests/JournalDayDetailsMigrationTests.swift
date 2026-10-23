import XCTest
import GRDB
@testable import WhoopStore

final class JournalDayDetailsMigrationTests: XCTestCase {
    func testUpgradeIsAdditiveAndCanReopenWithoutChangingExistingRows() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE journal (deviceId TEXT NOT NULL, day TEXT NOT NULL, question TEXT NOT NULL,
                    answeredYes INTEGER NOT NULL, notes TEXT, numericValue REAL,
                    PRIMARY KEY(deviceId, day, question));
                CREATE TABLE metricSeries (deviceId TEXT NOT NULL, day TEXT NOT NULL, key TEXT NOT NULL,
                    value REAL NOT NULL, PRIMARY KEY(deviceId, day, key));
                INSERT INTO journal VALUES ('my-whoop', '2026-10-22', 'Caffeine', 1, 'Imported answer note', 125);
                INSERT INTO journal VALUES ('noop-journal', '2026-10-22', 'Caffeine', 1, 'Native dose note', 0);
                INSERT INTO metricSeries VALUES ('noop-mood', '2026-10-22', 'mood', 4);
                """)
        }
        let before = try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM journal ORDER BY deviceId") }
        var migrator = DatabaseMigrator()
        JournalDayNoteMigration.register(on: &migrator)
        try migrator.migrate(queue)
        try migrator.migrate(queue)
        try queue.read { db in
            XCTAssertTrue(try db.tableExists("journalDayNote"))
            XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT * FROM journal ORDER BY deviceId"), before)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT value FROM metricSeries WHERE deviceId = 'noop-mood'"), 4)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journalDayNote"), 0)
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"), [JournalDayNoteMigration.identifier])
        }
    }

    func testNativeDayNoteTableIsCreatedWithoutRewritingAnswerRows() async throws {
        let store = try await WhoopStore.inMemory()
        let original = JournalEntry(day: "2026-10-22", question: "Caffeine", answeredYes: true,
                                    notes: "Keep this answer note", numericValue: 200)
        try await store.upsertJournal([original], deviceId: "my-whoop")
        let exists = try await store.registryWriter.read { db in try db.tableExists("journalDayNote") }
        XCTAssertTrue(exists, "The additive migration must install a separate native day-note table")
        let rows = try await store.journalEntries(deviceId: "my-whoop", from: original.day, to: original.day)
        XCTAssertEqual(rows, [original])
    }
}
