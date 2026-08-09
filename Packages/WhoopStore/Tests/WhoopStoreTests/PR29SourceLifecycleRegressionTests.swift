import XCTest
import GRDB
import NoopPhase34Core
@testable import WhoopStore

private func makePlannedTransition(
    mutationKind: String,
    sourceDeviceId: String,
    targetDeviceId: String? = nil,
    cleanupWorkId: UUID? = nil,
    contributorIds: Set<String>? = nil
) -> SourceTransitionRecoveryRecord {
    SourceTransitionRecoveryRecord(
        mutationKind: mutationKind,
        sourceDeviceId: sourceDeviceId,
        targetDeviceId: targetDeviceId,
        previousActiveDeviceId: sourceDeviceId,
        previousSinkContextId: "previous-context",
        previousSinkEpoch: 1,
        contributorIds: contributorIds ?? [sourceDeviceId, sourceDeviceId + "-noop"],
        transitionScope: .activeProjection,
        cleanupWorkId: cleanupWorkId,
        stage: .planned
    )
}

private func prepareTransition(
    _ planned: SourceTransitionRecoveryRecord,
    historicalEpoch: UInt64 = 1,
    externalEpoch: UInt64 = 1,
    sinkEpoch: UInt64 = 1
) -> SourceTransitionRecoveryRecord {
    var prepared = planned
    prepared.historicalEpoch = historicalEpoch
    prepared.externalEpoch = externalEpoch
    prepared.sinkEpoch = sinkEpoch
    prepared.stage = .prepared
    return prepared
}

private func insertSyntheticCleanupGroup(
    in db: Database,
    cleanupWorkId: UUID,
    sourceDeviceId: String,
    createdAt: Int,
    authorizationRetryAt: Int?
) throws {
    let transitionId = UUID()
    let contributorsJSON = try JSONEncoder().encode(Set([sourceDeviceId]))
    let emptySourcesJSON = try JSONEncoder().encode(Set<String>())
    try db.execute(sql: """
        INSERT INTO sourceTransitionJournal (
            transitionId, version, mutationKind, sourceDeviceId,
            targetDeviceId, previousActiveDeviceId,
            previousSinkContextId, previousSinkEpoch,
            contributorIdsJSON, transitionScope, cleanupWorkId,
            historicalEpoch, externalEpoch, sinkEpoch, stage,
            commitJSON, lastErrorCode, createdAt, updatedAt
        ) VALUES (?, 2, 'deleteData', ?, NULL, ?, 'synthetic-context', 1,
                  ?, 'activeProjection', ?, 1, 1, 1, 'complete',
                  NULL, NULL, ?, ?)
        """, arguments: [
            transitionId.uuidString,
            sourceDeviceId,
            sourceDeviceId,
            contributorsJSON,
            cleanupWorkId.uuidString,
            createdAt,
            createdAt,
        ])
    for category in SourcePrivacyCleanupCategory.allCases {
        try db.execute(sql: """
            INSERT INTO sourcePrivacyCleanupWork (
                cleanupWorkId, transitionId, sourceDeviceId, category,
                remainingImportedIdsJSON, remainingComputedIdsJSON,
                firstDay, throughDay, recordedTimeZoneIdentifier,
                state, attemptCount, nextAttemptAt, leaseOwner,
                leaseExpiresAt, authorizationBlockedAt, lastErrorCode,
                createdAt, updatedAt
            ) VALUES (?, ?, ?, ?, ?, ?, '2026-08-08', '2026-08-08',
                      'UTC', ?, 0, ?, NULL, NULL, ?, ?, ?, ?)
            """, arguments: [
                cleanupWorkId.uuidString,
                transitionId.uuidString,
                sourceDeviceId,
                category.rawValue,
                emptySourcesJSON,
                emptySourcesJSON,
                authorizationRetryAt == nil ? "pending" : "retryable",
                authorizationRetryAt,
                authorizationRetryAt == nil ? nil : createdAt,
                authorizationRetryAt == nil ? nil : "authorization_unavailable",
                createdAt,
                createdAt,
            ])
    }
}

