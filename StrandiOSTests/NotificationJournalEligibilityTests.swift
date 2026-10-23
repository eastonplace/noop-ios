import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

@MainActor
final class NotificationJournalEligibilityTests: XCTestCase {
    private let day = "2027-01-19"
    private let now = Date(timeIntervalSince1970: 1_800_360_000)

    private func defaults() -> UserDefaults {
        let name = "NotificationJournalEligibilityTests.\(UUID().uuidString)"
        let value = UserDefaults(suiteName: name)!
        value.removePersistentDomain(forName: name)
        return value
    }
    private func membership(_ question: String, active: Bool = true) -> CoachingBehaviorMembership {
        .init(setId: "daily-fundamentals", canonicalQuestion: question, coachingGroup: "other",
              sortIndex: 0, isActive: active, isQuickAdd: false)
    }
    private func catalog(_ defaults: UserDefaults) -> JournalCatalogStore {
        let value = JournalCatalogStore(defaults: defaults)
        value.addCustom("Question A")
        value.addCustom("Quantity B", kind: .numeric(unitLabel: "units"))
        return value
    }

    func testNoActiveQuestionsAndHiddenDeletedQuestionsDoNotCreateReminder() async throws {
        let store = try await WhoopStore.inMemory()
        let d = defaults()
        let catalog = catalog(d)
        _ = try await store.ensureDefaultCoachingSet(name: "Selected",
            memberships: [membership("Question A", active: false), membership("Quantity B", active: false)])
        let none = try await NotificationJournalEligibility.isIncomplete(day: day,
            catalog: catalog, importedQuestions: [], store: store)
        XCTAssertFalse(none)
        try await store.upsertCoachingMemberships([membership("Question A")])
        catalog.remove("Question A")
        let deleted = try await NotificationJournalEligibility.isIncomplete(day: day,
            catalog: JournalCatalogStore(defaults: d), importedQuestions: [], store: store)
        XCTAssertFalse(deleted, "An obsolete membership cannot revive a deleted custom question")
        let starter = JournalCatalogStore.starterQuestions[0]
        try await store.upsertCoachingMemberships([membership(starter)])
        catalog.remove(starter)
        let hidden = try await NotificationJournalEligibility.isIncomplete(day: day,
            catalog: JournalCatalogStore(defaults: d), importedQuestions: [], store: store)
        XCTAssertFalse(hidden, "A persisted Active membership cannot revive a hidden question")
    }

    func testPersistedSelectionRequiresEveryCurrentDayAnswerAndCountsNoAndNumericZero() async throws {
        let store = try await WhoopStore.inMemory()
        let d = defaults()
        let catalog = catalog(d)
        catalog.rename("Question A", to: "Renamed label")
        _ = try await store.ensureDefaultCoachingSet(name: "Selected",
            memberships: [membership("Question A"), membership("Quantity B")])
        _ = try await store.upsertJournal([
            .init(day: day, question: "Question A", answeredYes: false, notes: nil),
            .init(day: "2027-01-18", question: "Quantity B", answeredYes: true, notes: nil, numericValue: 0)
        ], deviceId: Repository.journalDeviceId)
        _ = try await store.upsertJournal([
            .init(day: day, question: "Quantity B", answeredYes: true, notes: nil, numericValue: 8)
        ], deviceId: "imported-source")
        let reopened = JournalCatalogStore(defaults: d)
        let partial = try await NotificationJournalEligibility.isIncomplete(day: day,
            catalog: reopened, importedQuestions: [], store: store)
        XCTAssertTrue(partial, "Yesterday or imported rows cannot finish the selected native civil day")
        _ = try await store.upsertJournal([
            .init(day: day, question: "Quantity B", answeredYes: true, notes: nil, numericValue: 0)
        ], deviceId: Repository.journalDeviceId)
        let complete = try await NotificationJournalEligibility.isIncomplete(day: day,
            catalog: reopened, importedQuestions: [], store: store)
        XCTAssertFalse(complete, "Explicit No and numeric zero are saved answers, not missing values")
        try await store.upsertCoachingMemberships([membership("Quantity B", active: false)])
        _ = try await store.deleteJournal(deviceId: Repository.journalDeviceId, day: day, question: "Quantity B")
        let selectedComplete = try await NotificationJournalEligibility.isIncomplete(day: day,
            catalog: reopened, importedQuestions: [], store: store)
        XCTAssertFalse(selectedComplete, "An inactive missing answer does not keep a check-in incomplete")
    }

