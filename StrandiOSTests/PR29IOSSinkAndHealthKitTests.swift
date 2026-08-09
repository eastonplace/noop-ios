import Foundation
import HealthKit
import XCTest
import NoopPhase34Core
import WhoopProtocol
import WhoopStore
@testable import NOOP

@MainActor
private final class VerifiedSinkLifecycleProbe {
    var events: [String] = []
}

@MainActor
final class PR29IOSSinkAndHealthKitTests: XCTestCase {
    func testPrivacyCleanupBackgroundRetryPolicySchedulesOnlyRetryableGates() {
        let id = UUID()
        XCTAssertEqual(
            SourcePrivacyCleanupBackgroundRetryPolicy.delay(
                for: SourcePrivacyCleanupCoordinatorError.pending(id)
            ),
            SourcePrivacyCleanupBackgroundRetryPolicy.pendingDelay
        )
        XCTAssertEqual(
            SourcePrivacyCleanupBackgroundRetryPolicy.delay(
                for: SourcePrivacyCleanupCoordinatorError.authorizationUnavailable(id)
            ),
            SourcePrivacyCleanupBackgroundRetryPolicy.authorizationDelay
        )
        XCTAssertEqual(
            SourcePrivacyCleanupBackgroundRetryPolicy.delay(
                for: SourcePrivacyCleanupCoordinatorError.quarantinedGroup(id)
            ),
            SourcePrivacyCleanupBackgroundRetryPolicy.quarantineCooldownDelay
        )
        XCTAssertEqual(
            SourcePrivacyCleanupBackgroundState.authorizationBlocked(
                until: Date(timeIntervalSince1970: 200)
            ).retryDelay(from: Date(timeIntervalSince1970: 100)),
            100
        )
        XCTAssertEqual(
            SourcePrivacyCleanupBackgroundState.quarantined(
                until: Date(timeIntervalSince1970: 300)
            ).retryDelay(from: Date(timeIntervalSince1970: 100)),
            200
        )
        XCTAssertNil(SourcePrivacyCleanupBackgroundRetryPolicy.delay(
            for: SourcePrivacyCleanupCoordinatorError.storeUnavailable
        ))
        XCTAssertNil(SourcePrivacyCleanupBackgroundRetryPolicy.delay(for: CancellationError()))
    }

    func testHealthKitCleanupPlannerCapsCivilWindowsAndKeepsDenseCursor() throws {
        let first = try CivilDay(key: "2020-01-01")
        let through = try CivilDay(key: "2020-12-31")
        let dailyRequest = HealthKitSourceDeletionChunkRequest(
            sourceDeviceId: "source-a",
            remainingImportedIds: ["source-b"],
            remainingComputedIds: ["source-b-noop"],
            category: .sleep,
            firstDay: first,
            throughDay: through,
            timeZoneIdentifier: "America/New_York"
        )
        let dailyInterval = try HealthKitSourceDeletionChunkPlanner.interval(for: dailyRequest)
        XCTAssertEqual(dailyInterval.firstDay.key, "2020-01-01")
        XCTAssertEqual(dailyInterval.lastDay.key, "2020-01-30")

        let denseCursor = HealthKitSourceDeletionCursor(
            category: .heartRate,
            day: first,
            phase: .deletingProjectedSamples,
            componentIndex: 0,
            lastTimestamp: 1_577_880_000,
            stableTieBreaker: "sample-5000"
        )
        let encoded = try JSONEncoder().encode(denseCursor)
        XCTAssertEqual(try JSONDecoder().decode(
            HealthKitSourceDeletionCursor.self,
            from: encoded
        ), denseCursor)
        let heartRateRequest = HealthKitSourceDeletionChunkRequest(
            sourceDeviceId: "source-a",
            remainingImportedIds: ["source-b"],
            remainingComputedIds: [],
            category: .heartRate,
            firstDay: first,
            throughDay: through,
            timeZoneIdentifier: "America/New_York",
            cursor: denseCursor
        )
        let heartRateInterval = try HealthKitSourceDeletionChunkPlanner.interval(for: heartRateRequest)
        XCTAssertEqual(heartRateInterval.firstDay, first)
        XCTAssertEqual(heartRateInterval.lastDay.key, "2020-01-03")
        XCTAssertEqual(HealthKitSourceDeletionChunkPlanner.maximumObjectsPerQuery, 5_000)
    }

