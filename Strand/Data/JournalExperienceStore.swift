import Foundation
import WhoopStore

struct JournalExperienceConfiguration {
    let items: [JournalCatalogItem]
    let memberships: [CoachingBehaviorMembership]
    let stacks: [CoachingStack]
    let setName: String
    var activeItems: [JournalCatalogItem] {
        let active = Set(memberships.filter(\.isActive).map(\.canonicalQuestion))
        let order = Dictionary(memberships.map { ($0.canonicalQuestion, $0.sortIndex) }, uniquingKeysWith: { first, _ in first })
        return items.filter { !$0.hidden && active.contains($0.canonical) }
            .sorted { (order[$0.canonical] ?? $0.sortIndex, $0.display) < (order[$1.canonical] ?? $1.sortIndex, $1.display) }
    }
}

@MainActor
enum JournalExperienceStore {
    enum Failure: Error, LocalizedError {
        case unavailable
        var errorDescription: String? { "Journal storage is unavailable. Your edits have not been discarded." }
    }

    static func configuration(repo: Repository, catalog: JournalCatalogStore) async throws -> JournalExperienceConfiguration {
        guard let store = await repo.storeHandle() else { throw Failure.unavailable }
        let imported = await repo.importedJournalEntries()
        try Task.checkCancellation()
        let questions = Array(Set(imported.map(\.question))).sorted()
        let items = catalog.resolvedItems(imported: questions, includeHidden: true)
        let defaults = items.enumerated().map { index, item in
            CoachingBehaviorMembership(setId: "daily-fundamentals", canonicalQuestion: item.canonical,
                                       coachingGroup: item.group.title, sortIndex: index,
                                       isActive: true, isQuickAdd: index < 6)
        }
        let set = try await store.ensureDefaultCoachingSet(name: "Daily fundamentals", memberships: defaults)
        let memberships = try await store.coachingMemberships(setId: set.id)
        let stacks = try await store.coachingStacks()
        try Task.checkCancellation()
        return .init(items: items, memberships: memberships, stacks: stacks, setName: set.name)
    }

    static func read(repo: Repository, from: String, to: String) async throws -> [JournalEntry] {
        guard let store = await repo.storeHandle() else { throw Failure.unavailable }
        return try await store.journalEntries(deviceId: Repository.journalDeviceId, from: from, to: to)
    }

    static func answers(_ rows: [JournalEntry]) -> [String: JournalAnswer] {
        var values: [String: JournalAnswer] = [:]
        for row in rows {
            let value: JournalAnswer = row.numericValue.map(JournalAnswer.number) ?? .boolean(row.answeredYes)
            if value.isValid { values[row.question] = value }
        }
        return values
    }

    static func save(repo: Repository, draft: JournalDraft, baseline: [JournalEntry]) async throws -> [JournalEntry] {
        guard let store = await repo.storeHandle() else { throw Failure.unavailable }
        let originals = Dictionary(baseline.map { ($0.question, $0) }, uniquingKeysWith: { _, last in last })
        let edits = draft.changedKeys.map { question -> NativeJournalEdit in
            let original = originals[question]
            let replacement = draft.answers[question].map { answer -> JournalEntry in
                switch answer {
                case .boolean(let yes):
                    return JournalEntry(day: draft.day, question: question, answeredYes: yes, notes: original?.notes)
                case .number(let value):
                    // Preserve the existing numeric-journal analytics contract, including numeric zero.
                    return JournalEntry(day: draft.day, question: question, answeredYes: true,
                                        notes: original?.notes, numericValue: value)
                }
            }
            return NativeJournalEdit(question: question, expected: original, replacement: replacement)
        }
        return try await store.applyNativeJournalEdits(day: draft.day, edits: edits)
    }
}
