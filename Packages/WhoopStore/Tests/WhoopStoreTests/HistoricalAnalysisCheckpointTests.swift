import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class HistoricalAnalysisCheckpointTests: XCTestCase {
    private func scope(
        deviceId: String = "strap-a",
        lineage: String,
        cursorEpoch: Int = 0,
        trimScope: String = HistoricalCursorScope.defaultTrimScope
    ) -> HistoricalCursorScope {
        HistoricalCursorScope(
            deviceId: deviceId,
            lineage: lineage,
            cursorEpoch: cursorEpoch,
            trimScope: trimScope
        )
    }

    private func commitReceipt(
        in store: WhoopStore,
        scope: HistoricalCursorScope,
        trim: Int,
        seed: UInt8
    ) async throws -> HistoricalDataCommitReceipt {
        let input = HistoricalReceivedFrameFingerprintInput(
            orderedFrames: [[0xAA, seed, 0x01]],
            protocolMetadata: Data([0x49, seed]),
            historyEndFrame: Data([0xAA, 0x02, seed]),
            minReceivedTs: 1_700_000_000,
            maxReceivedTs: 1_700_000_001
        )
        let chunkEndUnix = 1_700_000_100 + trim
        let fingerprint = try WhoopStore.historicalReceivedFrameFingerprint(
            input: input,
            deviceId: scope.deviceId,
            trim: trim,
            chunkEndUnix: chunkEndUnix
        )
        return try await store.commitHistoricalChunk(
            streams: Streams(),
            deviceId: scope.deviceId,
            trim: trim,
            chunkEndUnix: chunkEndUnix,
            rawBatch: nil,
            committedAt: chunkEndUnix + 1,
            scope: scope,
            fingerprint: fingerprint,
            fingerprintInput: input
        )
    }

    private func receipt(
        _ source: HistoricalDataCommitReceipt,
        generation: Int64
    ) -> HistoricalDataCommitReceipt {
        HistoricalDataCommitReceipt(
            receiptId: source.receiptId,
            generation: generation,
            databaseInstanceId: source.databaseInstanceId,
            deviceId: source.deviceId,
            trim: source.trim,
            chunkEndUnix: source.chunkEndUnix,
            committedAt: source.committedAt,
            rawBatchId: source.rawBatchId,
            insertedRows: source.insertedRows,
            fingerprint: source.fingerprint,
            lineage: source.lineage,
            cursorEpoch: source.cursorEpoch,
            trimScope: source.trimScope,
            minDecodedTs: source.minDecodedTs,
            maxDecodedTs: source.maxDecodedTs,
            touchedDays: source.touchedDays,
            decodedRows: source.decodedRows,
            rawStatus: source.rawStatus,
            rawRange: source.rawRange,
            burst: source.burst,
            timestampHeal: source.timestampHeal,
            isFinal: source.isFinal
        )
    }

    private func assertInvalidReceipt(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            try await operation()
            XCTFail("expected invalid receipt", file: file, line: line)
        } catch let error as HistoricalDataCommitJournalError {
            XCTAssertEqual(error, .invalidReceipt, file: file, line: line)
        }
    }

    func testV38CreatesCheckpointTableAndMigrationMarker() async throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v37-scoped-raw-batch-identity")
        try migrator.migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("historicalAnalysisCheckpoint"))
            XCTAssertEqual(
                try db.primaryKey("historicalAnalysisCheckpoint").columns,
                ["databaseInstanceId", "consumerId", "deviceId", "lineage", "cursorEpoch", "trimScope"]
            )
            XCTAssertTrue(Set(try db.columns(in: "historicalAnalysisCheckpoint").map(\.name)).isSuperset(of: [
                "databaseInstanceId", "consumerId", "deviceId", "lineage", "cursorEpoch", "trimScope",
                "throughGeneration", "throughTrim", "pendingGeneration", "pendingTrim",
                "pendingReceiptId", "pendingFingerprint", "pendingPayload",
            ]))
            XCTAssertTrue(
                try db.indexes(on: "historicalAnalysisCheckpoint")
                    .map(\.name)
                    .contains("idx_historicalAnalysisCheckpoint_database_consumer_generation")
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: ["v38-historical-analysis-checkpoint"]
                ),
                1
            )
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 38)
    }

    func testStageReloadResumesPendingPayloadAndReceiptFrontier() async throws {
        let path = NSTemporaryDirectory() + "whoop-analysis-checkpoint-\(UUID().uuidString).sqlite"
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        let scope = scope(lineage: "lineage-a")
        let firstStore = try await WhoopStore(path: path)
        let receipt = try await commitReceipt(in: firstStore, scope: scope, trim: 10, seed: 1)
        let payload = Data([0x01, 0x02, 0x03])
        let staged = try await firstStore.stageHistoricalAnalysis(
            consumerId: "recovery",
            for: scope,
            through: receipt,
            payload: payload
        )
        try await firstStore.close()

        let reopenedStore = try await WhoopStore(path: path)
        let readback = try await reopenedStore.historicalAnalysisCheckpoint(
            consumerId: "recovery",
            for: scope
        )
        let discovered = try await reopenedStore.pendingHistoricalAnalysisScopes(
            consumerId: "recovery"
        )

        XCTAssertEqual(readback, staged)
        XCTAssertEqual(readback?.databaseInstanceId, receipt.databaseInstanceId)
        XCTAssertEqual(readback?.pendingWork?.payload, payload)
        XCTAssertEqual(readback?.pendingWork?.target.receiptId, receipt.receiptId)
        XCTAssertEqual(readback?.pendingWork?.target.fingerprint, receipt.fingerprint)
        XCTAssertEqual(readback?.pendingWork?.target.generation, receipt.generation)
        XCTAssertEqual(readback?.pendingWork?.target.trim, receipt.trim)
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered.first?.pendingWork, staged.pendingWork)
        try await reopenedStore.close()
    }

    func testCheckpointIsScopedAndDiscoveryReturnsHighestUnacknowledgedWatermark() async throws {
        let store = try await WhoopStore.inMemory()
        let scopeA = scope(lineage: "lineage-a")
        let scopeB = scope(lineage: "lineage-b", cursorEpoch: 1, trimScope: "other")
        let receiptA1 = try await commitReceipt(in: store, scope: scopeA, trim: 20, seed: 1)
        let receiptA2 = try await commitReceipt(in: store, scope: scopeA, trim: 21, seed: 2)
        let receiptB1 = try await commitReceipt(in: store, scope: scopeB, trim: 20, seed: 3)

        let initial = try await store.pendingHistoricalAnalysisScopes()
        XCTAssertEqual(initial.map(\.scope), [scopeA, scopeB])
        XCTAssertEqual(
            initial.map(\.highestUnacknowledgedGeneration),
            [receiptA2.generation, receiptB1.generation]
        )
        XCTAssertEqual(initial[0].checkpoint, nil)
        XCTAssertEqual(initial[0].highestUnacknowledgedWatermark, receiptA2.durableWatermark)

        let stagedA1 = try await store.stageHistoricalAnalysis(
            for: scopeA,
            through: receiptA1,
            payload: Data([0xA1])
        )

        let afterA1 = try await store.pendingHistoricalAnalysisScopes()
        XCTAssertEqual(afterA1.map(\.scope), [scopeA, scopeB])
        XCTAssertEqual(afterA1[0].checkpoint, stagedA1)
        XCTAssertEqual(afterA1[0].pendingWork?.payload, Data([0xA1]))
        XCTAssertEqual(afterA1[0].highestUnacknowledgedGeneration, receiptA2.generation)
        XCTAssertEqual(afterA1[1].highestUnacknowledgedGeneration, receiptB1.generation)

        _ = try await store.acknowledgeHistoricalAnalysis(through: receiptA1)
        let afterAckA1 = try await store.historicalAnalysisCheckpoint(for: scopeA)
        XCTAssertEqual(afterAckA1?.throughGeneration, receiptA1.generation)
        XCTAssertNil(afterAckA1?.pendingWork)

        _ = try await store.stageHistoricalAnalysis(
            for: scopeA,
            through: receiptA2,
            payload: Data([0xA2])
        )
        _ = try await store.acknowledgeHistoricalAnalysis(through: receiptA2)
        let afterA2 = try await store.pendingHistoricalAnalysisScopes()
        XCTAssertEqual(afterA2.map(\.scope), [scopeB])
        XCTAssertEqual(afterA2[0].highestUnacknowledgedWatermark, receiptB1.durableWatermark)
    }

    func testAcknowledgementIsMonotonicAndIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        let sourceScope = scope(lineage: "lineage-a")
        let first = try await commitReceipt(in: store, scope: sourceScope, trim: 30, seed: 1)
        let second = try await commitReceipt(in: store, scope: sourceScope, trim: 31, seed: 2)

        let stagedFirst = try await store.stageHistoricalAnalysis(
            for: sourceScope,
            through: first,
            payload: Data([0x01])
        )
        let stagedAgain = try await store.stageHistoricalAnalysis(
            for: sourceScope,
            through: first,
            payload: Data([0x01])
        )
        let acknowledgedFirst = try await store.acknowledgeHistoricalAnalysis(
            through: first
        )
        let repeatedFirst = try await store.acknowledgeHistoricalAnalysis(through: first)
        let stagedSecond = try await store.stageHistoricalAnalysis(
            for: sourceScope,
            through: second,
            payload: Data([0x02])
        )
        let acknowledgedSecond = try await store.acknowledgeHistoricalAnalysis(
            through: second
        )
        let lower = try await store.acknowledgeHistoricalAnalysis(through: first)

        XCTAssertEqual(stagedAgain, stagedFirst)
        XCTAssertEqual(acknowledgedFirst.throughGeneration, first.generation)
        XCTAssertEqual(repeatedFirst, acknowledgedFirst)
        XCTAssertEqual(stagedSecond.throughGeneration, first.generation)
        XCTAssertEqual(acknowledgedSecond.throughGeneration, second.generation)
        XCTAssertNil(acknowledgedSecond.pendingWork)
        XCTAssertEqual(lower, acknowledgedSecond)
        let readback = try await store.historicalAnalysisCheckpoint(for: sourceScope)
        XCTAssertEqual(readback, acknowledgedSecond)
    }

    func testWrongOrMissingReceiptCannotAdvanceCheckpoint() async throws {
        let store = try await WhoopStore.inMemory()
        let scopeA = scope(lineage: "lineage-a")
        let receiptA1 = try await commitReceipt(in: store, scope: scopeA, trim: 40, seed: 1)
        let receiptA2 = try await commitReceipt(in: store, scope: scopeA, trim: 41, seed: 2)
        _ = try await store.stageHistoricalAnalysis(
            for: scopeA,
            through: receiptA1,
            payload: Data([0xA1])
        )

        try await assertInvalidReceipt {
            _ = try await store.acknowledgeHistoricalAnalysis(
                through: receipt(receiptA1, generation: receiptA1.generation + 100)
            )
        }
        try await assertInvalidReceipt {
            _ = try await store.acknowledgeHistoricalAnalysis(through: receiptA2)
        }
        try await assertInvalidReceipt {
            _ = try await store.acknowledgeHistoricalAnalysis(
                through: receiptA1.withFingerprint("rewound-fingerprint")
            )
        }
        let checkpointA = try await store.historicalAnalysisCheckpoint(for: scopeA)
        XCTAssertEqual(checkpointA?.pendingWork?.target.receiptId, receiptA1.receiptId)
        XCTAssertEqual(checkpointA?.pendingWork?.target.fingerprint, receiptA1.fingerprint)
    }

    func testIndependentConsumerIdsHaveIndependentPendingAndAcknowledgedState() async throws {
        let store = try await WhoopStore.inMemory()
        let sourceScope = scope(lineage: "lineage-a")
        let receipt = try await commitReceipt(in: store, scope: sourceScope, trim: 45, seed: 1)

        let consumerA = try await store.stageHistoricalAnalysis(
            consumerId: "consumer-a",
            for: sourceScope,
            through: receipt,
            payload: Data([0xA])
        )
        let consumerB = try await store.stageHistoricalAnalysis(
            consumerId: "consumer-b",
            for: sourceScope,
            through: receipt,
            payload: Data([0xB])
        )
        XCTAssertNotEqual(consumerA.consumerId, consumerB.consumerId)
        XCTAssertNotEqual(consumerA.pendingWork?.payload, consumerB.pendingWork?.payload)

        let acknowledgedA = try await store.acknowledgeHistoricalAnalysis(
            consumerId: "consumer-a",
            through: receipt
        )
        XCTAssertNil(acknowledgedA.pendingWork)
        let remainingB = try await store.historicalAnalysisCheckpoint(
            consumerId: "consumer-b",
            for: sourceScope
        )
        XCTAssertEqual(remainingB, consumerB)
        let pendingA = try await store.pendingHistoricalAnalysisScopes(consumerId: "consumer-a")
        let pendingB = try await store.pendingHistoricalAnalysisScopes(consumerId: "consumer-b")
        XCTAssertEqual(pendingA, [])
        XCTAssertEqual(pendingB.first?.pendingWork?.payload, Data([0xB]))
    }

    func testDistinctInMemoryDatabasesFenceReceiptAndCheckpointIdentity() async throws {
        let firstStore = try await WhoopStore.inMemory()
        let secondStore = try await WhoopStore.inMemory()
        let firstDatabaseId = try await firstStore.databaseInstanceId()
        let secondDatabaseId = try await secondStore.databaseInstanceId()
        XCTAssertNotEqual(firstDatabaseId, secondDatabaseId)

        let sourceScope = scope(lineage: "lineage-a")
        let receipt = try await commitReceipt(in: firstStore, scope: sourceScope, trim: 50, seed: 1)
        try await assertInvalidReceipt {
            _ = try await secondStore.stageHistoricalAnalysis(
                for: sourceScope,
                through: receipt,
                payload: Data([0x01])
            )
        }
        let staged = try await firstStore.stageHistoricalAnalysis(
            for: sourceScope,
            through: receipt,
            payload: Data([0x01])
        )
        let firstPending = try await firstStore.pendingHistoricalAnalysisScopes()
        let checkpoint = try await secondStore.historicalAnalysisCheckpoint(for: sourceScope)
        let pending = try await secondStore.pendingHistoricalAnalysisScopes()
        XCTAssertEqual(firstPending.first?.checkpoint, staged)
        XCTAssertNil(checkpoint)
        XCTAssertEqual(pending, [])
    }
}
