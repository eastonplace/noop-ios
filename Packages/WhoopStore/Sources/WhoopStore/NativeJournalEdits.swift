import Foundation
import GRDB

/// An optimistic edit to one native journal answer. Imported sources are never writable here.
public struct NativeJournalEdit: Sendable {
    public let question: String
    public let expected: JournalEntry?
    public let replacement: JournalEntry?

    public init(question: String, expected: JournalEntry?, replacement: JournalEntry?) {
        self.question = question
        self.expected = expected
        self.replacement = replacement
    }
}

public enum NativeJournalEditError: Error, LocalizedError, Sendable {
    case invalidEdit
    case conflict(String)
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidEdit: "This check-in contains an invalid answer. Review it before saving."
        case .conflict(let question): "An answer changed elsewhere: \(question). Reopen the check-in to review the saved value."
        case .verificationFailed: "The check-in could not be verified. Your edits remain on screen."
        }
    }
}

extension WhoopStore {
    /// Compare, write and verify inside one database transaction. Any error rolls back every edit.
    /// An exact replay is accepted, so retrying after a lost acknowledgement does not overwrite new work.
    public func applyNativeJournalEdits(day: String, edits: [NativeJournalEdit],
                                        stackUse: CoachingStackUse? = nil) async throws -> [JournalEntry] {
        guard day.count == 10, edits.count <= 512,
              Set(edits.map(\.question)).count == edits.count else { throw NativeJournalEditError.invalidEdit }
        if let stackUse {
            guard stackUse.day == day, !stackUse.id.isEmpty, !stackUse.stackId.isEmpty,
                  !stackUse.skipped || edits.isEmpty else { throw NativeJournalEditError.invalidEdit }
        }
        for edit in edits {
            guard !edit.question.isEmpty else { throw NativeJournalEditError.invalidEdit }
            for row in [edit.expected, edit.replacement].compactMap({ $0 }) {
                guard row.day == day, row.question == edit.question else { throw NativeJournalEditError.invalidEdit }
            }
            if let number = edit.replacement?.numericValue {
                guard number.isFinite, number >= 0, number <= 1_000_000_000 else {
                    throw NativeJournalEditError.invalidEdit
                }
            }
        }
        return try syncWrite { db in
            func readDay() throws -> [JournalEntry] {
                try Row.fetchAll(db, sql: """
                    SELECT day, question, answeredYes, notes, numericValue
                    FROM journal WHERE deviceId = ? AND day = ? ORDER BY question
                    """, arguments: ["noop-journal", day]).map {
                    JournalEntry(day: $0["day"], question: $0["question"],
                                 answeredYes: ($0["answeredYes"] as Int) != 0,
                                 notes: $0["notes"], numericValue: $0["numericValue"])
                }
            }
            func readUse(_ id: String) throws -> CoachingStackUse? {
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT id, stackId, day, loggedAt, notes, skipped FROM coachingStackUse WHERE id = ?
                    """, arguments: [id]) else { return nil }
                return CoachingStackUse(id: row["id"], stackId: row["stackId"], day: row["day"],
                                        loggedAt: row["loggedAt"], notes: row["notes"],
                                        skipped: (row["skipped"] as Int) != 0)
            }
            if let stackUse, let prior = try readUse(stackUse.id), prior != stackUse {
                throw NativeJournalEditError.conflict(stackUse.stackId)
            }
            let current = Dictionary(try readDay().map { ($0.question, $0) }, uniquingKeysWith: { _, last in last })
            for edit in edits {
                guard current[edit.question] == edit.expected || current[edit.question] == edit.replacement else {
                    throw NativeJournalEditError.conflict(edit.question)
                }
            }
            for edit in edits where current[edit.question] != edit.replacement {
                if let row = edit.replacement {
                    try db.execute(sql: """
                        INSERT INTO journal (deviceId, day, question, answeredYes, notes, numericValue)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(deviceId, day, question) DO UPDATE SET
                            answeredYes = excluded.answeredYes,
                            notes = excluded.notes,
                            numericValue = excluded.numericValue
                        """, arguments: ["noop-journal", day, edit.question, row.answeredYes ? 1 : 0,
                                         row.notes, row.numericValue])
                } else {
                    try db.execute(sql: "DELETE FROM journal WHERE deviceId = ? AND day = ? AND question = ?",
                                   arguments: ["noop-journal", day, edit.question])
                }
            }
            if let use = stackUse {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO coachingStackUse (id, stackId, day, loggedAt, notes, skipped)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [use.id, use.stackId, use.day, use.loggedAt, use.notes, use.skipped ? 1 : 0])
                guard try readUse(use.id) == use else { throw NativeJournalEditError.verificationFailed }
            }
            let saved = try readDay()
            let verified = Dictionary(saved.map { ($0.question, $0) }, uniquingKeysWith: { _, last in last })
            guard edits.allSatisfy({ verified[$0.question] == $0.replacement }) else {
                throw NativeJournalEditError.verificationFailed
            }
            return saved
        }
    }
}
