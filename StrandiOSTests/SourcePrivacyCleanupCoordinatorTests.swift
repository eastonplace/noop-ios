#if os(iOS)
import Foundation
import NoopPhase34Core
import WhoopStore
import XCTest
@testable import NOOP

private enum SourcePrivacyCleanupTestError: Error, Sendable {
    case missingFixture
    case transient
}

private actor SourcePrivacyCleanupRequestRecorder {
    private var requests: [HealthKitSourceDeletionChunkRequest] = []

    func append(_ request: HealthKitSourceDeletionChunkRequest) {
        requests.append(request)
    }

    func snapshot() -> [HealthKitSourceDeletionChunkRequest] {
        requests
    }
}

private final class SourcePrivacyCleanupTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private struct SourcePrivacyCleanupFixture {
    let store: WhoopStore
    let cleanupWorkId: UUID
    let group: SourcePrivacyCleanupGroup
}

@MainActor
private func makeSourcePrivacyCleanupFixture(
    firstDay: String = "2026-08-07",
    throughDay: String = "2026-08-08",
    now: Date = Date(timeIntervalSince1970: 1_786_147_200)
) async throws -> SourcePrivacyCleanupFixture {
    let store = try await WhoopStore.inMemory()
    let cleanupWorkId = UUID()
    let transitionId = UUID()
    let sourceDeviceId = "my-whoop"
    let remainingSourceId = "remaining-source"
    let points = [
        MetricPoint(day: firstDay, key: "cleanup-first", value: 1),
        MetricPoint(day: throughDay, key: "cleanup-through", value: 1),
    ]
    try await store.upsertMetricSeries(points, deviceId: sourceDeviceId)
    try await store.upsertMetricSeries(points, deviceId: remainingSourceId)

    let planned = SourceTransitionRecoveryRecord(
        id: transitionId,
        mutationKind: "deleteData",
        sourceDeviceId: sourceDeviceId,
        targetDeviceId: nil,
        previousActiveDeviceId: sourceDeviceId,
        previousSinkContextId: "cleanup-test-context",
        previousSinkEpoch: 1,
        contributorIds: [
            sourceDeviceId,
            sourceDeviceId + "-noop",
            remainingSourceId,
            remainingSourceId + "-noop",
        ],
        transitionScope: .activeProjection,
        cleanupWorkId: cleanupWorkId,
        stage: .planned
    )
    try await store.persistSourceTransitionRecovery(planned, now: now)
    var prepared = planned
    prepared.historicalEpoch = 1
    prepared.externalEpoch = 1
    prepared.sinkEpoch = 1
    prepared.stage = .prepared
    try await store.persistSourceTransitionRecovery(prepared, now: now)
    _ = try await store.commitSourceLifecycleMutation(
        .deleteData(deviceId: sourceDeviceId, consumerId: "cleanup-test"),
        recovery: prepared,
        now: now
    )
    guard let group = try await store.sourcePrivacyCleanupGroup(
        cleanupWorkId: cleanupWorkId
    ) else {
        throw SourcePrivacyCleanupTestError.missingFixture
    }
    return SourcePrivacyCleanupFixture(
        store: store,
        cleanupWorkId: cleanupWorkId,
        group: group
    )
}

private func processedDayCount(
    _ interval: HealthKitSourceDeletionProcessedInterval,
    timeZoneIdentifier: String
) throws -> Int {
    try HealthCalendar(timeZoneIdentifier: timeZoneIdentifier).days(
        from: interval.firstDay,
        through: interval.lastDay,
        limit: HealthKitSourceDeletionChunkPlanner.maximumCivilDays + 1
    ).count
}

private func completeChunkResult(
    for request: HealthKitSourceDeletionChunkRequest
) throws -> HealthKitSourceDeletionChunkResult {
    let interval = try HealthKitSourceDeletionChunkPlanner.interval(for: request)
    return HealthKitSourceDeletionChunkResult(
        processedInterval: interval,
        processedDayCount: try processedDayCount(
            interval,
            timeZoneIdentifier: request.timeZoneIdentifier
        ),
        deletedObjectCount: 3,
        rebuiltObjectCount: 2,
        continuationCursor: nil,
        isComplete: true
    )
}