    func testCompletionWithdrawsTheProductionScheduledRequestWhilePartialEntryKeepsIt() async throws {
        let store = try await WhoopStore.inMemory()
        let answers = try XCTUnwrap(JournalBehaviorDay.storageKey(forBehaviorKey: day))
        let catalog = catalog(defaults())
        _ = try await store.ensureDefaultCoachingSet(name: "Selected",
            memberships: [membership("Question A"), membership("Quantity B")])
        let center = NotificationCoordinatorTests.Center()
        let runtime = NotificationCoordinator(center: center, clock: { self.now },
            preferences: { .init(modes: [.journalCheckIn: .notify]) },
            context: { .init(sourceContext: "source", logicalDay: self.day) }, store: { store }, dryRun: { false })
        let candidate = NotificationSchedulePlanner.candidate(group: .journalCheckIn, id: day,
            scheduledAt: now.addingTimeInterval(3600), source: "source", destination: .journal(logicalDay: day), now: now)
        let needed = try await runtime.journalReminderIfNeeded(candidate, day: day,
            catalog: catalog, importedQuestions: [], store: store)
        await runtime.process(candidates: [try XCTUnwrap(needed)])
        XCTAssertEqual(center.requests.count, 1)
        _ = try await store.upsertJournal([
            .init(day: answers, question: "Question A", answeredYes: false, notes: nil)
        ], deviceId: Repository.journalDeviceId)
        let partial = try await runtime.journalReminderIfNeeded(candidate, day: day,
            catalog: catalog, importedQuestions: [], store: store)
        XCTAssertNotNil(partial)
        XCTAssertEqual(center.requests.count, 1)
        _ = try await store.upsertJournal([
            .init(day: answers, question: "Quantity B", answeredYes: true, notes: nil, numericValue: 0)
        ], deviceId: Repository.journalDeviceId)
        let complete = try await runtime.journalReminderIfNeeded(candidate, day: day,
            catalog: catalog, importedQuestions: [], store: store)
        XCTAssertNil(complete)
        XCTAssertTrue(center.requests.isEmpty)
        let rows = try await store.notificationRecords()
        XCTAssertEqual(rows.first?.state, .withdrawn)
    }

    func testACompleteYesterdayDoesNotSilenceTheReminderForAnIncompleteToday() async throws {
        let store = try await WhoopStore.inMemory()
        let catalog = catalog(defaults())
        _ = try await store.ensureDefaultCoachingSet(name: "Selected",
            memberships: [membership("Question A"), membership("Quantity B")])
        // The reminder is for the evening of `day`; its answers are stored under the morning after.
        let today = try XCTUnwrap(JournalBehaviorDay.storageKey(forBehaviorKey: day))
        // Yesterday (stored under `day` itself) is completely answered; Today is not started.
        _ = try await store.upsertJournal([
            .init(day: day, question: "Question A", answeredYes: false, notes: nil),
            .init(day: day, question: "Quantity B", answeredYes: true, notes: nil, numericValue: 0)
        ], deviceId: Repository.journalDeviceId)
        let runtime = NotificationCoordinator(center: NotificationCoordinatorTests.Center(), clock: { self.now },
            preferences: { .init(modes: [.journalCheckIn: .notify]) },
            context: { .init(sourceContext: "source", logicalDay: self.day) }, store: { store }, dryRun: { false })
        let candidate = NotificationSchedulePlanner.candidate(group: .journalCheckIn, id: day,
            scheduledAt: now.addingTimeInterval(3600), source: "source", destination: .journal(logicalDay: day), now: now)
        let yesterdayDone = try await runtime.journalReminderIfNeeded(candidate, day: day,
            catalog: catalog, importedQuestions: [], store: store)
        XCTAssertNotNil(yesterdayDone, "A finished Yesterday leaves tonight's check-in still to do")
        // Finishing Today is what silences it.
        _ = try await store.upsertJournal([
            .init(day: today, question: "Question A", answeredYes: true, notes: nil),
            .init(day: today, question: "Quantity B", answeredYes: true, notes: nil, numericValue: 2)
        ], deviceId: Repository.journalDeviceId)
        let todayDone = try await runtime.journalReminderIfNeeded(candidate, day: day,
            catalog: catalog, importedQuestions: [], store: store)
        XCTAssertNil(todayDone)
    }
}
