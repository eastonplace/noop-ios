import XCTest
@testable import NOOP

#if os(iOS)
@MainActor
final class DeviceActionsTests: XCTestCase {
    func testLegacyRawValuesStillDecodeAfterMacAppRemoval() {
        XCTAssertEqual(DeviceActionKind(rawValue: "none"), .none)
        XCTAssertEqual(DeviceActionKind(rawValue: "lockScreen"), .lockScreen)
        XCTAssertEqual(DeviceActionKind(rawValue: "buzzBack"), .buzzBack)
        XCTAssertEqual(DeviceActionKind(rawValue: "markMoment"), .markMoment)
        XCTAssertEqual(DeviceActionKind(rawValue: "sleepMark"), .sleepMark)
        XCTAssertEqual(DeviceActionKind(rawValue: "hapticClock"), .hapticClock)
        XCTAssertEqual(DeviceActionKind(rawValue: "runShortcut"), .runShortcut)
    }

    func testIPhoneNeverClaimsItCanLockTheDevice() {
        XCTAssertFalse(DeviceActions.lockScreen())
    }
}
#endif
