import XCTest
@testable import NOOP

/// "How was yesterday?" is stored under this morning's key, and "today" under tomorrow's.
final class JournalBehaviorDayTests: XCTestCase {
    private typealias D = JournalBehaviorDay

    func testYesterdayIsStoredUnderTodaysKeyAndTodayUnderTomorrows() {
        XCTAssertEqual(D.yesterdayStorageKey(today: "2026-10-23"), "2026-10-23")
        XCTAssertEqual(D.todayStorageKey(today: "2026-10-23"), "2026-10-24")
    }

    func testTheBehaviourDayIsTheDayBeforeTheStorageKey() {
        XCTAssertEqual(D.behaviorKey(forStorageKey: "2026-10-23"), "2026-10-22")
        XCTAssertEqual(D.storageKey(forBehaviorKey: "2026-10-22"), "2026-10-23")
        XCTAssertNil(D.behaviorKey(forStorageKey: "not a day"))
        XCTAssertNil(D.storageKey(forBehaviorKey: "2026-02-30"))
    }

    func testAnEveningReminderOpensOnThatEveningsBehaviours() throws {
        // The reminder is sent on 22 Oct, about that day. Its answers belong under the morning after.
        let key = try XCTUnwrap(D.storageKey(forBehaviorKey: "2026-10-22"))
        XCTAssertEqual(key, "2026-10-23")
        XCTAssertTrue(D.isSelectable(key, today: "2026-10-22"))
        XCTAssertTrue(D.words(forStorageKey: key, today: "2026-10-22").isToday, "Opened that evening: Today")
        XCTAssertTrue(D.words(forStorageKey: key, today: "2026-10-23").isYesterday, "Opened next morning: Yesterday")
        // Heads-Up's "Log how you feel" opens the same Today.
        XCTAssertEqual(D.todayStorageKey(today: "2026-10-22"), key)
    }

    func testKeysRollOverMonthYearAndLeapDay() {
        XCTAssertEqual(D.storageKey(forBehaviorKey: "2026-10-31"), "2026-11-01")
        XCTAssertEqual(D.storageKey(forBehaviorKey: "2026-12-31"), "2027-01-01")
        XCTAssertEqual(D.behaviorKey(forStorageKey: "2027-01-01"), "2026-12-31")
        XCTAssertEqual(D.behaviorKey(forStorageKey: "2026-11-01"), "2026-10-31")
        XCTAssertEqual(D.storageKey(forBehaviorKey: "2028-02-28"), "2028-02-29")
        XCTAssertEqual(D.storageKey(forBehaviorKey: "2028-02-29"), "2028-03-01")
        XCTAssertEqual(D.storageKey(forBehaviorKey: "2027-02-28"), "2027-03-01")
        XCTAssertEqual(D.behaviorKey(forStorageKey: "2028-03-01"), "2028-02-29")
        XCTAssertEqual(D.todayStorageKey(today: "2026-12-31"), "2027-01-01")
    }

