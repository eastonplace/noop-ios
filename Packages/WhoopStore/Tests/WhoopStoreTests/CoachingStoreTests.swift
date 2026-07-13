import XCTest
@testable import WhoopStore

final class CoachingStoreTests: XCTestCase {
    func testDefaultSetAndMembershipPreferencesRoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("coachingBehaviorSet"))
        XCTAssertTrue(tables.contains("coachingBehaviorMembership"))

        let seed = [
            CoachingBehaviorMembership(setId: "daily-fundamentals", canonicalQuestion: "Canonical A",
                                       coachingGroup: "Fuel", sortIndex: 0,
                                       isActive: true, isQuickAdd: true),
            CoachingBehaviorMembership(setId: "daily-fundamentals", canonicalQuestion: "Canonical B",
                                       coachingGroup: "Sleep setup", sortIndex: 1,
                                       isActive: true, isQuickAdd: false),
        ]
        let set = try await store.ensureDefaultCoachingSet(name: "Daily fundamentals", memberships: seed)
        XCTAssertEqual(set.id, "daily-fundamentals")

        var rows = try await store.coachingMemberships(setId: set.id)
        XCTAssertEqual(rows.map(\.canonicalQuestion), ["Canonical A", "Canonical B"])

        try await store.upsertCoachingMemberships([
            CoachingBehaviorMembership(setId: set.id, canonicalQuestion: "Canonical A",
                                       coachingGroup: "Fuel", sortIndex: 1,
                                       isActive: false, isQuickAdd: false),
            CoachingBehaviorMembership(setId: set.id, canonicalQuestion: "Canonical B",
                                       coachingGroup: "Sleep setup", sortIndex: 0,
                                       isActive: true, isQuickAdd: true),
        ])
        rows = try await store.coachingMemberships(setId: set.id)
        XCTAssertEqual(rows.map(\.canonicalQuestion), ["Canonical B", "Canonical A"])
        XCTAssertTrue(rows[0].isQuickAdd)
        XCTAssertFalse(rows[1].isActive)
    }

    func testEnsureDoesNotResetExistingPreferences() async throws {
        let store = try await WhoopStore.inMemory()
        let initial = CoachingBehaviorMembership(setId: "daily-fundamentals", canonicalQuestion: "Canonical",
                                                 coachingGroup: "Fuel", sortIndex: 0,
                                                 isActive: true, isQuickAdd: true)
        let set = try await store.ensureDefaultCoachingSet(name: "Daily fundamentals", memberships: [initial])
        try await store.upsertCoachingMemberships([
            CoachingBehaviorMembership(setId: set.id, canonicalQuestion: "Canonical",
                                       coachingGroup: "Fuel", sortIndex: 4,
                                       isActive: false, isQuickAdd: false),
        ])
        _ = try await store.ensureDefaultCoachingSet(name: "Daily fundamentals", memberships: [initial])
        let persisted = try await store.coachingMemberships(setId: set.id)
        let row = try XCTUnwrap(persisted.first)
        XCTAssertEqual(row.sortIndex, 4)
        XCTAssertFalse(row.isActive)
        XCTAssertFalse(row.isQuickAdd)
    }

    func testStackConfigurationAndUseProvenanceRoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("coachingStack"))
        XCTAssertTrue(tables.contains("coachingStackItem"))
        XCTAssertTrue(tables.contains("coachingStackUse"))

        let stack = CoachingStack(id: "evening", name: "Evening recovery",
                                  description: "Wind down", scheduleLabel: "Daily",
                                  isActive: true, notes: nil, sortIndex: 0)
        let seedItems = [
            CoachingStackItem(stackId: stack.id, canonicalQuestion: "Did you take magnesium?",
                              dose: 1, unit: "dose", sortIndex: 0),
            CoachingStackItem(stackId: stack.id, canonicalQuestion: "Did you use a sauna?",
                              dose: 10, unit: "min", sortIndex: 1),
        ]
        _ = try await store.ensureDefaultCoachingStack(stack, items: seedItems)
        let initialStacks = try await store.coachingStacks()
        let initialItems = try await store.coachingStackItems(stackId: stack.id)
        XCTAssertEqual(initialStacks, [stack])
        XCTAssertEqual(initialItems, seedItems)

        // A subsequent default seed must not overwrite user state.
        try await store.updateCoachingStack(id: stack.id, isActive: false, notes: "Paused for travel")
        _ = try await store.ensureDefaultCoachingStack(stack, items: seedItems)
        let storedStacks = try await store.coachingStacks()
        let persisted = try XCTUnwrap(storedStacks.first)
        XCTAssertFalse(persisted.isActive)
        XCTAssertEqual(persisted.notes, "Paused for travel")

        let use = try await store.logCoachingStackUse(stackId: stack.id, day: "2026-07-13",
                                                      notes: "Felt good", skipped: false,
                                                      id: "use-1", loggedAt: 123)
        let uses = try await store.coachingStackUses(stackId: stack.id)
        XCTAssertEqual(uses, [use])
    }
}
