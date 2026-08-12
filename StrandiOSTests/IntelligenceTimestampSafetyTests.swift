import XCTest
import WhoopStore
@testable import NOOP

@MainActor
final class IntelligenceTimestampSafetyTests: XCTestCase {
    private func newYorkCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        return calendar
    }

    func testMidnightHelpersPreserveRepresentableDatesAndRejectOverflow() throws {
        let utcTimestamp = 1_623_805_200
        let localMidnight = try XCTUnwrap(
            IntelligenceEngine.midnightLocal(utcTimestamp, offsetSec: -4 * 3_600))
        XCTAssertEqual(localMidnight, 1_623_729_600)
        XCTAssertEqual(
            try XCTUnwrap(IntelligenceEngine.midnightLocal(utcTimestamp, offsetSec: 0)),
            try XCTUnwrap(IntelligenceEngine.midnightUtc(utcTimestamp)))

        XCTAssertNil(IntelligenceEngine.midnightUtc(Int.min))
        XCTAssertNil(IntelligenceEngine.midnightLocal(Int.max, offsetSec: 1))
        XCTAssertNil(IntelligenceEngine.midnightLocal(Int.min, offsetSec: -1))
    }

    func testBandSleepStateSamplesKeepsValidSeriesWhenExtremeInputIsRejected() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "timestamp-test-noop"
        let validStart = 1_780_000_000
        let corruptStart = Int.max - 10

        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: validStart, endTs: validStart + 1_800, efficiency: 0.9,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil),
            CachedSleepSession(startTs: corruptStart, endTs: Int.max, efficiency: nil,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil),
        ], deviceId: deviceId)
        try await store.persistSessionSleepState(deviceId: deviceId, sessionStart: validStart,
                                                 states: [1, 2, 3])
        try await store.persistSessionSleepState(deviceId: deviceId, sessionStart: corruptStart,
                                                 states: [3])

        let samples = await IntelligenceEngine.bandSleepStateSamples(
            computedId: deviceId, from: validStart, to: Int.max, store: store)

        XCTAssertEqual(samples.map(\.ts), [validStart, validStart + 30, validStart + 60])
        XCTAssertEqual(samples.map(\.state), [1, 2, 3])
    }

    func testCivilDayWindowsStayAtMidnightAcrossSpringDST() throws {
        let calendar = try newYorkCalendar()
        let reference = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let windows = IntelligenceEngine.civilDayWindows(
            reference: reference, startOffset: 0, count: 4, calendar: calendar)

        XCTAssertEqual(windows.map(\.day), [
            "2026-03-10", "2026-03-09", "2026-03-08", "2026-03-07"
        ])
        XCTAssertEqual(windows[2].nextStart - windows[2].start, 23 * 3_600)
    }

    func testCivilDayWindowsStayAtMidnightAcrossFallDST() throws {
        let calendar = try newYorkCalendar()
        let reference = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 3, hour: 12)))
        let windows = IntelligenceEngine.civilDayWindows(
            reference: reference, startOffset: 0, count: 4, calendar: calendar)

        XCTAssertEqual(windows.map(\.day), [
            "2026-11-03", "2026-11-02", "2026-11-01", "2026-10-31"
        ])
        XCTAssertEqual(windows[2].nextStart - windows[2].start, 25 * 3_600)
    }

    func testHistoricalMigrationBoundsWorkToRealSourceDaysAcrossDST() throws {
        let calendar = try newYorkCalendar()
        let reference = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let earliest = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 3, day: 7, hour: 23)))

        XCTAssertEqual(IntelligenceEngine.boundedHistoryDays(
            earliestTimestamp: Int(earliest.timeIntervalSince1970),
            reference: reference,
            calendar: calendar,
            cap: 4_000), 4)
        XCTAssertEqual(IntelligenceEngine.boundedHistoryDays(
            earliestTimestamp: Int(reference.timeIntervalSince1970),
            reference: reference,
            calendar: calendar,
            cap: 4_000), 1)
        XCTAssertEqual(IntelligenceEngine.boundedHistoryDays(
            earliestTimestamp: 0,
            reference: reference,
            calendar: calendar,
            cap: 30), 30)
    }

    func testBandSleepStateSamplesRejectsSeriesThatEscapesItsSession() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "timestamp-series-test-noop"
        let start = 1_780_000_000

        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: start, endTs: start + 1_800, efficiency: 0.9,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil)
        ], deviceId: deviceId)
        try await store.persistSessionSleepState(deviceId: deviceId, sessionStart: start,
                                                 states: Array(repeating: 1, count: 62))

        let samples = await IntelligenceEngine.bandSleepStateSamples(
            computedId: deviceId, from: start, to: start + 1_800, store: store)

        XCTAssertTrue(samples.isEmpty)
    }
}
