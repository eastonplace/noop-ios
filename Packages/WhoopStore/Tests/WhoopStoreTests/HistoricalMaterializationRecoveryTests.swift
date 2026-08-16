import GRDB
import XCTest
@testable import WhoopStore

final class HistoricalMaterializationRecoveryTests: XCTestCase {
    private let receiptId = "quarantined-receipt"
    private let deviceId = "quarantined-device"
    private let lineage = "device:quarantined-device"
    private let batchId = "quarantined-batch"

    private func makeQuarantinedStore() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        let writer = store.registryWriter
        let receiptId = self.receiptId
        let deviceId = self.deviceId
        let lineage = self.lineage
        let batchId = self.batchId
        try await writer.write { db in
            let databaseInstanceId = try String.fetchOne(
                db,
                sql: "SELECT id FROM todayHealthSnapshotDatabase LIMIT 1"
            )!
            let framesBlob = Data([0x04, 0, 0, 0, 0x78, 0x9C, 0x01])
            try db.execute(sql: """
                INSERT INTO rawBatch
                    (batchId, deviceId, lineage, cursorEpoch, capturedAt,
                     deviceClockRef, wallClockRef, startTs, endTs, frameCount,
                     byteSize, framesBlob, syncedAt)
                VALUES (?, ?, ?, 0, 100, 100, 100, 100, 101, 1, 1244, ?, NULL)
                """, arguments: [batchId, deviceId, lineage, framesBlob])
            let rawRange = try JSONEncoder().encode(HistoricalRawRangeEvidence(
                source: .retainedRawBatch,
                minReceivedTs: 100,
                maxReceivedTs: 101,
                frameCount: 1,
                byteCount: 1244,
                hasHistoryEnd: true
            ))
            let counts = try JSONEncoder().encode(HistoricalStreamInsertCounts())
            let emptyStrings = try JSONEncoder().encode([String]())
            let emptyBuckets = Data("[]".utf8)
            let heal = try JSONEncoder().encode(HistoricalTimestampHeal.none)
            try db.execute(sql: """
                INSERT INTO historicalDataCommitJournal
                    (receiptId, databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope,
                     trim, chunkEndUnix, committedAt, fingerprint, minDecodedTs, maxDecodedTs,
                     touchedDaysJSON, decodedRowsJSON, insertedRowsJSON, rawBatchId, rawStatus,
                     burstJSON, rawRangeJSON, timestampHealJSON, isFinal, fingerprintVersion,
                     timestampBucketsJSON, recordedTimeZoneIdentifier, explicitAffectedDaysJSON)
                VALUES (?, ?, ?, ?, 0, 'historical', 1, 101, 102, ?, NULL, NULL,
                        ?, ?, ?, ?, 'materializationRequired', NULL, ?, ?, 0, 3, ?, 'UTC', ?)
                """, arguments: [
                    receiptId, databaseInstanceId, deviceId, lineage,
                    String(repeating: "a", count: 64), emptyStrings, counts, counts,
                    batchId, rawRange, heal, emptyBuckets, emptyStrings,
                ])
            try db.execute(sql: """
                INSERT INTO historicalMaterializationJob
                    (receiptId, databaseInstanceId, rawBatchId, deviceId, lineage, cursorEpoch,
                     trimScope, selectionMode, state, originalFrameIndexesJSON,
                     protectedByteCount, attemptCount, createdAt, updatedAt,
                     lastErrorCode, lastError)
                VALUES (?, ?, ?, ?, ?, 0, 'historical', 'selectiveMapped', 'quarantined',
                        ?, 1244, 5, 102, 103, 'invalidEnvelope', 'invalidEnvelope')
                """, arguments: [
                    receiptId, databaseInstanceId, batchId, deviceId, lineage,
                    try JSONEncoder().encode([0]),
                ])
        }
        return store
    }

    func testQuarantineSummaryAndExportPreserveCompressedArchive() async throws {
        let store = try await makeQuarantinedStore()

        let summary = try await store.historicalQuarantineSummary()
        XCTAssertEqual(summary.jobCount, 1)
        XCTAssertEqual(summary.protectedMappedByteCount, 1244)
        XCTAssertEqual(summary.archiveByteCount, 1244)
        XCTAssertEqual(summary.storedByteCount, 7)

        let fetchedExport = try await store.historicalQuarantinedArchive(receiptId: receiptId)
        let export = try XCTUnwrap(fetchedExport)
        XCTAssertEqual(export.compressedArchive, Data([0x04, 0, 0, 0, 0x78, 0x9C, 0x01]))
        XCTAssertEqual(export.job.lastErrorCode, "invalidEnvelope")
    }

    func testExplicitRetryMakesQuarantinedJobPending() async throws {
        let store = try await makeQuarantinedStore()

        let retried = try await store.retryQuarantinedHistoricalMaterialization(receiptId: receiptId)
        XCTAssertTrue(retried)
        let jobs = try await store.historicalQuarantinedJobs()
        XCTAssertTrue(jobs.isEmpty)
        let state = try await store.historicalMaterializationJobStateForTest(receiptId: receiptId)
        XCTAssertEqual(state, .pending)
    }

    func testExplicitDiscardKeepsReceiptEvidenceButRemovesOnlyArchive() async throws {
        let store = try await makeQuarantinedStore()

        let discarded = try await store.discardQuarantinedHistoricalArchive(receiptId: receiptId)
        XCTAssertTrue(discarded)
        let batchIds = try await store.allBatchIdsForTest()
        XCTAssertTrue(batchIds.isEmpty)
        let jobState = try await store.historicalMaterializationJobStateForTest(receiptId: receiptId)
        XCTAssertNil(jobState)
        let receipts = try await store.historicalDataCommitReceipts(deviceId: deviceId)
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.rawStatus, .unavailable)
        XCTAssertEqual(receipt.rawRange.source, .receivedFrames)
        XCTAssertEqual(receipt.rawRange.byteCount, 1244)
    }
}
