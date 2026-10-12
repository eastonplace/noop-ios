import XCTest
@testable import NOOP

/// The body-clock headline reads minutes below an hour and hours and minutes from an hour up.
@MainActor
final class BodyClockCopyTests: XCTestCase {
    func testAnHourOrMoreReadsInHours() {
        XCTAssertEqual(BodyClockCard.durationText(minutes: 194), "3 h 14 min")
        XCTAssertEqual(BodyClockCard.durationText(minutes: 180), "3 h")
        XCTAssertEqual(BodyClockCard.durationText(minutes: 60), "1 h")
        XCTAssertEqual(BodyClockCard.durationText(minutes: 61), "1 h 1 min")
    }

    func testHeadlineChoosesMinutesOrHoursAndTheDirection() {
        XCTAssertEqual(BodyClockCard.offsetTitle(offsetMinutes: -194, unreadable: false),
                       "About 3 h 14 min earlier than your schedule")
        XCTAssertEqual(BodyClockCard.offsetTitle(offsetMinutes: 125, unreadable: false),
                       "About 2 h 5 min later than your schedule")
        XCTAssertEqual(BodyClockCard.offsetTitle(offsetMinutes: -45, unreadable: false),
                       "About 45 min earlier than your schedule")
        XCTAssertEqual(BodyClockCard.offsetTitle(offsetMinutes: 59.6, unreadable: false),
                       "About 1 h later than your schedule")
    }

    func testInSyncAndUnreadable() {
        XCTAssertEqual(BodyClockCard.offsetTitle(offsetMinutes: 20, unreadable: false),
                       "About in sync with your schedule")
        XCTAssertEqual(BodyClockCard.offsetTitle(offsetMinutes: 300, unreadable: true), "Hard to read right now")
    }
}
