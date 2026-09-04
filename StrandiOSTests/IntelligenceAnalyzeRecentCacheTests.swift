import XCTest
import GRDB
import NoopPhase34Core
import StrandAnalytics
import WhoopProtocol
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

    func testSleepEditInvalidatesDayWithUnchangedRawHeartRateFingerprint() async throws {
        let harness = try await makeHarness()
        let coldCompleted = await run(harness, maxDays: 1)
        XCTAssertTrue(coldCompleted)
        await harness.probe.resetBundleCalls()

        let day = try XCTUnwrap(dayWindows(1).first)
        let detectedStart = day.start + 60 * 60
        let changed = try await harness.store.upsertSleepSessions([
            CachedSleepSession(
                startTs: detectedStart,
                endTs: detectedStart + 7 * 60 * 60,
                efficiency: 0.9,
                restingHr: 55,
                avgHrv: 60,
                stagesJSON: nil,
                userEdited: true,
                startTsAdjusted: detectedStart + 15 * 60
            )
        ], deviceId: Repository.whoopSource + "-noop")
        XCTAssertEqual(changed, 1)

        let warmCompleted = await run(harness, maxDays: 1)
        let warmBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertTrue(warmCompleted)
        XCTAssertEqual(warmBundleCalls, 1)
    }

    func testPreSleepOptOutFailsClosedDuringAnalysisThenRemovesEveryStoredKey() async throws {
        let defaults = UserDefaults.standard
        let oldValue = defaults.object(forKey: PreSleepHeartRateFeedback.enabledKey)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: PreSleepHeartRateFeedback.enabledKey) }
            else { defaults.removeObject(forKey: PreSleepHeartRateFeedback.enabledKey) }
        }
        defaults.set(true, forKey: PreSleepHeartRateFeedback.enabledKey)
        let harness = try await makeHarness()
        let retiredRawId = "whoop-retired"
        let registry = DeviceRegistryStore(dbQueue: harness.store.registryWriter)
        try registry.add(PairedDevice(
            id: retiredRawId,
            brand: "WHOOP",
            model: "WHOOP 4.0",
            sourceKind: .historyBLE,
            capabilities: [.hr, .hrv, .sleep],
            status: .archived,
            addedAt: 1,
            lastSeenAt: 1
        ))
        let day = try XCTUnwrap(dayWindows(1).first?.day)
        let source = Repository.whoopSource + "-noop"
        let retiredSource = retiredRawId + "-noop"
        let points = [
            MetricPoint(day: day, key: PreSleepHeartRateFeedback.meanMetricKey, value: 64),
            MetricPoint(day: day, key: PreSleepHeartRateFeedback.validSamplesMetricKey, value: 30),
            MetricPoint(day: day, key: PreSleepHeartRateFeedback.totalSamplesMetricKey, value: 30),
        ]
        _ = try await harness.store.upsertMetricSeries(points, deviceId: source)
        _ = try await harness.store.upsertMetricSeries(points, deviceId: retiredSource)

        await harness.probe.prepareFingerprintPause()
        let analysis = Task { await self.run(harness, maxDays: 1) }
        await harness.probe.waitUntilFingerprintPaused()

        let overlappingOptOut = await harness.engine.setPreSleepHeartRateFeedbackEnabled(false)
        XCTAssertFalse(overlappingOptOut)
        XCTAssertTrue(defaults.bool(forKey: PreSleepHeartRateFeedback.enabledKey))
        let retained = try await harness.store.metricSeries(
            deviceId: source, key: PreSleepHeartRateFeedback.meanMetricKey,
            from: day, to: day
        )
        XCTAssertEqual(retained.count, 1)

        await harness.probe.releaseFingerprint()
        _ = await analysis.value
        _ = try await harness.store.upsertMetricSeries(points, deviceId: source)
        _ = try await harness.store.upsertMetricSeries(points, deviceId: retiredSource)

        let completedOptOut = await harness.engine.setPreSleepHeartRateFeedbackEnabled(false)
        XCTAssertTrue(completedOptOut)
        XCTAssertFalse(defaults.bool(forKey: PreSleepHeartRateFeedback.enabledKey))
        for computedSource in [source, retiredSource] {
            for key in PreSleepHeartRateFeedback.metricKeys {
                let remaining = try await harness.store.metricSeries(
                    deviceId: computedSource,
                    key: key,
                    from: "0000-01-01",
                    to: "9999-12-31"
                )
                XCTAssertTrue(
                    remaining.isEmpty,
                    "expected complete cleanup for \(computedSource) \(key)"
                )
            }
        }
    }

    func testPreSleepOptOutScrubsOrphanedNamespacesWithoutRegistryEnumeration() async throws {
        let defaults = UserDefaults.standard
        let oldValue = defaults.object(forKey: PreSleepHeartRateFeedback.enabledKey)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: PreSleepHeartRateFeedback.enabledKey) }
            else { defaults.removeObject(forKey: PreSleepHeartRateFeedback.enabledKey) }
        }
        defaults.set(true, forKey: PreSleepHeartRateFeedback.enabledKey)
        let harness = try await makeHarness()
        let day = try XCTUnwrap(dayWindows(1).first?.day)
        let source = Repository.whoopSource + "-noop"
        let orphanSource = "orphan-noop"
        for computedSource in [source, orphanSource] {
            _ = try await harness.store.upsertMetricSeries([
                MetricPoint(day: day, key: PreSleepHeartRateFeedback.meanMetricKey, value: 64),
                MetricPoint(day: day, key: "unrelated", value: 80),
            ], deviceId: computedSource)
        }
        try await harness.store.registryWriter.write { db in
            try db.execute(sql: "ALTER TABLE pairedDevice RENAME TO pairedDeviceUnavailable")
        }

        let completed = await harness.engine.setPreSleepHeartRateFeedbackEnabled(false)

        XCTAssertTrue(completed)
        XCTAssertFalse(defaults.bool(forKey: PreSleepHeartRateFeedback.enabledKey))
        for computedSource in [source, orphanSource] {
            let removed = try await harness.store.metricSeries(
                deviceId: computedSource,
                key: PreSleepHeartRateFeedback.meanMetricKey,
                from: day,
                to: day
            )
            XCTAssertTrue(removed.isEmpty)
            let unrelated = try await harness.store.metricSeries(
                deviceId: computedSource, key: "unrelated", from: day, to: day
            )
            XCTAssertEqual(unrelated.map(\.value), [80])
        }
    }

    func testExactSourceWorkCannotGenerateOptionalPreSleepFeedback() {
        XCTAssertTrue(IntelligenceEngine.preSleepFeedbackEnabled(
            optedIn: true, isExactSourceWork: false
        ))
        XCTAssertFalse(IntelligenceEngine.preSleepFeedbackEnabled(
            optedIn: true, isExactSourceWork: true
        ))
        XCTAssertFalse(IntelligenceEngine.preSleepFeedbackEnabled(
            optedIn: false, isExactSourceWork: false
        ))
    }

    func testEditedSleepRowsApplyOnlyToTheirOwningRawSource() {
        let row = CachedSleepSession(
            startTs: 1_000,
            endTs: 20_000,
            efficiency: 0.9,
            restingHr: 52,
            avgHrv: 65,
            stagesJSON: nil,
            userEdited: true,
            startTsAdjusted: 1_600
        )
        let day = AnalyticsEngine.dayString(row.endTs, offsetSec: 0)

        XCTAssertEqual(IntelligenceEngine.editedRowsForOwnerDay(
            [row],
            rowsSourceId: "active-repair",
            owner: "active-repair",
            day: day,
            tzOffsetSeconds: 0
        ), [row])
        XCTAssertTrue(IntelligenceEngine.editedRowsForOwnerDay(
            [row],
            rowsSourceId: "active-repair",
            owner: Repository.whoopSource,
            day: day,
            tzOffsetSeconds: 0
        ).isEmpty)
    }

    func testSparseHeartRateStillPublishesQualifiedShadowsWithoutScoringSleep() async throws {
        let defaults = UserDefaults.standard
        let oldValue = defaults.object(forKey: PreSleepHeartRateFeedback.enabledKey)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: PreSleepHeartRateFeedback.enabledKey) }
            else { defaults.removeObject(forKey: PreSleepHeartRateFeedback.enabledKey) }
        }
        defaults.set(true, forKey: PreSleepHeartRateFeedback.enabledKey)
        let harness = try await makeHarness()
        let window = try XCTUnwrap(dayWindows(1).first)
        let sleepStart = window.start - 60 * 60
        let sleepEnd = window.start + 7 * 60 * 60
        // Sixty total samples stay below the legacy 200-row scoring gate while meeting the independent
        // shadow thresholds: 30 pre-sleep samples and 30 in-session samples.
        let hr = (0..<60).map { index in
            HRSample(ts: sleepStart - 30 * 60 + index * 60, bpm: index < 30 ? 64 : 54)
        }
        _ = try await harness.store.insert(Streams(hr: hr), deviceId: Repository.whoopSource)
        _ = try await harness.store.upsertSleepSessions([
            CachedSleepSession(
                startTs: sleepStart,
                endTs: sleepEnd,
                efficiency: 0.9,
                restingHr: 52,
                avgHrv: 66,
                stagesJSON: nil
            )
        ], deviceId: Repository.whoopSource)

        let completed = await run(harness, maxDays: 1)
        XCTAssertTrue(completed)
        let source = Repository.whoopSource + "-noop"
        let mean = try await harness.store.metricSeries(
            deviceId: source,
            key: PreSleepHeartRateFeedback.meanMetricKey,
            from: window.day,
            to: window.day
        )
        let valid = try await harness.store.metricSeries(
            deviceId: source,
            key: PreSleepHeartRateFeedback.validSamplesMetricKey,
            from: window.day,
            to: window.day
        )
        XCTAssertEqual(mean.map(\.value), [64])
        XCTAssertEqual(valid.map(\.value), [30])
        let primaryMean = try await harness.store.metricSeries(
            deviceId: source,
            key: PrimarySessionRestingHR.meanMetricKey,
            from: window.day,
            to: window.day
        )
        let primaryValid = try await harness.store.metricSeries(
            deviceId: source,
            key: PrimarySessionRestingHR.validSamplesMetricKey,
            from: window.day,
            to: window.day
        )
        let primaryDuration = try await harness.store.metricSeries(
            deviceId: source,
            key: PrimarySessionRestingHR.durationMetricKey,
            from: window.day,
            to: window.day
        )
        XCTAssertEqual(primaryMean.map(\.value), [54])
        XCTAssertEqual(primaryValid.map(\.value), [30])
        XCTAssertEqual(primaryDuration.map(\.value), [Double(sleepEnd - sleepStart)])
        let storedStart = try await harness.store.metricSeries(
            deviceId: source,
            key: PreSleepHeartRateFeedback.primarySleepStartMetricKey,
            from: window.day,
            to: window.day
        )
        let storedEnd = try await harness.store.metricSeries(
            deviceId: source,
            key: PreSleepHeartRateFeedback.primarySleepEndMetricKey,
            from: window.day,
            to: window.day
        )
        XCTAssertEqual(storedStart.map(\.value), [Double(sleepStart)])
        XCTAssertEqual(storedEnd.map(\.value), [Double(sleepEnd)])
        let computedDaily = try await harness.store.dailyMetrics(
            deviceId: source,
            from: window.day,
            to: window.day
        )
        XCTAssertNil(computedDaily.first?.recovery)
        XCTAssertNil(computedDaily.first?.totalSleepMin)
        let computedSleep = try await harness.store.sleepSessions(
            deviceId: source,
            from: window.start - 24 * 60 * 60,
            to: window.nextStart,
            limit: 10
        )
        XCTAssertTrue(computedSleep.isEmpty, "descriptive bounds must not create scored sleep")

        await harness.probe.resetBundleCalls()
        let unchangedCompleted = await run(harness, maxDays: 1)
        let unchangedBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertTrue(unchangedCompleted)
        XCTAssertEqual(unchangedBundleCalls, 0)

        _ = try await harness.store.upsertSleepSessions([
            CachedSleepSession(
                startTs: sleepStart,
                endTs: sleepEnd + 15 * 60,
                efficiency: 0.9,
                restingHr: 52,
                avgHrv: 66,
                stagesJSON: nil
            )
        ], deviceId: Repository.whoopSource)
        await harness.probe.resetBundleCalls()
        let changedCompleted = await run(harness, maxDays: 1)
        let changedBundleCalls = await harness.probe.totalBundleCalls()
        XCTAssertTrue(changedCompleted)
        XCTAssertEqual(
            changedBundleCalls, 1,
            "changed imported sleep bounds must invalidate the WHOOP 4 cache"
        )
    }

    func testPersistedShadowBoundsReplaceShiftedDetectorBoundsForCoveredWakeDay() {
        let detected = CachedSleepSession(
            startTs: 1_000,
            endTs: 20_000,
            efficiency: 0.9,
            restingHr: 52,
            avgHrv: 65,
            stagesJSON: nil
        )
        let persisted = CachedSleepSession(
            startTs: 1_900,
            endTs: 20_900,
            efficiency: 0.88,
            restingHr: 54,
            avgHrv: 63,
            stagesJSON: nil
        )

        let resolved = IntelligenceEngine.authoritativeShadowSleepSessions(
            detected: [detected],
            persisted: [persisted],
            edits: []
        )

        XCTAssertEqual(resolved.map(\.start), [persisted.startTs])
        XCTAssertEqual(resolved.map(\.end), [persisted.endTs])
    }

    func testImportedSleepReadFailureRetainsPreviouslyPublishedShadowRows() async throws {
        let harness = try await makeHarness()
        let day = try XCTUnwrap(dayWindows(1).first?.day)
        let source = Repository.whoopSource + "-noop"
        _ = try await harness.store.upsertMetricSeries([
            MetricPoint(day: day, key: PrimarySessionRestingHR.meanMetricKey, value: 54)
        ], deviceId: source)
        try await harness.store.registryWriter.write { db in
            try db.execute(sql: "ALTER TABLE sleepSession RENAME TO sleepSessionUnavailable")
        }

        let completed = await run(harness, maxDays: 1)

        XCTAssertFalse(completed)
        let retained = try await harness.store.metricSeries(
            deviceId: source, key: PrimarySessionRestingHR.meanMetricKey, from: day, to: day
        )
        XCTAssertEqual(retained.map(\.value), [54])
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

    func testPreSleepOptInChangeInvalidatesAllEligibleDays() async throws {
        let defaults = UserDefaults.standard
        let oldValue = defaults.object(forKey: PreSleepHeartRateFeedback.enabledKey)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: PreSleepHeartRateFeedback.enabledKey) }
            else { defaults.removeObject(forKey: PreSleepHeartRateFeedback.enabledKey) }
        }
        defaults.set(false, forKey: PreSleepHeartRateFeedback.enabledKey)
        let harness = try await makeHarness()
        let coldCompleted = await run(harness, maxDays: 2)
        XCTAssertTrue(coldCompleted)
        await harness.probe.resetBundleCalls()

        defaults.set(true, forKey: PreSleepHeartRateFeedback.enabledKey)
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

    func testExactCommittedSourceAnalysisReconcilesPrimaryButPreservesPreSleepConsentRows() async throws {
        let defaults = UserDefaults.standard
        let oldValue = defaults.object(forKey: PreSleepHeartRateFeedback.enabledKey)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: PreSleepHeartRateFeedback.enabledKey) }
            else { defaults.removeObject(forKey: PreSleepHeartRateFeedback.enabledKey) }
        }
        defaults.set(true, forKey: PreSleepHeartRateFeedback.enabledKey)

        let harness = try await makeHarness()
        let window = try XCTUnwrap(dayWindows(1).first)
        let day = window.day
        let computedSource = Repository.whoopSource + "-noop"
        let sleepStart = window.start - 60 * 60
        let sleepEnd = window.start + 7 * 60 * 60
        let retainedPreSleepPoints = [
            MetricPoint(day: day, key: PreSleepHeartRateFeedback.meanMetricKey, value: 64),
            MetricPoint(day: day, key: PreSleepHeartRateFeedback.validSamplesMetricKey, value: 30),
            MetricPoint(day: day, key: PreSleepHeartRateFeedback.totalSamplesMetricKey, value: 31),
            MetricPoint(
                day: day,
                key: PreSleepHeartRateFeedback.primarySleepStartMetricKey,
                value: Double(sleepStart)
            ),
            MetricPoint(
                day: day,
                key: PreSleepHeartRateFeedback.primarySleepEndMetricKey,
                value: Double(sleepEnd)
            ),
        ]
        let stalePrimaryPoints = PrimarySessionRestingHR.metricKeys.enumerated().map { index, key in
            MetricPoint(day: day, key: key, value: Double(50 + index))
        }
        _ = try await harness.store.upsertMetricSeries(
            retainedPreSleepPoints + stalePrimaryPoints,
            deviceId: computedSource
        )
        _ = try await harness.store.upsertSleepSessions([
            CachedSleepSession(
                startTs: sleepStart,
                endTs: sleepEnd,
                efficiency: 0.9,
                restingHr: 52,
                avgHrv: 64,
                stagesJSON: nil
            )
        ], deviceId: computedSource)

        let scope = try HistoricalAnalysisScope(
            databaseInstanceId: "exact-consent-test-db",
            sourceId: Repository.whoopSource,
            deviceId: Repository.whoopSource,
            deviceLineageId: "exact-consent-test-lineage",
            cursorEpoch: 0,
            trimScope: "historical"
        )
        let work = try HistoricalAnalysisWork(
            scope: scope,
            firstReceiptGeneration: 1,
            lastReceiptGeneration: 1,
            affectedDays: [try CivilDay(key: day)],
            recordedTimeZoneIdentifier: "GMT",
            createdAt: reference
        )

        // `analyzeCommittedWork` invokes this exact cache-free sourceContext lane. Keep the test on the
        // mutation boundary so its in-memory store remains isolated from the app's on-disk repository.
        let completed = await run(
            harness,
            maxDays: 1,
            sourceContext: ExactWorkSourceContext(work: work)
        )

        XCTAssertTrue(completed)
        for expected in retainedPreSleepPoints {
            let stored = try await harness.store.metricSeries(
                deviceId: computedSource,
                key: expected.key,
                from: day,
                to: day
            )
            XCTAssertEqual(stored, [expected], "exact source work must preserve consent-owned \(expected.key)")
        }
        for key in PrimarySessionRestingHR.metricKeys {
            let stored = try await harness.store.metricSeries(
                deviceId: computedSource,
                key: key,
                from: day,
                to: day
            )
            XCTAssertTrue(stored.isEmpty, "exact source work must still reconcile stale \(key)")
        }
    }

    func testExactSourceSleepDedupScrubsPreSleepRowsWhenBoundaryIdentityChangesGlobally() async throws {
        let defaults = UserDefaults.standard
        let oldValue = defaults.object(forKey: PreSleepHeartRateFeedback.enabledKey)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: PreSleepHeartRateFeedback.enabledKey) }
            else { defaults.removeObject(forKey: PreSleepHeartRateFeedback.enabledKey) }
        }
        defaults.set(true, forKey: PreSleepHeartRateFeedback.enabledKey)

        let harness = try await makeHarness()
        let window = try XCTUnwrap(dayWindows(1).first)
        let computedSource = Repository.whoopSource + "-noop"
        let orphanSource = "retired-exact-source-noop"
        let earlierStart = window.start - 60 * 60
        let earlierEnd = window.start + 7 * 60 * 60
        let shiftedStart = earlierStart + 10 * 60
        let shiftedEnd = earlierEnd + 10 * 60
        _ = try await harness.store.upsertSleepSessions([
            CachedSleepSession(
                startTs: earlierStart,
                endTs: earlierEnd,
                efficiency: 0.9,
                restingHr: 52,
                avgHrv: 64,
                stagesJSON: nil
            ),
            CachedSleepSession(
                startTs: shiftedStart,
                endTs: shiftedEnd,
                efficiency: 0.9,
                restingHr: 52,
                avgHrv: 64,
                stagesJSON: nil
            ),
        ], deviceId: computedSource)
        let priorObservation = [
            MetricPoint(day: window.day, key: PreSleepHeartRateFeedback.meanMetricKey, value: 64),
            MetricPoint(day: window.day, key: PreSleepHeartRateFeedback.validSamplesMetricKey, value: 30),
            MetricPoint(day: window.day, key: PreSleepHeartRateFeedback.totalSamplesMetricKey, value: 31),
            MetricPoint(
                day: window.day,
                key: PreSleepHeartRateFeedback.primarySleepStartMetricKey,
                value: Double(earlierStart)
            ),
            MetricPoint(
                day: window.day,
                key: PreSleepHeartRateFeedback.primarySleepEndMetricKey,
                value: Double(earlierEnd)
            ),
        ]
        for source in [computedSource, orphanSource] {
            _ = try await harness.store.upsertMetricSeries(priorObservation, deviceId: source)
        }

        let scope = try HistoricalAnalysisScope(
            databaseInstanceId: "exact-boundary-test-db",
            sourceId: Repository.whoopSource,
            deviceId: Repository.whoopSource,
            deviceLineageId: "exact-boundary-test-lineage",
            cursorEpoch: 0,
            trimScope: "historical"
        )
        let work = try HistoricalAnalysisWork(
            scope: scope,
            firstReceiptGeneration: 1,
            lastReceiptGeneration: 1,
            affectedDays: [try CivilDay(key: window.day)],
            recordedTimeZoneIdentifier: "GMT",
            createdAt: reference
        )

        let completed = await run(
            harness,
            maxDays: 1,
            sourceContext: ExactWorkSourceContext(work: work)
        )

        XCTAssertFalse(completed, "the dedup heal must request its bounded exact replay")
        let remainingSleep = try await harness.store.sleepSessions(
            deviceId: computedSource,
            from: window.start - 24 * 60 * 60,
            to: window.nextStart,
            limit: 10
        )
        XCTAssertEqual(remainingSleep.map(\.startTs), [shiftedStart])
        for source in [computedSource, orphanSource] {
            for key in PreSleepHeartRateFeedback.metricKeys {
                let remaining = try await harness.store.metricSeries(
                    deviceId: source,
                    key: key,
                    from: window.day,
                    to: window.day
                )
                XCTAssertTrue(
                    remaining.isEmpty,
                    "changed exact sleep authority must scrub \(source) \(key)"
                )
            }
        }
    }

    func testCacheHitStillRunsDailyReconciliationAndReceiptPath() async throws {
        let harness = try await makeHarness()
        let day = try XCTUnwrap(dayWindows(1).first?.day)
        let coldCompleted = await run(harness, maxDays: 1)
        XCTAssertTrue(coldCompleted)

        _ = try await harness.store.upsertDailyMetrics(
            [staleDaily(day)],
            deviceId: Repository.whoopSource + "-noop")
        _ = try await harness.store.upsertMetricSeries([
            .init(day: day, key: PrimarySessionRestingHR.meanMetricKey, value: 55),
            .init(day: day, key: PreSleepHeartRateFeedback.meanMetricKey, value: 70),
            .init(day: day, key: PreSleepHeartRateFeedback.validSamplesMetricKey, value: 12),
            .init(day: day, key: PreSleepHeartRateFeedback.totalSamplesMetricKey, value: 15),
        ], deviceId: Repository.whoopSource + "-noop")
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
        for key in PrimarySessionRestingHR.metricKeys + PreSleepHeartRateFeedback.metricKeys {
            let shadow = try await harness.store.metricSeries(
                deviceId: Repository.whoopSource + "-noop", key: key, from: day, to: day)
            XCTAssertTrue(shadow.isEmpty, "a cache hit must delete stale \(key)")
        }

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
