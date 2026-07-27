import XCTest
import WhoopProtocol
@testable import WhoopStore

final class SleepEfficiencyStoreIntegrityTests: XCTestCase {
    private func daily(day: String, efficiency: Double?) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: 420,
            efficiency: efficiency,
            deepMin: 70,
            remMin: 90,
            lightMin: 260,
            disturbances: 3,
            restingHr: 52,
            avgHrv: 64,
            recovery: 72,
            strain: 20,
            exerciseCount: 1)
    }

    func testSleepSessionRejectsZeroAndOutOfRangeEfficiencyButKeepsValidDomains() async throws {
        let store = try await WhoopStore.inMemory()
        let start = 100_000

        func write(_ efficiency: Double?) async throws -> Double? {
            _ = try await store.upsertSleepSessions([
                CachedSleepSession(
                    startTs: start,
                    endTs: start + 8 * 3_600,
                    efficiency: efficiency,
                    restingHr: 52,
                    avgHrv: 64,
                    stagesJSON: #"{"awake":30,"light":240,"deep":70,"rem":80}"#)
            ], deviceId: "efficiency-test")
            return try await store.sleepSessions(
                deviceId: "efficiency-test",
                from: start,
                to: start + 8 * 3_600,
                limit: 10).first?.efficiency
        }

        let zero = try await write(0)
        let negative = try await write(-0.2)
        let tooHigh = try await write(101)
        let fraction = try await write(0.91)
        let percentage = try await write(91)

        XCTAssertNil(zero, "legacy placeholder zero is missing data, not 0% physiology")
        XCTAssertNil(negative)
        XCTAssertNil(tooHigh)
        XCTAssertEqual(fraction, 0.91, accuracy: 0.0001)
        XCTAssertEqual(percentage, 91, accuracy: 0.0001,
                       "historical percentage-domain imports remain supported")
    }

    func testDailyMetricRejectsInvalidEfficiencyAtPersistenceBoundary() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "daily-efficiency-test"

        _ = try await store.upsertDailyMetrics([daily(day: "2026-07-26", efficiency: 0)], deviceId: device)
        var rows = try await store.dailyMetrics(
            deviceId: device,
            from: "2026-07-26",
            to: "2026-07-26")
        var row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.efficiency)

        _ = try await store.upsertDailyMetrics([daily(day: "2026-07-26", efficiency: 0.88)], deviceId: device)
        rows = try await store.dailyMetrics(
            deviceId: device,
            from: "2026-07-26",
            to: "2026-07-26")
        row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.efficiency, 0.88, accuracy: 0.0001)
    }

    func testEditingSleepShapeClearsStaleEfficiencyUntilReanalysisSuppliesOne() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "edited-efficiency-test"
        let start = 200_000
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(
                startTs: start,
                endTs: start + 8 * 3_600,
                efficiency: 0.9,
                restingHr: 52,
                avgHrv: 64,
                stagesJSON: #"{"awake":30,"light":240,"deep":70,"rem":80}"#)
        ], deviceId: device)

        _ = try await store.applySleepEdit(
            deviceId: device,
            detectedStartTs: start,
            newStartTs: start,
            newEndTs: start + 7 * 3_600,
            stagesJSON: #"{"awake":20,"light":210,"deep":65,"rem":75}"#)

        let rows = try await store.sleepSessions(
            deviceId: device,
            from: start,
            to: start + 8 * 3_600,
            limit: 10)
        let edited = try XCTUnwrap(rows.first)
        XCTAssertNil(edited.efficiency,
                     "a changed denominator cannot retain the previous window's efficiency")
    }
}
