import Foundation
import XCTest
import NoopPhase34Core
import WhoopStore
@testable import NOOP

private enum PR28TestError: Error {
    case injected
}

private actor PR28PublicationProbe {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private actor PR28LeaseSequence {
    private var item: ExternalPublicationOutboxItem?

    init(item: ExternalPublicationOutboxItem) {
        self.item = item
    }

    func next() -> ExternalPublicationOutboxItem? {
        defer { item = nil }
        return item
    }
}

@MainActor
final class PR28Round3RootFixTests: XCTestCase {
    func testExactRepositoryReplacementUsesRequestedDaysForDeletionAcrossCacheFamilies() throws {
        let requested = try CivilDay(key: "2026-08-02")
        let other = try CivilDay(key: "2026-08-03")
        let requestedKey = requested.key
        let otherKey = other.key

        let metricRows = RepositoryExactAuthoritativeMerge.replaceAuthoritative(
            existing: [metric(day: requestedKey), metric(day: otherKey)],
            incoming: [],
            authoritativeKeys: [requestedKey],
            key: \.day,
            areInIncreasingOrder: { $0.day < $1.day })
        let sleepRows = RepositoryExactAuthoritativeMerge.replaceAuthoritative(
            existing: [requestedKey: "stale-sleep", otherKey: "kept-sleep"],
            incoming: [:],
            authoritativeKeys: [requestedKey])
        let vitalRows = RepositoryExactAuthoritativeMerge.replaceAuthoritative(
            existing: [requestedKey: "stale-vitals", otherKey: "kept-vitals"],
            incoming: [:],
            authoritativeKeys: [requestedKey])
        let strainRows = RepositoryExactAuthoritativeMerge.replaceAuthoritative(
            existing: [requestedKey: "stale-strain", otherKey: "kept-strain"],
            incoming: [:],
            authoritativeKeys: RepositoryExactAuthoritativeMerge.authoritativeDayKeys([requested]))

        XCTAssertEqual(metricRows.map(\.day), [otherKey])
        XCTAssertEqual(sleepRows, [otherKey: "kept-sleep"])
        XCTAssertEqual(vitalRows, [otherKey: "kept-vitals"])
        XCTAssertEqual(strainRows, [otherKey: "kept-strain"])
        XCTAssertEqual(
            RepositoryExactAuthoritativeMerge.authoritativeDayKeys([requested]),
            [requestedKey])
    }

    func testFallbackSourceWinnerPreservesStoredProvenance() throws {
        let day = "2026-08-02"
        let fallback = StoredSourcedDailyMetric(
            sourceId: "fallback-source",
            sourcePriority: 3,
            metric: metric(day: day, recovery: 71))
        let primary = StoredSourcedDailyMetric(
            sourceId: "primary-source",
            sourcePriority: 1,
            metric: metric(day: day, recovery: 64))

        let winners = RepositoryExactAuthoritativeMerge.bestRowsPreservingSource([primary, fallback])

        XCTAssertEqual(winners[day]?.sourceId, "fallback-source")
        XCTAssertEqual(winners[day]?.metric.recovery, 71)
    }

    func testPaddedSleepRowsAreIsolatedByExactWakeDay() throws {
        let prior = StoredSourcedSleepSession(
            sourceId: "imported",
            sourcePriority: 2,
            session: CachedSleepSession(startTs: 1_785_456_000, endTs: 1_785_499_200,
                                        efficiency: 0.8, restingHr: 50, avgHrv: 60, stagesJSON: nil))
        let requested = StoredSourcedSleepSession(
            sourceId: "imported",
            sourcePriority: 2,
            session: CachedSleepSession(startTs: 1_785_628_800, endTs: 1_785_672_000,
                                        efficiency: 0.9, restingHr: 51, avgHrv: 61, stagesJSON: nil))
        let next = StoredSourcedSleepSession(
            sourceId: "imported",
            sourcePriority: 2,
            session: CachedSleepSession(startTs: 1_785_801_600, endTs: 1_785_844_800,
                                        efficiency: 0.7, restingHr: 52, avgHrv: 62, stagesJSON: nil))

        let result = try RepositoryExactAuthoritativeMerge.exactSleepRows(
            [prior, requested, next],
            importedSourceIds: ["imported"],
            computedSourceIds: [],
            authoritativeDayKeys: ["2026-08-02"],
            timeZoneIdentifier: "UTC")

        XCTAssertEqual(result.imported.map { $0.startTs }, [1_785_628_800])
        XCTAssertTrue(result.computed.isEmpty)
    }

    func testSourceTransitionFenceFailsClosedAndRunsTheNextOperation() async throws {
        let fence = SourceTransitionFence()
        do {
            _ = try await fence.runThrowing { () async throws -> Void in
                throw PR28TestError.injected
            }
            XCTFail("injected source transition failure was swallowed")
        } catch PR28TestError.injected {
            // Expected: registry and source state must not advance after a failed phase.
        }

        var nextRan = false
        try await fence.runThrowing { () async throws -> Void in
            nextRan = true
        }
        XCTAssertTrue(nextRan)
    }

    func testAppGroupSinkEpochRejectsLateOldWriterAndReadbackFailure() throws {
        let suite = "noop.pr28.round3.sink.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let epochA = try XCTUnwrap(ActiveVerifiedSinkEpochStore.beginTransition(defaults: defaults))
        let tokenA = try XCTUnwrap(
            ActiveVerifiedSinkEpochStore.activate(contextId: "context-A", epoch: epochA, defaults: defaults))
        XCTAssertEqual(
            ActiveVerifiedSinkEpochStore.commitIfCurrent(
                token: tokenA,
                generation: 1,
                defaults: defaults,
                generationKey: ActiveVerifiedSinkEpochStore.widgetGenerationKey,
                writeAndReadBackPayload: { values in
                    values.set(Data("A".utf8), forKey: "core")
                    return values.data(forKey: "core") == Data("A".utf8)
                }),
            .published)

        let epochB = try XCTUnwrap(ActiveVerifiedSinkEpochStore.beginTransition(defaults: defaults))
        let tokenB = try XCTUnwrap(
            ActiveVerifiedSinkEpochStore.activate(contextId: "context-B", epoch: epochB, defaults: defaults))
        XCTAssertEqual(
            ActiveVerifiedSinkEpochStore.commitIfCurrent(
                token: tokenA,
                generation: 2,
                defaults: defaults,
                generationKey: ActiveVerifiedSinkEpochStore.widgetGenerationKey,
                writeAndReadBackPayload: { _ in true }),
            .superseded)
        XCTAssertEqual(
            ActiveVerifiedSinkEpochStore.commitIfCurrent(
                token: tokenB,
                generation: 1,
                defaults: defaults,
                generationKey: ActiveVerifiedSinkEpochStore.widgetGenerationKey,
                writeAndReadBackPayload: { _ in false }),
            .failed)
        let generationData = try XCTUnwrap(
            defaults.data(forKey: ActiveVerifiedSinkEpochStore.widgetGenerationKey))
        let generation = try JSONDecoder().decode(VerifiedSinkGenerationRecord.self, from: generationData)
        XCTAssertEqual(generation.generation, 1)
        XCTAssertEqual(generation.contextId, "context-A")
    }

    func testWidgetLiveOverlayRequiresExactVerifiedIdentityAndNeverChangesVerifiedCore() throws {
        let suite = "noop.pr28.round3.widget.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let epoch = try XCTUnwrap(ActiveVerifiedSinkEpochStore.beginTransition(defaults: defaults))
        let token = try XCTUnwrap(
            ActiveVerifiedSinkEpochStore.activate(contextId: "context-A", epoch: epoch, defaults: defaults))
        let verified = WidgetSnapshot.publishing(
            recovery: 70, storedStrain: 40, sleepScore: 82, bpm: 60, batteryPct: 90,
            bonded: true, hrv: 65, restingHr: 51,
            verifiedContextId: "context-A", verifiedProjectionGeneration: 3,
            updated: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(verified.saveAndReadBack(to: defaults))

        let mismatched = WidgetLiveOverlay(
            epoch: epoch, contextId: "context-B", generation: 3, bpm: 120, batteryPct: 1,
            bonded: false, hrSparkline: [120], updated: Date())
        XCTAssertFalse(ActiveVerifiedSinkEpochStore.commitLiveOverlayIfCurrent(
            token: token, generation: 3, defaults: defaults, overlay: mismatched))

        let matching = WidgetLiveOverlay(
            epoch: epoch, contextId: "context-A", generation: 3, bpm: 120, batteryPct: 1,
            bonded: false, hrSparkline: [120], updated: Date())
        XCTAssertTrue(ActiveVerifiedSinkEpochStore.commitLiveOverlayIfCurrent(
            token: token, generation: 3, defaults: defaults, overlay: matching))
        let storedCore = try XCTUnwrap(defaults.data(forKey: WidgetSnapshot.storageKey))
        let decodedCore = try JSONDecoder().decode(WidgetSnapshot.self, from: storedCore)
        XCTAssertEqual(decodedCore.verifiedContextId, "context-A")
        XCTAssertEqual(decodedCore.verifiedProjectionGeneration, 3)
        XCTAssertEqual(decodedCore.recovery, verified.recovery)
        XCTAssertEqual(decodedCore.hrv, verified.hrv)
    }

    func testLiveAndVerifiedActivityKitCommandsRemainStrictlySerialized() async throws {
        let token = VerifiedSinkToken(epoch: 1, contextId: "context")
        var calls: [String] = []
        let publication = SerializedLiveActivityCommands<String>(
            validate: { candidate in candidate == token },
            perform: { payload, _ in
                if payload == "verified" {
                    try await Task.sleep(for: .milliseconds(25))
                }
                calls.append(payload)
                return .published
            },
            repairStale: {})

        let verified = Task { @MainActor in
            try await publication.submitVerified("verified", token: token)
        }
        try await Task.sleep(for: .milliseconds(5))
        publication.submitLive("live-old", token: nil)
        publication.submitLive("live-new", token: nil)

        let verifiedResult = try await verified.value
        XCTAssertEqual(verifiedResult, .published)
        _ = try await publication.submitBarrier("live-final")
        XCTAssertEqual(calls, ["verified", "live-new", "live-final"])
    }

    func testExternalWorkerQuiescesSuspendedHealthKitBeforeSourceTransition() async throws {
        let day = try CivilDay(key: "2026-08-02")
        let payload = try HistoricalHealthKitMutationPayload(
            contextId: "context",
            deviceId: "device",
            analysisGeneration: 8,
            recordedTimeZoneIdentifier: "UTC",
            changedDays: [day],
            dailyMutations: [],
            sleepMutations: [])
        let item = try ExternalPublicationOutboxItem(
            contextId: "context",
            deviceId: "device",
            snapshotGeneration: 1,
            analysisGeneration: 8,
            changedDays: [day],
            recordedTimeZoneIdentifier: "UTC",
            healthKitPayload: payload,
            destination: .healthKit,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let sequence = PR28LeaseSequence(item: item)
        let probe = PR28PublicationProbe()
        let worker = ExternalPublicationWorker(
            dependencies: ExternalPublicationWorkerDependencies(
                leaseNext: { _, _, _, _ in await sequence.next() },
                applyEvent: { _, event, _ in
                    await probe.append("event:\(event)")
                    return item
                },
                loadBundle: { _, _ in
                    await probe.append("projection")
                    return nil
                },
                publishWidget: { _ in .published },
                publishLiveActivity: { _ in .published },
                publishHealthKitWriteOnly: { _ in
                    await probe.append("healthKit-started")
                    try await Task.sleep(for: .seconds(60))
                    return .published
                },
                publishWatch: { _ in .published },
                classifyError: { _ in
                    PipelineFailureClassification(code: "test", disposition: .retryable)
                },
                pruneCompleted: {},
                report: { _ in },
                now: { Date(timeIntervalSince1970: 1_800_000_000) }))

        let signal = Task { await worker.signal(maximumItems: 1) }
        for _ in 0..<100 {
            let events = await probe.snapshot()
            if events.contains("healthKit-started") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let startedEvents = await probe.snapshot()
        XCTAssertTrue(startedEvents.contains("healthKit-started"))

        let epoch = try await worker.quiesce()
        await signal.value
        try await worker.resume(expectedEpoch: epoch)

        let events = await probe.snapshot()
        XCTAssertFalse(events.contains { $0.contains("succeeded") })
    }

    func testPayloadOnlyHealthKitLanePublishesWithoutAProjection() async throws {
        let day = try CivilDay(key: "2026-08-02")
        let payload = try HistoricalHealthKitMutationPayload(
            contextId: "context",
            deviceId: "device",
            analysisGeneration: 8,
            recordedTimeZoneIdentifier: "UTC",
            changedDays: [day],
            dailyMutations: [],
            sleepMutations: [])
        let item = try ExternalPublicationOutboxItem(
            contextId: "context",
            deviceId: "device",
            snapshotGeneration: 1,
            analysisGeneration: 8,
            changedDays: [day],
            recordedTimeZoneIdentifier: "UTC",
            healthKitPayload: payload,
            destination: .healthKit,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let sequence = PR28LeaseSequence(item: item)
        let probe = PR28PublicationProbe()

        let worker = ExternalPublicationWorker(
            dependencies: ExternalPublicationWorkerDependencies(
                leaseNext: { _, _, _, _ in await sequence.next() },
                applyEvent: { _, _, _ in
                    await probe.append("event")
                    return item
                },
                loadBundle: { _, _ in
                    await probe.append("projection")
                    return nil
                },
                publishWidget: { _ in
                    await probe.append("widget")
                    return .published
                },
                publishLiveActivity: { _ in
                    await probe.append("live")
                    return .published
                },
                publishHealthKitWriteOnly: { _ in
                    await probe.append("healthKit")
                    return .published
                },
                publishWatch: { _ in
                    await probe.append("watch")
                    return .published
                },
                classifyError: { _ in
                    PipelineFailureClassification(code: "test", disposition: .retryable)
                },
                pruneCompleted: {},
                report: { _ in },
                now: { Date(timeIntervalSince1970: 1_800_000_000) }))

        await worker.signal(maximumItems: 1)
        let events = await probe.snapshot()
        XCTAssertTrue(events.contains("healthKit"))
        XCTAssertFalse(events.contains("projection"))
        XCTAssertFalse(events.contains("widget"))
    }

    func testHistoricalPlannerIgnoresStaleTemplateAndKeepsSparseRuns() throws {
        let day = try CivilDay(key: "2026-08-01")
        let template = TodayHealthSnapshot(
            scopeId: "scope",
            deviceId: "device",
            displayDay: "2000-01-01",
            logicalDay: "2000-01-01",
            localDay: "2000-01-01",
            generatedAt: 1,
            dailyMetric: metric(day: "2000-01-01"))
        let windows = try RepositoryHistoricalWindowPlanner.make(
            analyzedDays: [day],
            recordedTimeZoneIdentifier: "UTC",
            template: template,
            now: Date(timeIntervalSince1970: 1_785_931_200))

        XCTAssertFalse(windows.contains { $0.fromDay == "2000-01-01" })
        let coalesced = RepositoryHistoricalWindowPlanner.coalesced([
            CanonicalHealthSurfaceReadWindow(
                fromDay: "2026-01-01", throughDay: "2026-01-02", sleepFromTs: 1, sleepThroughTs: 3),
            CanonicalHealthSurfaceReadWindow(
                fromDay: "2026-01-02", throughDay: "2026-01-03", sleepFromTs: 2, sleepThroughTs: 4),
            CanonicalHealthSurfaceReadWindow(
                fromDay: "2026-03-01", throughDay: "2026-03-01", sleepFromTs: 10, sleepThroughTs: 11)
        ])
        XCTAssertEqual(coalesced.count, 2)
        XCTAssertEqual(coalesced.first?.fromDay, "2026-01-01")
        XCTAssertEqual(coalesced.first?.throughDay, "2026-01-03")
    }

    func testTrendsBoundsClampIntMinAndCapHistoryBeforeArithmetic() {
        XCTAssertEqual(TrendsBounds.clampWeekOffset(Int.min), TrendsBounds.minimumWeekOffset)
        XCTAssertEqual(TrendsBounds.clampRangeDays(Int.max), TrendsBounds.maximumRangeDays)
        XCTAssertLessThanOrEqual(
            TrendsBounds.requiredDays(rangeDays: Int.max, weekOffset: Int.min),
            TrendsBounds.maximumRequiredDays)
    }

    private func metric(day: String, recovery: Double? = 70) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: 420,
            efficiency: 0.9,
            deepMin: 90,
            remMin: 110,
            lightMin: 220,
            disturbances: 2,
            restingHr: 52,
            avgHrv: 64,
            recovery: recovery,
            strain: 40,
            exerciseCount: 1,
            strainVersion: 2)
    }
}
