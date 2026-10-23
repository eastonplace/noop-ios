import XCTest
@testable import WhoopStore

final class WorkoutSuggestionStoreTests: XCTestCase {
    private func registeredStore() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pairedDevice
                    (id, brand, model, sourceKind, capabilities, status, addedAt, lastSeenAt,
                     historyLineage, historyCursorEpoch)
                VALUES ('strap', 'WHOOP', 'WHOOP', 'liveBLE', 'hr', 'paired', 1, 1, 'test:strap', 0)
                """)
        }
        return store
    }

    private func row(start: Int = 10_000, end: Int = 11_237, sport: String = "Running",
                     source: String = "manual") -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: nil, avgHr: 145, maxHr: nil,
                   strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
    }

    func testOverlapReadFindsAnEarlierLongWorkoutAndIncludesTouchingEndpoints() async throws {
        let store = try await registeredStore()
        try await store.upsertWorkouts([row(start: 100, end: 10_000), row(start: 11_237, end: 12_000)],
                                       deviceId: "apple-health")
        try await store.upsertWorkouts([row()], deviceId: "unrelated-source")
        let spans = try await store.workoutSuggestionSpans(deviceIds: ["apple-health"],
                                                           from: 10_000, to: 11_237)
        XCTAssertEqual(spans.map(\.startSec), [100, 11_237])
        XCTAssertEqual(Set(spans.map(\.deviceId)), ["apple-health"])
    }

    func testInsertPreservesExactBoundsAndRejectsASecondTypeForTheSameWindow() async throws {
        let store = try await registeredStore()
        let identity = try await store.databaseInstanceId()
        let owner = try await store.workoutSuggestionSourceOwner(deviceId: "strap")
        let first = try await store.insertWorkoutSuggestion(
            row(), deviceId: "strap", overlapDeviceIds: ["strap", "apple-health"],
            expectedDatabaseInstanceId: identity, sourceOwner: owner)
        let second = try await store.insertWorkoutSuggestion(
            row(sport: "Cycling"), deviceId: "strap", overlapDeviceIds: ["strap", "apple-health"],
            expectedDatabaseInstanceId: identity, sourceOwner: owner)
        XCTAssertEqual(first, .inserted)
        XCTAssertEqual(second, .overlapsExisting)
        let rows = try await store.workouts(deviceId: "strap", from: 0, to: 20_000, limit: 10)
        XCTAssertEqual(rows, [row()])
    }

    func testConcurrentSaveAttemptsCommitOnlyOneWorkout() async throws {
        let store = try await registeredStore()
        let identity = try await store.databaseInstanceId()
        let owner = try await store.workoutSuggestionSourceOwner(deviceId: "strap")
        let running = row(), cycling = row(sport: "Cycling")
        async let first = store.insertWorkoutSuggestion(running, deviceId: "strap",
                                                        overlapDeviceIds: ["strap"],
                                                        expectedDatabaseInstanceId: identity, sourceOwner: owner)
        async let second = store.insertWorkoutSuggestion(cycling, deviceId: "strap",
                                                         overlapDeviceIds: ["strap"],
                                                         expectedDatabaseInstanceId: identity, sourceOwner: owner)
        let results = try await [first, second]
        XCTAssertEqual(results.filter { $0 == .inserted }.count, 1)
        XCTAssertEqual(results.filter { $0 == .overlapsExisting }.count, 1)
        let rows = try await store.workouts(deviceId: "strap", from: 0, to: 20_000, limit: 10)
        XCTAssertEqual(rows.count, 1)
    }

    func testAllSpecifiedWorkoutSourcesSuppressTheInsert() async throws {
        for owner in ["strap", "strap-noop", "my-whoop", "my-whoop-noop", "apple-health", "lifting", "activity-file"] {
            let store = try await registeredStore()
            try await store.upsertWorkouts([row(start: 100, end: 11_000, source: owner)], deviceId: owner)
            let result = try await store.insertWorkoutSuggestion(
                row(), deviceId: "strap", overlapDeviceIds: [owner],
                expectedDatabaseInstanceId: store.databaseInstanceId(),
                sourceOwner: store.workoutSuggestionSourceOwner(deviceId: "strap"))
            XCTAssertEqual(result, .overlapsExisting, owner)
        }
    }

    func testTheTargetSourceIsAlwaysCheckedEvenWhenCallerOmitsIt() async throws {
        let store = try await registeredStore()
        try await store.upsertWorkouts([row()], deviceId: "strap")
        let result = try await store.insertWorkoutSuggestion(
            row(sport: "Strength"), deviceId: "strap", overlapDeviceIds: [],
            expectedDatabaseInstanceId: store.databaseInstanceId(),
            sourceOwner: store.workoutSuggestionSourceOwner(deviceId: "strap"))
        XCTAssertEqual(result, .overlapsExisting)
    }

    func testDismissedDetectedRowsDoNotSuppressButManualRowsStillDo() async throws {
        let store = try await registeredStore()
        let dismissed = WorkoutSuggestionSpan(startSec: 9_000, endSec: 12_000)
        try await store.upsertWorkouts([row(source: "strap-noop")], deviceId: "strap-noop")
        let identity = try await store.databaseInstanceId()
        let owner = try await store.workoutSuggestionSourceOwner(deviceId: "strap")
        let result = try await store.insertWorkoutSuggestion(
            row(), deviceId: "strap", overlapDeviceIds: ["strap-noop"],
            dismissedDetectedSpans: [dismissed], expectedDatabaseInstanceId: identity, sourceOwner: owner)
        XCTAssertEqual(result, .inserted)
        let again = try await store.insertWorkoutSuggestion(
            row(sport: "Cycling"), deviceId: "strap", overlapDeviceIds: ["strap-noop"],
            dismissedDetectedSpans: [dismissed], expectedDatabaseInstanceId: identity, sourceOwner: owner)
        XCTAssertEqual(again, .overlapsExisting)
    }

    func testAReplacedDatabaseIdentityCannotAcceptTheOldSuggestion() async throws {
        let first = try await registeredStore()
        let replacement = try await registeredStore()
        let identity = try await first.databaseInstanceId()
        let owner = try await first.workoutSuggestionSourceOwner(deviceId: "strap")
        let result = try await replacement.insertWorkoutSuggestion(
            row(), deviceId: "strap", overlapDeviceIds: ["strap"],
            expectedDatabaseInstanceId: identity, sourceOwner: owner)
        XCTAssertEqual(result, .staleDatabase)
        let rows = try await replacement.workouts(deviceId: "strap", from: 0, to: 20_000, limit: 10)
        XCTAssertTrue(rows.isEmpty)
    }

    func testInvalidRowsAndAClosedStoreThrowInsteadOfReportingSuccess() async throws {
        let store = try await registeredStore()
        let identity = try await store.databaseInstanceId()
        let owner = try await store.workoutSuggestionSourceOwner(deviceId: "strap")
        do {
            _ = try await store.insertWorkoutSuggestion(row(end: 9_000), deviceId: "strap",
                                                        overlapDeviceIds: ["strap"],
                                                        expectedDatabaseInstanceId: identity, sourceOwner: owner)
            XCTFail("Invalid workout should be rejected")
        } catch WorkoutSuggestionStoreError.invalidWorkout { }
        try await store.close()
        do {
            _ = try await store.insertWorkoutSuggestion(row(), deviceId: "strap",
                                                        overlapDeviceIds: ["strap"],
                                                        expectedDatabaseInstanceId: identity, sourceOwner: owner)
            XCTFail("Closed store should throw")
        } catch { }
    }

    func testChangedLineageOrCursorCannotResurrectASuggestionAfterOwnerReuse() async throws {
        for change in ["historyLineage = 'replacement-owner'", "historyCursorEpoch = historyCursorEpoch + 1"] {
            let store = try await registeredStore()
            let owner = try await store.workoutSuggestionSourceOwner(deviceId: "strap")
            let identity = try await store.databaseInstanceId()
            // The review happened before a queued write; the owner changes before that write starts.
            try await store.registryWriter.write { db in
                try db.execute(sql: "UPDATE pairedDevice SET \(change) WHERE id = 'strap'")
            }
            let result = try await store.insertWorkoutSuggestion(
                row(), deviceId: "strap", overlapDeviceIds: [],
                expectedDatabaseInstanceId: identity, sourceOwner: owner)
            XCTAssertEqual(result, .staleSource, change)
            let rows = try await store.workouts(deviceId: "strap", from: 0, to: 20_000, limit: 10)
            XCTAssertTrue(rows.isEmpty, "a stale review recreated a workout after its owner changed")
        }
    }

    func testDeletionInProgressCannotAcceptAPreviouslyReviewedSuggestion() async throws {
        let store = try await registeredStore()
        let owner = try await store.workoutSuggestionSourceOwner(deviceId: "strap")
        let identity = try await store.databaseInstanceId()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO sourceTransitionJournal (
                    transitionId, version, mutationKind, sourceDeviceId, contributorIdsJSON,
                    transitionScope, historicalEpoch, externalEpoch, sinkEpoch, stage, createdAt, updatedAt
                ) VALUES ('workout-deletion', 2, 'deleteData', 'strap', ?, 'targetOnly', 1, 1, 1, 'prepared', 1, 1)
                """, arguments: [Data("[\"strap\"]".utf8)])
        }
        let result = try await store.insertWorkoutSuggestion(
            row(), deviceId: "strap", overlapDeviceIds: [],
            expectedDatabaseInstanceId: identity, sourceOwner: owner)
        XCTAssertEqual(result, .staleSource)
        let rows = try await store.workouts(deviceId: "strap", from: 0, to: 20_000, limit: 10)
        XCTAssertTrue(rows.isEmpty)
    }

    func testDiscardedLifecycleCannotAcceptAPreviouslyReviewedSuggestion() async throws {
        let store = try await registeredStore()
        let owner = try await store.workoutSuggestionSourceOwner(deviceId: "strap")
        let identity = try await store.databaseInstanceId()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO historicalReceiptScopeLifecycle (
                    databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope,
                    state, closedThroughGeneration, reason, updatedAt
                ) VALUES (?, ?, ?, ?, ?, 'discarded', 0, 'test-purge', 1)
                """, arguments: [identity, owner.deviceId, owner.lineage, owner.cursorEpoch, owner.trimScope])
        }
        let result = try await store.insertWorkoutSuggestion(
            row(), deviceId: "strap", overlapDeviceIds: [],
            expectedDatabaseInstanceId: identity, sourceOwner: owner)
        XCTAssertEqual(result, .staleSource)
        let rows = try await store.workouts(deviceId: "strap", from: 0, to: 20_000, limit: 10)
        XCTAssertTrue(rows.isEmpty)
        do {
            _ = try await store.workoutSuggestionSourceOwner(deviceId: "strap")
            XCTFail("a discarded source must not admit a fresh suggestion")
        } catch let error as LiftReceiptStateError {
            XCTAssertEqual(error, .ownerPurged(deviceId: "strap"))
        }
    }

    func testArchivedOrMissingOwnerCannotAcceptAPreviouslyReviewedSuggestion() async throws {
        for mutation in ["UPDATE pairedDevice SET status = 'archived' WHERE id = 'strap'",
                         "DELETE FROM pairedDevice WHERE id = 'strap'"] {
            let store = try await registeredStore()
            let owner = try await store.workoutSuggestionSourceOwner(deviceId: "strap")
            let identity = try await store.databaseInstanceId()
            try await store.registryWriter.write { db in try db.execute(sql: mutation) }
            let result = try await store.insertWorkoutSuggestion(
                row(), deviceId: "strap", overlapDeviceIds: [],
                expectedDatabaseInstanceId: identity, sourceOwner: owner)
            XCTAssertEqual(result, .staleSource)
            let rows = try await store.workouts(deviceId: "strap", from: 0, to: 20_000, limit: 10)
            XCTAssertTrue(rows.isEmpty)
        }
    }

    func testAnOwnerTokenCannotAuthorizeADifferentNamespace() async throws {
        let store = try await registeredStore()
        let owner = try await store.workoutSuggestionSourceOwner(deviceId: "strap")
        let result = try await store.insertWorkoutSuggestion(
            row(), deviceId: "another-source", overlapDeviceIds: [],
            expectedDatabaseInstanceId: store.databaseInstanceId(), sourceOwner: owner)
        XCTAssertEqual(result, .staleSource)
        let rows = try await store.workouts(deviceId: "another-source", from: 0, to: 20_000, limit: 10)
        XCTAssertTrue(rows.isEmpty)
    }
}
