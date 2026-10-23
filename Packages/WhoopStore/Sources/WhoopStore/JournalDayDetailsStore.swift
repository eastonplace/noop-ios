import Foundation
import GRDB

/// Exact persisted day details captured for optimistic concurrency. The raw optional mood value
/// is intentionally not rounded: another writer changing 4 to 4.25 must still invalidate a review.
/// Nil note/mood means no row in that native namespace, not an inferred empty answer.
public struct JournalDayDetailsSnapshot: Equatable, Sendable {
    public let day: String
    public let note: String?
    public let mood: Double?

    public init(day: String, note: String?, mood: Double?) {
        self.day = day
        self.note = note
        self.mood = mood
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.day == rhs.day, lhs.mood == rhs.mood else { return false }
        // String equality folds canonically equivalent Unicode. A review must instead notice
        // every change to the persisted text, even an edit that looks identical on screen.
        switch (lhs.note, rhs.note) {
        case (.none, .none): return true
        case (.some(let left), .some(let right)): return left.utf8.elementsEqual(right.utf8)
        default: return false
        }
    }
}

/// Explicit replacement of a reviewed day's note and mood. Omit this change entirely to preserve
/// details. When included, an empty note or nil mood clears only that exact day's native row.
public struct ReviewedJournalDayDetailsChange: Equatable, Sendable {
    public static let maximumNoteBytes = 8_000
    public let day: String
    public let note: String
    public let mood: Int?
    public let expected: JournalDayDetailsSnapshot

    public init(day: String, note: String, mood: Int?, expected: JournalDayDetailsSnapshot) {
        self.day = day
        self.note = note
        self.mood = mood
        self.expected = expected
    }

    public static func isValid(note: String, mood: Int?) -> Bool {
        note.utf8.count <= maximumNoteBytes && !note.contains("\0")
            && (mood.map { (1...5).contains($0) } ?? true)
    }
}

extension WhoopStore {
    /// Read both details from one SQLite snapshot. Notes share the native journal namespace;
    /// mood reuses the existing MoodStore metric (noop-mood / mood), never a second mood store.
    public func journalDayDetails(day: String) async throws -> JournalDayDetailsSnapshot {
        try Task.checkCancellation()
        guard Self.isValidJournalDay(day) else { throw ReviewedJournalSaveError.invalidChange }
        return try syncRead { db in try Self.journalDayDetails(day: day, in: db) }
    }

    static func journalDayDetails(day: String, in db: Database) throws -> JournalDayDetailsSnapshot {
        let note = try String.fetchOne(db, sql: """
            SELECT note FROM journalDayNote WHERE deviceId = 'noop-journal' AND day = ?
            """, arguments: [day])
        let mood = try Double.fetchOne(db, sql: """
            SELECT value FROM metricSeries WHERE deviceId = 'noop-mood' AND day = ? AND key = 'mood'
            """, arguments: [day])
        return JournalDayDetailsSnapshot(day: day, note: note, mood: mood)
    }

    /// Called only after the reviewed snapshot was compared inside the caller's write transaction.
    static func saveJournalDayDetails(_ change: ReviewedJournalDayDetailsChange, in db: Database) throws -> Int {
        if change.note.isEmpty {
            try db.execute(sql: "DELETE FROM journalDayNote WHERE deviceId = 'noop-journal' AND day = ?",
                           arguments: [change.day])
        } else {
            try db.execute(sql: """
                INSERT INTO journalDayNote (deviceId, day, note) VALUES ('noop-journal', ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET note = excluded.note
                WHERE journalDayNote.note IS NOT excluded.note
                """, arguments: [change.day, change.note])
        }
        var count = db.changesCount
        if let mood = change.mood {
            try db.execute(sql: """
                INSERT INTO metricSeries (deviceId, day, key, value) VALUES ('noop-mood', ?, 'mood', ?)
                ON CONFLICT(deviceId, day, key) DO UPDATE SET value = excluded.value
                WHERE metricSeries.value IS NOT excluded.value
                """, arguments: [change.day, Double(mood)])
        } else {
            try db.execute(sql: """
                DELETE FROM metricSeries WHERE deviceId = 'noop-mood' AND day = ? AND key = 'mood'
                """, arguments: [change.day])
        }
        count += db.changesCount
        return count
    }
}
