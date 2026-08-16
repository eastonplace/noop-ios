
import XCTest
@testable import NOOP
#if canImport(MapKit)
import MapKit
#endif

final class GpsRouteReliabilityIssue43Tests: XCTestCase {
    func testNonMonotonicAndDuplicateFixesAreRejected() {
        let filter = TrackFilter(minimumPointDistanceM: 1)
        let first = RawFix(lat: 40.7580, lon: -73.9855, accuracyM: 5, tMs: 1_000)
        let duplicate = RawFix(lat: 40.7580, lon: -73.9855, accuracyM: 5, tMs: 2_000)
        let old = RawFix(lat: 40.7581, lon: -73.9854, accuracyM: 5, tMs: 900)

        XCTAssertNotNil(filter.acceptWithMetadata(first))
        XCTAssertNil(filter.acceptWithMetadata(duplicate))
        XCTAssertNil(filter.acceptWithMetadata(old))
    }

    func testLongGapStartsNewSegmentInsteadOfDrawingABridge() {
        let filter = TrackFilter(segmentGapSeconds: 120)
        let first = RawFix(lat: 40.7580, lon: -73.9855, accuracyM: 5, tMs: 1_000)
        let later = RawFix(lat: 40.7308, lon: -73.9973, accuracyM: 5, tMs: 200_000)

        XCTAssertEqual(filter.acceptWithMetadata(first)?.startsNewSegment, false)
        XCTAssertEqual(filter.acceptWithMetadata(later)?.startsNewSegment, true)
    }

    func testShortIntervalTeleportStillFailsSpeedGate() {
        let filter = TrackFilter(maxSpeedMps: 12)
        _ = filter.acceptWithMetadata(RawFix(
            lat: 40.7580, lon: -73.9855, accuracyM: 5, tMs: 1_000))
        let teleport = filter.acceptWithMetadata(RawFix(
            lat: 40.7308, lon: -73.9973, accuracyM: 5, tMs: 2_000))

        XCTAssertNil(teleport)
    }

    #if canImport(MapKit)
    @MainActor
    func testMapCoordinatorConfiguresOneUnchangedRouteOnce() {
        let identity = WorkoutRouteRenderIdentity(
            segments: [[
                RouteMath.LatLng(40.7580, -73.9855),
                RouteMath.LatLng(40.7582, -73.9852),
            ]],
            showsEndpoints: true
        )
        let coordinator = WorkoutRouteMap.Coordinator()

        XCTAssertTrue(coordinator.accepts(identity))
        XCTAssertFalse(coordinator.accepts(identity))
    }
    #endif
}
