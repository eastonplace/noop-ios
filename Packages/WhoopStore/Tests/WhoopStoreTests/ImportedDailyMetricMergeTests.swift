import XCTest
import GRDB
@testable import WhoopStore

final class ImportedDailyMetricMergeTests: XCTestCase {
    private func row(_ day: String = "2026-06-01", sleep: Double? = nil, hrv: Double? = nil,
                     steps: Int? = nil, temp: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: hrv, recovery: nil,
                    strain: nil, exerciseCount: nil, skinTempDevC: temp, steps: steps)
    }

    func testFragmentMergePreservesAbsentValuesUsesZeroAndIsIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertDailyMetrics([row(sleep: 400, hrv: 65, steps: 8421, temp: -0.2)], deviceId: "oura-import")
        _ = try await store.upsertDailyMetrics([row(sleep: 300, hrv: 55, steps: 123)], deviceId: "other-source")
        _ = try await store.upsertDailyMetrics([row("2026-06-02", sleep: 420)], deviceId: "oura-import")
        let first = try await store.mergeImportedDailyMetrics([row(steps: 0, temp: 0)], deviceId: "oura-import")
        let repeatWrite = try await store.mergeImportedDailyMetrics([row(steps: 0, temp: 0)], deviceId: "oura-import")
        XCTAssertEqual(first, 1)
        XCTAssertEqual(repeatWrite, 0)
        let days = try await store.dailyMetrics(deviceId: "oura-import", from: "2026-06-01", to: "2026-06-02")
        XCTAssertEqual(days[0].totalSleepMin, 400)
        XCTAssertEqual(days[0].avgHrv, 65)
        XCTAssertEqual(days[0].steps, 0)
        XCTAssertEqual(days[0].skinTempDevC, 0)
        XCTAssertEqual(days[1].totalSleepMin, 420)
        let other = try await store.dailyMetrics(deviceId: "other-source", from: "2026-06-01", to: "2026-06-01")
        XCTAssertEqual(other[0].steps, 123)
    }

    func testFragmentMergeDoesNotChangeAuthoritativeReplacementSemantics() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertDailyMetrics([row(sleep: 400)], deviceId: "dev")
        _ = try await store.upsertDailyMetrics([row(hrv: 65)], deviceId: "dev")
        let values = try await store.dailyMetrics(deviceId: "dev", from: "2026-06-01", to: "2026-06-01")
        XCTAssertNil(values[0].totalSleepMin)
    }

    func testInvalidSourceOrDayFailsBeforeAnyRowChanges() async throws {
        let store = try await WhoopStore.inMemory()
        for (source, day) in [("", "2026-06-01"), ("oura-import", "2026-02-30"), ("oura-import", "not-a-day")] {
            do {
                _ = try await store.mergeImportedDailyMetrics([row(sleep: 400), row(day, hrv: 65)], deviceId: source)
                XCTFail("Invalid source/day must not be imported")
            } catch {}
        }
        let days = try await store.dailyMetrics(deviceId: "oura-import", from: "0000-01-01", to: "9999-12-31")
        XCTAssertTrue(days.isEmpty)
    }

    func testAllMergedDaysRollbackWhenPersistenceFails() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_import_day BEFORE INSERT ON dailyMetric
                WHEN NEW.day = '2026-06-02'
                BEGIN SELECT RAISE(ABORT, 'simulated import write failure'); END
                """)
        }
        do {
            _ = try await store.mergeImportedDailyMetrics([row(sleep: 400), row("2026-06-02", sleep: 420)], deviceId: "oura-import")
            XCTFail("The injected persistence failure must surface")
        } catch {}
        let days = try await store.dailyMetrics(deviceId: "oura-import", from: "2026-06-01", to: "2026-06-02")
        XCTAssertTrue(days.isEmpty, "The successful first row must roll back with the rejected second row")
    }
}