@MainActor
final class SourcePrivacyCleanupCoordinatorTests: XCTestCase {
    func testOneDrainUsesDurableEnvelopeAndPersistsExactlyOneCursor() async throws {
        let fixture = try await makeSourcePrivacyCleanupFixture()
        let recorder = SourcePrivacyCleanupRequestRecorder()
        let coordinator = SourcePrivacyCleanupCoordinator(
            storeProvider: { [store = fixture.store] in store },
            owner: "cleanup-test-owner",
            processChunk: { request in
                await recorder.append(request)
                let interval = try HealthKitSourceDeletionChunkPlanner.interval(for: request)
                return HealthKitSourceDeletionChunkResult(
                    processedInterval: interval,
                    processedDayCount: try processedDayCount(
                        interval,
                        timeZoneIdentifier: request.timeZoneIdentifier
                    ),
                    deletedObjectCount: 4_000,
                    rebuiltObjectCount: 4_000,
                    continuationCursor: HealthKitSourceDeletionCursor(
                        category: request.category,
                        day: interval.firstDay,
                        phase: .rebuildingRemainingSources
                    ),
                    isComplete: false
                )
            }
        )

        do {
            try await coordinator.drain(cleanupWorkId: fixture.cleanupWorkId)
            XCTFail("one incomplete category chunk returned as a complete group")
        } catch let error as SourcePrivacyCleanupCoordinatorError {
            XCTAssertEqual(error, .pending(fixture.cleanupWorkId))
        }

        let requests = await recorder.snapshot()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        let durableWork = try XCTUnwrap(fixture.group.work.first)
        XCTAssertEqual(request.sourceDeviceId, durableWork.sourceDeviceId)
        XCTAssertEqual(request.remainingImportedIds, ["remaining-source"])
        XCTAssertEqual(request.remainingComputedIds, ["remaining-source-noop"])
        XCTAssertEqual(request.firstDay.key, durableWork.firstDay)
        XCTAssertEqual(request.throughDay.key, durableWork.throughDay)
        XCTAssertEqual(request.timeZoneIdentifier, durableWork.recordedTimeZoneIdentifier)

        let persistedGroupValue = try await fixture.store.sourcePrivacyCleanupGroup(
            cleanupWorkId: fixture.cleanupWorkId
        )
        let persistedGroup = try XCTUnwrap(persistedGroupValue)
        let vitals = try XCTUnwrap(
            persistedGroup.work.first { $0.category == .vitals }
        )
        XCTAssertEqual(vitals.state, .retryable)
        XCTAssertEqual(vitals.attemptCount, 0)
        let cursorData = try XCTUnwrap(vitals.cleanupCursor)
        let cursor = try JSONDecoder().decode(
            HealthKitSourceDeletionCursor.self,
            from: cursorData
        )
        XCTAssertEqual(cursor.category, .vitals)
        XCTAssertEqual(cursor.phase, .rebuildingRemainingSources)
        XCTAssertEqual(
            persistedGroup.work.filter { $0.state == .pending }.count,
            3
        )
        // Both per-query counts are 4,000. Their sum is invalid for the store.
        // Reaching this state proves the coordinator persisted max(4,000, 4,000).
    }

