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
}
#endif
