import XCTest
import WhoopStore
import StrandAnalytics
@testable import NOOP

@MainActor
final class DailyTrainingTargetRepositoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_685_600)

    private func fixture() async throws -> (Repository, WhoopStore, String) {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: Repository.whoopSource)
        repo.setStoreForTesting(store)
        repo.setTodayHealthSnapshotTestNow(now)
        let day = Repository.logicalDayKey(now)
        let source = Repository.whoopSource + "-noop"
        let rows = (0..<42).map { offset in
            DailyMetric(day: DailyTrainingTargetEngine.offsetDay(day, by: -offset)!,
                        totalSleepMin: 480, efficiency: 0.9, deepMin: 80, remMin: 100, lightMin: 300,
                        disturbances: 2, restingHr: 55, avgHrv: 60, recovery: 80,
                        strain: offset == 0 ? 10 : 45, exerciseCount: 1, strainVersion: 2)
        }
        try await store.upsertDailyMetrics(rows, deviceId: source)
        try await store.upsertMetricSeries([.init(day: day, key: Repository.sleepNeedV2Key, value: 480)], deviceId: source)
        _ = await repo.refresh(days: 56)
        return (repo, store, day)
    }

    func testReadsCanonicalHistoryAndLeavesTodayOutOfUsualLoad() async throws {
        let (repo, _, day) = try await fixture()
        let data = try await repo.loadDailyTrainingTarget(now: now)
        let result = try XCTUnwrap(repo.dailyTrainingTargetEvaluation(data, now: now))
        XCTAssertEqual(result.day, day)
        XCTAssertEqual(result.target?.usualStrainStored, 45)
        XCTAssertEqual(result.target?.observedDays, 14)
        XCTAssertEqual(data.history.count, 41)
        XCTAssertFalse(data.history.contains { $0.day >= day })
    }

    func testImportedOrLegacyStrainCannotEnterTarget() async throws {
        let (repo, store, day) = try await fixture()
        let start = DailyTrainingTargetEngine.offsetDay(day, by: -14)!
        let originals = try await store.dailyMetrics(deviceId: Repository.whoopSource + "-noop", from: start, to: day)
        try await store.upsertDailyMetrics(originals.map { $0.replacing(strainVersion: .some(nil)) },
                                           deviceId: Repository.whoopSource + "-noop")
        try await store.upsertDailyMetrics(originals.map { $0.replacing(strain: .some(99), strainVersion: .some(nil)) },
                                           deviceId: Repository.whoopSource)
        _ = await repo.refresh(days: 56)
        let data = try await repo.loadDailyTrainingTarget(now: now)
        XCTAssertNil(repo.dailyTrainingTargetEvaluation(data, now: now)?.target)
    }

    func testPriorDayRecoveryCarryCannotBecomeCurrentRecommendation() async throws {
        let (repo, store, day) = try await fixture()
        let rows = try await store.dailyMetrics(deviceId: Repository.whoopSource + "-noop", from: day, to: day)
        try await store.upsertDailyMetrics(rows.map { $0.replacing(recovery: .some(nil)) },
                                           deviceId: Repository.whoopSource + "-noop")
        _ = await repo.refresh(days: 56)
        let data = try await repo.loadDailyTrainingTarget(now: now)
        XCTAssertEqual(repo.dailyTrainingTargetEvaluation(data, now: now)?.unavailableReason, .needsRecovery)
    }

    func testSourceInvalidationWhileReadIsSuspendedRejectsCompletion() async throws {
        let (repo, _, _) = try await fixture()
        do {
            _ = try await repo.loadDailyTrainingTargetForTesting(now: now) {
                repo.invalidateVerifiedExternalSurface()
            }
            XCTFail("An obsolete read must not produce a new target")
        } catch {
            XCTAssertEqual(error as? DailyTrainingTargetReadError, .sourceChanged)
        }
    }

    func testRefreshAndDayRolloverInvalidateAnAlreadyLoadedPlan() async throws {
        let (repo, _, _) = try await fixture()
        let data = try await repo.loadDailyTrainingTarget(now: now)
        XCTAssertNotNil(repo.dailyTrainingTargetEvaluation(data, now: now))
        XCTAssertNil(repo.dailyTrainingTargetEvaluation(data, now: now.addingTimeInterval(86_400)))
        repo.refreshSeq += 1
        XCTAssertNil(repo.dailyTrainingTargetEvaluation(data, now: now))
    }

    func testMissingOrOldStrainEvidenceKeepsProgressUnknown() async throws {
        let (repo, _, _) = try await fixture()
        // A daily aggregate without a raw frontier is valid historical load, but cannot claim live progress.
        let data = try await repo.loadDailyTrainingTarget(now: now)
        let result = try XCTUnwrap(repo.dailyTrainingTargetEvaluation(data, now: now.addingTimeInterval(3_601)))
        XCTAssertEqual(result.target?.progress, .unknown)
        XCTAssertNil(DailyTrainingTargetEngine.preview(result, plannedTotalStored: 50, plannedSleepHours: 8))
    }

    func testDatabaseReadFailureDoesNotReturnAnEmptySuccessfulPlan() async throws {
        let (repo, store, _) = try await fixture()
        try await store.close()
        do {
            _ = try await repo.loadDailyTrainingTarget(now: now)
            XCTFail("Read failure must remain distinguishable from missing observations")
        } catch { }
    }
}
