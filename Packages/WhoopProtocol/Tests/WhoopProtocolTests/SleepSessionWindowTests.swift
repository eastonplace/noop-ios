import XCTest
@testable import WhoopProtocol

final class SleepSessionWindowTests: XCTestCase {
    func testStrictScoringWindowIncludesDeclaredDurationEdges() {
        let start = 1_000_000

        XCTAssertTrue(SleepSessionWindow.isValid(
            start: start,
            end: start + SleepSessionWindow.minimumDurationSeconds))
        XCTAssertTrue(SleepSessionWindow.isValid(
            start: start,
            end: start + SleepSessionWindow.maximumDurationSeconds))
        XCTAssertFalse(SleepSessionWindow.isValid(
            start: start,
            end: start + SleepSessionWindow.minimumDurationSeconds - 1))
        XCTAssertFalse(SleepSessionWindow.isValid(
            start: start,
            end: start + SleepSessionWindow.maximumDurationSeconds + 1))
    }

    func testPlausibleProviderBoundaryPreservesShortFragmentsButNotOverlongWindows() {
        let start = 1_000_000

        XCTAssertTrue(SleepSessionWindow.hasPlausibleBounds(start: start, end: start + 1),
                      "a positive short provider fragment remains available for repair and diagnostics")
        XCTAssertFalse(SleepSessionWindow.isValid(start: start, end: start + 1),
                       "cache preservation does not admit the fragment into scoring")
        XCTAssertTrue(SleepSessionWindow.hasPlausibleBounds(
            start: start,
            end: start + SleepSessionWindow.maximumDurationSeconds))
        XCTAssertFalse(SleepSessionWindow.hasPlausibleBounds(
            start: start,
            end: start + SleepSessionWindow.maximumDurationSeconds + 1))
    }

    func testInvalidArithmeticFailsClosed() {
        XCTAssertFalse(SleepSessionWindow.hasPlausibleBounds(start: 5, end: 5))
        XCTAssertFalse(SleepSessionWindow.hasPlausibleBounds(start: 6, end: 5))
        XCTAssertFalse(SleepSessionWindow.hasPlausibleBounds(start: Int.min, end: Int.max))
        XCTAssertFalse(SleepSessionWindow.isValid(start: Int.min, end: Int.max))
    }
}
