import XCTest
import GRDB
@testable import WhoopStore

final class LiftReceiptStateTests: XCTestCase {

    func testReceiptStateRoundTripsForExactSourceOwner() async throws {
        let store = try await WhoopStore.inMemory()
        let owner = try await store.receiptLiftSourceOwner(deviceId: "my-whoop")
        let data = Data("{\"schemaVersion\":2}".utf8)

        try await store.saveReceiptLiftState(sourceOwner: owner, data: data)

        let loaded = try await store.loadReceiptLiftState(sourceOwner: owner)
        XCTAssertEqual(loaded, data)
        let otherSource = try await store.loadReceiptLiftState(deviceId: "another-source")
        XCTAssertNil(otherSource)
    }

    func testAtomicBridgeWritesEnvelopeAndCompletedWorkoutForExactOwner() async throws {
        let store = try await WhoopStore.inMemory()
        let owner = try await store.receiptLiftSourceOwner(deviceId: "my-whoop")
        let session = LiftSessionRow(
            id: "receipt-session", deviceId: owner.deviceId, startTs: 1_700_000_000,
            endTs: 1_700_000_600, sport: "Strength Training", programId: nil,
            programName: "Upper A", sessionRpe: 7, note: nil)
        let set = LiftSetRow(
            id: "receipt-set", deviceId: owner.deviceId, sessionId: session.id, ord: 0,
            exercise: "Bench press", primaryMuscle: .chest, secondaryMuscles: [.triceps],
            setIndex: 1, weightKg: 80, reps: 8, rpe: 8, isWarmup: false,
            startTs: session.startTs, endTs: session.startTs + 60, restSec: 120, note: nil)
        let workout = WorkoutRow(
            startTs: session.startTs, endTs: session.endTs!, sport: session.sport,
            source: "manual", durationS: 600, energyKcal: nil, avgHr: nil, maxHr: nil,
            strain: nil, distanceM: nil, zonesJSON: nil, notes: session.programName)
        let data = Data("receipt-envelope".utf8)

        try await store.saveReceiptLiftStateAndWorkout(
            sourceOwner: owner,
            data: data,
            sessions: [session],
            sets: [set],
            workouts: [workout]
        )

        let loaded = try await store.loadReceiptLiftState(sourceOwner: owner)
        XCTAssertEqual(loaded, data)
        let counts = try await store.registryWriter.read { db -> (Int, Int, Int) in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout WHERE deviceId = ?",
                                 arguments: [owner.deviceId]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftSession WHERE deviceId = ?",
                                 arguments: [owner.deviceId]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftSet WHERE deviceId = ?",
                                 arguments: [owner.deviceId]) ?? 0
            )
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 1)
    }

    func testAtomicBridgeRejectsPendingDeletionBeforeWritingAnything() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO sourceTransitionJournal (
                    transitionId, version, mutationKind, sourceDeviceId,
                    contributorIdsJSON, transitionScope, historicalEpoch,
                    externalEpoch, sinkEpoch, stage, createdAt, updatedAt
                ) VALUES (?, ?, 'deleteData', ?, ?, 'targetOnly', ?, ?, ?, 'prepared', ?, ?)
                """, arguments: [
                    "transition-delete-lift",
                    2,
                    "my-whoop",
                    Data("[\"my-whoop\"]".utf8),
                    1,
                    1,
                    1,
                    1,
                    1,
                ])
        }

        do {
            try await store.saveReceiptLiftStateAndWorkout(
                deviceId: "my-whoop",
                data: Data("pending".utf8),
                sessions: [],
                sets: [],
                workouts: []
            )
            XCTFail("a pending source deletion must reject the receipt bridge")
        } catch let error as LiftReceiptStateError {
            XCTAssertEqual(error, .ownerDeleting(deviceId: "my-whoop"))
        }

        let receiptCount = try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftReceiptState") ?? 0
        }
        XCTAssertEqual(receiptCount, 0)
    }

    func testPurgedSourceRejectsLegacyBridgeAndRollsBackEnvelopeAndWorkout() async throws {
        let store = try await WhoopStore.inMemory()
        let owner = try await store.receiptLiftSourceOwner(deviceId: "my-whoop")
        let databaseId = try await store.registryWriter.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM todayHealthSnapshotDatabase LIMIT 1")!
        }
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO historicalReceiptScopeLifecycle (
                    databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope,
                    state, closedThroughGeneration, reason, updatedAt
                ) VALUES (?, ?, ?, ?, ?, 'discarded', 0, ?, ?)
                """, arguments: [
                    databaseId,
                    owner.deviceId,
                    owner.lineage,
                    owner.cursorEpoch,
                    HistoricalCursorScope.defaultTrimScope,
                    "test-purge",
                    1,
                ])
        }

        let session = LiftSessionRow(
            id: "purged-session", deviceId: owner.deviceId, startTs: 1_700_000_000,
            endTs: 1_700_000_060, sport: "Strength Training", programId: nil,
            programName: "Upper A", sessionRpe: nil, note: nil)
        let workout = WorkoutRow(
            startTs: session.startTs, endTs: session.endTs!, sport: session.sport,
            source: "manual", durationS: 60, energyKcal: nil, avgHr: nil, maxHr: nil,
            strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)

        do {
            try await store.saveReceiptLiftStateAndWorkout(
                deviceId: owner.deviceId,
                data: Data("must-not-land".utf8),
                sessions: [session],
                sets: [],
                workouts: [workout]
            )
            XCTFail("a purged source must reject the legacy device-id bridge")
        } catch let error as LiftReceiptStateError {
            XCTAssertEqual(error, .ownerPurged(deviceId: owner.deviceId))
        }

        let counts = try await store.registryWriter.read { db -> (Int, Int) in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftReceiptState") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout") ?? 0
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }

    func testExactOwnerRejectsLineageChangeInsideWriteTransaction() async throws {
        let store = try await WhoopStore.inMemory()
        let owner = try await store.receiptLiftSourceOwner(deviceId: "my-whoop")
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                UPDATE pairedDevice
                SET historyLineage = ?, historyCursorEpoch = historyCursorEpoch + 1
                WHERE id = ?
                """, arguments: ["new-lineage", owner.deviceId])
        }

        do {
            try await store.saveReceiptLiftState(sourceOwner: owner, data: Data("stale".utf8))
            XCTFail("a stale source owner must be rejected")
        } catch let error as LiftReceiptStateError {
            XCTAssertEqual(error, .ownerChanged(deviceId: owner.deviceId))
        }

        let receiptCount = try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftReceiptState") ?? 0
        }
        XCTAssertEqual(receiptCount, 0)
    }

    func testDeviceDeletionClearsReceiptState() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveReceiptLiftState(deviceId: "my-whoop", data: Data("delete-me".utf8))

        try await store.deleteAllData(deviceId: "my-whoop")

        let loaded = try await store.loadReceiptLiftState(deviceId: "my-whoop")
        XCTAssertNil(loaded)
        let count = try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftReceiptState") ?? 0
        }
        XCTAssertEqual(count, 0)
    }
}
