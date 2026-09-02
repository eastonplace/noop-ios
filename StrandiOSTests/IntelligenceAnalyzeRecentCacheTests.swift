import XCTest
import NoopPhase34Core
import WhoopStore
@testable import NOOP

private actor AnalyzeRecentCacheProbe {
    enum ProbeError: Error {
        case injectedBundleFailure
    }

    private var bundleCallsByWindow: [Int: Int] = [:]
    private var fingerprintRevisionByWindow: [Int: Int] = [:]
    private var failingBundleWindow: Int?
    private var pauseNextFingerprint = false
    private var fingerprintIsPaused = false
    private var fingerprintPauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var fingerprintRelease: CheckedContinuation<Void, Never>?

    func fingerprint(owner: String, from: Int, to: Int) async -> (count: Int, maxTs: Int) {
        if pauseNextFingerprint {
            pauseNextFingerprint = false
            fingerprintIsPaused = true
            let waiters = fingerprintPauseWaiters
            fingerprintPauseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                fingerprintRelease = continuation
            }
            fingerprintIsPaused = false
        }
        let revision = fingerprintRevisionByWindow[from, default: 0]
        // The owner is intentionally not folded into the fake fingerprint. Production puts owner in the
        // cache key itself, so an owner switch must invalidate even when two straps have the same witness.
        _ = owner
        _ = to
        return (1_000 + revision, from + 10_000 + revision)
    }

    func loadBundle(
        store: WhoopStore,
        owner: String,
        from: Int,
        to: Int,
        limit: Int
    ) async throws -> AnalysisDayBundle {
        bundleCallsByWindow[from, default: 0] += 1
        if failingBundleWindow == from {
            throw ProbeError.injectedBundleFailure
        }
        return try await store.analysisDayBundle(deviceId: owner, from: from, to: to, limit: limit)
    }

    func totalBundleCalls() -> Int {
        bundleCallsByWindow.values.reduce(0, +)
    }

    func bundleWindows() -> [Int] {
        bundleCallsByWindow.keys.sorted()
    }

    func resetBundleCalls() {
        bundleCallsByWindow = [:]
    }

    func changeFingerprint(for window: Int) {
        fingerprintRevisionByWindow[window, default: 0] += 1
    }

    func failBundle(for window: Int?) {
        failingBundleWindow = window
    }

    func prepareFingerprintPause() {
        pauseNextFingerprint = true
    }

    func waitUntilFingerprintPaused() async {
        if fingerprintIsPaused { return }
        await withCheckedContinuation { continuation in
            fingerprintPauseWaiters.append(continuation)
        }
    }

    func releaseFingerprint() {
        fingerprintRelease?.resume()
        fingerprintRelease = nil
    }
}

@MainActor
final class IntelligenceAnalyzeRecentCacheTests: XCTestCase {
    private struct Harness {
        let store: WhoopStore
        let repository: Repository
        let profile: ProfileStore
        let engine: IntelligenceEngine
        let probe: AnalyzeRecentCacheProbe
    }

