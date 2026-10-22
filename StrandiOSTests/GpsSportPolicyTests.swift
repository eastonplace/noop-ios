import CoreLocation
import XCTest
@testable import NOOP

/// Synthetic route replay only. The manager never opens the device location stream.
@MainActor
final class GpsSportPolicyTests: XCTestCase {
    private final class LocationManager: CLLocationManager {
        override var authorizationStatus: CLAuthorizationStatus { .authorizedWhenInUse }
        override var accuracyAuthorization: CLAccuracyAuthorization { .fullAccuracy }
        override func startUpdatingLocation() {}
        override func stopUpdatingLocation() {}
    }

    private let startMs: Int64 = 1_700_000_000_000

    private func location(meters: Double, second: Int, accuracy: Double = 5) -> CLLocation {
        // Northbound equatorial arc: 111194.9266 metres per latitude degree.
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: meters / 111_194.9266, longitude: 0),
                   altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
                   timestamp: Date(timeIntervalSince1970: Double(startMs) / 1000 + Double(second)))
    }

    private func snapshot(policy: String) throws -> ActiveGpsWorkoutPersistence.Snapshot {
        let empty = ActiveGpsWorkoutPersistence.Snapshot(
            sessionID: UUID(), workoutStartMs: startMs, segments: [], distanceM: 0,
            rawFixCount: 0, recordingWasActive: true, hadTerminatedGap: false)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(empty)) as? [String: Any])
        // An additive field lets this test compile and expose behavior on the pre-fix decoder too.
        json["filterPolicy"] = policy
        return try JSONDecoder().decode(ActiveGpsWorkoutPersistence.Snapshot.self,
                                       from: JSONSerialization.data(withJSONObject: json))
    }

    private func recorder(policy: String) throws -> (GpsWorkoutRecorder, LocationManager) {
        let manager = LocationManager()
        let recorder = GpsWorkoutRecorder(manager: manager, makeBackgroundActivity: { nil })
        recorder.restore(try snapshot(policy: policy))
        return (recorder, manager)
    }

    private func deliver(_ recorder: GpsWorkoutRecorder, _ manager: LocationManager, _ fixes: [CLLocation]) {
        recorder.locationManager(manager, didUpdateLocations: fixes)
    }

    func testFastCyclingAndSnowTravelRetainsNineKilometers() throws {
        for policy in ["cycling", "snow"] {
            let (recorder, manager) = try recorder(policy: policy)
            defer { recorder.stop() }
            deliver(recorder, manager, (0...600).map { location(meters: Double($0) * 15, second: $0) })
            XCTAssertEqual(recorder.pointCount, 601, policy)
            XCTAssertEqual(recorder.routeSegments.count, 1, policy)
            XCTAssertEqual(recorder.distanceM, 9_000, accuracy: 0.01, policy)
        }
    }

    func testFastPoliciesStillRejectTeleportsAndPoorAccuracy() throws {
        for policy in ["cycling", "snow"] {
            let (recorder, manager) = try recorder(policy: policy)
            defer { recorder.stop() }
            deliver(recorder, manager, [location(meters: 0, second: 0),
                                        location(meters: 15, second: 1),
                                        location(meters: 500, second: 2),
                                        location(meters: 30, second: 2, accuracy: 80),
                                        location(meters: 30, second: 2, accuracy: -1),
                                        location(meters: 30, second: 2)])
            XCTAssertEqual(recorder.pointCount, 3, policy)
            XCTAssertEqual(recorder.distanceM, 30, accuracy: 0.01, policy)
        }
    }

    func testSnowAllowsFastDescentThatExceedsCyclingCeiling() throws {
        let (snow, snowManager) = try recorder(policy: "snow")
        let (cycling, cyclingManager) = try recorder(policy: "cycling")
        defer { snow.stop(); cycling.stop() }
        let fixes = [location(meters: 0, second: 0), location(meters: 35, second: 1)]
        deliver(snow, snowManager, fixes)
        deliver(cycling, cyclingManager, fixes)
        XCTAssertEqual(snow.distanceM, 35, accuracy: 0.01)
        XCTAssertEqual(cycling.distanceM, 0)
    }

    func testAbruptPreciseAccelerationIsRejectedBelowSpeedCeiling() throws {
        let (recorder, manager) = try recorder(policy: "standard")
        defer { recorder.stop() }
        deliver(recorder, manager, [location(meters: 0, second: 0, accuracy: 0.1),
                                    location(meters: 2, second: 1, accuracy: 0.1),
                                    location(meters: 13, second: 2, accuracy: 0.1),
                                    location(meters: 6, second: 3, accuracy: 0.1)])
        XCTAssertEqual(recorder.pointCount, 3)
        XCTAssertEqual(recorder.distanceM, 6, accuracy: 0.01)
    }

    func testNonFiniteAccuracyCannotSeedFilter() {
        let filter = TrackFilter()
        XCTAssertNil(filter.accept(RawFix(lat: 0, lon: 0, accuracyM: .nan, tMs: startMs)))
        XCTAssertNil(filter.accept(RawFix(lat: 0, lon: 0, accuracyM: .infinity, tMs: startMs)))
    }

    func testStandardPolicyStillRejectsFifteenMetersPerSecond() throws {
        let (recorder, manager) = try recorder(policy: "standard")
        defer { recorder.stop() }
        deliver(recorder, manager, [location(meters: 0, second: 0), location(meters: 15, second: 1)])
        XCTAssertEqual(recorder.pointCount, 1)
        XCTAssertEqual(recorder.distanceM, 0)
    }

    func testFastPoliciesKeepSubMeterDriftOutOfDistance() throws {
        let (recorder, manager) = try recorder(policy: "cycling")
        defer { recorder.stop() }
        deliver(recorder, manager, (0...60).map { location(meters: Double($0 % 2) * 0.4, second: $0) })
        XCTAssertEqual(recorder.pointCount, 1)
        XCTAssertEqual(recorder.distanceM, 0)
    }

    func testPauseResumeRetainsFastPolicyWithoutCountingPausedTravel() throws {
        let (recorder, manager) = try recorder(policy: "cycling")
        defer { recorder.stop() }
        deliver(recorder, manager, [location(meters: 0, second: 0), location(meters: 15, second: 1)])
        recorder.setPaused(true)
        deliver(recorder, manager, [location(meters: 500, second: 2)])
        recorder.setPaused(false)
        deliver(recorder, manager, [location(meters: 1_000, second: 3), location(meters: 1_015, second: 4)])
        XCTAssertEqual(recorder.routeSegments.map(\.count), [2, 2])
        XCTAssertEqual(recorder.distanceM, 30, accuracy: 0.01)
    }

    func testJournalRestoreKeepsPolicyAndDistanceButSeparatesTerminationGap() throws {
        let (recorder, manager) = try recorder(policy: "snow")
        defer { recorder.stop() }
        var checkpoints: [ActiveGpsWorkoutPersistence.Checkpoint] = []
        recorder.onCheckpoint = { checkpoints.append($0) }
        deliver(recorder, manager, [location(meters: 0, second: 0), location(meters: 20, second: 1)])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "GpsSportPolicyTests.\(UUID())"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ActiveGpsWorkoutPersistence.JournalWriter(defaults: defaults, directory: directory)
        XCTAssertTrue(writer.store(try XCTUnwrap(checkpoints.last), synchronously: true))
        let restored = try XCTUnwrap(writer.load())
        let nextManager = LocationManager()
        let next = GpsWorkoutRecorder(manager: nextManager, makeBackgroundActivity: { nil })
        defer { next.stop() }
        next.restore(restored)
        deliver(next, nextManager, [location(meters: 10_000, second: 2), location(meters: 10_020, second: 3)])
        XCTAssertEqual(next.routeSegments.map(\.count), [2, 2])
        XCTAssertEqual(next.distanceM, 40, accuracy: 0.01)
    }

    func testLongGapNeverAddsMissingTravelUnderFastPolicy() throws {
        let (recorder, manager) = try recorder(policy: "snow")
        defer { recorder.stop() }
        deliver(recorder, manager, [location(meters: 0, second: 0), location(meters: 20, second: 1),
                                    location(meters: 10_000, second: 122), location(meters: 10_020, second: 123)])
        XCTAssertEqual(recorder.routeSegments.map(\.count), [2, 2])
        XCTAssertEqual(recorder.distanceM, 40, accuracy: 0.01)
    }
}
