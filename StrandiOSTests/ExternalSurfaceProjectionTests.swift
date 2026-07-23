import XCTest
@testable import NOOP

final class ExternalSurfaceProjectionTests: XCTestCase {
    func testExtremeFiniteRecoveryIsOmittedInsteadOfConvertingToInt() {
        XCTAssertNil(ExternalSurfaceDayProjection.recoveryValue(.greatestFiniteMagnitude))
        XCTAssertNil(ExternalSurfaceDayProjection.recoveryValue(-.greatestFiniteMagnitude))
        XCTAssertEqual(ExternalSurfaceDayProjection.recoveryValue(72.6), 73)
    }
}
