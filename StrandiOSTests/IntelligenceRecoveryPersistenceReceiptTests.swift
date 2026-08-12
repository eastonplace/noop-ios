import XCTest
import WhoopStore
@testable import NOOP

@MainActor
final class IntelligenceRecoveryPersistenceReceiptTests: XCTestCase {
    private func daily(_ day: String, _ recovery: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: 70, remMin: 90,
                    lightMin: 260, disturbances: 2, restingHr: 52, avgHrv: 64,
                    recovery: recovery, strain: 30, exerciseCount: 1)
    }

    private func result(
        _ day: String,
        _ recovery: Double?,
        source: IntelligenceEngine.DaySource = .computed,
        owner: IntelligenceEngine.RecoveryPersistenceOwner = .canonicalComputed
    ) -> IntelligenceEngine.Computed {
        IntelligenceEngine.Computed(
            day: day, recovery: recovery, strain: 30, sleepMin: 420, hrv: 64, rhr: 52,
            source: source, recoveryPersistenceOwner: owner)
    }

    private func verify(
        _ results: [IntelligenceEngine.Computed],
        _ range: ClosedRange<String>,
        _ repository: Repository
    ) async -> IntelligenceRecoveryPersistenceReceipt {
        await IntelligenceRecoveryPersistenceReceipt.verify(
            results: results, reconciledDays: range, repository: repository)
    }

    func testNilOutcomeRequiresARealClearingWrite() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let day = "2026-07-27"
        let expected = result(day, nil)

        var receipt = await verify([expected], day...day, repository)
        XCTAssertFalse(receipt.complete, "an absent row cannot prove stale Recovery was cleared")

        _ = try await store.upsertDailyMetrics([daily(day, 82)], deviceId: Repository.whoopSource + "-noop")
        receipt = await verify([expected], day...day, repository)
        XCTAssertFalse(receipt.complete, "a stale number cannot satisfy an expected nil")

        _ = try await store.upsertDailyMetrics([daily(day, nil)], deviceId: Repository.whoopSource + "-noop")
        receipt = await verify([expected], day...day, repository)
        XCTAssertTrue(receipt.complete)
    }

    func testEmptyResultsStillRequireReadableStoreAndReconciledRange() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let range = "2026-07-26"..."2026-07-27"
        var receipt = await verify([], range, repository)
        XCTAssertTrue(receipt.complete)

        _ = try await store.upsertDailyMetrics(
            [daily("2026-07-27", 91)], deviceId: Repository.whoopSource + "-noop")
        receipt = await verify([], range, repository)
        XCTAssertFalse(receipt.complete)
        try await store.close()
        receipt = await verify([], range, repository)
        XCTAssertFalse(receipt.complete)
    }

    func testWhoopOwnsRecoveryOnlyWhenItsFieldIsNonNil() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let day = "2026-07-27"
        let shadow = result(day, 66, source: .whoopImport)

        _ = try await store.upsertDailyMetrics([daily(day, 75)], deviceId: Repository.whoopSource)
        var receipt = await verify([shadow], day...day, repository)
        XCTAssertTrue(receipt.complete)

        _ = try await store.upsertDailyMetrics(
            [daily(day, 66)], deviceId: Repository.whoopSource + "-noop")
        receipt = await verify([shadow], day...day, repository)
        XCTAssertTrue(receipt.complete,
                      "the expected NOOP shadow must not look like a stale reconciled day")

        _ = try await store.upsertDailyMetrics([daily(day, nil)], deviceId: Repository.whoopSource)
        receipt = await verify([shadow], day...day, repository)
        XCTAssertTrue(receipt.complete,
                      "an imported nil must use the matching canonical computed fallback")

        _ = try await store.upsertDailyMetrics(
            [daily(day, 65)], deviceId: Repository.whoopSource + "-noop")
        receipt = await verify([shadow], day...day, repository)
        XCTAssertFalse(receipt.complete,
                       "a stale canonical fallback cannot satisfy an imported nil")
    }

    func testDisplayProvenanceCannotChangeTheActualPersistenceOwner() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let day = "2026-07-27"
        let strapResult = result(day, 68, source: .appleHealth, owner: .canonicalComputed)
        _ = try await store.upsertDailyMetrics([daily(day, 68)], deviceId: Repository.whoopSource + "-noop")
        _ = try await store.upsertDailyMetrics([daily(day, nil)], deviceId: Repository.appleHealthSource)

        let receipt = await verify([strapResult], day...day, repository)
        XCTAssertTrue(receipt.complete)
    }

    func testWatchOnlyResultMustMatchAppleNamespace() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let day = "2026-07-27"
        let expected = result(day, 73, source: .appleHealth, owner: .appleHealth)
        _ = try await store.upsertDailyMetrics([daily(day, 72)], deviceId: Repository.appleHealthSource)
        var receipt = await verify([expected], day...day, repository)
        XCTAssertFalse(receipt.complete)
        _ = try await store.upsertDailyMetrics([daily(day, 73)], deviceId: Repository.appleHealthSource)
        receipt = await verify([expected], day...day, repository)
        XCTAssertTrue(receipt.complete)
    }

    func testUnexpectedCanonicalDayFailsReconciliation() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let source = Repository.whoopSource + "-noop"
        _ = try await store.upsertDailyMetrics(
            [daily("2026-07-26", 92), daily("2026-07-27", 63)], deviceId: source)
        let receipt = await verify(
            [result("2026-07-27", 63)], "2026-07-26"..."2026-07-27", repository)
        XCTAssertFalse(receipt.complete)
        XCTAssertFalse(receipt.reconciledComputedRange)
    }

    func testManualOverrideOwnsCanonicalVisibleValue() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let day = "2026-07-27"
        let source = Repository.whoopSource + "-noop"
        let override = SleepRecoveryDailyOverride(
            day: day, sessionStartTs: 100_000, totalSleepMin: 420, efficiency: 0.9,
            deepMin: 70, remMin: 90, lightMin: 260, disturbances: 2, restingHr: 52,
            avgHrv: 64, recovery: nil, restScore: 85, updatedAt: 10_000)
        _ = try await store.persistSleepRecoveryDailyOverride(
            override, daily: daily(day, nil), deviceId: source)

        let receipt = await verify([result(day, 66)], day...day, repository)
        XCTAssertTrue(receipt.complete)
    }

    func testProtectedManualDayWithoutAutomaticResultIsNotTreatedAsStale() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let day = "2026-07-27"
        let source = Repository.whoopSource + "-noop"
        let override = SleepRecoveryDailyOverride(
            day: day, sessionStartTs: 100_000, totalSleepMin: 420, efficiency: 0.9,
            deepMin: 70, remMin: 90, lightMin: 260, disturbances: 2, restingHr: 52,
            avgHrv: 64, recovery: 77, restScore: 85, updatedAt: 10_000)
        _ = try await store.persistSleepRecoveryDailyOverride(
            override, daily: daily(day, 77), deviceId: source)

        let receipt = await verify([], day...day, repository)
        XCTAssertTrue(receipt.complete)
    }
}
