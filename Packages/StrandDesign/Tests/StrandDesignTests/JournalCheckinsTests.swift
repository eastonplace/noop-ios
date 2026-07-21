import XCTest
@testable import StrandDesign

final class JournalCheckinsTests: XCTestCase {
    func testTriStateRetapClearsAndOppositeTapReplaces() {
        XCTAssertEqual(JournalTriStateSelection.next(current: nil, tapped: true), true)
        XCTAssertNil(JournalTriStateSelection.next(current: true, tapped: true))
        XCTAssertEqual(JournalTriStateSelection.next(current: true, tapped: false), false)
    }

    func testStreakCountsBackFromNewestLoggedDay() {
        XCTAssertEqual(JournalStreakSummary.currentStreak(in: [true, false, true, true, true]), 3)
        XCTAssertEqual(JournalStreakSummary.currentStreak(in: [true, true, false]), 0)
        XCTAssertEqual(JournalStreakSummary.currentStreak(in: []), 0)
    }

    func testStreakWindowKeepsRealHistoryAndPadsOnlyAsMissing() {
        XCTAssertEqual(
            JournalStreakSummary.window(loggedDays: ["2026-07-18", "2026-07-20"],
                                        endingOn: "2026-07-20", days: 3),
            [true, false, true]
        )
        XCTAssertEqual(
            JournalStreakSummary.window(loggedDays: [], endingOn: "2026-07-20", days: 3),
            [false, false, false]
        )
    }
}