    func testDrainReturnsOnlyAfterAllFourCategoryRowsComplete() async throws {
        let fixture = try await makeSourcePrivacyCleanupFixture(
            firstDay: "2026-08-08",
            throughDay: "2026-08-08"
        )
        let recorder = SourcePrivacyCleanupRequestRecorder()
        let coordinator = SourcePrivacyCleanupCoordinator(
            storeProvider: { [store = fixture.store] in store },
            owner: "cleanup-completion-owner",
            processChunk: { request in
                await recorder.append(request)
                return try completeChunkResult(for: request)
            }
        )

        for index in 0..<SourcePrivacyCleanupCategory.allCases.count {
            do {
                try await coordinator.drain(cleanupWorkId: fixture.cleanupWorkId)
                XCTAssertEqual(index, SourcePrivacyCleanupCategory.allCases.count - 1)
            } catch let error as SourcePrivacyCleanupCoordinatorError {
                XCTAssertLessThan(index, SourcePrivacyCleanupCategory.allCases.count - 1)
                XCTAssertEqual(error, .pending(fixture.cleanupWorkId))
            }
        }

        let requests = await recorder.snapshot()
        XCTAssertEqual(
            requests.map(\.category),
            [.vitals, .sleep, .workouts, .heartRate]
        )
        let groupValue = try await fixture.store.sourcePrivacyCleanupGroup(
            cleanupWorkId: fixture.cleanupWorkId
        )
        let group = try XCTUnwrap(groupValue)
        XCTAssertTrue(group.completedSuccessfully)
    }

    func testAuthorizationUnavailablePersistsDurableDeferralWithoutConsumingRetry() async throws {
        let start = Date(timeIntervalSince1970: 1_786_147_200)
        let fixture = try await makeSourcePrivacyCleanupFixture(now: start)
        let clock = SourcePrivacyCleanupTestClock(start)
        let recorder = SourcePrivacyCleanupRequestRecorder()
        let coordinator = SourcePrivacyCleanupCoordinator(
            storeProvider: { [store = fixture.store] in store },
            owner: "cleanup-auth-owner",
            now: { clock.now() },
            processChunk: { request in
                await recorder.append(request)
                throw ExactPublicationError.authorizationUnavailable
            }
        )

        do {
            try await coordinator.drain(cleanupWorkId: fixture.cleanupWorkId)
            XCTFail("authorization failure did not keep cleanup pending")
        } catch let error as SourcePrivacyCleanupCoordinatorError {
            XCTAssertEqual(error, .authorizationUnavailable(fixture.cleanupWorkId))
        }

        let groupValue = try await fixture.store.sourcePrivacyCleanupGroup(
            cleanupWorkId: fixture.cleanupWorkId
        )
        let group = try XCTUnwrap(groupValue)
        let vitals = try XCTUnwrap(group.work.first { $0.category == .vitals })
        XCTAssertEqual(vitals.state, .retryable)
        XCTAssertEqual(vitals.attemptCount, 0)
        XCTAssertEqual(vitals.authorizationBlockedAt, start)
        XCTAssertEqual(
            vitals.nextAttemptAt,
            start.addingTimeInterval(
                SourcePrivacyCleanupPolicy.authorizationRetryInterval
            )
        )
        XCTAssertNil(vitals.leaseOwner)
        XCTAssertEqual(vitals.lastErrorCode, "authorization_unavailable")

        do {
            try await coordinator.drain(cleanupWorkId: fixture.cleanupWorkId)
            XCTFail("authorization cooldown was ignored")
        } catch let error as SourcePrivacyCleanupCoordinatorError {
            XCTAssertEqual(error, .authorizationUnavailable(fixture.cleanupWorkId))
        }
        let requestsBeforeRetry = await recorder.snapshot()
        XCTAssertEqual(requestsBeforeRetry.map(\.category), [.vitals, .sleep])

        let stillDeferredGroupValue = try await fixture.store.sourcePrivacyCleanupGroup(
            cleanupWorkId: fixture.cleanupWorkId
        )
        let stillDeferredGroup = try XCTUnwrap(stillDeferredGroupValue)
        let stillDeferredVitals = try XCTUnwrap(
            stillDeferredGroup.work.first { $0.category == .vitals }
        )
        XCTAssertEqual(stillDeferredVitals.attemptCount, 0)
        XCTAssertEqual(stillDeferredVitals.authorizationBlockedAt, start)
        XCTAssertEqual(
            stillDeferredVitals.nextAttemptAt,
            start.addingTimeInterval(
                SourcePrivacyCleanupPolicy.authorizationRetryInterval
            )
        )

        clock.advance(by: SourcePrivacyCleanupPolicy.authorizationRetryInterval)
        do {
            try await coordinator.drain(cleanupWorkId: fixture.cleanupWorkId)
            XCTFail("due authorization retry returned success")
        } catch let error as SourcePrivacyCleanupCoordinatorError {
            XCTAssertEqual(error, .authorizationUnavailable(fixture.cleanupWorkId))
        }
        let requestsAfterRetry = await recorder.snapshot()
        XCTAssertEqual(requestsAfterRetry.map(\.category), [.vitals, .sleep, .vitals])
    }

