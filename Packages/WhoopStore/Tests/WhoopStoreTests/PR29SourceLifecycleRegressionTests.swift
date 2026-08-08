import XCTest
import GRDB
import NoopPhase34Core
@testable import WhoopStore

final class PR29SourceLifecycleRegressionTests: XCTestCase {
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
        XCTAssertEqual(try await store.latestSourceTransitionRecovery(), expectedRecovery)
        XCTAssertEqual(
            try await store.sourceTransitionCommit(transitionId: recovery.id),
            commit
        )

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
        XCTAssertEqual(try await store.latestSourceTransitionRecovery(), expectedRecovery)
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

        XCTAssertEqual(try await count(raw), 0)
        XCTAssertEqual(try await count(derived), 0)
        XCTAssertEqual(try await count(unrelated), 1)
    }
}
