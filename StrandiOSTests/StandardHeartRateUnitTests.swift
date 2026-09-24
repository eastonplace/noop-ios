import XCTest
import WhoopProtocol
@testable import NOOP

final class StandardHeartRateUnitTests: XCTestCase {
    func testWhoopFiveStandardWordsAreMilliseconds() throws {
        let payload: [UInt8] = [0x10, 60, 0x00, 0x04, 0x20, 0x03]
        let whoop5 = try XCTUnwrap(StandardHeartRate.parse(payload, family: .whoop5))
        XCTAssertEqual(whoop5.rr, [1024, 800])
        let generic = try XCTUnwrap(StandardHeartRate.parse(payload))
        XCTAssertEqual(generic.rr, [1000, 781])
        XCTAssertEqual(StandardHeartRate.parse(payload, family: .whoop4)?.rr, generic.rr)
    }
}