    func testIndependentDrainProcessesOnlyOneBoundedCategory() async throws {
        let fixture = try await makeSourcePrivacyCleanupFixture(
            firstDay: "2026-08-08",
            throughDay: "2026-08-08"
        )
        let recorder = SourcePrivacyCleanupRequestRecorder()
        let coordinator = SourcePrivacyCleanupCoordinator(
            storeProvider: { [store = fixture.store] in store },
            owner: "independent-drain-owner",
            processChunk: { request in
                await recorder.append(request)
                return try completeChunkResult(for: request)
            }
        )

        do {
            _ = try await coordinator.drainOldestUnresolved()
            XCTFail("one completed category returned a completed group")
        } catch let error as SourcePrivacyCleanupCoordinatorError {
            XCTAssertEqual(error, .pending(fixture.cleanupWorkId))
        }
        let requests = await recorder.snapshot()
        XCTAssertEqual(requests.map(\.category), [.vitals])
    }

    func testIndependentDrainPolicyRequiresNoNonterminalJournal() {
        XCTAssertTrue(SourcePrivacyCleanupIndependentDrainPolicy.shouldDrain(
            latestTransition: nil
        ))
        let planned = SourceTransitionRecoveryRecord(
            mutationKind: "deleteData",
            sourceDeviceId: "source-a",
            targetDeviceId: nil,
            previousActiveDeviceId: "source-a",
            previousSinkContextId: "context-a",
            previousSinkEpoch: 1,
            contributorIds: ["source-a", "source-a-noop"],
            transitionScope: .activeProjection,
            cleanupWorkId: UUID(),
            stage: .planned
        )
        XCTAssertFalse(SourcePrivacyCleanupIndependentDrainPolicy.shouldDrain(
            latestTransition: planned
        ))
    }

    func testTransitionHandoffPolicyOnlyDecouplesAuthorizationFailure() {
        let cleanupWorkId = UUID()
        XCTAssertTrue(SourcePrivacyCleanupTransitionHandoffPolicy.completesTransition(
            after: .authorizationUnavailable(cleanupWorkId)
        ))
        XCTAssertFalse(SourcePrivacyCleanupTransitionHandoffPolicy.completesTransition(
            after: .pending(cleanupWorkId)
        ))
        XCTAssertFalse(SourcePrivacyCleanupTransitionHandoffPolicy.completesTransition(
            after: .quarantinedGroup(cleanupWorkId)
        ))
    }

    func testThrownCancellationReleasesLeaseWithoutConsumingRetry() async throws {
        let fixture = try await makeSourcePrivacyCleanupFixture()
        let coordinator = SourcePrivacyCleanupCoordinator(
            storeProvider: { [store = fixture.store] in store },
            owner: "cleanup-cancel-owner",
            processChunk: { _ in throw CancellationError() }
        )

        do {
            try await coordinator.drain(cleanupWorkId: fixture.cleanupWorkId)
            XCTFail("cancellation did not escape")
        } catch is CancellationError {
            // Expected.
        }

        let groupValue = try await fixture.store.sourcePrivacyCleanupGroup(
            cleanupWorkId: fixture.cleanupWorkId
        )
        let group = try XCTUnwrap(groupValue)
        let vitals = try XCTUnwrap(group.work.first { $0.category == .vitals })
        XCTAssertEqual(vitals.state, .retryable)
        XCTAssertEqual(vitals.attemptCount, 0)
        XCTAssertNil(vitals.nextAttemptAt)
        XCTAssertNil(vitals.leaseOwner)
    }

