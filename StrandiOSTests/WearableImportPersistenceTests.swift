import XCTest
import WhoopStore
@testable import NOOP

final class WearableImportPersistenceTests: XCTestCase {
    private func importFile(_ json: String, into store: WhoopStore) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oura-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        _ = try await WearableImporter.importExport(url: url, into: store)
    }

    private func importNamedFiles(_ files: [String: String], into store: WhoopStore) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wearable-fragments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        _ = try await WearableImporter.importExport(url: folder, into: store)
    }

    private func assertStepProjections(_ store: WhoopStore, source: String, expected: Int,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let days = try await store.dailyMetrics(deviceId: source, from: "2026-06-01", to: "2026-06-01")
        let points = try await store.metricSeries(deviceId: source, key: "steps", from: "2026-06-01", to: "2026-06-01")
        XCTAssertEqual(days.first?.steps, expected, file: file, line: line)
        XCTAssertEqual(points.first?.value, Double(expected), file: file, line: line)
    }

    func testFitbitObservedZeroReplacesStepsWhileAbsentOrInvalidCountsPreservePriorProjections() async throws {
        let store = try await WhoopStore.inMemory()
        for field in [",\"value\":8421", "", ",\"value\":-1", ",\"value\":\"nan\"", ",\"value\":\"inf\"", ",\"value\":\"1e300\"", ",\"value\":0"] {
            try await importNamedFiles([
                "steps-2026.json": "[{\"dateTime\":\"2026-06-01\"\(field)}]",
                "resting_heart_rate-2026.json": "[{\"dateTime\":\"2026-06-01\",\"value\":{\"value\":48}}]"
            ], into: store)
            try await assertStepProjections(store, source: "fitbit-import", expected: field.hasSuffix(":0") ? 0 : 8421)
        }
    }

    func testGarminObservedZeroReplacesStepsWhileAbsentOrInvalidCountsPreservePriorProjections() async throws {
        let store = try await WhoopStore.inMemory()
        for field in [",\"steps\":8421", "", ",\"steps\":-1", ",\"steps\":\"nan\"", ",\"steps\":\"inf\"", ",\"steps\":\"1e300\"", ",\"steps\":0"] {
            try await importNamedFiles([
                "di_connect_daily.json": "[{\"calendarDate\":\"2026-06-01\",\"restingHeartRate\":48\(field)}]"
            ], into: store)
            try await assertStepProjections(store, source: "garmin-import", expected: field.hasSuffix(":0") ? 0 : 8421)
        }
    }

    func testSingleCategoryImportsPreservePreviouslyImportedDailyMeasurements() async throws {
        let store = try await WhoopStore.inMemory()
        try await importFile("""
        {"sleep":[{"day":"2026-06-01","bedtime_start":"2026-05-31T23:00:00Z",
          "bedtime_end":"2026-06-01T06:00:00Z","total_sleep_duration":24000,
          "deep_sleep_duration":4800,"light_sleep_duration":14400,"rem_sleep_duration":4800,
          "awake_time":1200,"efficiency":95,"lowest_heart_rate":48,"average_hrv":65,
          "average_breath":14.2}]}
        """, into: store)
        try await importFile("""
        {"daily_readiness":[{"day":"2026-06-01","score":81,"temperature_deviation":-0.2}]}
        """, into: store)
        try await importFile("""
        {"daily_activity":[{"day":"2026-06-01","steps":8421,"active_calories":520}]}
        """, into: store)

        let rows = try await store.dailyMetrics(deviceId: "oura-import", from: "2026-06-01", to: "2026-06-01")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.totalSleepMin, 400)
        XCTAssertEqual(row.deepMin, 80)
        XCTAssertEqual(row.remMin, 80)
        XCTAssertEqual(row.lightMin, 240)
        XCTAssertEqual(row.restingHr, 48)
        XCTAssertEqual(row.avgHrv, 65)
        XCTAssertEqual(row.efficiency, 95)
        XCTAssertEqual(row.respRateBpm, 14.2)
        XCTAssertEqual(row.skinTempDevC, -0.2)
        XCTAssertNil(row.recovery, "The provider's reference readiness score is not NOOP Recovery")

        let hrv = try await store.metricSeries(deviceId: "oura-import", key: "hrv", from: row.day, to: row.day)
        XCTAssertEqual(hrv.first?.value, row.avgHrv, "Daily measurements and retained metric-series evidence must agree")
        let sleeps = try await store.sleepSessions(deviceId: "oura-import", from: 0, to: Int.max, limit: 10)
        XCTAssertEqual(sleeps.count, 1)
    }

    func testObservedZeroStepsReplaceOldValueInDailyAndMetricSeriesProjections() async throws {
        let store = try await WhoopStore.inMemory()
        for steps in [8421, 0] {
            try await importFile("""
            {"daily_activity":[{"day":"2026-06-01","steps":\(steps),"active_calories":520}]}
            """, into: store)
        }
        let rows = try await store.dailyMetrics(deviceId: "oura-import", from: "2026-06-01", to: "2026-06-01")
        XCTAssertEqual(rows.first?.steps, 0)
        let points = try await store.metricSeries(deviceId: "oura-import", key: "steps", from: "2026-06-01", to: "2026-06-01")
        XCTAssertEqual(points.first?.value, 0)
    }

    func testImportedStepsReachDailyProjection() async throws {
        let store = try await WhoopStore.inMemory()
        try await importFile("""
        {"daily_activity":[{"day":"2026-06-01","steps":8421,"active_calories":520}]}
        """, into: store)
        let rows = try await store.dailyMetrics(deviceId: "oura-import", from: "2026-06-01", to: "2026-06-01")
        XCTAssertEqual(rows.first?.steps, 8421)
    }
}
