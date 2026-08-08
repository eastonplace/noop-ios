import XCTest
import GRDB
import NoopPhase34Core
@testable import WhoopStore

final class PR29SourceLifecycleRegressionTests: XCTestCase {
    func testPrivacyDeleteRetainsRecoveryJournalAndDiscardedScopeTombstone() async throws {
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

        try await store.persistSourceTransitionRecovery(recovery, now: now)
        _ = try await store.commitSourceLifecycleMutation(
            .deleteData(deviceId: "my-whoop", consumerId: "privacy-test"),
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(try await store.latestSourceTransitionRecovery(), recovery)
        let lifecycleState: String? = try await writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM historicalReceiptScopeLifecycle WHERE deviceId = ? LIMIT 1",
                arguments: ["my-whoop"]
            )
        }
        XCTAssertEqual(lifecycleState, HistoricalScopeLifecycleState.discarded.rawValue)
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
