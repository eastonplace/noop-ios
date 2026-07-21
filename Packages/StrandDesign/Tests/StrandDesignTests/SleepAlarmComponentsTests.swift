import XCTest
@testable import StrandDesign

final class SleepAlarmComponentsTests: XCTestCase {
    func testAsleepByIsWakeMinusWindowMinusNeed() {
        // 6:40 AM wake on the continuous axis (400 + 600 = 1000 minutes), a 30-min smart window, and a
        // 7h50m (470-minute) need -> asleep by 1000 - 30 - 470 = 500.
        XCTAssertEqual(SleepAlarmTime.asleepByMinutes(wakeMinutes: 1000, windowMinutes: 30, needMinutes: 470), 500)
        // Exact-time mode has no window: asleep by = wake - need.
        XCTAssertEqual(SleepAlarmTime.asleepByMinutes(wakeMinutes: 1000, windowMinutes: 0, needMinutes: 480), 520)
    }

    /// T702's explicit alarm need-recompute test: changing the canonical Sleep Need changes the
    /// computed "be asleep by" instant, holding wake/window fixed. A longer need pulls bedtime earlier.
    func testAsleepByRecomputesWhenTheCanonicalNeedChanges() {
        let wake = 6 * 60 + 40 + 1440   // 6:40 AM tomorrow, continuous axis
        let shortNeedBedtime = SleepAlarmTime.asleepByMinutes(wakeMinutes: wake, windowMinutes: 30, needMinutes: 420)
        let longNeedBedtime = SleepAlarmTime.asleepByMinutes(wakeMinutes: wake, windowMinutes: 30, needMinutes: 540)
        XCTAssertGreaterThan(shortNeedBedtime, longNeedBedtime)
        XCTAssertEqual(shortNeedBedtime - longNeedBedtime, 120)
    }

    func testClockFormatsMinutesOfDayAndWrapsPastMidnight() {
        XCTAssertEqual(SleepAlarmTime.clock(6 * 60 + 40), "6:40 AM")
        XCTAssertEqual(SleepAlarmTime.clock(0), "12:00 AM")
        XCTAssertEqual(SleepAlarmTime.clock(12 * 60), "12:00 PM")
        // A continuous-axis minute past 1440 wraps to the correct clock time (tomorrow's 6:40 AM).
        XCTAssertEqual(SleepAlarmTime.clock(24 * 60 + 6 * 60 + 40), "6:40 AM")
    }

    func testDurationPhrasingNeverGoesNegative() {
        XCTAssertEqual(SleepAlarmTime.duration(0), "0 m")
        XCTAssertEqual(SleepAlarmTime.duration(45), "45 m")
        XCTAssertEqual(SleepAlarmTime.duration(60), "1 h")
        XCTAssertEqual(SleepAlarmTime.duration(90), "1 h 30 m")
        XCTAssertEqual(SleepAlarmTime.duration(-10), "0 m")
    }

    func testHoursMinutesSignedFormattingMatchesTheNeedBreakdownCard() {
        XCTAssertEqual(SleepAlarmTime.hoursMinutes(450), "7:30")
        XCTAssertEqual(SleepAlarmTime.hoursMinutes(14, signed: true), "+0:14")
        XCTAssertEqual(SleepAlarmTime.hoursMinutes(0, signed: true), "+0:00")
        XCTAssertEqual(SleepAlarmTime.hoursMinutes(-20, signed: true), "\u{2212}0:20")
    }

    func testNextOccurrenceRollsToTomorrowOnlyWhenTheTimeHasAlreadyPassedToday() {
        // 9:26 PM now, 6:40 AM target -> already passed today, so it's tomorrow.
        XCTAssertEqual(SleepAlarmTime.nextOccurrence(now: 21 * 60 + 26, timeOfDay: 6 * 60 + 40),
                       24 * 60 + 6 * 60 + 40)
        // 1:00 AM now, 6:40 AM target -> still ahead today, no +1440.
        XCTAssertEqual(SleepAlarmTime.nextOccurrence(now: 60, timeOfDay: 6 * 60 + 40), 6 * 60 + 40)
    }

    func testWakeModeAvailability() {
        let available = SleepAlarmWakeMode(id: "goal", title: "Sleep goal", explanation: "x", windowMinutes: 30)
        XCTAssertTrue(available.isAvailable)
        let unavailable = SleepAlarmWakeMode(id: "green", title: "In the green", explanation: "x",
                                             windowMinutes: 30, availability: .unavailable(reason: "no forecast yet"))
        XCTAssertFalse(unavailable.isAvailable)
    }
}
