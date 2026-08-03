import XCTest
import WhoopStore
@testable import NOOP

final class TodayStartupAnchorTests: XCTestCase {
    private func day(_ key: String, strain: Double? = nil, version: Int? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: 420, efficiency: 91, deepMin: 80, remMin: 95,
                    lightMin: 245, disturbances: 2, restingHr: 52, avgHrv: 68,
                    recovery: 81, strain: strain, exerciseCount: 1, spo2Pct: 97,
                    skinTempDevC: -0.2, respRateBpm: 14.1, steps: 8_000,
                    activeKcalEst: 640, strainVersion: version)
    }

    func testAnchorRetainsOnlyNewestTwentyOneDays() {
        let rows = (1 ... 25).map { day(String(format: "2026-07-%02d", $0)) }
        let anchor = TodayStartupAnchor(days: rows, canonicalStrainV2: [],
                                        sleepPerformance: [], vitality: [])

        XCTAssertEqual(anchor.days.count, 21)
        XCTAssertEqual(anchor.days.first?.day, "2026-07-05")
        XCTAssertEqual(anchor.days.last?.day, "2026-07-25")
    }

    func testAnchorKeepsExactDayScoresAndRejectsInvalidValues() {
        let key = "2026-08-02"
        let anchor = TodayStartupAnchor(
            days: [day(key, strain: 62, version: 2)],
            canonicalStrainV2: [MetricPoint(day: key, key: "strain", value: 62),
                                MetricPoint(day: "2026-08-01", key: "strain", value: .nan)],
            sleepPerformance: [MetricPoint(day: key, key: "sleep_performance", value: 88)],
            vitality: [MetricPoint(day: key, key: "vitality", value: 73)])

        XCTAssertEqual(anchor.canonicalStrain(for: key), 62)
        XCTAssertNil(anchor.canonicalStrain(for: "2026-08-01"))
        XCTAssertEqual(anchor.sleepPerformance(for: key), 88)
        XCTAssertEqual(anchor.vitality(for: key), 73)
    }

    func testScalarOnlyDayStillCreatesASelectablePresentationRow() {
        let key = "2026-08-02"
        let anchor = TodayStartupAnchor(
            days: [], canonicalStrainV2: [],
            sleepPerformance: [MetricPoint(day: key, key: "sleep_performance", value: 86)],
            vitality: [])

        XCTAssertEqual(anchor.days.map(\.day), [key])
        XCTAssertEqual(anchor.sleepPerformance(for: key), 86)
    }

    func testStoreLoadsPersistedProjectionSynchronously() {
        let suite = "TodayStartupAnchorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TodayStartupAnchorStore(defaults: defaults)
        let anchor = TodayStartupAnchor(
            days: [day("2026-08-02")], canonicalStrainV2: [],
            sleepPerformance: [MetricPoint(day: "2026-08-02", key: "sleep_performance", value: 84)],
            vitality: [])

        store.save(anchor)

        XCTAssertEqual(store.load(), anchor)
    }

    func testDisplayResolverPreservesPreFourAMLocalWakeDayFromAnchor() {
        let rows = [day("2026-08-02"), day("2026-08-03")]

        XCTAssertEqual(
            TodayView.resolveDisplayDay(days: rows, selectedDayOffset: 0,
                                        logicalKey: "2026-08-02", localKey: "2026-08-03",
                                        selectedDayKey: "2026-08-02")?.day,
            "2026-08-03")
    }
}
