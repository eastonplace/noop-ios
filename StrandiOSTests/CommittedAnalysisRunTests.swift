import XCTest
@testable import NOOP

final class CommittedAnalysisRunTests: XCTestCase {
    func testDisjointAffectedDaysBecomeExactContiguousRuns() throws {
        let calendar = try gregorianCalendar(timeZone: "America/New_York")
        let reference = try date(calendar, 2026, 8, 12, 12)

        let runs = try CommittedAnalysisRunPlanner.runs(
            for: [day(2026, 8, 12), day(2026, 8, 11), day(2026, 8, 7), day(2026, 8, 6)],
            reference: reference,
            calendar: calendar
        )

        XCTAssertEqual(runs.map(\.startOffset), [0, 5])
        XCTAssertEqual(runs.map(\.maxDays), [2, 2])
        XCTAssertEqual(runs[0].days, [day(2026, 8, 12), day(2026, 8, 11)])
        XCTAssertEqual(runs[1].days, [day(2026, 8, 7), day(2026, 8, 6)])
    }

    func testSpringForwardUsesCalendarDaysInsteadOfTwentyFourHourSteps() throws {
        let calendar = try gregorianCalendar(timeZone: "America/New_York")
        let reference = try date(calendar, 2026, 3, 9, 12)

        let runs = try CommittedAnalysisRunPlanner.runs(
            for: [day(2026, 3, 8), day(2026, 3, 7)],
            reference: reference,
            calendar: calendar
        )

        XCTAssertEqual(runs.map(\.startOffset), [1])
        XCTAssertEqual(runs.map(\.maxDays), [2])
    }

    func testFutureDayFailsClosed() throws {
        let calendar = try gregorianCalendar(timeZone: "UTC")
        let reference = try date(calendar, 2026, 8, 12, 12)

        XCTAssertThrowsError(try CommittedAnalysisRunPlanner.runs(
            for: [day(2026, 8, 13)],
            reference: reference,
            calendar: calendar
        )) { error in
            XCTAssertEqual(error as? CommittedAnalysisRunError, .futureCivilDay)
        }
    }

    func testNonGregorianCalendarFailsClosed() throws {
        var calendar = Calendar(identifier: .japanese)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))

        XCTAssertThrowsError(try CommittedAnalysisRunPlanner.runs(
            for: [day(2026, 8, 12)],
            reference: Date(),
            calendar: calendar
        )) { error in
            XCTAssertEqual(error as? CommittedAnalysisRunError, .nonGregorianCalendar)
        }
    }

    func testOutOfRangeDayFailsClosed() throws {
        let calendar = try gregorianCalendar(timeZone: "UTC")
        let reference = try date(calendar, 2055, 1, 1, 12)
        let tooOld = try XCTUnwrap(AnalysisCivilDay(
            date: try date(calendar, 2026, 1, 1, 12),
            calendar: calendar
        ))

        XCTAssertThrowsError(try CommittedAnalysisRunPlanner.runs(
            for: [tooOld],
            reference: reference,
            calendar: calendar
        )) { error in
            XCTAssertEqual(error as? CommittedAnalysisRunError, .tooFarInPast)
        }
    }

    private func gregorianCalendar(timeZone identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
        return calendar
    }

    private func date(
        _ calendar: Calendar,
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        )))
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> AnalysisCivilDay {
        AnalysisCivilDay(year: year, month: month, day: day)!
    }
}
