import XCTest
@testable import StrandAnalytics

/// N2-3: import-only Charge (Apple Health, Oura, Fitbit, Garmin, Health Connect) scored in one pass over the
/// whole history (DL-12), with a baseline that reaches back before the scoring window (DL-04).
final class WatchRecoveryHistoryTests: XCTestCase {

    private func key(_ i: Int) -> String {
        keyFormatter.string(from: Date(timeIntervalSince1970: 1_767_225_600 + TimeInterval(i) * 86_400))  // 2026-01-01
    }

    /// Gregorian POSIX, like production's key parsing, so the keys don't follow the machine's calendar.
    private let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func history(_ n: Int) -> [WatchRecovery.Day] {
        (0..<n).map { i in
            WatchRecovery.Day(day: key(i), sdnn: i % 6 == 2 ? nil : 40 + Double(i % 7) * 2.5,
                              rhr: i % 5 == 4 ? nil : 50 + i % 4)
        }
    }

    /// The one-pass scorer equals the per-day re-fold it replaces (no recalibration).
    func testOnePassMatchesThePerDayRefold() {
        let days = history(60)
        let scored = WatchRecovery.scoreHistory(days)
        XCTAssertEqual(scored.map(\.day), days.map(\.day))
        for (i, item) in scored.enumerated() {
            let prior = days[..<i]
            let expected = WatchRecovery.compute(todaySDNN: days[i].sdnn, todayRHR: days[i].rhr,
                                                 sdnnHistory: prior.compactMap(\.sdnn),
                                                 rhrHistory: prior.compactMap { $0.rhr.map(Double.init) })
            XCTAssertEqual(item.result, expected, "day \(i)")
        }
        XCTAssertNil(scored[3].result.recovery, "fewer than 7 prior nights stays calibrating")
        XCTAssertNotNil(scored.last?.result.recovery)
    }

    /// An import-only user scored one day at a time: the old window-only read gave the baseline nothing,
    /// so the day never got Charge. Reading the history before the window does.
    func testImportOnlyDayGetsChargeWhenTheBaselineReadsBeforeTheWindow() throws {
        let days = history(10)
        let windowOnly = WatchRecovery.scoreHistory([days[9]])
        XCTAssertNil(windowOnly.first?.result.recovery)
        let fullHistory = WatchRecovery.scoreHistory(days).filter { $0.day >= days[9].day }
        XCTAssertNotNil(try XCTUnwrap(fullHistory.first).result.recovery)
    }

    /// Days before a manual recalibration no longer feed the baseline (compute ignored the epoch).
    func testRecalibrationEpochRestartsTheImportBaseline() throws {
        let days = history(30)
        let epoch = try XCTUnwrap(keyFormatter.date(from: key(25))).timeIntervalSince1970
        let scored = WatchRecovery.scoreHistory(days, hrvEpoch: epoch, recoveryEpoch: epoch)
        XCTAssertNil(scored[29].result.recovery, "the few post-epoch nights are below the 7-night baseline")
        XCTAssertEqual(scored[29].result.confidence, .calibrating)
        XCTAssertNotNil(WatchRecovery.scoreHistory(days)[29].result.recovery)
        // Review F1: days before the recalibration keep their Charge (they were scored before it existed).
        let plain = WatchRecovery.scoreHistory(days)
        for i in 0..<25 { XCTAssertEqual(scored[i].result, plain[i].result, "pre-epoch day \(i)") }
        XCTAssertNotNil(scored[24].result.recovery)
    }

    /// Years of history score in one linear pass.
    func testFiveYearsOfHistoryScoreInOnePass() {
        let days = history(5 * 366)
        let scored = WatchRecovery.scoreHistory(days)
        XCTAssertEqual(scored.count, days.count)
    }
    /// Review round 4 (3): each scored day carries the drivers of the inputs its Charge used (SDNN against the
    /// SDNN baseline, resting HR when the day has one), and a calibrating day carries none.
    func testScoredDaysCarryTheDriversOfTheirOwnScore() {
        let scored = WatchRecovery.scoreHistory(history(40))
        XCTAssertGreaterThan(scored.filter { $0.result.recovery != nil }.count, 20)
        for (index, item) in scored.enumerated() {
            guard item.result.recovery != nil else {
                XCTAssertTrue(item.result.drivers.isEmpty, item.day)
                continue
            }
            let day = history(40)[index]
            XCTAssertEqual(item.result.drivers.first { $0.term == .hrv }?.value, day.sdnn, item.day)
            XCTAssertEqual(item.result.drivers.contains { $0.term == .restingHR }, day.rhr != nil, item.day)
            XCTAssertEqual(item.result.drivers.count, day.rhr != nil ? 2 : 1, item.day)
        }
    }
}
