import Foundation
import Testing
@testable import NoopPhase34Core

@Test func springForwardUsesCalendarDays() throws {
    let health = try HealthCalendar(timeZoneIdentifier: "America/New_York")
    let day = try CivilDay(key: "2026-03-08")
    let interval = try health.interval(for: day)
    #expect(interval.duration == 23 * 60 * 60)
    #expect(try health.adding(days: 1, to: day) == CivilDay(key: "2026-03-09"))
}

@Test func fallBackUsesCalendarDays() throws {
    let health = try HealthCalendar(timeZoneIdentifier: "America/New_York")
    let day = try CivilDay(key: "2026-11-01")
    let interval = try health.interval(for: day)
    #expect(interval.duration == 25 * 60 * 60)
    #expect(try health.adding(days: 1, to: day) == CivilDay(key: "2026-11-02"))
}

@Test func physiologicalDayRollsAtFourAM() throws {
    let health = try HealthCalendar(timeZoneIdentifier: "America/New_York")
    let formatter = ISO8601DateFormatter()
    let before = try #require(formatter.date(from: "2026-08-04T07:59:00Z")) // 03:59 EDT
    let after = try #require(formatter.date(from: "2026-08-04T08:00:00Z"))  // 04:00 EDT
    #expect(try health.physiologicalDay(containing: before) == CivilDay(key: "2026-08-03"))
    #expect(try health.physiologicalDay(containing: after) == CivilDay(key: "2026-08-04"))
}

@Test func springForwardFourAMStartsNewPhysiologicalDay() throws {
    let health = try HealthCalendar(timeZoneIdentifier: "America/New_York")
    let formatter = ISO8601DateFormatter()
    let before = try #require(formatter.date(from: "2026-03-08T07:59:00Z")) // 03:59 EDT
    let after = try #require(formatter.date(from: "2026-03-08T08:00:00Z"))  // 04:00 EDT
    #expect(try health.physiologicalDay(containing: before) == CivilDay(key: "2026-03-07"))
    #expect(try health.physiologicalDay(containing: after) == CivilDay(key: "2026-03-08"))
}

@Test func fallBackRepeatedHourStillRollsAtLocalFourAM() throws {
    let health = try HealthCalendar(timeZoneIdentifier: "America/New_York")
    let formatter = ISO8601DateFormatter()
    let before = try #require(formatter.date(from: "2026-11-01T08:59:00Z")) // 03:59 EST
    let after = try #require(formatter.date(from: "2026-11-01T09:00:00Z"))  // 04:00 EST
    #expect(try health.physiologicalDay(containing: before) == CivilDay(key: "2026-10-31"))
    #expect(try health.physiologicalDay(containing: after) == CivilDay(key: "2026-11-01"))
}

@Test func civilDayDecoderRejectsNormalizedInvalidDates() throws {
    let invalid = Data(#"{"year":2026,"month":2,"day":31}"#.utf8)
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(CivilDay.self, from: invalid)
    }
}