    func testCancellationAfterSuccessfulChunkStillPersistsReturnedCursor() async throws {
        let fixture = try await makeSourcePrivacyCleanupFixture()
        let coordinator = SourcePrivacyCleanupCoordinator(
            storeProvider: { [store = fixture.store] in store },
            owner: "cleanup-post-result-cancel-owner",
            processChunk: { request in
                let interval = try HealthKitSourceDeletionChunkPlanner.interval(for: request)
                withUnsafeCurrentTask { $0?.cancel() }
                return HealthKitSourceDeletionChunkResult(
                    processedInterval: interval,
                    processedDayCount: try processedDayCount(
                        interval,
                        timeZoneIdentifier: request.timeZoneIdentifier
                    ),
                    deletedObjectCount: 1,
                    rebuiltObjectCount: 0,
                    continuationCursor: HealthKitSourceDeletionCursor(
                        category: request.category,
                        day: interval.firstDay,
                        phase: .rebuildingRemainingSources
                    ),
                    isComplete: false
                )
            }
        )

        let task = Task { @MainActor in
            try await coordinator.drain(cleanupWorkId: fixture.cleanupWorkId)
        }
        switch await task.result {
        case .success:
            XCTFail("incomplete cleanup returned success")
        case let .failure(error as SourcePrivacyCleanupCoordinatorError):
            XCTAssertEqual(error, .pending(fixture.cleanupWorkId))
        case let .failure(error):
            XCTFail("unexpected error: \(error)")
        }

        let groupValue = try await fixture.store.sourcePrivacyCleanupGroup(
            cleanupWorkId: fixture.cleanupWorkId
        )
        let group = try XCTUnwrap(groupValue)
        let vitals = try XCTUnwrap(group.work.first { $0.category == .vitals })
        XCTAssertEqual(vitals.state, .retryable)
        XCTAssertNotNil(vitals.cleanupCursor)
        XCTAssertNil(vitals.leaseOwner)
    }

    func testTransientFailureUsesBoundedRetryThenDurablyRearms() async throws {
        let start = Date(timeIntervalSince1970: 1_786_147_200)
        let fixture = try await makeSourcePrivacyCleanupFixture(now: start)
        let clock = SourcePrivacyCleanupTestClock(start)
        let recorder = SourcePrivacyCleanupRequestRecorder()
        let coordinator = SourcePrivacyCleanupCoordinator(
            storeProvider: { [store = fixture.store] in store },
            owner: "cleanup-retry-owner",
            now: { clock.now() },
            processChunk: { request in
                await recorder.append(request)
                throw SourcePrivacyCleanupTestError.transient
            }
        )

        for attempt in 1...12 {
            if attempt > 1 { clock.advance(by: 7 * 60 * 60) }
            do {
                try await coordinator.drain(cleanupWorkId: fixture.cleanupWorkId)
                XCTFail("failed cleanup returned success")
            } catch let error as SourcePrivacyCleanupCoordinatorError {
                XCTAssertEqual(error, .pending(fixture.cleanupWorkId))
            }
        }

        let requestsBeforeRearmedReplay = await recorder.snapshot()
        XCTAssertEqual(requestsBeforeRearmedReplay.count, 12)
        let rearmedGroupValue = try await fixture.store.sourcePrivacyCleanupGroup(
            cleanupWorkId: fixture.cleanupWorkId
        )
        let rearmedGroup = try XCTUnwrap(rearmedGroupValue)
        let rearmedVitals = try XCTUnwrap(
            rearmedGroup.work.first { $0.category == .vitals }
        )
        XCTAssertEqual(rearmedVitals.state, .retryable)
        XCTAssertEqual(rearmedVitals.attemptCount, 0)
        XCTAssertEqual(rearmedVitals.rearmCount, 1)

        do {
            try await coordinator.drain(cleanupWorkId: fixture.cleanupWorkId)
            XCTFail("rearmed cleanup returned success")
        } catch let error as SourcePrivacyCleanupCoordinatorError {
            XCTAssertEqual(error, .pending(fixture.cleanupWorkId))
        }
        let requestsAfterRearmedReplay = await recorder.snapshot()
        XCTAssertEqual(requestsAfterRearmedReplay.count, 13)

        let groupValue = try await fixture.store.sourcePrivacyCleanupGroup(
            cleanupWorkId: fixture.cleanupWorkId
        )
        let group = try XCTUnwrap(groupValue)
        let vitals = try XCTUnwrap(group.work.first { $0.category == .vitals })
        XCTAssertEqual(vitals.state, .retryable)
        XCTAssertEqual(vitals.attemptCount, 1)
        XCTAssertEqual(vitals.rearmCount, 1)
    }