    private let reference = Date(timeIntervalSince1970: 1_778_000_000)

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeHarness(addSecondWhoop4: Bool = false) async throws -> Harness {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(
            id: Repository.whoopSource,
            brand: "WHOOP",
            model: "WHOOP 4.0",
            sourceKind: .liveBLE,
            capabilities: [.hr, .hrv, .skinTemp, .sleep],
            status: .active,
            addedAt: 0,
            lastSeenAt: 0))
        try registry.setActive(Repository.whoopSource)
        if addSecondWhoop4 {
            try registry.add(PairedDevice(
                id: "whoop4-b",
                brand: "WHOOP",
                model: "WHOOP 4.0",
                sourceKind: .liveBLE,
                capabilities: [.hr, .hrv, .skinTemp, .sleep],
                status: .paired,
                addedAt: 1,
                lastSeenAt: 1))
        }

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let profile = ProfileStore()
        let engine = IntelligenceEngine(
            repo: repository,
            profile: profile,
            deviceId: Repository.whoopSource)
        let probe = AnalyzeRecentCacheProbe()
        engine.setAnalyzeRecentCacheTestingSeamsForTesting(.init(
            fingerprintLoader: { _, owner, from, to in
                await probe.fingerprint(owner: owner, from: from, to: to)
            },
            bundleLoader: { store, owner, from, to, limit in
                try await probe.loadBundle(
                    store: store, owner: owner, from: from, to: to, limit: limit)
            }))
        return Harness(store: store, repository: repository, profile: profile, engine: engine, probe: probe)
    }

    private func run(
        _ harness: Harness,
        maxDays: Int,
        startOffset: Int = 0,
        sourceContext: ExactWorkSourceContext? = nil
    ) async -> Bool {
        await harness.engine.analyzeRecent(
            maxDays: maxDays,
            startOffset: startOffset,
            force: true,
            refreshRepository: false,
            analysisReference: reference,
            analysisCalendar: utcCalendar,
            sourceContext: sourceContext)
    }

    private func dayWindows(_ count: Int) -> [IntelligenceEngine.CivilDayWindow] {
        IntelligenceEngine.civilDayWindows(
            reference: reference,
            startOffset: 0,
            count: count,
            calendar: utcCalendar)
    }

    private func staleDaily(_ day: String) -> DailyMetric {
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
            recovery: 80,
            strain: 30,
            exerciseCount: 1)
    }

    func testColdRunReadsEveryBundleAndWarmRunReadsNone() async throws {
        let harness = try await makeHarness()

        let coldCompleted = await run(harness, maxDays: 3)
        let coldBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertTrue(coldCompleted)
        XCTAssertEqual(coldBundleCalls, 3)

        await harness.probe.resetBundleCalls()
        let warmCompleted = await run(harness, maxDays: 3)
        let warmBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertTrue(warmCompleted)
        XCTAssertEqual(warmBundleCalls, 0)
    }

    func testOneChangedFingerprintReadsOnlyThatDay() async throws {
        let harness = try await makeHarness()
        let coldCompleted = await run(harness, maxDays: 3)
        XCTAssertTrue(coldCompleted)
        let windows = await harness.probe.bundleWindows()
        XCTAssertEqual(windows.count, 3)

        await harness.probe.resetBundleCalls()
        await harness.probe.changeFingerprint(for: try XCTUnwrap(windows.dropFirst().first))

        let changedCompleted = await run(harness, maxDays: 3)
        let changedBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertTrue(changedCompleted)
        XCTAssertEqual(changedBundleCalls, 1)
    }

    func testConfigChangeInvalidatesAllEligibleDays() async throws {
        let harness = try await makeHarness()
        let originalWeight = harness.profile.weightKg
        defer { harness.profile.weightKg = originalWeight }

        let coldCompleted = await run(harness, maxDays: 2)
        XCTAssertTrue(coldCompleted)
        await harness.probe.resetBundleCalls()
        harness.profile.weightKg = originalWeight + 0.5

        let changedCompleted = await run(harness, maxDays: 2)
        let changedBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertTrue(changedCompleted)
        XCTAssertEqual(changedBundleCalls, 2)
    }

    func testOwnerChangeInvalidatesOnlyTheLockedDay() async throws {
        let harness = try await makeHarness(addSecondWhoop4: true)
        let coldCompleted = await run(harness, maxDays: 3)
        XCTAssertTrue(coldCompleted)
        await harness.probe.resetBundleCalls()

        let targetDay = try XCTUnwrap(dayWindows(3).dropFirst().first?.day)
        let registry = DeviceRegistryStore(dbQueue: harness.store.registryWriter)
        try registry.setDayOwner(day: targetDay, deviceId: "whoop4-b", locked: true)

        let ownerChangedCompleted = await run(harness, maxDays: 3)
        let ownerChangedBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertTrue(ownerChangedCompleted)
        XCTAssertEqual(ownerChangedBundleCalls, 1)
    }

    func testExactSourceWorkBypassesCacheWithoutDestroyingNormalCache() async throws {
        let harness = try await makeHarness()
        let coldCompleted = await run(harness, maxDays: 1)
        XCTAssertTrue(coldCompleted)
        await harness.probe.resetBundleCalls()

        let day = try XCTUnwrap(dayWindows(1).first?.day)
        let scope = try HistoricalAnalysisScope(
            databaseInstanceId: "cache-test-db",
            sourceId: Repository.whoopSource,
            deviceId: Repository.whoopSource,
            deviceLineageId: "cache-test-lineage",
            cursorEpoch: 0,
            trimScope: "historical")
        let work = try HistoricalAnalysisWork(
            scope: scope,
            firstReceiptGeneration: 1,
            lastReceiptGeneration: 1,
            affectedDays: [try CivilDay(key: day)],
            recordedTimeZoneIdentifier: "GMT",
            createdAt: reference)
        let sourceContext = ExactWorkSourceContext(work: work)

        let exactCompleted = await run(harness, maxDays: 1, sourceContext: sourceContext)
        let exactBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertTrue(exactCompleted)
        XCTAssertEqual(exactBundleCalls, 1)

        await harness.probe.resetBundleCalls()
        let warmCompleted = await run(harness, maxDays: 1)
        let warmBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertTrue(warmCompleted)
        XCTAssertEqual(warmBundleCalls, 0)
    }

    func testCacheHitStillRunsDailyReconciliationAndReceiptPath() async throws {
        let harness = try await makeHarness()
        let day = try XCTUnwrap(dayWindows(1).first?.day)
        let coldCompleted = await run(harness, maxDays: 1)
        XCTAssertTrue(coldCompleted)

        _ = try await harness.store.upsertDailyMetrics(
            [staleDaily(day)],
            deviceId: Repository.whoopSource + "-noop")
        await harness.probe.resetBundleCalls()

        let warmCompleted = await run(harness, maxDays: 1)
        let warmBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertTrue(warmCompleted)
        XCTAssertEqual(warmBundleCalls, 0)
        let rows = try await harness.store.dailyMetrics(
            deviceId: Repository.whoopSource + "-noop",
            from: day,
            to: day)
        XCTAssertTrue(rows.isEmpty, "a hit must still run stale-row reconciliation")

        let receipt = await IntelligenceRecoveryPersistenceReceipt.verify(
            results: harness.engine.results,
            reconciledDays: day...day,
            repository: harness.repository)
        XCTAssertTrue(receipt.complete, "a hit must preserve the publication receipt postcondition")
    }

    func testFailedChangedDayDoesNotAdvanceCache() async throws {
        let harness = try await makeHarness()
        let coldCompleted = await run(harness, maxDays: 2)
        XCTAssertTrue(coldCompleted)
        let warmWindows = await harness.probe.bundleWindows()
        let changedWindow = try XCTUnwrap(warmWindows.first)
        await harness.probe.changeFingerprint(for: changedWindow)
        await harness.probe.resetBundleCalls()
        await harness.probe.failBundle(for: changedWindow)

        let failedCompleted = await run(harness, maxDays: 2)
        let failedBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertFalse(failedCompleted)
        XCTAssertEqual(failedBundleCalls, 1)

        await harness.probe.failBundle(for: nil)
        await harness.probe.resetBundleCalls()
        let retryCompleted = await run(harness, maxDays: 2)
        let retryBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertTrue(retryCompleted)
        XCTAssertEqual(
            retryBundleCalls,
            1,
            "the failed pass must not cache the changed fingerprint")
    }

    func testCancellationDuringHitOnlyLoopKeepsPreviousCache() async throws {
        let harness = try await makeHarness()
        let coldCompleted = await run(harness, maxDays: 3)
        XCTAssertTrue(coldCompleted)
        await harness.probe.resetBundleCalls()
        await harness.probe.prepareFingerprintPause()

        let cancelledPass = Task { @MainActor in
            await run(harness, maxDays: 3)
        }
        await harness.probe.waitUntilFingerprintPaused()
        cancelledPass.cancel()
        await harness.probe.releaseFingerprint()
        let cancelledCompleted = await cancelledPass.value
        XCTAssertFalse(cancelledCompleted)

        let retryCompleted = await run(harness, maxDays: 3)
        let retryBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertTrue(retryCompleted)
        XCTAssertEqual(
            retryBundleCalls,
            0,
            "a cancelled hit-only pass must leave the last successful cache untouched")
    }

    func testSuccessfulNarrowWindowPrunesOldCachedDays() async throws {
        let harness = try await makeHarness()
        let coldCompleted = await run(harness, maxDays: 3)
        XCTAssertTrue(coldCompleted)

        await harness.probe.resetBundleCalls()
        let narrowCompleted = await run(harness, maxDays: 1)
        let narrowBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertTrue(narrowCompleted)
        XCTAssertEqual(narrowBundleCalls, 0)

        await harness.probe.resetBundleCalls()
        let expandedCompleted = await run(harness, maxDays: 3)
        let expandedBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertTrue(expandedCompleted)
        XCTAssertEqual(
            expandedBundleCalls,
            2,
            "the successful one-day pass must prune the two days outside its active window")
    }
}