    func testWorkoutPrivacyCleanupOwnsWorkoutEnergyAndDistanceSamples() throws {
        let types = HealthKitBridge.sourceDeletionTypes(for: .workouts)
        let identifiers = Set(types.map(\.identifier))
        XCTAssertEqual(identifiers, Set([
            HKObjectType.workoutType().identifier,
            try XCTUnwrap(HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)).identifier,
            try XCTUnwrap(HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)).identifier,
            try XCTUnwrap(HKQuantityType.quantityType(forIdentifier: .distanceCycling)).identifier,
        ]))
        XCTAssertEqual(
            HealthKitSourceDeletionChunkPlanner.deletionComponentCount(for: .workouts),
            types.count
        )
    }

    func testWorkoutReplayAfterFinishCrashReplacesOneNOOPOwnedFinalSet() {
        let startTimestamp = 1_786_147_200
        let plan = HealthKitWorkoutReplayPlan(
            noopDeviceId: "my-whoop-noop",
            startTimestamps: [startTimestamp]
        )
        let thirdPartyIdentity = "third-party:workout:\(startTimestamp)"
        var persisted: [String: Int] = [thirdPartyIdentity: 1]

        func finishWorkout(distance: HealthKitWorkoutReplayComponent) {
            for component in [
                HealthKitWorkoutReplayComponent.workout,
                .activeEnergy,
                distance,
            ] {
                let identity = plan.externalUUID(
                    component: component,
                    startTimestamp: startTimestamp
                )
                persisted[identity, default: 0] += 1
            }
        }

        // The first finish succeeds. The process then dies before the durable
        // cleanup cursor records the row.
        finishWorkout(distance: .distanceWalkingRunning)

        // Replay deletes every deterministic NOOP-owned component, including
        // both distance types, before it rebuilds the corrected workout.
        for component in HealthKitWorkoutReplayComponent.allCases {
            for identity in plan.externalUUIDs(for: component) {
                persisted.removeValue(forKey: identity)
            }
        }
        finishWorkout(distance: .distanceCycling)

        let workoutIdentity = plan.externalUUID(
            component: .workout,
            startTimestamp: startTimestamp
        )
        let energyIdentity = plan.externalUUID(
            component: .activeEnergy,
            startTimestamp: startTimestamp
        )
        let walkingIdentity = plan.externalUUID(
            component: .distanceWalkingRunning,
            startTimestamp: startTimestamp
        )
        let cyclingIdentity = plan.externalUUID(
            component: .distanceCycling,
            startTimestamp: startTimestamp
        )
        XCTAssertEqual(persisted[workoutIdentity], 1)
        XCTAssertEqual(persisted[energyIdentity], 1)
        XCTAssertNil(persisted[walkingIdentity])
        XCTAssertEqual(persisted[cyclingIdentity], 1)
        XCTAssertEqual(persisted[thirdPartyIdentity], 1)
        XCTAssertEqual(
            Set([
                workoutIdentity,
                energyIdentity,
                walkingIdentity,
                cyclingIdentity,
            ]).count,
            4
        )
        XCTAssertTrue([
            workoutIdentity,
            energyIdentity,
            walkingIdentity,
            cyclingIdentity,
        ].allSatisfy { $0.hasPrefix("noop:my-whoop-noop:workout") })
    }

    func testPrivacyCleanupDoesNotAdvanceWhenAnyRequiredShareGrantIsMissing() throws {
        let denied = try XCTUnwrap(
            HKQuantityType.quantityType(forIdentifier: .distanceCycling)
        ).identifier
        XCTAssertFalse(HealthKitBridge.sourceDeletionAuthorizationAvailable(
            for: .workouts,
            authorizationStatus: { type in
                type.identifier == denied ? .sharingDenied : .sharingAuthorized
            }
        ))
        XCTAssertTrue(HealthKitBridge.sourceDeletionAuthorizationAvailable(
            for: .workouts,
            authorizationStatus: { _ in .sharingAuthorized }
        ))
    }

    func testReconnectCannotReopenLifecycleSuspension() async throws {
        let token = VerifiedSinkToken(epoch: 1, contextId: "context")
        var calls: [String] = []
        let publication = SerializedLiveActivityCommands<String>(
            validate: { $0 == token },
            perform: { payload, _ in
                calls.append(payload)
                return .published
            },
            repairStale: {}
        )

        publication.suspendForLifecycleTransition()
        publication.setConnectivityAvailable(true)
        publication.submitLive("stale-connected", token: nil)
        _ = try await publication.submitBarrier("barrier")
        XCTAssertEqual(calls, ["barrier"])

        publication.activateLifecycleSubmissions()
        publication.submitLive("fresh", token: nil)
        try await Task.sleep(for: .milliseconds(5))
        _ = try await publication.submitBarrier("flush")
        XCTAssertEqual(calls, ["barrier", "fresh", "flush"])
    }

    func testVerifiedSinkLifecycleOrdersBarrierClearReloadAndActivationReload() async {
        let probe = VerifiedSinkLifecycleProbe()
        let lifecycle = IOSVerifiedSinkLifecycle(dependencies: .init(
            suspendAndEndLiveActivity: { probe.events.append("live-barrier") },
            clearWidgetState: { probe.events.append("widget-clear") },
            reloadWidgets: { probe.events.append("widget-reload") },
            activateLiveActivity: { contextId, epoch in
                probe.events.append("activate:\(contextId):\(epoch)")
                return true
            }
        ))

        await lifecycle.prepareTransition(scope: .clearPrivacyVisibleState)
        XCTAssertTrue(lifecycle.activate(contextId: "context-b", epoch: 9))
        XCTAssertEqual(probe.events, [
            "live-barrier",
            "widget-clear",
            "widget-reload",
            "activate:context-b:9",
            "widget-reload",
        ])
    }

    func testWidgetCorePublicationPreservesImmutableRecoveryDelta() throws {
        let day = try CivilDay(key: "2026-08-08")
        let projection = try VerifiedHealthProjection(
            contextId: "context",
            deviceId: "source-a",
            generation: 8,
            logicalDay: day,
            metrics: [:]
        )
        let core = try VerifiedWidgetCorePayload(
            contextId: "context",
            projectionGeneration: 8,
            logicalDay: day,
            restingHR: 51,
            sleepMinutes: 420,
            steps: 8_000,
            calories: 2_100,
            recoveryDelta: -7,
            recordedTimeZoneIdentifier: "America/New_York",
            enrichmentSourceIds: ["source-a", "source-a-noop"]
        )
        let bundle = try VerifiedExternalProjectionBundle(
            projection: projection,
            widgetCore: core
        )

        let snapshot = WidgetCorePublication.makeCoreSnapshot(
            bundle: bundle,
            bpm: 72,
            batteryPct: 82,
            bonded: true,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(snapshot.recoveryDelta, -7)
    }

    func testWidgetHRVEnrichmentUsesOnlyVerifiedSourceOrder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-08-06", key: "hrv", value: 40),
            MetricPoint(day: "2026-08-07", key: "hrv", value: 41),
        ], deviceId: "source-a")
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-08-07", key: "hrv", value: 70),
            MetricPoint(day: "2026-08-08", key: "hrv", value: 71),
        ], deviceId: "source-b")
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-08-08", key: "hrv", value: 999),
        ], deviceId: "my-whoop")

        let points = try await WidgetSnapshot.verifiedHRVSeries(
            store: store,
            sourceIds: ["source-b", "source-a"],
            anchorDay: CivilDay(key: "2026-08-08")
        )
        XCTAssertEqual(points.map(\.day), ["2026-08-06", "2026-08-07", "2026-08-08"])
        XCTAssertEqual(points.map(\.value), [40, 70, 71])
    }

    func testWidgetStressEnrichmentUsesVerifiedDayAndSourceOrder() async throws {
        let store = try await WhoopStore.inMemory()
        let anchorDay = try CivilDay(key: "2026-08-08")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let anchor = Int(try anchorDay.date(in: calendar).timeIntervalSince1970)
        _ = try await store.insert(Streams(
            hr: [HRSample(ts: anchor + 60, bpm: 72)],
            rr: [RRInterval(ts: anchor + 60, rrMs: 810)]
        ), deviceId: "source-b")
        _ = try await store.insert(Streams(
            hr: [HRSample(ts: anchor + 60, bpm: 155)],
            rr: [RRInterval(ts: anchor + 60, rrMs: 400)]
        ), deviceId: "source-a")
        _ = try await store.insert(Streams(
            hr: [HRSample(ts: anchor + 86_400 + 60, bpm: 199)],
            rr: [RRInterval(ts: anchor + 86_400 + 60, rrMs: 300)]
        ), deviceId: "my-whoop")

        let input = try await WidgetSnapshot.verifiedStressInput(
            store: store,
            sourceIds: ["source-b", "source-a"],
            anchorDay: anchorDay,
            timeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(input.hr, [HRSample(ts: anchor + 60, bpm: 72)])
        XCTAssertEqual(input.rr, [RRInterval(ts: anchor + 60, rrMs: 810)])
        XCTAssertEqual(input.timeZoneOffsetSeconds, 0)
    }

    private func seedIncompleteRepositoryArtifact(
        store: WhoopStore,
        databaseInstanceId: String,
        index: Int,
        includeImmutableSnapshot: Bool,
        createdAt: Int
    ) async throws -> (
        receipt: SnapshotCommitReceipt,
        snapshot: TodayHealthSnapshot,
        projection: VerifiedHealthProjection
    ) {
        let deviceId = "repair-source-\(index)"
        let context = TodayHealthSnapshotContext(
            databaseInstanceId: databaseInstanceId,
            dashboardProfileId: "repository-artifact-repair-\(index)",
            sourceLineage: "\(deviceId),\(deviceId)-noop",
            algorithmBundleVersion: "v51-test"
        )
        let day = try CivilDay(key: "2026-08-08")
        let generation = Int64(index + 1)
        let recovery = try VerifiedHealthMetric(
            kind: .recovery,
            value: 73,
            metricDay: day,
            sourceId: deviceId + "-noop",
            algorithmVersion: "v51-test",
            generation: generation,
            freshness: .fresh
        )
        let projection = try VerifiedHealthProjection(
            contextId: context.identifier,
            deviceId: deviceId,
            generation: generation,
            logicalDay: day,
            metrics: [.recovery: recovery]
        )
        let receipt = try SnapshotCommitReceipt(
            throughReceiptGeneration: generation,
            analysisGeneration: generation,
            snapshotGeneration: generation,
            analyzedDays: [day],
            recordedTimeZoneIdentifier: "UTC",
            projection: projection
        )
        let daily = DailyMetric(
            day: day.key,
            totalSleepMin: 440,
            efficiency: 0.9,
            deepMin: 90,
            remMin: 100,
            lightMin: 250,
            disturbances: 4,
            restingHr: 51,
            avgHrv: 62,
            recovery: 73,
            strain: 61,
            exerciseCount: 1,
            steps: 8_000,
            activeKcalEst: 600,
            strainVersion: 2
        )
        let snapshot = TodayHealthSnapshot(
            scopeId: "dashboard|\(context.identifier)",
            context: context,
            deviceId: deviceId,
            displayDay: day.key,
            logicalDay: day.key,
            localDay: day.key,
            generatedAt: createdAt,
            rawFrontierTs: createdAt - 1,
            generation: generation,
            authoritativeMetrics: [],
            dailyMetric: daily
        )
        if includeImmutableSnapshot {
            let saved = try await store.saveTodayHealthSnapshot(snapshot)
            XCTAssertTrue(saved)
        }
        _ = try await store.recordVerifiedSnapshotCommit(
            receipt,
            now: Date(timeIntervalSince1970: TimeInterval(createdAt))
        )
        return (receipt, snapshot, projection)
    }

    private func repairedWidgetCore(
        currentRecovery: Double,
        previousRecovery: Double?,
        mutatedPreviousRecovery: Double? = nil,
        projectionDeviceId: String = "source-a",
        recoverySourceId: String = "source-a-noop",
        previousSourceId: String = "source-a",
        recordedTimeZoneIdentifier: String = "America/New_York"
    ) async throws -> VerifiedWidgetCorePayload {
        let store = try await WhoopStore.inMemory()
        let databaseInstanceId = try await store.databaseInstanceId()
        let context = TodayHealthSnapshotContext(
            databaseInstanceId: databaseInstanceId,
            dashboardProfileId: "repository-artifact-repair",
            sourceLineage: "\(projectionDeviceId),\(recoverySourceId)",
            algorithmBundleVersion: "v51-test"
        )
        let day = try CivilDay(key: "2026-08-08")
        let recovery = try VerifiedHealthMetric(
            kind: .recovery,
            value: currentRecovery,
            metricDay: day,
            sourceId: recoverySourceId,
            algorithmVersion: "v51-test",
            generation: 1,
            freshness: .fresh
        )
        let projection = try VerifiedHealthProjection(
            contextId: context.identifier,
            deviceId: projectionDeviceId,
            generation: 1,
            logicalDay: day,
            metrics: [.recovery: recovery]
        )
        let receipt = try SnapshotCommitReceipt(
            throughReceiptGeneration: 1,
            analysisGeneration: 1,
            snapshotGeneration: 1,
            analyzedDays: [day],
            recordedTimeZoneIdentifier: recordedTimeZoneIdentifier,
            projection: projection
        )

        func dailyMetric(day: String, recovery: Double) -> DailyMetric {
            DailyMetric(
                day: day,
                totalSleepMin: 440,
                efficiency: 0.9,
                deepMin: 90,
                remMin: 100,
                lightMin: 250,
                disturbances: 4,
                restingHr: 51,
                avgHrv: 62,
                recovery: recovery,
                strain: 61,
                exerciseCount: 1,
                steps: 8_000,
                activeKcalEst: 600,
                strainVersion: 2
            )
        }

        let daily = dailyMetric(day: day.key, recovery: currentRecovery)
        let snapshot = TodayHealthSnapshot(
            scopeId: "dashboard|\(context.identifier)",
            context: context,
            deviceId: projectionDeviceId,
            displayDay: day.key,
            logicalDay: day.key,
            localDay: day.key,
            generatedAt: 1_800_000_000,
            rawFrontierTs: 1_799_999_900,
            generation: 1,
            authoritativeMetrics: [],
            dailyMetric: daily
        )
        let saved = try await store.saveTodayHealthSnapshot(snapshot)
        XCTAssertTrue(saved)
        let calendar = try HealthCalendar(timeZoneIdentifier: recordedTimeZoneIdentifier)
        let previousDay = try calendar.adding(days: -1, to: day)
        if let previousRecovery {
            _ = try await store.upsertDailyMetrics(
                [dailyMetric(day: previousDay.key, recovery: previousRecovery)],
                deviceId: previousSourceId
            )
        }
        if previousSourceId != projectionDeviceId {
            _ = try await store.upsertDailyMetrics(
                [dailyMetric(day: previousDay.key, recovery: 10)],
                deviceId: projectionDeviceId
            )
        }
        _ = try await store.upsertDailyMetrics(
            [dailyMetric(day: previousDay.key, recovery: 1)],
            deviceId: "unrelated-source"
        )
        _ = try await store.recordVerifiedSnapshotCommit(
            receipt,
            now: Date(timeIntervalSince1970: 1_800_000_001)
        )
        let before = try await store.verifiedExternalProjectionArtifacts(
            contextId: projection.contextId,
            generation: projection.generation
        )
        XCTAssertNil(before.widgetCore)

        // Legacy commits did not retain the prior-day WAL evidence. Mutating that row after verification
        // must not let repair manufacture a new delta for the old generation.
        if let mutatedPreviousRecovery {
            _ = try await store.upsertDailyMetrics(
                [dailyMetric(day: previousDay.key, recovery: mutatedPreviousRecovery)],
                deviceId: previousSourceId
            )
        }

        // A later mutable Today row is also outside the verified artifact generation.
        let laterSnapshot = TodayHealthSnapshot(
            scopeId: snapshot.scopeId,
            context: context,
            deviceId: projectionDeviceId,
            displayDay: day.key,
            logicalDay: day.key,
            localDay: day.key,
            generatedAt: 1_800_000_002,
            rawFrontierTs: 1_800_000_001,
            generation: 2,
            authoritativeMetrics: [],
            dailyMetric: dailyMetric(day: day.key, recovery: 5)
        )
        let laterSaved = try await store.saveTodayHealthSnapshot(laterSnapshot)
        XCTAssertTrue(laterSaved)

        let repository = Repository(deviceId: projectionDeviceId)
        repository.setStoreForTesting(store)
        let repairedCount = await repository.repairIncompleteVerifiedArtifacts(limit: 25)
        XCTAssertEqual(repairedCount, 1)

        let repairedValue = try await store.verifiedExternalProjectionBundle(
            contextId: projection.contextId,
            generation: projection.generation
        )
        let repaired = try XCTUnwrap(repairedValue)
        return repaired.widgetCore
    }

    func testRepositoryLegacyRepairOmitsDeltaAfterPriorDayMutation() async throws {
        let core = try await repairedWidgetCore(
            currentRecovery: 73,
            previousRecovery: 68,
            mutatedPreviousRecovery: 99,
            projectionDeviceId: "source-b",
            recoverySourceId: "source-a-noop",
            previousSourceId: "source-a"
        )
        XCTAssertEqual(core.logicalDay, try CivilDay(key: "2026-08-08"))
        XCTAssertNil(core.recoveryDelta)
        XCTAssertEqual(
            core.recordedTimeZoneIdentifier,
            "America/New_York"
        )
        XCTAssertEqual(
            core.enrichmentSourceIds,
            ["source-a", "source-a-noop", "source-b", "source-b-noop"]
        )
    }

    func testRepositoryRepairAdvancesPastPermanentPublicationConflict() async throws {
        let store = try await WhoopStore.inMemory()
        let databaseInstanceId = try await store.databaseInstanceId()
        // Save the repairable snapshot first so its caller generation matches SQLite's assigned generation.
        let repairable = try await seedIncompleteRepositoryArtifact(
            store: store,
            databaseInstanceId: databaseInstanceId,
            index: 0,
            includeImmutableSnapshot: true,
            createdAt: 100
        )
        for index in 1...26 {
            _ = try await seedIncompleteRepositoryArtifact(
                store: store,
                databaseInstanceId: databaseInstanceId,
                index: index,
                includeImmutableSnapshot: false,
                createdAt: 100 + index
            )
        }

        let conflictingProjection = try VerifiedHealthProjection(
            contextId: repairable.projection.contextId,
            deviceId: "conflicting-source",
            generation: repairable.projection.generation,
            logicalDay: repairable.projection.logicalDay,
            metrics: [:]
        )
        let conflictingCore = try VerifiedWidgetCorePayload(
            contextId: conflictingProjection.contextId,
            projectionGeneration: conflictingProjection.generation,
            logicalDay: conflictingProjection.logicalDay,
            restingHR: 51,
            sleepMinutes: 440,
            steps: 8_000,
            calories: 2_100,
            recoveryDelta: 1,
            recordedTimeZoneIdentifier: "UTC",
            enrichmentSourceIds: ["conflicting-source"]
        )
        try await store.recordLatestStateDeliveryCheckpoint(
            projection: conflictingProjection,
            widgetCore: conflictingCore,
            destination: .widget,
            deliveredAt: Date(timeIntervalSince1970: 201)
        )

        let repository = Repository(deviceId: repairable.projection.deviceId)
        repository.setStoreForTesting(store)

        // The permanent checkpoint conflict is the oldest row. Its artifact repair rolls back, but the
        // bounded scan continues across the next 24 deterministic legacy rows.
        let firstRepairCount = await repository.repairIncompleteVerifiedArtifacts(limit: 25)
        XCTAssertEqual(firstRepairCount, 0)
        let firstCursorValue = try await store.incompleteVerifiedArtifactRepairScanCursor()
        let firstCursor = try XCTUnwrap(firstCursorValue)
        let secondPage = try await store.incompleteVerifiedArtifactRepairPage(
            after: firstCursor,
            limit: 25
        )
        XCTAssertEqual(secondPage.repairs.count, 2)
        XCTAssertFalse(secondPage.repairs.contains {
            $0.contextId == repairable.projection.contextId
        })
        let repairableSnapshot = try await store.verifiedTodaySnapshot(
            contextId: repairable.projection.contextId,
            analysisGeneration: repairable.receipt.analysisGeneration
        )
        XCTAssertEqual(repairableSnapshot, repairable.snapshot)
        let blockedArtifacts = try await store.verifiedExternalProjectionArtifacts(
            contextId: repairable.projection.contextId,
            generation: repairable.projection.generation
        )
        XCTAssertNil(blockedArtifacts.widgetCore)

        // A second grant reaches the end instead of pinning the cursor behind the permanent conflict.
        let tailRepairCount = await repository.repairIncompleteVerifiedArtifacts(limit: 25)
        XCTAssertEqual(tailRepairCount, 0)
        let completedTailCursor = try await store.incompleteVerifiedArtifactRepairScanCursor()
        XCTAssertNil(completedTailCursor)

        let cleared = try await store.clearLatestStateDeliveryCheckpoint(
            contextId: repairable.projection.contextId,
            destination: .widget
        )
        XCTAssertTrue(cleared)
        let retryRepairCount = await repository.repairIncompleteVerifiedArtifacts(limit: 25)
        XCTAssertEqual(retryRepairCount, 1)
        let repairedBundleValue = try await store.verifiedExternalProjectionBundle(
            contextId: repairable.projection.contextId,
            generation: repairable.projection.generation
        )
        let repairedBundle = try XCTUnwrap(repairedBundleValue)
        XCTAssertNil(repairedBundle.widgetCore.recoveryDelta)
        let widgetItem = try await store.leaseNextExternalPublication(
            owner: "widget-worker",
            now: Date(timeIntervalSince1970: 202),
            preferredDestination: .widget
        )
        let liveItem = try await store.leaseNextExternalPublication(
            owner: "live-worker",
            now: Date(timeIntervalSince1970: 202),
            preferredDestination: .liveActivity
        )
        XCTAssertNotNil(widgetItem)
        XCTAssertNotNil(liveItem)
    }
}