    func testMalformedDurableCursorQuarantinesBeforeHealthKit() async throws {
        let fixture = try await makeSourcePrivacyCleanupFixture()
        let seedOwner = "bad-cursor-seed-owner"
        let leasedValue = try await fixture.store.leaseNextSourcePrivacyCleanupWork(
            owner: seedOwner,
            cleanupWorkId: fixture.cleanupWorkId
        )
        let leased = try XCTUnwrap(leasedValue)
        let firstDay = try CivilDay(key: leased.firstDay)
        let invalidCursor = HealthKitSourceDeletionCursor(
            category: .vitals,
            day: firstDay,
            componentIndex: -1
        )
        _ = try await fixture.store.persistSourcePrivacyCleanupCursors(
            leased,
            owner: seedOwner,
            scanCursor: nil,
            cleanupCursor: try JSONEncoder().encode(invalidCursor),
            batchDayCount: 1,
            batchObjectCount: 0,
            hasMore: true
        )

        let recorder = SourcePrivacyCleanupRequestRecorder()
        let coordinator = SourcePrivacyCleanupCoordinator(
            storeProvider: { [store = fixture.store] in store },
            owner: "bad-cursor-coordinator-owner",
            processChunk: { request in
                await recorder.append(request)
                return try completeChunkResult(for: request)
            }
        )
        do {
            try await coordinator.drain(cleanupWorkId: fixture.cleanupWorkId)
            XCTFail("invalid cursor reached HealthKit")
        } catch let error as SourcePrivacyCleanupCoordinatorError {
            XCTAssertEqual(error, .quarantinedGroup(fixture.cleanupWorkId))
        }
        let requests = await recorder.snapshot()
        XCTAssertTrue(requests.isEmpty)

        let groupValue = try await fixture.store.sourcePrivacyCleanupGroup(
            cleanupWorkId: fixture.cleanupWorkId
        )
        let group = try XCTUnwrap(groupValue)
        let vitals = try XCTUnwrap(group.work.first { $0.category == .vitals })
        XCTAssertEqual(vitals.state, .quarantined)
        XCTAssertEqual(vitals.attemptCount, 1)
    }

    func testMissingGroupFailsClosedBeforeHealthKit() async throws {
        let store = try await WhoopStore.inMemory()
        let missingId = UUID()
        let recorder = SourcePrivacyCleanupRequestRecorder()
        let coordinator = SourcePrivacyCleanupCoordinator(
            storeProvider: { store },
            owner: "missing-group-owner",
            processChunk: { request in
                await recorder.append(request)
                return try completeChunkResult(for: request)
            }
        )

        do {
            try await coordinator.drain(cleanupWorkId: missingId)
            XCTFail("missing cleanup group returned success")
        } catch let error as SourcePrivacyCleanupCoordinatorError {
            XCTAssertEqual(error, .missingGroup(missingId))
        }
        let requests = await recorder.snapshot()
        XCTAssertTrue(requests.isEmpty)
    }
}
#endif
