import CoreLocation
import XCTest
@testable import NOOP

@MainActor
final class GpsAvailabilityTests: XCTestCase {
    private final class StubLocationManager: CLLocationManager {
        var status: CLAuthorizationStatus = .notDetermined
        override var authorizationStatus: CLAuthorizationStatus { status }
        override func startUpdatingLocation() {}
        override func stopUpdatingLocation() {}
        override func requestWhenInUseAuthorization() {}
        override class func locationServicesEnabled() -> Bool { true }
    }

    // MARK: The permission, as a start screen says it

    func testOnlyAnAuthorisedPermissionIsReady() {
        XCTAssertEqual(GpsAvailability.of(status: .authorizedWhenInUse), .ready)
        XCTAssertEqual(GpsAvailability.of(status: .authorizedAlways), .ready)
    }

    func testBeforeThePersonHasAnsweredNothingIsPromised() {
        XCTAssertEqual(GpsAvailability.of(status: .notDetermined), .willAsk)
    }

    func testRefusedAndRestrictedAreOffAndOnlyTheFirstCanBeChangedFromSettings() {
        XCTAssertEqual(GpsAvailability.of(status: .denied), .denied)
        XCTAssertEqual(GpsAvailability.of(status: .restricted), .restricted)
    }

    // MARK: The recorder keeps it current

    func testTheRecorderStartsUndeterminedAndFollowsTheAnswer() {
        let manager = StubLocationManager()
        let recorder = GpsWorkoutRecorder(manager: manager)
        XCTAssertEqual(recorder.availability, .willAsk)

        manager.status = .authorizedWhenInUse
        recorder.locationManagerDidChangeAuthorization(manager)
        XCTAssertEqual(recorder.availability, .ready)

        manager.status = .denied
        recorder.locationManagerDidChangeAuthorization(manager)
        XCTAssertEqual(recorder.availability, .denied)
    }

    func testReturningFromSettingsPicksUpAChangeTheCallbackMissed() {
        let manager = StubLocationManager()
        manager.status = .denied
        let recorder = GpsWorkoutRecorder(manager: manager)
        XCTAssertEqual(recorder.availability, .denied)

        manager.status = .authorizedWhenInUse
        recorder.refreshAvailability()
        XCTAssertEqual(recorder.availability, .ready)
    }
}
