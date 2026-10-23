import Foundation
import WhoopStore

extension Repository {
    /// One day of the journal the way the Journal page shows it: the answers tapped in the app, and the answers an
    /// import brought for the same day. They are kept apart so a tap can replace an imported answer, and a cleared tap
    /// can bring it back. The first imported source to answer a question keeps it, as everywhere else.
    func journalDayValues(day: String) async -> (native: JournalQuickLog.DayValues, imported: JournalQuickLog.DayValues) {
        guard let store = await storeHandle() else { return (.init(), .init()) }
        let nativeRows = (try? await store.journalEntries(deviceId: Self.journalDeviceId, from: day, to: day)) ?? []
        var importedRows: [JournalEntry] = []
        for owner in importedReadIds {
            importedRows += (try? await store.journalEntries(deviceId: owner, from: day, to: day)) ?? []
        }
        let imported = Self.mergeJournal(imported: importedRows, native: [])
        return (JournalQuickLog.values(from: nativeRows, day: day), JournalQuickLog.values(from: imported, day: day))
    }
}

extension Repository {
    /// The questions the Journal asks: the active members of the "Daily fundamentals" set. A question that has no
    /// membership yet joins it as active, so a newly added one is asked straight away. Unavailable reads fall back
    /// to the catalog keys; a successfully read empty set means the person turned every question off.
    func activeCoachingQuestions(for items: [JournalCatalogItem]) async -> Set<String> {
        let fallback = Set(items.map(\.canonical))
        guard let store = await storeHandle() else { return fallback }
        let defaults = items.enumerated().map { index, item in
            CoachingBehaviorMembership(setId: "daily-fundamentals", canonicalQuestion: item.canonical,
                                       coachingGroup: coachingPresentationGroup(for: item).rawValue,
                                       sortIndex: index, isActive: true, isQuickAdd: index < 6)
        }
        guard let set = try? await store.ensureDefaultCoachingSet(name: "Daily fundamentals", memberships: defaults) else {
            return fallback
        }
        guard let memberships = try? await store.coachingMemberships(setId: set.id) else { return fallback }
        return Set(memberships.filter(\.isActive).map(\.canonicalQuestion))
    }
}
