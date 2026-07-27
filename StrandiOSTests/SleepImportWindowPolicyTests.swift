import XCTest
import WhoopProtocol
@testable import NOOP

final class SleepImportWindowPolicyTests: XCTestCase {
    func testBoundaryDurationsMatchSharedSleepPolicy() {
        let start = 1_800_000_000

        XCTAssertFalse(SleepImportWindowPolicy.accepts(
            start: start,
            end: start + SleepSessionWindow.minimumDurationSeconds - 1))
        XCTAssertTrue(SleepImportWindowPolicy.accepts(
            start: start,
            end: start + SleepSessionWindow.minimumDurationSeconds))
        XCTAssertTrue(SleepImportWindowPolicy.accepts(
            start: start,
            end: start + SleepSessionWindow.maximumDurationSeconds))
        XCTAssertFalse(SleepImportWindowPolicy.accepts(
            start: start,
            end: start + SleepSessionWindow.maximumDurationSeconds + 1))
    }

    func testInvalidAndOverflowingWindowsFailClosed() {
        XCTAssertFalse(SleepImportWindowPolicy.accepts(start: 10, end: 10))
        XCTAssertFalse(SleepImportWindowPolicy.accepts(start: 11, end: 10))
        XCTAssertFalse(SleepImportWindowPolicy.accepts(start: Int.min, end: Int.max))
    }

    func testDateConversionRejectsExtremeDatesAndReturnsExactValidSeconds() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(8 * 3_600)
        let accepted = try XCTUnwrap(SleepImportWindowPolicy.acceptedUnixSeconds(start: start, end: end))
        XCTAssertEqual(accepted.start, 1_800_000_000)
        XCTAssertEqual(accepted.end, 1_800_028_800)

        let extreme = Date(timeIntervalSince1970: Double(Int.max))
        XCTAssertNil(SleepImportWindowPolicy.acceptedUnixSeconds(start: start, end: extreme))
    }
}
