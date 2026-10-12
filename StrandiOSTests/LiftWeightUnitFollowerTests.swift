import XCTest
@testable import NOOP
@testable import ReceiptLiftFeature

/// A unit change made in Settings reaches a running Lift session's Live Activity without reopening Lift: Lift's own view
/// only follows the setting while it is on screen, and Settings is reached by closing it.
@MainActor
final class LiftWeightUnitFollowerTests: XCTestCase {
    private static let suite = "LiftWeightUnitFollowerTests"

    /// A defaults domain of the test's own, emptied before and after.
    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: Self.suite)!
        defaults.removePersistentDomain(forName: Self.suite)
        addTeardownBlock { UserDefaults(suiteName: LiftWeightUnitFollowerTests.suite)?
            .removePersistentDomain(forName: LiftWeightUnitFollowerTests.suite) }
        return defaults
    }

    func testTheUnitIsReadFromTheSettingAndIsMetricUntilThePersonChooses() {
        let defaults = makeDefaults()
        XCTAssertEqual(LiftWeightUnitFollower.unit(in: defaults), .kilograms)
        defaults.set(UnitSystem.imperial.rawValue, forKey: UnitPrefs.systemKey)
        XCTAssertEqual(LiftWeightUnitFollower.unit(in: defaults), .pounds)
        defaults.set("not a unit system", forKey: UnitPrefs.systemKey)
        XCTAssertEqual(LiftWeightUnitFollower.unit(in: defaults), .kilograms)
    }

    func testAChangeToTheSettingIsHandedToLiftWhetherOrNotLiftIsOnScreen() async {
        let defaults = makeDefaults()
        let seen = expectation(description: "Lift is told pounds")
        var units: [LiftWeightUnit] = []
        let follower = LiftWeightUnitFollower(defaults: defaults) { unit in
            units.append(unit)
            if unit == .pounds { seen.fulfill() }
        }
        defaults.set(UnitSystem.imperial.rawValue, forKey: UnitPrefs.systemKey)
        await fulfillment(of: [seen], timeout: 5)
        XCTAssertEqual(units.last, .pounds)
        withExtendedLifetime(follower) {}
    }

    func testTheCoordinatorsStoreFollowsWithoutAViewMounted() async {
        let defaults = makeDefaults()
        // No ReceiptLiftView exists here: this is the long-lived coordinator the host keeps after the sheet is closed.
        let coordinator = ReceiptLiftCoordinator(load: { nil }, save: { _, _ in }, weightUnit: .kilograms)
        XCTAssertEqual(coordinator.store.weightUnit, .kilograms)
        let seen = expectation(description: "the store follows")
        let follower = LiftWeightUnitFollower(defaults: defaults) { unit in
            coordinator.setWeightUnit(unit)
            if coordinator.store.weightUnit == .pounds { seen.fulfill() }
        }
        defaults.set(UnitSystem.imperial.rawValue, forKey: UnitPrefs.systemKey)
        await fulfillment(of: [seen], timeout: 5)
        XCTAssertEqual(coordinator.store.weightUnit, .pounds)
        withExtendedLifetime(follower) {}
    }
}
