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
}
