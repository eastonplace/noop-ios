import Foundation
import WhoopStore

/// Reads the same canonical catalog, persisted Active membership choices and native
/// civil-day rows as Journal. Stack-level Skip is not a journal-day completion.
@MainActor
enum NotificationJournalEligibility {
    static func isIncomplete(day: String, catalog: JournalCatalogStore,
                             importedQuestions: [String], store: WhoopStore) async throws -> Bool {
        let resolved = catalog.resolvedItems(imported: importedQuestions)
        let sets = try await store.coachingBehaviorSets()
        let activeItems: [JournalCatalogItem]
        if let activeSet = sets.first(where: \.isActive) {
            let memberships = try await store.coachingMemberships(setId: activeSet.id)
            let selected = Set(memberships.filter(\.isActive).map { JournalCatalogStore.norm($0.canonicalQuestion) })
            activeItems = resolved.filter { selected.contains(JournalCatalogStore.norm($0.canonical)) }
        } else {
            // Before a coaching set is materialized, Journal uses its visible
            // starter/imported/custom catalog as the default check-in set.
            activeItems = resolved
        }
        guard !activeItems.isEmpty else { return false }
        let rows = try await store.journalEntries(deviceId: Repository.journalDeviceId, from: day, to: day)
        // Presence means answered, including explicit No and a numeric zero.
        // Absence remains unknown. Imported history cannot complete a native entry.
        let answered = Set(rows.filter { $0.numericValue?.isFinite ?? true }
            .map { JournalCatalogStore.norm($0.question) })
        return activeItems.contains { !answered.contains(JournalCatalogStore.norm($0.canonical)) }
    }
}
