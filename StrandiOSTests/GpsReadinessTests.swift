import CoreLocation
import XCTest
@testable import NOOP

/// What the setup page says about the GPS, from the permission and the freshest fix.
final class GpsReadinessTests: XCTestCase {
    private func make(_ status: CLAuthorizationStatus, services: Bool = true, accuracy: Double? = nil,
                      age: TimeInterval? = nil) -> GpsReadiness {
        GpsReadiness.make(status: status, servicesEnabled: services, accuracy: accuracy, fixAge: age)
    }

    func testNotAskedYetOffersToAsk() {
        XCTAssertEqual(make(.notDetermined), .allowNeeded)
    }

    func testDeniedAndDeviceWideOffBothSayLocationIsOff() {
        XCTAssertEqual(make(.denied), .off)
        XCTAssertEqual(make(.authorizedWhenInUse, services: false, accuracy: 5, age: 1), .off)
        XCTAssertEqual(make(.notDetermined, services: false), .off)
    }

    func testRestrictedIsItsOwnState() {
        XCTAssertEqual(make(.restricted), .restricted)
    }

    func testAllowedWithoutAGoodFreshFixIsLocating() {
        XCTAssertEqual(make(.authorizedWhenInUse), .locating)
        XCTAssertEqual(make(.authorizedWhenInUse, accuracy: 35, age: 1), .locating, "35 m is not good enough")
        XCTAssertEqual(make(.authorizedAlways, accuracy: -1, age: 1), .locating, "a negative accuracy is an invalid fix")
        XCTAssertEqual(make(.authorizedWhenInUse, accuracy: 5, age: 60), .locating, "a minute-old fix says nothing about now")
    }

    func testAGoodFreshFixIsLockedWithItsAccuracyInWholeMetres() {
        XCTAssertEqual(make(.authorizedWhenInUse, accuracy: 5.6, age: 2), .locked(accuracyMeters: 6))
        XCTAssertEqual(make(.authorizedAlways, accuracy: 20, age: 20), .locked(accuracyMeters: 20), "the thresholds are inclusive")
        XCTAssertEqual(make(.authorizedAlways, accuracy: 20.4, age: 1), .locating)
    }

    func testOnlyARefusalMeansNoRoute() {
        XCTAssertTrue(GpsReadiness.allowNeeded.canRecordRoute, "starting asks once")
        XCTAssertTrue(GpsReadiness.locating.canRecordRoute)
        XCTAssertTrue(GpsReadiness.locked(accuracyMeters: 4).canRecordRoute)
        XCTAssertFalse(GpsReadiness.off.canRecordRoute)
        XCTAssertFalse(GpsReadiness.restricted.canRecordRoute)
    }
}
