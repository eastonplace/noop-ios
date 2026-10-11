import XCTest
@testable import NOOP
import StrandDesign

/// Rest, steady and push follow the wearer's maximum heart rate: the profile's override, else the age estimate.
final class PersonalHRZonesTests: XCTestCase {
    func testTheMaximumIsTheOverrideWhenSetElseTheAgeEstimate() {
        XCTAssertEqual(ProfileStore.hrMax(age: 30, override: 200), 200)
        XCTAssertEqual(ProfileStore.hrMax(age: 30, override: 0), 187)
        XCTAssertEqual(ProfileStore.hrMax(age: 40, override: 0), 180)
        XCTAssertEqual(ProfileStore.hrMax(age: 40, override: -5), 180, "a negative override is no override")
    }

    func testTheZonesFollowTheEstimateAtTheBoundaries() {
        let zones = ProfileStore.hrZoneThresholds(override: 0, age: 30)   // maximum 187
        XCTAssertEqual([93, 94, 130, 131].map { zones.zone(for: Double($0)) }, [0, 1, 1, 2])
    }

    func testAnOverrideMovesTheZones() {
        let zones = ProfileStore.hrZoneThresholds(override: 200, age: 30)
        XCTAssertEqual([99, 100, 139, 140].map { zones.zone(for: Double($0)) }, [0, 1, 1, 2])
        XCTAssertEqual(zones.steadyStartBPM, 100)
        XCTAssertEqual(zones.pushStartBPM, 140)
    }

    func testAnAbsurdOverrideFallsBackToTheFixedSplit() {
        XCTAssertEqual(ProfileStore.hrZoneThresholds(override: 30, age: 30), .default)
        XCTAssertEqual(ProfileStore.hrZoneThresholds(override: 300, age: 30), .default)
    }
}
