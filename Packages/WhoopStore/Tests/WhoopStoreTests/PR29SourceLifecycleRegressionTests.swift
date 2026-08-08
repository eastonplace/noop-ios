import XCTest
import GRDB
import NoopPhase34Core
@testable import WhoopStore

final class PR29SourceLifecycleRegressionTests: XCTestCase {
    func testSecondTransitionCannotOvertakeIncompleteRecoveryJournal() async throws {
        let store = try await WhoopStore.inMemory()
        let first = SourceTransitionRecoveryRecord(
            mutationKind: "deleteData",
            sourceDeviceId: "device-a",
            targetDeviceId: "device-b",
            historicalEpoch: 1,
            externalEpoch: 1,
            sinkEpoch: 1,
            stage: .prepared
        )
        let second = SourceTransitionRecoveryRecord(
            mutationKind: "archive",
            sourceDeviceId: "device-b",
            targetDeviceId: nil,
            historicalEpoch: 2,
            externalEpoch: 2,
            sinkEpoch: 2,
            stage: .prepared
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
        let recovery = SourceTransitionRecoveryRecord(
            mutationKind: "deleteData",
            sourceDeviceId: "my-whoop",
            targetDeviceId: nil,
            historicalEpoch: 7,
            externalEpoch: 11,
            sinkEpoch: 13,
            stage: .prepared
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
        let recovery = SourceTransitionRecoveryRecord(
            mutationKind: "deleteData",
            sourceDeviceId: "my-whoop",
            targetDeviceId: nil,
            historicalEpoch: 1,
            externalEpoch: 1,
            sinkEpoch: 1,
            stage: .prepared
        )
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
        let recovery = SourceTransitionRecoveryRecord(
            mutationKind: "deleteData",
            sourceDeviceId: "my-whoop",
            targetDeviceId: nil,
            historicalEpoch: 1,
            externalEpoch: 1,
            sinkEpoch: 1,
            stage: .prepared
        )

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
                        contextId, deviceId, snapshotGeneration, presentationJSON,
                        widgetCoreJSON, logicalDay, deliveredAt
                    ) VALUES (?, ?, 1, ?, ?, '2026-08-08', 1)
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
}
