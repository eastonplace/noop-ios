import XCTest
import WhoopStore
@testable import NOOP

@MainActor
final class IntelligenceRecoveryPersistenceReceiptTests: XCTestCase {
    private func daily(day: String, recovery: Double?) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: 420,
            efficiency: 0.9,
            deepMin: 70,
            remMin: 90,
            lightMin: 260,
            disturbances: 2,
            restingHr: 52,
            avgHrv: 64,
            recovery: recovery,
            strain: 30,
            exerciseCount: 1)
    }

    private func result(
        day: String,
        recovery: Double?,
        source: IntelligenceEngine.DaySource
    ) -> IntelligenceEngine.Computed {
        IntelligenceEngine.Computed(
            day: day,
            recovery: recovery,
            strain: 30,
            sleepMin: 420,
            hrv: 64,
            rhr: 52,
            source: source)
    }

    private func override(
        day: String,
        sessionStart: Int,
        recovery: Double?
    ) -> SleepRecoveryDailyOverride {
        SleepRecoveryDailyOverride(
            day: day,
            sessionStartTs: sessionStart,
            totalSleepMin: 420,
            efficiency: 0.9,
            deepMin: 70,
            remMin: 90,
            lightMin: 260,
            disturbances: 2,
            restingHr: 52,
            avgHrv: 64,
            recovery: recovery,
            restScore: 85,
            updatedAt: 10_000)
    }

    func testNilCalculatedRecoveryNeedsNoFabricatedPersistence() async throws {
        let repository = Repository(deviceId: Repository.whoopSource)
        let receipt = await IntelligenceRecoveryPersistenceReceipt.verify(
            results: [result(day: "2026-07-27", recovery: nil, source: .appleHealth)],
            repository: repository)

        XCTAssertTrue(receipt.complete)
        XCTAssertEqual(receipt.expectedRecoveries, 0)
        XCTAssertEqual(receipt.verifiedRecoveries, 0)
    }

    func testAppleRecoveryMustExistAndMatchInAppleNamespace() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let day = "2026-07-27"
        let expected = result(day: day, recovery: 73, source: .appleHealth)

        _ = try await store.upsertDailyMetrics(
            [daily(day: day, recovery: nil)],
            deviceId: Repository.appleHealthSource)
        var receipt = await IntelligenceRecoveryPersistenceReceipt.verify(
            results: [expected], repository: repository)
        XCTAssertFalse(receipt.complete,
                       "calculation success cannot clear the journal before its Apple row is durable")
        XCTAssertEqual(receipt.verifiedRecoveries, 0)

        _ = try await store.upsertDailyMetrics(
            [daily(day: day, recovery: 72)],
            deviceId: Repository.appleHealthSource)
        receipt = await IntelligenceRecoveryPersistenceReceipt.verify(
            results: [expected], repository: repository)
        XCTAssertFalse(receipt.complete, "a stale prior numeric Recovery is not completion")

        _ = try await store.upsertDailyMetrics(
            [daily(day: day, recovery: 73)],
            deviceId: Repository.appleHealthSource)
        receipt = await IntelligenceRecoveryPersistenceReceipt.verify(
            results: [expected], repository: repository)
        XCTAssertTrue(receipt.complete)
        XCTAssertEqual(receipt.verifiedRecoveries, 1)
    }

    func testComputedRecoveryMustExistInAComputedReadNamespace() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let day = "2026-07-27"
        let computedId = Repository.whoopSource + "-noop"
        let expected = result(day: day, recovery: 66, source: .computed)

        _ = try await store.upsertDailyMetrics(
            [daily(day: day, recovery: 65)],
            deviceId: computedId)
        var receipt = await IntelligenceRecoveryPersistenceReceipt.verify(
            results: [expected], repository: repository)
        XCTAssertFalse(receipt.complete)

        _ = try await store.upsertDailyMetrics(
            [daily(day: day, recovery: 66)],
            deviceId: computedId)
        receipt = await IntelligenceRecoveryPersistenceReceipt.verify(
            results: [expected], repository: repository)
        XCTAssertTrue(receipt.complete)
    }

    func testDurableManualOverrideOwnsVisibleRecoveryInsteadOfAutomaticResult() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let day = "2026-07-27"
        let computedId = Repository.whoopSource + "-noop"
        let corrected = override(day: day, sessionStart: 100_000, recovery: nil)
        _ = try await store.persistSleepRecoveryDailyOverride(
            corrected,
            daily: daily(day: day, recovery: nil),
            deviceId: computedId)

        let receipt = await IntelligenceRecoveryPersistenceReceipt.verify(
            results: [result(day: day, recovery: 66, source: .computed)],
            repository: repository)

        XCTAssertTrue(receipt.complete,
                      "a persisted user-owned nil is intentional, not a swallowed automatic write")
        XCTAssertEqual(receipt.verifiedRecoveries, 1)
    }
}
