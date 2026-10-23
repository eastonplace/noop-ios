import XCTest
@testable import StrandImport

final class ActivityGeodesicSafetyTests: XCTestCase {
    func testAntipodalCoordinatesProduceFiniteHalfEarthDistances() {
        // Valid coordinates can round the haversine intermediate just above one. A real route
        // with an erroneous but in-range GPS fix must not publish a NaN distance.
        var nonFiniteCount = 0
        var largestError = 0.0
        let halfCircumference = Double.pi * 6_371_000
        for index in 1..<900 {
            let latitude = Double(index) / 10
            let distance = ActivityFileImporter.haversineMeters(
                RoutePoint(lat: -latitude, lon: 0), RoutePoint(lat: latitude, lon: 180))
            if distance.isFinite {
                largestError = max(largestError, abs(distance - halfCircumference))
            } else {
                nonFiniteCount += 1
            }
        }
        XCTAssertEqual(nonFiniteCount, 0)
        XCTAssertLessThan(largestError, 1)
    }
}
