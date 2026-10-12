import XCTest
@testable import NOOP

/// The trend pages open on the number their Today card showed, so the order of sources is pinned here.
final class HealthDailyPickTests: XCTestCase {
    func testCaloriesPreferThePhonesActiveEnergyOverTheStrapEstimate() throws {
        let both = try XCTUnwrap(HealthDailyPick.calories(phoneActiveKcal: 141, strapEstimateKcal: 227))
        XCTAssertEqual(both.value, 141)
        XCTAssertFalse(both.isStrapEstimate)
    }

    func testCaloriesFallBackToTheStrapEstimateAndSayItIsOne() throws {
        let strapOnly = try XCTUnwrap(HealthDailyPick.calories(phoneActiveKcal: nil, strapEstimateKcal: 227))
        XCTAssertEqual(strapOnly.value, 227)
        XCTAssertTrue(strapOnly.isStrapEstimate)
    }

    func testCaloriesWithNoSourceReadNothing() {
        XCTAssertNil(HealthDailyPick.calories(phoneActiveKcal: nil, strapEstimateKcal: nil))
    }

    func testAZeroFromThePhoneIsStillThePhonesNumber() throws {
        let zero = try XCTUnwrap(HealthDailyPick.calories(phoneActiveKcal: 0, strapEstimateKcal: 227))
        XCTAssertEqual(zero.value, 0)
        XCTAssertFalse(zero.isStrapEstimate)
    }

    func testStepsTakeTheStrapThenThePhoneThenTheEstimate() {
        XCTAssertEqual(HealthDailyPick.steps(strap: 5000, phone: 6000, estimate: 7000), 5000)
        XCTAssertEqual(HealthDailyPick.steps(strap: nil, phone: 6000, estimate: 7000), 6000)
        XCTAssertEqual(HealthDailyPick.steps(strap: nil, phone: nil, estimate: 7000), 7000)
        XCTAssertNil(HealthDailyPick.steps(strap: nil, phone: nil, estimate: nil))
    }
}
