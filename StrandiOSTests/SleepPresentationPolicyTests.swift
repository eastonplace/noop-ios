import XCTest
import WhoopStore
@testable import NOOP

final class SleepPresentationPolicyTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(_ day: Int, month: Int = 9, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    func testOlderHistoryDoesNotHideMissingToday() {
        XCTAssertTrue(SleepPresentationPolicy.isMissingCurrentNight(wakeDates: [date(5)], now: date(6), calendar: calendar))
        XCTAssertFalse(SleepPresentationPolicy.isMissingCurrentNight(wakeDates: [date(5), date(6, hour: 7)], now: date(6), calendar: calendar))
    }
    func testThirtyCalendarDaysExcludeOldAndFutureRows() {
        XCTAssertTrue(SleepPresentationPolicy.containsInRecentWindow(date(8, month: 8), now: date(6), calendar: calendar))
        XCTAssertFalse(SleepPresentationPolicy.containsInRecentWindow(date(7, month: 8), now: date(6), calendar: calendar))
        XCTAssertFalse(SleepPresentationPolicy.containsInRecentWindow(date(7), now: date(6), calendar: calendar))
    }
}

@MainActor
final class SleepPresentationRepositoryTests: XCTestCase {
    func testExactDayNeedsRefreshAndExcludeRepayment() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let source = try XCTUnwrap(repo.computedReadIds.first)
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: "2026-09-05", key: Repository.sleepNeedV2Key, value: 510),
            MetricPoint(day: "2026-09-05", key: "noop_sleep_debt_need_v2_min", value: 30),
            MetricPoint(day: "2026-09-06", key: Repository.sleepNeedV2Key, value: 520)
        ], deviceId: source)
        let first = try await repo.sleepPresentationNeeds(from: "2026-09-05", to: "2026-09-06")
        XCTAssertEqual(first["2026-09-05"]?.totalMinutes, 510)
        XCTAssertEqual(first["2026-09-05"]?.ledgerMinutes, 480)
        XCTAssertNil(first["2026-09-06"]?.ledgerMinutes)
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: "2026-09-05", key: Repository.sleepNeedV2Key, value: 540)
        ], deviceId: source)
        let updated = try await repo.sleepPresentationNeeds(from: "2026-09-05", to: "2026-09-05")
        XCTAssertEqual(updated["2026-09-05"]?.totalMinutes, 540)
        XCTAssertNil(updated["2026-09-06"])
    }
}
