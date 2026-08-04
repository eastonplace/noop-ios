import XCTest
@testable import NOOP

final class ExternalSurfaceProjectionTests: XCTestCase {
    func testExtremeFiniteRecoveryIsOmittedInsteadOfConvertingToInt() {
        XCTAssertNil(ExternalSurfaceProjection.recoveryValue(.greatestFiniteMagnitude))
        XCTAssertNil(ExternalSurfaceProjection.recoveryValue(-.greatestFiniteMagnitude))
        XCTAssertEqual(ExternalSurfaceProjection.recoveryValue(72.6), 73)
    }

    func testRecoveryConversionRejectsUnrepresentableAndOutOfRangeValues() {
        XCTAssertNil(ExternalSurfaceProjection.recoveryValue(Double(Int.max)))
        XCTAssertNil(ExternalSurfaceProjection.recoveryValue(.infinity))
        XCTAssertNil(ExternalSurfaceProjection.recoveryValue(-0.1))
        XCTAssertNil(ExternalSurfaceProjection.recoveryValue(100.1))
        XCTAssertEqual(ExternalSurfaceProjection.recoveryValue(99.6), 100)
    }

    func testEffortConversionRejectsNonFiniteStoredValues() {
        XCTAssertNil(ExternalSurfaceProjection.effortValue(.nan))
        XCTAssertNil(ExternalSurfaceProjection.effortValue(.infinity))
        XCTAssertNotNil(ExternalSurfaceProjection.effortValue(10))
    }
}
