import Foundation
import GRDB

/// A value the user reviewed together with the exact native row shown beside it. Nil means that
/// the question was unanswered at review time, not an explicit No. Existing notes are preserved.
public struct ReviewedJournalChange: Equatable, Sendable {
    public let day: String
    public let question: String
    public let answeredYes: Bool
    public let numericValue: Double?
    public let expected: JournalEntry?

    public init(day: String, question: String, answeredYes: Bool, numericValue: Double?, expected: JournalEntry?) {
        self.day = day
        self.question = question
        self.answeredYes = answeredYes
        self.numericValue = numericValue
        self.expected = expected
    }
}

public enum ReviewedJournalSaveError: Error, LocalizedError, Equatable {
    case invalidChange
    case changedSinceReview
    case databaseChanged

    public var errorDescription: String? {
        switch self {
        case .invalidChange: return "Check the journal date and values, then review the entry again."
        case .changedSinceReview: return "An answer, note, or mood changed after this review. Review the entry again to see the current values before saving."
        case .databaseChanged: return "The journal database changed. Open a new entry and review it before saving."
        }
    }
}

extension WhoopStore {
    /// Compare and write one reviewed wake day in one transaction. The namespace is intentionally
    /// fixed: imported answers cannot be edited through this API. Only included answer keys are
    /// changed, with their notes preserved. Optional, explicitly reviewed day details are saved in
    /// this same transaction; empty note/nil mood clears only those native day-detail rows.
    /// A conflict or write failure rolls back the complete batch.
    @discardableResult
    public func saveReviewedJournal(_ changes: [ReviewedJournalChange], expectedDatabaseInstanceId: String,
                                    dayDetails: ReviewedJournalDayDetailsChange? = nil) async throws -> Int {
        try Task.checkCancellation()
        guard let day = changes.first?.day ?? dayDetails?.day, changes.count <= 256,
              Self.isValidJournalDay(day),
              Set(changes.map(\.question)).count == changes.count else {
            throw ReviewedJournalSaveError.invalidChange
        }
        if let dayDetails {
            guard dayDetails.day == day, dayDetails.expected.day == day,
                  ReviewedJournalDayDetailsChange.isValid(note: dayDetails.note, mood: dayDetails.mood) else {
                throw ReviewedJournalSaveError.invalidChange
            }
        }
        for change in changes {
            guard change.day == day,
                  !change.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  change.question.utf8.count <= 1_000,
                  !change.question.contains("\0"),
                  change.expected.map({ $0.day == change.day && $0.question == change.question }) ?? true else {
                throw ReviewedJournalSaveError.invalidChange
            }
            if let value = change.numericValue {
                guard change.answeredYes, value.isFinite, (0...1_000_000_000).contains(value) else {
                    throw ReviewedJournalSaveError.invalidChange
                }
            }
        }
        return try syncWrite { db in
            try Task.checkCancellation()
            guard try Self.databaseInstanceId(in: db) == expectedDatabaseInstanceId else {
                throw ReviewedJournalSaveError.databaseChanged
            }
            for change in changes {
                let row = try Row.fetchOne(db, sql: """
                    SELECT day, question, answeredYes, notes, numericValue FROM journal
                    WHERE deviceId = 'noop-journal' AND day = ? AND question = ?
                    """, arguments: [change.day, change.question])
                let current = row.map { row in
                    JournalEntry(day: row["day"], question: row["question"],
                                 answeredYes: (row["answeredYes"] as Int) != 0,
                                 notes: row["notes"], numericValue: row["numericValue"])
                }
                guard current == change.expected else { throw ReviewedJournalSaveError.changedSinceReview }
            }
            if let dayDetails {
                let current = try Self.journalDayDetails(day: day, in: db)
                guard current == dayDetails.expected else { throw ReviewedJournalSaveError.changedSinceReview }
            }
            try Task.checkCancellation()
            var count = 0
            for change in changes {
                try db.execute(sql: """
                    INSERT INTO journal (deviceId, day, question, answeredYes, notes, numericValue)
                    VALUES ('noop-journal', ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, question) DO UPDATE SET
                        answeredYes = excluded.answeredYes,
                        numericValue = excluded.numericValue
                    """, arguments: [change.day, change.question, change.answeredYes ? 1 : 0,
                                     change.expected?.notes, change.numericValue])
                count += db.changesCount
            }
            if let dayDetails { count += try Self.saveJournalDayDetails(dayDetails, in: db) }
            return count
        }
    }

    /// Exact Gregorian civil-day key accepted by both the read/review and save boundaries.
    public static func isValidJournalDay(_ day: String) -> Bool {
        guard day.utf8.count == 10,
              day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: day) else { return false }
        return formatter.string(from: date) == day
    }
}
