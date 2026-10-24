import XCTest
import WhoopStore
import StrandDesign
@testable import NOOP

@MainActor
final class TrendsHistoryExtentTests: XCTestCase {
    func testSparseReadRetainsFullHistoryNavigationBoundAcrossMultiYearGap() async throws {
        let store = try await WhoopStore.inMemory()
        let source = Repository.whoopSource + "-noop"
        try await store.upsertDailyMetrics([day("2020-01-01"), day("2026-10-24")], deviceId: source)
        let repo = Repository(deviceId: Repository.whoopSource)
        repo.setStoreForTesting(store)
        await repo.refreshHistoryExtent()
        XCTAssertEqual(repo.historyExtent.earliestDay?.key, "2020-01-01")

        let currentRead = await repo.loadCanonicalTrendsData(
            anchorDay: "2026-10-24", timeZoneIdentifier: "UTC", rangeDays: 30, weekOffset: 0)
        let current = try XCTUnwrap(currentRead)
        XCTAssertEqual(current.canonicalDays.map(\.day), ["2026-10-24"],
            "Navigation metadata must not expand the bounded sparse metric read")
        let snapshot = try XCTUnwrap(TrendsScreenSnapshot.build(
            key: TrendsScreenSnapshotKey(
                revision: current.revision, anchorDay: current.anchorDay, timeZoneIdentifier: "UTC",
                metric: "Recovery", range: "M", weekOffset: 0, completedLoadIdentity: current.loadIdentity),
            data: current, metric: .recovery, range: .month, weekOffset: 0,
            referenceDate: Date(timeIntervalSince1970: 1_792_800_000), calendar: utcCalendar,
            effortDisplayFactor: 1))
        // Monday 2019-12-30 to Monday 2026-10-19 is exactly 355 weeks.
        XCTAssertEqual(snapshot.minimumWeekOffset, -355,
            "A gap outside the current window must not disable navigation to stored history")

        let historicalRead = await repo.loadCanonicalTrendsData(
            anchorDay: "2026-10-24", timeZoneIdentifier: "UTC", rangeDays: 30, weekOffset: -355)
        let historical = try XCTUnwrap(historicalRead)
        XCTAssertEqual(historical.canonicalDays.map(\.day), ["2020-01-01", "2026-10-24"])
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func day(_ key: String) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: 440, efficiency: 0.9, deepMin: 90, remMin: 100,
            lightMin: 250, disturbances: 3, restingHr: 52, avgHrv: 63, recovery: 78,
            strain: 64, exerciseCount: 1, strainVersion: 2)
    }
}