final class PR29SourceLifecycleRegressionTests: XCTestCase {
    func testQuarantinedCleanupRearmsAndNoLongerPermanentlyBlocksTransitions() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let cleanupWorkId = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let planned = makePlannedTransition(
            mutationKind: "deleteData",
            sourceDeviceId: "my-whoop",
            cleanupWorkId: cleanupWorkId
        )
        let prepared = prepareTransition(planned)
        try await writer.write { db in
            try db.execute(
                sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?, ?, ?, ?)",
                arguments: ["my-whoop", "2026-08-08", "stress", 1.0]
            )
        }
        try await store.persistSourceTransitionRecovery(planned, now: start)
        try await store.persistSourceTransitionRecovery(prepared, now: start)
        _ = try await store.commitSourceLifecycleMutation(
            .deleteData(deviceId: "my-whoop", consumerId: "quarantine-test"),
            recovery: prepared,
            now: start
        )

        let firstLeaseValue = try await store.leaseNextSourcePrivacyCleanupWork(
            owner: "cleanup-worker",
            now: start.addingTimeInterval(1),
            cleanupWorkId: cleanupWorkId
        )
        let firstLease = try XCTUnwrap(firstLeaseValue)
        XCTAssertEqual(firstLease.category, .vitals)
        var failed = try await store.failSourcePrivacyCleanupWork(
            firstLease,
            owner: "cleanup-worker",
            code: "healthkit_unavailable",
            retryable: true,
            now: start.addingTimeInterval(2)
        )

        // Finish the other lanes while vitals waits for its first backoff.
        var completionTime = start.addingTimeInterval(3)
        for expectedCategory in [
            SourcePrivacyCleanupCategory.sleep,
            .workouts,
            .heartRate,
        ] {
            let leaseValue = try await store.leaseNextSourcePrivacyCleanupWork(
                owner: "cleanup-worker",
                now: completionTime,
                cleanupWorkId: cleanupWorkId
            )
            let lease = try XCTUnwrap(leaseValue)
            XCTAssertEqual(lease.category, expectedCategory)
            _ = try await store.completeSourcePrivacyCleanupWork(
                lease,
                owner: "cleanup-worker",
                now: completionTime.addingTimeInterval(1)
            )
            completionTime = completionTime.addingTimeInterval(2)
        }

        var retryTime = start.addingTimeInterval(7 * 60 * 60)
        for expectedAttempt in 2...12 {
            let leaseValue = try await store.leaseNextSourcePrivacyCleanupWork(
                owner: "cleanup-worker",
                now: retryTime,
                cleanupWorkId: cleanupWorkId
            )
            let lease = try XCTUnwrap(leaseValue)
            XCTAssertEqual(lease.category, .vitals)
            failed = try await store.failSourcePrivacyCleanupWork(
                lease,
                owner: "cleanup-worker",
                code: "healthkit_unavailable",
                retryable: true,
                now: retryTime.addingTimeInterval(1)
            )
            XCTAssertEqual(failed.attemptCount, expectedAttempt)
            retryTime = retryTime.addingTimeInterval(7 * 60 * 60)
        }
        XCTAssertEqual(failed.state, .quarantined)
        let quarantinedPendingCount = try await store.pendingSourcePrivacyCleanupCount()
        XCTAssertEqual(quarantinedPendingCount, 1)
        let unresolved = try await store.unresolvedSourcePrivacyCleanupGroups()
        XCTAssertEqual(unresolved.map(\.cleanupWorkId), [cleanupWorkId])
        XCTAssertTrue(unresolved[0].hasQuarantinedWork)

        let second = makePlannedTransition(
            mutationKind: "archive",
            sourceDeviceId: "device-b"
        )
        do {
            try await store.persistSourceTransitionRecovery(second)
            XCTFail("a quarantined cleanup did not keep its transition unresolved")
        } catch DurableSourceLifecycleError.invalidMutation {
            // Expected until cleanup is rearmed and completed.
        }

        let rearmed = try await store.rearmQuarantinedSourcePrivacyCleanupGroup(
            cleanupWorkId: cleanupWorkId,
            now: retryTime
        )
        let rearmedVitals = try XCTUnwrap(
            rearmed.work.first { $0.category == .vitals }
        )
        XCTAssertEqual(rearmedVitals.state, .retryable)
        XCTAssertEqual(rearmedVitals.attemptCount, 0)
        XCTAssertEqual(rearmedVitals.rearmCount, 1)
        XCTAssertEqual(rearmedVitals.lastRearmedAt, retryTime)

        let finalLeaseValue = try await store.leaseNextSourcePrivacyCleanupWork(
            owner: "cleanup-worker",
            now: retryTime.addingTimeInterval(1),
            cleanupWorkId: cleanupWorkId
        )
        let finalLease = try XCTUnwrap(finalLeaseValue)
        _ = try await store.completeSourcePrivacyCleanupWork(
            finalLease,
            owner: "cleanup-worker",
            now: retryTime.addingTimeInterval(2)
        )
        let completedGroupValue = try await store.sourcePrivacyCleanupGroup(
            cleanupWorkId: cleanupWorkId
        )
        XCTAssertTrue(try XCTUnwrap(completedGroupValue).completedSuccessfully)

        var completed = prepared
        completed.stage = .complete
        try await store.persistSourceTransitionRecovery(
            completed,
            now: retryTime.addingTimeInterval(3)
        )
        try await store.persistSourceTransitionRecovery(
            second,
            now: retryTime.addingTimeInterval(4)
        )
        let latestTransition = try await store.latestSourceTransitionRecovery()
        XCTAssertEqual(latestTransition, second)
    }

    func testCleanupRearmCooldownBoundsChurnWithoutLifetimeBrick() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let cleanupWorkId = UUID()
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let planned = makePlannedTransition(
            mutationKind: "deleteData",
            sourceDeviceId: "my-whoop",
            cleanupWorkId: cleanupWorkId
        )
        let prepared = prepareTransition(planned)
        try await writer.write { db in
            try db.execute(
                sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?, ?, ?, ?)",
                arguments: ["my-whoop", "2026-08-08", "stress", 1.0]
            )
        }
        try await store.persistSourceTransitionRecovery(planned, now: start)
        try await store.persistSourceTransitionRecovery(prepared, now: start)
        _ = try await store.commitSourceLifecycleMutation(
            .deleteData(deviceId: "my-whoop", consumerId: "rearm-cooldown-test"),
            recovery: prepared,
            now: start
        )
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE sourcePrivacyCleanupWork
                SET state = 'quarantined', attemptCount = 12,
                    lastErrorCode = 'retry_limit_exceeded:test'
                WHERE cleanupWorkId = ? AND category = 'vitals'
                """, arguments: [cleanupWorkId.uuidString])
        }

        let firstRearmAt = start.addingTimeInterval(1)
        let firstRearm = try await store.rearmQuarantinedSourcePrivacyCleanupGroup(
            cleanupWorkId: cleanupWorkId,
            now: firstRearmAt
        )
        XCTAssertEqual(
            firstRearm.work.first { $0.category == .vitals }?.rearmCount,
            1
        )
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE sourcePrivacyCleanupWork
                SET state = 'quarantined', attemptCount = 12,
                    rearmCount = 100, lastRearmedAt = ?,
                    lastErrorCode = 'retry_limit_exceeded:test'
                WHERE cleanupWorkId = ? AND category = 'vitals'
                """, arguments: [
                    Int(firstRearmAt.timeIntervalSince1970),
                    cleanupWorkId.uuidString,
                ])
        }

        do {
            _ = try await store.rearmQuarantinedSourcePrivacyCleanupGroup(
                cleanupWorkId: cleanupWorkId,
                now: firstRearmAt.addingTimeInterval(60)
            )
            XCTFail("cleanup ignored its durable rearm cooldown")
        } catch SourcePrivacyCleanupStoreError.rearmCooldownActive(let until) {
            XCTAssertEqual(
                until,
                firstRearmAt.addingTimeInterval(
                    SourcePrivacyCleanupPolicy.minimumRearmInterval
                )
            )
        }
        let cooldownPendingCount = try await store.pendingSourcePrivacyCleanupCount()
        XCTAssertGreaterThan(cooldownPendingCount, 0)
        let unresolved = try await store.unresolvedSourcePrivacyCleanupGroups()
        XCTAssertEqual(unresolved.map(\.cleanupWorkId), [cleanupWorkId])
        XCTAssertTrue(unresolved[0].hasQuarantinedWork)
        XCTAssertEqual(
            unresolved[0].nextRearmEligibleAt,
            firstRearmAt.addingTimeInterval(
                SourcePrivacyCleanupPolicy.minimumRearmInterval
            )
        )

        // A high historical count is evidence, not a lifetime lock. Recovery
        // becomes eligible again after the fixed cooldown.
        let laterRearm = try await store.rearmQuarantinedSourcePrivacyCleanupGroup(
            cleanupWorkId: cleanupWorkId,
            now: firstRearmAt.addingTimeInterval(
                SourcePrivacyCleanupPolicy.minimumRearmInterval
            )
        )
        let laterVitals = try XCTUnwrap(
            laterRearm.work.first { $0.category == .vitals }
        )
        XCTAssertEqual(laterVitals.state, .retryable)
        XCTAssertEqual(laterVitals.rearmCount, 101)
    }

    func testAuthorizationDeferralHandsOffJournalAndDoesNotStarveNewerReadyGroup() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let start = Date(timeIntervalSince1970: 1_800_200_000)
        let blockedCleanupId = UUID()
        let blockedPlanned = makePlannedTransition(
            mutationKind: "deleteData",
            sourceDeviceId: "my-whoop",
            cleanupWorkId: blockedCleanupId
        )
        let blockedPrepared = prepareTransition(blockedPlanned)
        try await writer.write { db in
            try db.execute(
                sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?, ?, ?, ?)",
                arguments: ["my-whoop", "2026-08-08", "stress", 1.0]
            )
        }
        try await store.persistSourceTransitionRecovery(blockedPlanned, now: start)
        try await store.persistSourceTransitionRecovery(blockedPrepared, now: start)
        _ = try await store.commitSourceLifecycleMutation(
            .deleteData(deviceId: "my-whoop", consumerId: "authorization-test"),
            recovery: blockedPrepared,
            now: start
        )

        let blockedAt = start.addingTimeInterval(2)
        for expectedCategory in SourcePrivacyCleanupCategory.allCases {
            let leaseValue = try await store.leaseNextSourcePrivacyCleanupWork(
                owner: "authorization-worker",
                now: start.addingTimeInterval(1),
                cleanupWorkId: blockedCleanupId
            )
            let lease = try XCTUnwrap(leaseValue)
            XCTAssertEqual(lease.category, expectedCategory)
            let deferred = try await store.blockSourcePrivacyCleanupWorkForAuthorization(
                lease,
                owner: "authorization-worker",
                now: blockedAt
            )
            XCTAssertEqual(deferred.state, .retryable)
            XCTAssertEqual(deferred.attemptCount, 0)
            XCTAssertEqual(deferred.authorizationBlockedAt, blockedAt)
            XCTAssertEqual(
                deferred.nextAttemptAt,
                blockedAt.addingTimeInterval(
                    SourcePrivacyCleanupPolicy.authorizationRetryInterval
                )
            )
            XCTAssertEqual(deferred.lastErrorCode, "authorization_unavailable")
            XCTAssertNil(deferred.leaseOwner)
        }
        let tooEarlyLease = try await store.leaseNextSourcePrivacyCleanupWork(
            owner: "too-early-worker",
            now: blockedAt,
            cleanupWorkId: blockedCleanupId
        )
        XCTAssertNil(tooEarlyLease)

        // The app's authorization-only handoff closes the journal. The cleanup
        // group remains durable and discoverable for the independent drain.
        var handedOff = blockedPrepared
        handedOff.stage = .complete
        try await store.persistSourceTransitionRecovery(
            handedOff,
            now: blockedAt.addingTimeInterval(1)
        )
        let blockedGroupValue = try await store.sourcePrivacyCleanupGroup(
            cleanupWorkId: blockedCleanupId
        )
        let blockedGroup = try XCTUnwrap(blockedGroupValue)
        XCTAssertTrue(blockedGroup.hasAuthorizationBlockedWork)
        XCTAssertFalse(blockedGroup.completedSuccessfully)

        let registry = DeviceRegistryStore(dbQueue: writer)
        try registry.add(PairedDevice(
            id: "device-b",
            brand: "Test",
            model: "B",
            sourceKind: .liveBLE,
            capabilities: [.hr],
            status: .paired,
            addedAt: Int(blockedAt.timeIntervalSince1970),
            lastSeenAt: Int(blockedAt.timeIntervalSince1970)
        ))
        try await writer.write { db in
            try db.execute(
                sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?, ?, ?, ?)",
                arguments: ["device-b", "2026-08-09", "stress", 2.0]
            )
        }
        let readyCleanupId = UUID()
        let readyPlanned = makePlannedTransition(
            mutationKind: "deleteData",
            sourceDeviceId: "device-b",
            cleanupWorkId: readyCleanupId
        )
        let readyPrepared = prepareTransition(readyPlanned)
        try await store.persistSourceTransitionRecovery(
            readyPlanned,
            now: blockedAt.addingTimeInterval(2)
        )
        try await store.persistSourceTransitionRecovery(
            readyPrepared,
            now: blockedAt.addingTimeInterval(2)
        )
        _ = try await store.commitSourceLifecycleMutation(
            .deleteData(deviceId: "device-b", consumerId: "authorization-test-2"),
            recovery: readyPrepared,
            now: blockedAt.addingTimeInterval(2)
        )

        let candidates = try await store.sourcePrivacyCleanupDrainCandidates(
            now: blockedAt.addingTimeInterval(3),
            limit: 100
        )
        XCTAssertEqual(candidates.map(\.cleanupWorkId), [
            readyCleanupId,
            blockedCleanupId,
        ])
        XCTAssertTrue(candidates[0].isReadyForRecovery(at: blockedAt))
        XCTAssertTrue(candidates[1].hasAuthorizationBlockedWork)

        let dueAt = blockedAt.addingTimeInterval(
            SourcePrivacyCleanupPolicy.authorizationRetryInterval
        )
        let replayLeaseValue = try await store.leaseNextSourcePrivacyCleanupWork(
            owner: "authorization-replay-worker",
            now: dueAt,
            cleanupWorkId: blockedCleanupId
        )
        let replayLease = try XCTUnwrap(replayLeaseValue)
        XCTAssertNil(replayLease.authorizationBlockedAt)
        let cancelled = try await store.cancelSourcePrivacyCleanupLease(
            replayLease,
            owner: "authorization-replay-worker",
            now: dueAt
        )
        XCTAssertNil(cancelled.authorizationBlockedAt)
        XCTAssertNil(cancelled.nextAttemptAt)
    }

    func testSQLCandidatePriorityFindsReadyGroupAfterMoreThanOneHundredDeferredGroups() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let readyCleanupWorkId = UUID()
        try await writer.write { db in
            for index in 0..<101 {
                try insertSyntheticCleanupGroup(
                    in: db,
                    cleanupWorkId: UUID(),
                    sourceDeviceId: "blocked-source-\(index)",
                    createdAt: index + 1,
                    authorizationRetryAt: 10_000
                )
            }
            try insertSyntheticCleanupGroup(
                in: db,
                cleanupWorkId: readyCleanupWorkId,
                sourceDeviceId: "ready-source",
                createdAt: 1_000,
                authorizationRetryAt: nil
            )
        }

        let candidates = try await store.sourcePrivacyCleanupDrainCandidates(
            now: Date(timeIntervalSince1970: 100),
            limit: 100
        )
        XCTAssertEqual(candidates.count, 100)
        XCTAssertEqual(candidates.first?.cleanupWorkId, readyCleanupWorkId)
        XCTAssertTrue(try XCTUnwrap(candidates.first).isReadyForRecovery(
            at: Date(timeIntervalSince1970: 100)
        ))
        XCTAssertTrue(candidates.dropFirst().allSatisfy {
            $0.hasAuthorizationBlockedWork
        })
    }

    func testSecondTransitionCannotOvertakeIncompleteRecoveryJournal() async throws {
        let store = try await WhoopStore.inMemory()
        let first = makePlannedTransition(
            mutationKind: "deleteData",
            sourceDeviceId: "device-a",
            targetDeviceId: "device-b",
            cleanupWorkId: UUID()
        )
        let second = makePlannedTransition(
            mutationKind: "archive",
            sourceDeviceId: "device-b",
            targetDeviceId: nil
        )

        try await store.persistSourceTransitionRecovery(first)
        do {
            try await store.persistSourceTransitionRecovery(second)
            XCTFail("a newer transition overtook an incomplete durable journal")
        } catch DurableSourceLifecycleError.invalidMutation {
            // Expected. Recovery must finish or abort the first transition before another can start.
        }

        var aborted = first
        aborted.stage = .aborted
        try await store.persistSourceTransitionRecovery(aborted)
        try await store.persistSourceTransitionRecovery(second)
        let pending = try await store.latestSourceTransitionRecovery()
        XCTAssertEqual(pending, second)
    }

    func testCurrentAppModelPathAtomicallyCommitsRecoveryPayloadAndDiscardedScopeTombstone() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let planned = makePlannedTransition(
            mutationKind: "deleteData",
            sourceDeviceId: "my-whoop",
            targetDeviceId: nil,
            cleanupWorkId: UUID()
        )
        try await store.persistSourceTransitionRecovery(planned, now: now)
        let recovery = prepareTransition(
            planned,
            historicalEpoch: 7,
            externalEpoch: 11,
            sinkEpoch: 13
        )

        // AppModel persists prepared, then calls the store mutation without passing the record. The writer
        // connection's TEMP binding must still promote that exact transition in the mutation transaction.
        try await store.persistSourceTransitionRecovery(recovery, now: now)
        let commit = try await store.commitSourceLifecycleMutation(
            .deleteData(deviceId: "my-whoop", consumerId: "privacy-test"),
            now: now.addingTimeInterval(1)
        )

        var expectedRecovery = recovery
        expectedRecovery.stage = .storeCommitted
        let storedRecovery = try await store.latestSourceTransitionRecovery()
        let storedCommit = try await store.sourceTransitionCommit(transitionId: recovery.id)
        XCTAssertEqual(storedRecovery, expectedRecovery)
        XCTAssertEqual(storedCommit, commit)

        let lifecycleState: String? = try await writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM historicalReceiptScopeLifecycle WHERE deviceId = ? LIMIT 1",
                arguments: ["my-whoop"]
            )
        }
        XCTAssertEqual(lifecycleState, HistoricalScopeLifecycleState.discarded.rawValue)

        // A stale prepared writer cannot move a committed transition backward after a crash/relaunch race.
        do {
            try await store.persistSourceTransitionRecovery(
                recovery,
                now: now.addingTimeInterval(2)
            )
            XCTFail("stale recovery stage moved backward")
        } catch DurableSourceLifecycleError.invalidMutation {
            // Expected.
        }
        let recoveryAfterRejectedReplay = try await store.latestSourceTransitionRecovery()
        XCTAssertEqual(recoveryAfterRejectedReplay, expectedRecovery)

        // Launch recovery may repair every remaining postcommit side effect and then persist `complete`
        // directly. That forward jump is legal; only backward/precommit jumps are rejected.
        var completedRecovery = expectedRecovery
        completedRecovery.stage = .complete
        try await store.persistSourceTransitionRecovery(
            completedRecovery,
            now: now.addingTimeInterval(3)
        )
        let terminalRecovery = try await store.latestSourceTransitionRecovery()
        XCTAssertNil(terminalRecovery)
    }

    func testPreparedRecordWithoutProcessBindingFailsClosedBeforeMutation() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let planned = makePlannedTransition(
            mutationKind: "deleteData",
            sourceDeviceId: "my-whoop",
            targetDeviceId: nil,
            cleanupWorkId: UUID()
        )
        try await store.persistSourceTransitionRecovery(planned)
        let recovery = prepareTransition(planned)
        try await store.persistSourceTransitionRecovery(recovery)
        try await writer.write { db in
            // Simulate a relaunch: durable journal state survives but TEMP process binding does not.
            try db.execute(sql: "DELETE FROM sourceTransitionPreparedBinding")
            try db.execute(
                sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?, ?, ?, ?)",
                arguments: ["my-whoop", "2026-08-08", "stress", 1.0]
            )
        }

        do {
            _ = try await store.commitSourceLifecycleMutation(
                .deleteData(deviceId: "my-whoop", consumerId: "privacy-test")
            )
            XCTFail("stale prepared transition was bypassed")
        } catch DurableSourceLifecycleError.invalidMutation {
            // Expected. Launch recovery must resolve the durable prepared row first.
        }

        let remaining: Int = try await writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM metricSeries WHERE deviceId = ?",
                arguments: ["my-whoop"]
            ) ?? 0
        }
        XCTAssertEqual(remaining, 1)
    }

    func testMissingPreparedJournalRollsBackExplicitRecoveryMutation() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let recovery = prepareTransition(makePlannedTransition(
            mutationKind: "deleteData",
            sourceDeviceId: "my-whoop",
            targetDeviceId: nil,
            cleanupWorkId: UUID()
        ))

        try await writer.write { db in
            try db.execute(
                sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?, ?, ?, ?)",
                arguments: ["my-whoop", "2026-08-08", "stress", 1.0]
            )
        }

        do {
            _ = try await store.commitSourceLifecycleMutation(
                .deleteData(deviceId: "my-whoop", consumerId: "privacy-test"),
                recovery: recovery
            )
            XCTFail("mutation committed without its prepared journal")
        } catch DurableSourceLifecycleError.invalidMutation {
            // Expected. The source mutation and journal edge share one SQLite transaction.
        }

        let remaining: Int = try await writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM metricSeries WHERE deviceId = ?",
                arguments: ["my-whoop"]
            ) ?? 0
        }
        XCTAssertEqual(remaining, 1)
    }

    func testPrivacyDeleteRemovesRawAndDerivedSourceNamespacesOnly() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let raw = "my-whoop"
        let derived = "my-whoop-noop"
        let unrelated = "unrelated-source"

        try await writer.write { db in
            for deviceId in [raw, derived, unrelated] {
                try db.execute(
                    sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?, ?, ?, ?)",
                    arguments: [deviceId, "2026-08-08", "stress", 1.0]
                )
            }
            for (contextId, deviceId) in [
                ("checkpoint-raw", raw),
                ("checkpoint-derived", derived),
                ("checkpoint-unrelated", unrelated),
            ] {
                try db.execute(sql: """
                    INSERT INTO latestStateDeliveryCheckpoint (
                        contextId, destination, deviceId, snapshotGeneration, presentationJSON,
                        widgetCoreJSON, logicalDay, deliveredAt
                    ) VALUES (?, 'widget', ?, 1, ?, ?, '2026-08-08', 1)
                    """, arguments: [contextId, deviceId, Data("{}".utf8), Data("{}".utf8)])
            }
        }

        _ = try await store.commitSourceLifecycleMutation(
            .deleteData(deviceId: raw, consumerId: "privacy-test")
        )

        func count(_ deviceId: String) async throws -> Int {
            try await writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM metricSeries WHERE deviceId = ?",
                    arguments: [deviceId]
                ) ?? 0
            }
        }

        let rawCount = try await count(raw)
        let derivedCount = try await count(derived)
        let unrelatedCount = try await count(unrelated)
        XCTAssertEqual(rawCount, 0)
        XCTAssertEqual(derivedCount, 0)
        XCTAssertEqual(unrelatedCount, 1)

        let checkpointOwners = try await writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT deviceId FROM latestStateDeliveryCheckpoint ORDER BY deviceId")
        }
        XCTAssertEqual(checkpointOwners, [unrelated])
    }

    func testDeletingInactiveSourceLeavesActiveSourceAndItsDataUntouched() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let registry = DeviceRegistryStore(dbQueue: writer)
        let sourceA = "my-whoop"
        let sourceB = "source-b"

        try registry.add(PairedDevice(
            id: sourceB,
            brand: "Polar",
            model: "H10",
            sourceKind: .liveBLE,
            capabilities: [.hr, .hrv],
            status: .paired,
            addedAt: 2,
            lastSeenAt: 2))
        try registry.setActive(sourceB)
        XCTAssertEqual(try registry.activeDeviceId(), sourceB)

        try await writer.write { db in
            for deviceId in [sourceA, sourceA + "-noop", sourceB, sourceB + "-noop"] {
                try db.execute(
                    sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?, ?, ?, ?)",
                    arguments: [deviceId, "2026-08-08", "stress", 1.0]
                )
            }
        }

        _ = try await store.commitSourceLifecycleMutation(
            .deleteData(deviceId: sourceA, consumerId: "privacy-test")
        )

        XCTAssertEqual(try registry.activeDeviceId(), sourceB)
        XCTAssertEqual(try registry.all().first { $0.id == sourceB }?.status, .active)
        let remainingOwners = try await writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT deviceId FROM metricSeries ORDER BY deviceId"
            )
        }
        XCTAssertEqual(remainingOwners, [sourceB, sourceB + "-noop"])
    }

    func testSelectExistingCommitsActiveSelectionWithoutClosingHistoryScope() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let registry = DeviceRegistryStore(dbQueue: writer)
        let sourceA = "my-whoop"
        let sourceB = "source-b"
        try registry.add(PairedDevice(
            id: sourceB,
            brand: "Polar",
            model: "H10",
            sourceKind: .liveBLE,
            capabilities: [.hr, .hrv],
            status: .paired,
            addedAt: 2,
            lastSeenAt: 2
        ))
        let originalLineage = try XCTUnwrap(registry.historyLineage(for: sourceB))
        let originalEpoch = try XCTUnwrap(registry.historyCursorEpoch(for: sourceB))
        let planned = makePlannedTransition(
            mutationKind: "selectExisting",
            sourceDeviceId: sourceA,
            targetDeviceId: sourceB,
            contributorIds: [sourceA, sourceA + "-noop"]
        )
        try await store.persistSourceTransitionRecovery(planned)
        let prepared = prepareTransition(planned)
        try await store.persistSourceTransitionRecovery(prepared)

        let commit = try await store.commitSourceLifecycleMutation(
            .selectExisting(deviceId: sourceB),
            recovery: prepared
        )

        XCTAssertEqual(try registry.activeDeviceId(), sourceB)
        XCTAssertEqual(try registry.all().first { $0.id == sourceA }?.status, .paired)
        XCTAssertEqual(commit.deviceId, sourceB)
        XCTAssertEqual(commit.activeDeviceId, sourceB)
        XCTAssertEqual(commit.previousScope.deviceId, sourceB)
        XCTAssertEqual(commit.nextScope.deviceId, sourceB)
        XCTAssertEqual(commit.previousScope.lineage, originalLineage)
        XCTAssertEqual(commit.nextScope.lineage, originalLineage)
        XCTAssertEqual(commit.previousScope.cursorEpoch, originalEpoch)
        XCTAssertEqual(commit.nextScope.cursorEpoch, originalEpoch)
        let lifecycleRows = try await writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM historicalReceiptScopeLifecycle WHERE deviceId IN (?, ?)",
                arguments: [sourceA, sourceB]
            ) ?? 0
        }
        XCTAssertEqual(lifecycleRows, 0)
        var expectedRecovery = prepared
        expectedRecovery.stage = .storeCommitted
        let storedRecovery = try await store.latestSourceTransitionRecovery()
        XCTAssertEqual(storedRecovery, expectedRecovery)
    }
}
