import CoreLocation
import XCTest
@testable import NOOP

/// What the setup page says about the GPS, from the permission and the freshest fix.
final class GpsReadinessTests: XCTestCase {
    private func make(_ status: CLAuthorizationStatus, services: Bool = true, reduced: Bool = false, accuracy: Double? = nil,
                      age: TimeInterval? = nil) -> GpsReadiness {
        GpsReadiness.make(status: status, servicesEnabled: services, reducedAccuracy: reduced, accuracy: accuracy, fixAge: age)
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

    /// With Precise Location off every fix is kilometres wide and never "good": the page says so instead of "Locating…" for ever.
    func testPreciseLocationOffIsApproximateNotLocatingForEver() {
        XCTAssertEqual(make(.authorizedWhenInUse, reduced: true), .approximate)
        XCTAssertEqual(make(.authorizedAlways, reduced: true, accuracy: 4_000, age: 1), .approximate)
        XCTAssertEqual(make(.authorizedWhenInUse, reduced: false), .locating)
        XCTAssertTrue(GpsReadiness.approximate.canRecordRoute, "location is allowed; the route is just a rough one")
    }

    func testAnyRefusalOutranksReducedAccuracy() {
        XCTAssertEqual(make(.denied, reduced: true), .off)
        XCTAssertEqual(make(.notDetermined, reduced: true), .allowNeeded)
        XCTAssertEqual(make(.restricted, reduced: true), .restricted)
        XCTAssertEqual(make(.authorizedWhenInUse, services: false, reduced: true), .off)
    }

    /// The accuracy is told in the person's unit: metres, or feet for imperial (20 m is about 66 ft).
    func testTheLockedAccuracyFollowsTheUnitSetting() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(GpsReadiness.accuracyText(meters: 6, imperial: false, locale: en), "±6 m")
        XCTAssertEqual(GpsReadiness.accuracyText(meters: 20, imperial: true, locale: en), "±66 ft")
        XCTAssertTrue(GpsReadiness.accuracyText(meters: 6, imperial: true, locale: en).hasSuffix("ft"))
    }
}
