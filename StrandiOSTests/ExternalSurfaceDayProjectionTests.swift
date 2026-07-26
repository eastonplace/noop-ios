import XCTest
@testable import NOOP

final class ExternalSurfaceDayProjectionTests: XCTestCase {
    func testRecoveryConversionRejectsUnrepresentableAndOutOfRangeValues() {
        XCTAssertNil(ExternalSurfaceDayProjection.recoveryValue(Double(Int.max)))
        XCTAssertNil(ExternalSurfaceDayProjection.recoveryValue(.infinity))
        XCTAssertNil(ExternalSurfaceDayProjection.recoveryValue(-0.1))
        XCTAssertNil(ExternalSurfaceDayProjection.recoveryValue(100.1))
        XCTAssertEqual(ExternalSurfaceDayProjection.recoveryValue(99.6), 100)
    }

    func testEffortConversionRejectsNonFiniteStoredValues() {
        XCTAssertNil(ExternalSurfaceDayProjection.effortValue(.nan))
        XCTAssertNil(ExternalSurfaceDayProjection.effortValue(.infinity))
        XCTAssertNotNil(ExternalSurfaceDayProjection.effortValue(10))
    }
}
