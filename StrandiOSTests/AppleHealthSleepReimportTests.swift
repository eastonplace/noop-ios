import XCTest
import WhoopStore
@testable import NOOP

#if os(iOS)
final class AppleHealthSleepReimportTests: XCTestCase {
    func testFragmentReimportKeepsPriorDayAndAddsCorrectWakeDayIdempotently() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2024-03-09"
        _ = try await store.upsertDailyMetrics([DailyMetric(day: day, totalSleepMin: 60, efficiency: nil,
            deepMin: 0, remMin: 0, lightMin: 60, disturbances: nil, restingHr: 52, avgHrv: 65,
            recovery: nil, strain: nil, exerciseCount: nil)], deviceId: "apple-health")
        _ = try await store.upsertMetricSeries([MetricPoint(day: day, key: "asleep_min", value: 60),
            MetricPoint(day: day, key: "hrv", value: 65)], deviceId: "apple-health")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sleep-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData locale="en_US">
          <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Watch" startDate="2024-03-09 22:00:00 +0000" endDate="2024-03-09 23:00:00 +0000" value="HKCategoryValueSleepAnalysisAsleepCore"/>
          <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Watch" startDate="2024-03-09 23:00:00 +0000" endDate="2024-03-10 01:00:00 +0000" value="HKCategoryValueSleepAnalysisAsleepDeep"/>
          <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Watch" startDate="2024-03-10 01:00:00 +0000" endDate="2024-03-10 07:00:00 +0000" value="HKCategoryValueSleepAnalysisAsleepCore"/>
        </HealthData>
        """.write(to: url, atomically: true, encoding: .utf8)
        for _ in 0..<2 { _ = try await AppleHealthImport.importExport(url: url, into: store, deviceId: "apple-health") }
        let old = try await store.dailyMetrics(deviceId: "apple-health", from: day, to: day)
        XCTAssertEqual(old.first?.totalSleepMin, 60)
        XCTAssertEqual(old.first?.avgHrv, 65)
        let current = try await store.dailyMetrics(deviceId: "apple-health", from: "2024-03-10", to: "2024-03-10")
        XCTAssertEqual(current.first?.totalSleepMin, 540)
        XCTAssertEqual(current.first?.deepMin, 120)
        let stalePoints = try await store.metricSeries(deviceId: "apple-health", key: "asleep_min", from: day, to: day)
        XCTAssertEqual(stalePoints.first?.value, 60)
        let hrv = try await store.metricSeries(deviceId: "apple-health", key: "hrv", from: day, to: day)
        XCTAssertEqual(hrv.first?.value, 65)
    }

    func testInBedOrAwakeOnlyFragmentPreservesBankedSleepAndOtherMetrics() async throws {
        for stage in ["InBed", "Awake"] {
            let store = try await WhoopStore.inMemory()
            let day = "2024-03-10"
            for owner in ["apple-health", "whoop"] {
                _ = try await store.upsertDailyMetrics([DailyMetric(day: day, totalSleepMin: 480, efficiency: 95,
                    deepMin: 90, remMin: 90, lightMin: 300, disturbances: 2, restingHr: 52, avgHrv: 65,
                    recovery: nil, strain: nil, exerciseCount: nil)], deviceId: owner)
                _ = try await store.upsertAppleDaily([AppleDaily(day: day, steps: 8000, activeKcal: nil,
                    basalKcal: nil, vo2max: nil, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: 80)], deviceId: owner)
                _ = try await store.upsertMetricSeries([MetricPoint(day: day, key: "asleep_min", value: 480),
                    MetricPoint(day: day, key: "deep_min", value: 90),
                    MetricPoint(day: day, key: "awake_min", value: 30),
                    MetricPoint(day: day, key: "in_bed_min", value: 600)], deviceId: owner)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sleep-fragment-\(UUID().uuidString).xml")
            defer { try? FileManager.default.removeItem(at: url) }
            try """
            <?xml version="1.0" encoding="UTF-8"?><HealthData locale="en_US">
              <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Watch" startDate="2024-03-10 00:00:00 +0000" endDate="2024-03-10 08:00:00 +0000" value="HKCategoryValueSleepAnalysis\(stage)"/>
              <Record type="HKQuantityTypeIdentifierHeartRateVariabilitySDNN" sourceName="Watch" unit="ms" value="70" startDate="2024-03-10 08:00:00 +0000" endDate="2024-03-10 08:00:00 +0000"/>
            </HealthData>
            """.write(to: url, atomically: true, encoding: .utf8)
            for _ in 0..<2 { _ = try await AppleHealthImport.importExport(url: url, into: store, deviceId: "apple-health") }
            let rows = try await store.dailyMetrics(deviceId: "apple-health", from: day, to: day)
            XCTAssertEqual(rows.first?.totalSleepMin, 480)
            XCTAssertEqual(rows.first?.deepMin, 90)
            XCTAssertEqual(rows.first?.efficiency, 95)
            XCTAssertEqual(rows.first?.restingHr, 52)
            XCTAssertEqual(rows.first?.avgHrv, 70)
            let activity = try await store.appleDaily(deviceId: "apple-health", from: day, to: day)
            XCTAssertEqual(activity.first?.steps, 8000)
            XCTAssertEqual(activity.first?.weightKg, 80)
            let points = try await store.metricSeries(deviceId: "apple-health", key: "asleep_min", from: day, to: day)
            XCTAssertEqual(points.first?.value, 480)
            let companionKey = stage == "InBed" ? "awake_min" : "in_bed_min"
            let companion = try await store.metricSeries(deviceId: "apple-health", key: companionKey, from: day, to: day)
            XCTAssertEqual(companion.first?.value, stage == "InBed" ? 30 : 600)
            let other = try await store.dailyMetrics(deviceId: "whoop", from: day, to: day)
            XCTAssertEqual(other.first?.totalSleepMin, 480)
            XCTAssertEqual(other.first?.avgHrv, 65)
        }
    }
}
#endif
