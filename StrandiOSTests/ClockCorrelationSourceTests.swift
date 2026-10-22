import Foundation
import XCTest
@testable import NOOP

final class ClockCorrelationSourceTests: XCTestCase {
    func testOnlyAConnectedMatchingPhysicalTargetCanKeepTheClock() {
        let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        XCTAssertTrue(ClockCorrelation.canRetainReferenceForSourceChange(
            referencePeripheralID: a,
            connectedPeripheralID: a, targetPeripheralID: a, isConnected: true))
        XCTAssertFalse(ClockCorrelation.canRetainReferenceForSourceChange(
            referencePeripheralID: a,
            connectedPeripheralID: a, targetPeripheralID: b, isConnected: true))
        XCTAssertFalse(ClockCorrelation.canRetainReferenceForSourceChange(
            referencePeripheralID: a,
            connectedPeripheralID: a, targetPeripheralID: nil, isConnected: true))
        XCTAssertFalse(ClockCorrelation.canRetainReferenceForSourceChange(
            referencePeripheralID: a,
            connectedPeripheralID: nil, targetPeripheralID: a, isConnected: true))
        XCTAssertFalse(ClockCorrelation.canRetainReferenceForSourceChange(
            referencePeripheralID: a,
            connectedPeripheralID: a, targetPeripheralID: a, isConnected: false))
        XCTAssertFalse(ClockCorrelation.canRetainReferenceForSourceChange(
            referencePeripheralID: b,
            connectedPeripheralID: a, targetPeripheralID: a, isConnected: true))
    }
}
