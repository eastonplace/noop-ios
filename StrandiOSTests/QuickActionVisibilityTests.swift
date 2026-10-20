import XCTest
@testable import NOOP

final class QuickActionVisibilityTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "QuickActionVisibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testUpgradeDefaultsShowEveryFixedActionAndPermitRecentActivity() {
        withDefaults { defaults in
            let policy = QuickActionVisibilityPolicy(defaults: defaults)
            XCTAssertEqual(policy.visibleActions, [.journal, .live, .workout, .strength, .intervals, .breathe])
            XCTAssertEqual(policy.recentSport(eligible: "running"), "running")
            XCTAssertNil(policy.recentSport(eligible: nil))
        }
    }

    func testStableAppLocalKeysRoundTripIndependentPermissions() {
        withDefaults { defaults in
            XCTAssertEqual(QuickActionVisibilityID.allCases.map(\.defaultsKey), [
                "quickActions.visible.journal", "quickActions.visible.live", "quickActions.visible.workout",
                "quickActions.visible.strength", "quickActions.visible.intervals", "quickActions.visible.breathe",
            ])
            defaults.set(false, forKey: QuickActionVisibilityID.workout.defaultsKey)
            defaults.set(false, forKey: QuickActionVisibilityID.breathe.defaultsKey)
            defaults.set(false, forKey: QuickActionVisibilityID.recentActivityKey)
            var policy = QuickActionVisibilityPolicy(defaults: defaults)
            XCTAssertEqual(policy.visibleActions, [.journal, .live, .strength, .intervals])
            XCTAssertNil(policy.recentSport(eligible: "running"))
            defaults.set(true, forKey: QuickActionVisibilityID.workout.defaultsKey)
            policy = QuickActionVisibilityPolicy(defaults: defaults)
            XCTAssertTrue(policy.visibleActions.contains(.workout))
            XCTAssertFalse(policy.visibleActions.contains(.breathe))
            XCTAssertFalse(policy.recentActivityEnabled)
        }
    }

    func testEverySelectionPreservesCatalogOrder() {
        let catalog = QuickActionVisibilityID.allCases
        for mask in 0..<(1 << catalog.count) {
            let hidden = Set(catalog.enumerated().compactMap { index, action in
                mask & (1 << index) == 0 ? action : nil
            })
            XCTAssertEqual(QuickActionVisibilityPolicy(hiddenActions: hidden).visibleActions,
                           catalog.filter { !hidden.contains($0) })
        }
    }

    func testRecentActivityIsIndependentOfWorkoutAndStillNeedsRuntimeEligibility() {
        let policy = QuickActionVisibilityPolicy(hiddenActions: Set(QuickActionVisibilityID.allCases))
        XCTAssertEqual(policy.recentSport(eligible: "cycling"), "cycling")
        XCTAssertFalse(policy.isEmpty(eligibleRecentSport: "cycling"))
        XCTAssertTrue(policy.isEmpty(eligibleRecentSport: nil))
        let disabled = QuickActionVisibilityPolicy(hiddenActions: policy.hiddenActions, recentActivityEnabled: false)
        XCTAssertTrue(disabled.isEmpty(eligibleRecentSport: "cycling"))
    }

    func testSettingsHasOneQuickActionsOwnerAndSearchEntry() {
        let rows = SettingsRouteCatalog.rootSections.first { $0.id == .appPreferences }?.routes
        XCTAssertEqual(rows?.filter { $0.id == .quickActions }.count, 1)
        XCTAssertEqual(SettingsRouteCatalog.search("quick actions").map(\.route), [.quickActions])
        XCTAssertEqual(SettingsRouteCatalog.search("recent activity").map(\.route), [.quickActions])
    }
}
