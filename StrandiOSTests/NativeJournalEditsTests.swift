import Foundation
import Testing
import GRDB
import WhoopStore

@Suite("Atomic native journal edits")
struct NativeJournalEditsTests {
    private let day = "2026-09-06"
    private func entry(_ question: String = "Habit", value: Double? = nil, yes: Bool = true) -> JournalEntry {
        JournalEntry(day: day, question: question, answeredYes: yes, notes: "Retained note", numericValue: value)
    }
    @Test func savesNumericZeroAndKeepsImportedRows() async throws {
        let store = try await WhoopStore.inMemory()
        let imported = entry(yes: false)
        try await store.upsertJournal([imported], deviceId: "imported-whoop")
        let zero = entry(value: 0)
        let saved = try await store.applyNativeJournalEdits(day: day, edits: [.init(question: zero.question, expected: nil, replacement: zero)])
        #expect(saved == [zero])
        let foreign = try await store.journalEntries(deviceId: "imported-whoop", from: day, to: day)
        #expect(foreign == [imported])
    }
    @Test func conflictRollsBackTheEntireCheckIn() async throws {
        let store = try await WhoopStore.inMemory()
        let existing = entry("B", yes: false)
        try await store.upsertJournal([existing], deviceId: "noop-journal")
        do {
            _ = try await store.applyNativeJournalEdits(day: day, edits: [
                .init(question: "A", expected: nil, replacement: entry("A")),
                .init(question: "B", expected: nil, replacement: entry("B")),
            ])
            Issue.record("Expected a conflict")
        } catch NativeJournalEditError.conflict(let question) { #expect(question == "B") }
        let saved = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        #expect(saved == [existing])
    }
    @Test func exactReplayIsIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        let row = entry()
        let edit = NativeJournalEdit(question: row.question, expected: nil, replacement: row)
        _ = try await store.applyNativeJournalEdits(day: day, edits: [edit])
        let replay = try await store.applyNativeJournalEdits(day: day, edits: [edit])
        #expect(replay == [row])
    }
    @Test func clearingOnlyTouchesTheExactNativeAnswer() async throws {
        let store = try await WhoopStore.inMemory()
        let row = entry()
        try await store.upsertJournal([row], deviceId: "noop-journal")
        try await store.upsertJournal([row], deviceId: "imported-whoop")
        let saved = try await store.applyNativeJournalEdits(day: day, edits: [.init(question: row.question, expected: row, replacement: nil)])
        #expect(saved.isEmpty)
        #expect(try await store.journalEntries(deviceId: "imported-whoop", from: day, to: day) == [row])
    }
    @Test(arguments: [Double.nan, .infinity, -1, 1_000_000_001])
    func invalidNumberNeverReachesStorage(_ value: Double) async throws {
        let store = try await WhoopStore.inMemory()
        await #expect(throws: NativeJournalEditError.self) {
            try await store.applyNativeJournalEdits(day: day, edits: [.init(question: "Habit", expected: nil, replacement: entry(value: value))])
        }
        #expect(try await store.journalEntries(deviceId: "noop-journal", from: day, to: day).isEmpty)
    }
    @Test func duplicateEditsFailBeforeAnyWrite() async throws {
        let store = try await WhoopStore.inMemory()
        let edit = NativeJournalEdit(question: "Habit", expected: nil, replacement: entry())
        await #expect(throws: NativeJournalEditError.self) { try await store.applyNativeJournalEdits(day: day, edits: [edit, edit]) }
    }
    @Test func verifiesInsideTheTransaction() async throws {
        let store = try await WhoopStore.inMemory()
        try installTrigger(store, sql: """
            CREATE TRIGGER lose_native_insert AFTER INSERT ON journal
            WHEN NEW.deviceId = 'noop-journal'
            BEGIN DELETE FROM journal WHERE deviceId = NEW.deviceId AND day = NEW.day AND question = NEW.question; END;
            """)
        await #expect(throws: NativeJournalEditError.self) {
            try await store.applyNativeJournalEdits(day: day, edits: [.init(question: "Habit", expected: nil, replacement: entry())])
        }
    }
    @Test func routineAndAnswersCommitTogether() async throws {
        let store = try await WhoopStore.inMemory()
        let stack = CoachingStack(id: "test-routine", name: "Test", description: nil, scheduleLabel: nil, isActive: true, notes: nil, sortIndex: 0)
        _ = try await store.ensureDefaultCoachingStack(stack, items: [])
        let use = CoachingStackUse(id: "operation-1", stackId: stack.id, day: day, loggedAt: 123, notes: nil, skipped: false)
        let edits = [NativeJournalEdit(question: "Habit", expected: nil, replacement: entry())]
        _ = try await store.applyNativeJournalEdits(day: day, edits: edits, stackUse: use)
        _ = try await store.applyNativeJournalEdits(day: day, edits: edits, stackUse: use)
        #expect(try await store.coachingStackUses(stackId: stack.id) == [use])
        #expect(try await store.journalEntries(deviceId: "noop-journal", from: day, to: day) == [entry()])
    }
    @Test func provenanceFailureRollsBackAnswers() async throws {
        let store = try await WhoopStore.inMemory()
        let stack = CoachingStack(id: "test-routine", name: "Test", description: nil, scheduleLabel: nil, isActive: true, notes: nil, sortIndex: 0)
        _ = try await store.ensureDefaultCoachingStack(stack, items: [])
        try installTrigger(store, sql: """
            CREATE TRIGGER reject_use BEFORE INSERT ON coachingStackUse
            BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
            """)
        let use = CoachingStackUse(id: "operation-1", stackId: stack.id, day: day, loggedAt: 123, notes: nil, skipped: false)
        await #expect(throws: (any Error).self) {
            try await store.applyNativeJournalEdits(day: day, edits: [.init(question: "Habit", expected: nil, replacement: entry())], stackUse: use)
        }
        #expect(try await store.journalEntries(deviceId: "noop-journal", from: day, to: day).isEmpty)
        #expect(try await store.coachingStackUses(stackId: stack.id).isEmpty)
    }
    private func installTrigger(_ store: WhoopStore, sql: String) throws {
        try store.registryWriter.write { db in try db.execute(sql: sql) }
    }
}
