import XCTest
import WhoopStore
@testable import NOOP

/// DL-03: editing, deleting or adding a nap on any night but last night never rescored that day, because the
/// edit flows only ask for the one-day `analyzeRecent()`. The mutators now enqueue the affected days and that
/// pass widens to cover them.
@MainActor
final class RepositoryEditRescoreTests: XCTestCase {
    override func setUp() async throws {
        _ = EditedDayRescoreQueue.shared.take()
    }

    override func tearDown() async throws {
        _ = EditedDayRescoreQueue.shared.take()
    }

    private func newYorkCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        return calendar
    }

    func testEditThreeNightsAgoRescoresFromThatDayThroughToday() throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let threeNightsAgoWake = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 7)))

        let request = try XCTUnwrap(IntelligenceAnalysisRequest.editedDays(
            containingTimestamps: [Int(threeNightsAgoWake.timeIntervalSince1970), Int(now.timeIntervalSince1970)],
            now: now, calendar: calendar))
        XCTAssertEqual(request.startOffset, 0)
        XCTAssertEqual(request.maxDays, 4, "Oct 9 through Oct 12: the edited day and every later carry")
        XCTAssertTrue(request.force)
        XCTAssertTrue(request.refreshRepository)
    }

    func testEditedDayWindowCountsCalendarDaysAcrossFallBack() throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9)))
        let wake = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23)))
        let request = try XCTUnwrap(IntelligenceAnalysisRequest.editedDays(
            containingTimestamps: [Int(wake.timeIntervalSince1970)], now: now, calendar: calendar))
        XCTAssertEqual(request.maxDays, 3)
    }

    func testFutureOrEmptyEditsNeverWidenPastToday() throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let request = try XCTUnwrap(IntelligenceAnalysisRequest.editedDays(
            containingTimestamps: [Int(now.timeIntervalSince1970) + 86_400], now: now, calendar: calendar))
        XCTAssertEqual(request.maxDays, 1)
        XCTAssertNil(IntelligenceAnalysisRequest.editedDays(containingTimestamps: [Int](), now: now))
    }

    func testDeletingAnOlderNightQueuesItsWakeDayForRescore() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let wake = Int(Date().timeIntervalSince1970) - 3 * 86_400
        _ = try await store.insertManualSleepSession(
            deviceId: Repository.whoopSource + "-noop", startTs: wake - 8 * 3_600, endTs: wake,
            efficiency: 0.9, stagesJSON: "[]")

        _ = await repository.deleteSleepSession(detectedStartTs: wake - 8 * 3_600, endTs: wake)

        XCTAssertEqual(EditedDayRescoreQueue.shared.timestamps, [wake])
    }

    func testAddingANapQueuesItsDay() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let end = Int(Date().timeIntervalSince1970) - 2 * 86_400

        await repository.addManualNap(startTs: end - 2_700, endTs: end)

        XCTAssertEqual(EditedDayRescoreQueue.shared.timestamps, [end])
        XCTAssertEqual(EditedDayRescoreQueue.shared.take(), [end])
        XCTAssertTrue(EditedDayRescoreQueue.shared.timestamps.isEmpty, "the pass drains what it rescored")
    }

    func testComputedDailyRowsReadThePersistedNoopRows() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let rows = ["2026-10-08", "2026-10-09", "2026-10-10"].map {
            DailyMetric(day: $0, totalSleepMin: 440, efficiency: 0.9, deepMin: 90, remMin: 100,
                        lightMin: 250, disturbances: 3, restingHr: 52, avgHrv: 63, recovery: 70,
                        strain: 60, exerciseCount: 1, strainVersion: 2)
        }
        try await store.upsertDailyMetrics(rows, deviceId: Repository.whoopSource + "-noop")
        try await store.upsertDailyMetrics([rows[0]], deviceId: Repository.whoopSource)

        let read = try await repository.computedDailyRows(fromDay: "2026-10-09", throughDay: "2026-10-12")
        XCTAssertEqual(read.map(\.day), ["2026-10-09", "2026-10-10"])
    }
}