    func testAPickedCalendarDateBecomesTheMorningAfterIt() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let lastDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 9)))
        XCTAssertEqual(D.storageKey(forBehaviorDate: lastDay, calendar: calendar), "2027-01-01")
        let leap = try XCTUnwrap(calendar.date(from: DateComponents(year: 2028, month: 2, day: 28, hour: 23)))
        XCTAssertEqual(D.storageKey(forBehaviorDate: leap, calendar: calendar), "2028-02-29")
        let back = D.behaviorDate(forStorageKey: "2027-01-01", calendar: calendar)
        XCTAssertEqual(back.map { calendar.component(.day, from: $0) }, 31)
        XCTAssertEqual(back.map { calendar.component(.month, from: $0) }, 12)
    }

    func testTheLabelsNameTheBehaviourDayNotTheStorageDay() {
        let today = "2026-10-23"
        XCTAssertEqual(D.label(forStorageKey: "2026-10-24", today: today), "Today")
        XCTAssertEqual(D.label(forStorageKey: "2026-10-23", today: today), "Yesterday")
        XCTAssertFalse(["Today", "Yesterday"].contains(D.label(forStorageKey: "2026-10-22", today: today)),
                       "The day before yesterday is a date, not a name")
        XCTAssertFalse(D.label(forStorageKey: "2026-10-22", today: today).contains("2026"), "Raw keys never reach the screen")
        XCTAssertEqual(D.label(forStorageKey: "junk", today: today), "this day")
    }

    func testTheLabelsAcrossAMonthBoundary() {
        XCTAssertEqual(D.label(forStorageKey: "2026-11-01", today: "2026-11-01"), "Yesterday")
        XCTAssertEqual(D.label(forStorageKey: "2026-11-02", today: "2026-11-01"), "Today")
        XCTAssertEqual(D.label(forStorageKey: "2027-01-01", today: "2027-01-01"), "Yesterday")
        XCTAssertEqual(D.label(forStorageKey: "2027-01-02", today: "2027-01-01"), "Today")
    }

    func testEverySentenceAgreesWithTheDayItIsAbout() {
        let today = "2026-10-23"
        let yesterday = D.words(forStorageKey: "2026-10-23", today: today)
        XCTAssertEqual(yesterday.moodTitle, "How was yesterday?")
        XCTAssertEqual(yesterday.dictationTitle, "Say how yesterday went")
        XCTAssertEqual(yesterday.doneTitle, "Yesterday’s logged")
        XCTAssertEqual(yesterday.repeatTitle, "Same as the day before")
        XCTAssertTrue(yesterday.isYesterday)
        let now = D.words(forStorageKey: "2026-10-24", today: today)
        XCTAssertEqual(now.moodTitle, "How’s today going?")
        XCTAssertEqual(now.dictationTitle, "Say how today’s going")
        XCTAssertEqual(now.doneTitle, "Today’s logged")
        XCTAssertEqual(now.repeatTitle, "Same as yesterday")
        XCTAssertTrue(now.isToday)
        let older = D.words(forStorageKey: "2026-10-20", today: today)
        XCTAssertEqual(older.doneTitle, "Oct 19 logged")
        XCTAssertTrue(older.moodTitle.hasPrefix("How was "))
        XCTAssertFalse(older.isToday || older.isYesterday)
    }

    func testAnyPastDayAndTodayCanBeOpenedButNothingAfter() {
        let today = "2026-10-23"
        XCTAssertTrue(D.isSelectable("2026-10-24", today: today), "Today")
        XCTAssertTrue(D.isSelectable("2026-10-23", today: today))
        XCTAssertTrue(D.isSelectable("2025-01-05", today: today))
        XCTAssertFalse(D.isSelectable("2026-10-25", today: today))
        XCTAssertFalse(D.isSelectable("nonsense", today: today))
    }

    func testTheTwoWeekWindowEndsOnYesterdayOrTodayAndRollsAcrossMonths() {
        let without = D.window(today: "2026-11-05", includesToday: false)
        XCTAssertEqual(without.count, 14)
        XCTAssertEqual(without.first, "2026-10-23")
        XCTAssertEqual(without.last, "2026-11-05")
        let with = D.window(today: "2026-11-05", includesToday: true)
        XCTAssertEqual(with.count, 14)
        XCTAssertEqual(with.last, "2026-11-06")
        XCTAssertEqual(with.first, "2026-10-24")
        XCTAssertEqual(D.window(today: "2027-01-03", includesToday: false).first, "2026-12-21")
        XCTAssertTrue(D.window(includesToday: false, days: 0).isEmpty)
    }

    func testAStreakCountsBackFromYesterdayAndIgnoresAnUnstartedToday() {
        let today = "2026-10-23"
        let logged: Set<String> = ["2026-10-23", "2026-10-22", "2026-10-21", "2026-10-19"]
        XCTAssertEqual(D.currentStreak(logged: logged, today: today), 3)
        XCTAssertEqual(D.currentStreak(logged: logged.union(["2026-10-24"]), today: today), 4, "A logged Today extends it")
        XCTAssertEqual(D.currentStreak(logged: ["2026-10-24"], today: today), 1)
        XCTAssertEqual(D.currentStreak(logged: ["2026-10-21"], today: today), 0, "Yesterday missed: no streak")
        XCTAssertEqual(D.streak(logged: logged, endingAt: "2026-10-21"), 1)
        XCTAssertEqual(D.streak(logged: ["2026-11-01", "2026-10-31", "2026-10-30"], endingAt: "2026-11-01"), 3)
    }
}
