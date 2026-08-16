import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class MigrationTests: XCTestCase {
    private static let v55ReceiptId = "v55-receipt"
    private static let v55BatchId = "v55-batch"
    private static let v55DeviceId = "v55-device"
    private static let v55Lineage = "device:v55-device"

    private func putU32(_ frame: inout [UInt8], at offset: Int, value: UInt32) {
        frame[offset] = UInt8(value & 0xFF)
        frame[offset + 1] = UInt8((value >> 8) & 0xFF)
        frame[offset + 2] = UInt8((value >> 16) & 0xFF)
        frame[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func v55V20(unix: UInt32) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: Whoop5RawOptical.bufferLength)
        frame[0] = 0xAA
        frame[1] = 0x01
        let declared = frame.count - 8
        frame[2] = UInt8(declared & 0xFF)
        frame[3] = UInt8((declared >> 8) & 0xFF)
        frame[4] = 0x01
        frame[8] = 0x2F
        frame[9] = 20
        frame[10] = 0x81
        putU32(&frame, at: 15, value: unix)
        frame[Whoop5RawOptical.blockStart] = 25
        frame[Whoop5RawOptical.blockStart + Whoop5RawOptical.headerLength] = 0x7F
        let headerCRC = crc16Modbus(Array(frame[0..<6]))
        frame[6] = UInt8(headerCRC & 0xFF)
        frame[7] = UInt8((headerCRC >> 8) & 0xFF)
        let payloadEnd = frame.count - 4
        putU32(&frame, at: payloadEnd, value: crc32(Array(frame[8..<payloadEnd])))
        return frame
    }

    private func seedCompletedV54(
        in dbQueue: DatabaseQueue,
        exactFrame: [UInt8],
        archiveFrame: [UInt8],
        retainArchive: Bool,
        state: String = "completed",
        committedAt: Int? = nil
    ) async throws {
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: PR29V53Migrations.identifier)
        let packed = WhoopStore.packFrames([archiveFrame])
        let compressed = try WhoopStore.zlibCompressWithLength(packed)
        let unix = try XCTUnwrap(parseFrame(archiveFrame, family: .whoop5).parsed["unix"]?.intValue)
        let receiptCommittedAt = committedAt ?? unix + 1

        try await dbQueue.write { db in
            let databaseInstanceId = try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT id FROM todayHealthSnapshotDatabase LIMIT 1")
            )
            try db.execute(sql: """
                INSERT INTO rawBatch
                    (batchId, deviceId, lineage, cursorEpoch, capturedAt, deviceClockRef,
                     wallClockRef, startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
                VALUES (?, ?, ?, 0, ?, ?, ?, ?, ?, 1, ?, ?, NULL)
                """, arguments: [
                    Self.v55BatchId, Self.v55DeviceId, Self.v55Lineage, unix, unix, unix, unix, unix,
                    archiveFrame.count, compressed,
                ])
            try db.execute(sql: """
                INSERT INTO historicalDataCommitJournal
                    (receiptId, databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope,
                     trim, chunkEndUnix, committedAt, fingerprint, minDecodedTs, maxDecodedTs,
                     touchedDaysJSON, decodedRowsJSON, insertedRowsJSON, rawBatchId, rawStatus,
                     rawRangeJSON, timestampHealJSON, isFinal, fingerprintVersion,
                     timestampBucketsJSON, recordedTimeZoneIdentifier, explicitAffectedDaysJSON)
                VALUES (?, ?, ?, ?, 0, 'historical', 7, ?, ?, 'v55-fingerprint', ?, ?,
                        ?, ?, ?, ?, 'materializationRequired', ?, ?, 0, 3, ?, 'UTC', ?)
                """, arguments: [
                    Self.v55ReceiptId, databaseInstanceId, Self.v55DeviceId, Self.v55Lineage,
                    unix, receiptCommittedAt,
                    unix, unix, Data("[]".utf8), Data("{}".utf8), Data("{}".utf8),
                    Self.v55BatchId, Data("{}".utf8), Data("{}".utf8), Data("[]".utf8),
                    Data("[]".utf8),
                ])
        }

        try migrator.migrate(dbQueue, upTo: PR37V54Migrations.identifier)
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE historicalMaterializationJob
                SET state = ?, completedAt = ?, updatedAt = ?
                WHERE receiptId = ?
                """, arguments: [
                    state, state == "completed" ? unix + 2 : nil, unix + 2, Self.v55ReceiptId,
                ])
            try db.execute(sql: """
                INSERT INTO historicalMappedRawFrame
                    (receiptId, originalFrameIndex, version, unix, exactFrame,
                     frameByteCount, materializedAt)
                VALUES (?, 0, 20, ?, ?, ?, ?)
                """, arguments: [
                    Self.v55ReceiptId, unix, Data(exactFrame), exactFrame.count, unix + 2,
                ])
            if !retainArchive {
                try db.execute(sql: """
                    DELETE FROM rawBatch
                    WHERE batchId = ? AND deviceId = ? AND lineage = ? AND cursorEpoch = 0
                    """, arguments: [Self.v55BatchId, Self.v55DeviceId, Self.v55Lineage])
            }
        }
    }

    func testInMemoryRunsMigrations() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in [
            "device", "hrSample", "rrInterval", "event", "battery", "rawBatch",
            "coachingBehaviorSet", "coachingBehaviorMembership",
            "coachingStack", "coachingStackItem", "coachingStackUse",
            "ppgWaveformSample", "todayHealthSnapshot", "historicalDataCommitJournal",
            "historicalReceiptConsumer", "historicalAnalysisWork", "analysisMutationJournal",
            "verifiedHealthProjection", "verifiedSnapshotCommit", "externalPublicationOutbox",
            "historicalReceiptScopeLifecycle", "historicalMaintenanceWork", "sourceTransitionJournal",
            "historicalMaterializationJob", "historicalMappedRawFrame",
        ] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 56)
    }

    func testV54AddsDurableMappedRawMaterializationLifecycleWithoutRewritingV53() async throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: PR29V53Migrations.identifier)

        try await dbQueue.read { db in
            XCTAssertFalse(try db.tableExists("historicalMaterializationJob"))
            XCTAssertTrue(try db.tableExists("historicalDataCommitJournal"))
        }

        try migrator.migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("historicalMaterializationJob"))
            XCTAssertTrue(try db.tableExists("historicalMappedRawFrame"))
            let jobColumns = Set(try db.columns(in: "historicalMaterializationJob").map(\.name))
            XCTAssertTrue(jobColumns.isSuperset(of: [
                "receiptId", "databaseInstanceId", "rawBatchId", "deviceId", "lineage",
                "cursorEpoch", "trimScope", "selectionMode", "state",
                "originalFrameIndexesJSON", "protectedByteCount", "mappedRawMinTs",
                "mappedRawMaxTs", "attemptCount", "nextAttemptAt", "leaseOwner",
                "leaseExpiresAt", "lastErrorCode", "lastError", "completedAt", "evictedAt",
            ]))
            let materializedColumns = Set(try db.columns(in: "historicalMappedRawFrame").map(\.name))
            XCTAssertTrue(materializedColumns.isSuperset(of: [
                "receiptId", "databaseInstanceId", "rawBatchId", "deviceId", "lineage",
                "cursorEpoch", "trimScope", "originalFrameIndex", "rawFrameOffset",
                "version", "unix", "exactByteCount",
            ]))
            XCTAssertFalse(materializedColumns.contains("exactFrame"))
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: [PR29V53Migrations.identifier]),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: [PR37V54Migrations.identifier]),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: [PR37V55Migrations.identifier]),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: [PR37V56Migrations.identifier]),
                1
            )
        }
    }

    func testV56DelayedUpgradeRepairsReceiptTimeFrontierAndConvergesWithFreshMigration() async throws {
        let frameUnix = Int(Date().timeIntervalSince1970) - 60
        let committedAt = frameUnix - FUTURE_MARGIN - 1
        let frame = v55V20(unix: UInt32(frameUnix))
        let delayed = try DatabaseQueue()
        let fresh = try DatabaseQueue()
        for queue in [delayed, fresh] {
            try await seedCompletedV54(
                in: queue,
                exactFrame: frame,
                archiveFrame: frame,
                retainArchive: true,
                committedAt: committedAt
            )
        }

        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(delayed, upTo: PR37V55Migrations.identifier)
        try await delayed.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT mappedRawMaxTs FROM historicalMaterializationJob WHERE receiptId = ?",
                    arguments: [Self.v55ReceiptId]
                ),
                frameUnix,
                "V55 used upgrade wall time and demonstrates the delayed-upgrade bug"
            )
        }

        try migrator.migrate(delayed)
        try migrator.migrate(fresh)

        let delayedValues: [Int?] = try await delayed.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT mappedRawMinTs, mappedRawMaxTs, protectedByteCount
                FROM historicalMaterializationJob WHERE receiptId = ?
                """, arguments: [Self.v55ReceiptId]))
            return [
                row["mappedRawMinTs"] as Int?,
                row["mappedRawMaxTs"] as Int?,
                row["protectedByteCount"] as Int,
            ]
        }
        let freshValues: [Int?] = try await fresh.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT mappedRawMinTs, mappedRawMaxTs, protectedByteCount
                FROM historicalMaterializationJob WHERE receiptId = ?
                """, arguments: [Self.v55ReceiptId]))
            return [
                row["mappedRawMinTs"] as Int?,
                row["mappedRawMaxTs"] as Int?,
                row["protectedByteCount"] as Int,
            ]
        }
        XCTAssertEqual(delayedValues, freshValues)
        XCTAssertNil(delayedValues[0])
        XCTAssertNil(delayedValues[1])
        XCTAssertEqual(delayedValues[2], frame.count)
        try await delayed.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: [PR37V56Migrations.identifier]
                ),
                1
            )
        }
    }

    func testV56QuarantinedCorruptArchiveDoesNotBlockMigration() async throws {
        let frame = v55V20(unix: 1_781_600_950)
        let dbQueue = try DatabaseQueue()
        try await seedCompletedV54(
            in: dbQueue,
            exactFrame: frame,
            archiveFrame: frame,
            retainArchive: true,
            state: "quarantined"
        )

        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: PR37V55Migrations.identifier)
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO rawBatch
                    (batchId, deviceId, lineage, cursorEpoch, capturedAt, deviceClockRef,
                     wallClockRef, startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
                SELECT 'v56-valid-batch', deviceId, lineage, cursorEpoch, capturedAt, deviceClockRef,
                       wallClockRef, startTs, endTs, frameCount, byteSize, framesBlob, syncedAt
                FROM rawBatch
                WHERE batchId = ? AND deviceId = ? AND lineage = ? AND cursorEpoch = 0
                """, arguments: [Self.v55BatchId, Self.v55DeviceId, Self.v55Lineage])
            try db.execute(sql: """
                INSERT INTO historicalDataCommitJournal
                    (receiptId, databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope,
                     trim, chunkEndUnix, committedAt, fingerprint, minDecodedTs, maxDecodedTs,
                     touchedDaysJSON, decodedRowsJSON, insertedRowsJSON, rawBatchId, rawStatus,
                     burstJSON, rawRangeJSON, timestampHealJSON, isFinal, fingerprintVersion,
                     timestampBucketsJSON, recordedTimeZoneIdentifier, explicitAffectedDaysJSON)
                SELECT 'v56-valid-receipt', databaseInstanceId, deviceId, lineage, cursorEpoch,
                       trimScope, trim + 1, chunkEndUnix, committedAt, 'v56-valid-fingerprint',
                       minDecodedTs, maxDecodedTs, touchedDaysJSON, decodedRowsJSON,
                       insertedRowsJSON, 'v56-valid-batch', rawStatus, burstJSON, rawRangeJSON,
                       timestampHealJSON, isFinal, fingerprintVersion, timestampBucketsJSON,
                       recordedTimeZoneIdentifier, explicitAffectedDaysJSON
                FROM historicalDataCommitJournal WHERE receiptId = ?
                """, arguments: [Self.v55ReceiptId])
            try db.execute(sql: """
                INSERT INTO historicalMaterializationJob
                    (receiptId, databaseInstanceId, rawBatchId, deviceId, lineage, cursorEpoch,
                     trimScope, selectionMode, state, originalFrameIndexesJSON,
                     protectedByteCount, mappedRawMinTs, mappedRawMaxTs, attemptCount,
                     nextAttemptAt, leaseOwner, leaseExpiresAt, lastErrorCode, lastError,
                     createdAt, updatedAt, completedAt, evictedAt)
                SELECT 'v56-valid-receipt', databaseInstanceId, 'v56-valid-batch', deviceId,
                       lineage, cursorEpoch, trimScope, selectionMode, 'pending',
                       originalFrameIndexesJSON, 8_888, NULL, NULL, 0, NULL, NULL, NULL,
                       NULL, NULL, createdAt + 1, updatedAt + 1, NULL, NULL
                FROM historicalMaterializationJob WHERE receiptId = ?
                """, arguments: [Self.v55ReceiptId])
            try db.execute(sql: """
                UPDATE rawBatch SET framesBlob = ?
                WHERE batchId = ? AND deviceId = ? AND lineage = ? AND cursorEpoch = 0
                """, arguments: [
                    Data([0x04, 0x00, 0x00, 0x00, 0x78]),
                    Self.v55BatchId, Self.v55DeviceId, Self.v55Lineage,
                ])
            try db.execute(sql: """
                UPDATE historicalMaterializationJob
                SET protectedByteCount = 9_999, mappedRawMinTs = ?, mappedRawMaxTs = ?
                WHERE receiptId = ?
                """, arguments: [1_781_600_950, 1_781_600_950, Self.v55ReceiptId])
        }

        XCTAssertNoThrow(try migrator.migrate(dbQueue))

        try await dbQueue.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT state, protectedByteCount, mappedRawMinTs, mappedRawMaxTs
                FROM historicalMaterializationJob WHERE receiptId = ?
                """, arguments: [Self.v55ReceiptId]))
            XCTAssertEqual(row["state"] as String, "quarantined")
            XCTAssertEqual(row["protectedByteCount"] as Int, 9_999)
            XCTAssertNil(row["mappedRawMinTs"] as Int?)
            XCTAssertNil(row["mappedRawMaxTs"] as Int?)
            let valid = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT protectedByteCount, mappedRawMinTs, mappedRawMaxTs
                FROM historicalMaterializationJob WHERE receiptId = 'v56-valid-receipt'
                """))
            XCTAssertEqual(valid["protectedByteCount"] as Int, frame.count)
            XCTAssertEqual(valid["mappedRawMinTs"] as Int?, 1_781_600_950)
            XCTAssertEqual(valid["mappedRawMaxTs"] as Int?, 1_781_600_950)
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: [PR37V56Migrations.identifier]
                ),
                1
            )
        }
    }

    func testV55ReconstructsCompressedArchiveByteForByteBeforeDroppingExactFrame() async throws {
        let dbQueue = try DatabaseQueue()
        let frame = v55V20(unix: 1_781_600_700)
        try await seedCompletedV54(
            in: dbQueue,
            exactFrame: frame,
            archiveFrame: frame,
            retainArchive: false
        )

        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT frameCount, byteSize, framesBlob FROM rawBatch
                WHERE batchId = ? AND deviceId = ? AND lineage = ? AND cursorEpoch = 0
                """, arguments: [Self.v55BatchId, Self.v55DeviceId, Self.v55Lineage]))
            let packed = try WhoopStore.zlibDecompressWithLengthStrict(
                row["framesBlob"],
                expectedUncompressedLength: try WhoopStore.expectedPackedFrameLength(
                    frameCount: row["frameCount"], byteSize: row["byteSize"]
                )
            )
            XCTAssertEqual(
                try WhoopStore.unpackFramesStrict(
                    packed,
                    expectedFrameCount: row["frameCount"],
                    expectedFrameBytes: row["byteSize"]
                ),
                [frame]
            )
            let columns = Set(try db.columns(in: "historicalMappedRawFrame").map(\.name))
            XCTAssertFalse(columns.contains("exactFrame"))
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT exactByteCount FROM historicalMappedRawFrame WHERE receiptId = ?", arguments: [Self.v55ReceiptId]),
                frame.count
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?", arguments: [PR37V55Migrations.identifier]),
                1
            )
        }
    }

    func testV55ReconstructsPrunedLegacyFullCaptureAsSelectiveMappedArchive() async throws {
        let dbQueue = try DatabaseQueue()
        let frame = v55V20(unix: 1_781_600_750)
        try await seedCompletedV54(
            in: dbQueue,
            exactFrame: frame,
            archiveFrame: frame,
            retainArchive: false
        )
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE historicalMaterializationJob
                SET originalFrameIndexesJSON = ?
                WHERE receiptId = ?
                """, arguments: [try JSONEncoder().encode([0, 1]), Self.v55ReceiptId])
            try db.execute(sql: """
                UPDATE historicalMappedRawFrame
                SET originalFrameIndex = 1
                WHERE receiptId = ?
                """, arguments: [Self.v55ReceiptId])
        }

        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT selectionMode FROM historicalMaterializationJob WHERE receiptId = ?", arguments: [Self.v55ReceiptId]),
                "selectiveMapped"
            )
            XCTAssertEqual(
                try JSONDecoder().decode([Int].self, from: XCTUnwrap(Data.fetchOne(
                    db,
                    sql: "SELECT originalFrameIndexesJSON FROM historicalMaterializationJob WHERE receiptId = ?",
                    arguments: [Self.v55ReceiptId]
                ))),
                [1]
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT originalFrameIndex FROM historicalMappedRawFrame WHERE receiptId = ?", arguments: [Self.v55ReceiptId]),
                1
            )
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT frameCount, byteSize, framesBlob FROM rawBatch
                WHERE batchId = ? AND deviceId = ? AND lineage = ? AND cursorEpoch = 0
                """, arguments: [Self.v55BatchId, Self.v55DeviceId, Self.v55Lineage]))
            let packed = try WhoopStore.zlibDecompressWithLengthStrict(
                row["framesBlob"],
                expectedUncompressedLength: try WhoopStore.expectedPackedFrameLength(
                    frameCount: row["frameCount"], byteSize: row["byteSize"]
                )
            )
            XCTAssertEqual(
                try WhoopStore.unpackFramesStrict(
                    packed,
                    expectedFrameCount: row["frameCount"],
                    expectedFrameBytes: row["byteSize"]
                ),
                [frame]
            )
        }
    }

    func testV55ByteMismatchRollsBackWholeMigrationAndKeepsV54ExactFrame() async throws {
        let dbQueue = try DatabaseQueue()
        let archiveFrame = v55V20(unix: 1_781_600_800)
        var mismatchedExactFrame = archiveFrame
        mismatchedExactFrame[Whoop5RawOptical.blockStart + Whoop5RawOptical.headerLength] ^= 0x01
        try await seedCompletedV54(
            in: dbQueue,
            exactFrame: mismatchedExactFrame,
            archiveFrame: archiveFrame,
            retainArchive: true
        )

        XCTAssertThrowsError(try WhoopStore.makeMigrator().migrate(dbQueue)) { error in
            XCTAssertEqual(error as? PR37V55MigrationError, .byteMismatch(Self.v55ReceiptId))
        }

        let mismatchedExactData = Data(mismatchedExactFrame)

        try await dbQueue.read { db in
            XCTAssertTrue(try db.columns(in: "historicalMappedRawFrame").map(\.name).contains("exactFrame"))
            XCTAssertEqual(
                try Data.fetchOne(db, sql: "SELECT exactFrame FROM historicalMappedRawFrame WHERE receiptId = ?", arguments: [Self.v55ReceiptId]),
                mismatchedExactData
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT state FROM historicalMaterializationJob WHERE receiptId = ?", arguments: [Self.v55ReceiptId]),
                "completed"
            )
            XCTAssertFalse(try db.tableExists("historicalMaterializationJob_v55"))
            XCTAssertFalse(try db.tableExists("historicalMappedRawFrame_v55"))
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?", arguments: [PR37V55Migrations.identifier]),
                0
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
        }
    }

    func testV55PartialRunningConversionStillVerifiesExactFrameBeforeDeletion() async throws {
        let dbQueue = try DatabaseQueue()
        let archiveFrame = v55V20(unix: 1_781_600_900)
        var mismatchedExactFrame = archiveFrame
        mismatchedExactFrame[Whoop5RawOptical.blockStart + Whoop5RawOptical.headerLength] ^= 0x01
        try await seedCompletedV54(
            in: dbQueue,
            exactFrame: mismatchedExactFrame,
            archiveFrame: archiveFrame,
            retainArchive: true,
            state: "running"
        )

        XCTAssertThrowsError(try WhoopStore.makeMigrator().migrate(dbQueue)) { error in
            XCTAssertEqual(error as? PR37V55MigrationError, .byteMismatch(Self.v55ReceiptId))
        }

        try await dbQueue.read { db in
            XCTAssertTrue(try db.columns(in: "historicalMappedRawFrame").map(\.name).contains("exactFrame"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT state FROM historicalMaterializationJob WHERE receiptId = ?", arguments: [Self.v55ReceiptId]),
                "running"
            )
            XCTAssertFalse(try db.tableExists("historicalMaterializationJob_v55"))
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?", arguments: [PR37V55Migrations.identifier]),
                0
            )
        }
    }

    func testFileInitRunsMigrations() async throws {
        let path = NSTemporaryDirectory() + "whoopstore-\(UUID().uuidString).sqlite"
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        let store = try await WhoopStore(path: path)
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("hrSample"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testV36HistoricalReceiptSchemaRequiresDurableIdentityAndRawEvidence() async throws {
        let store = try await WhoopStore.inMemory()
        let receiptColumns = Set(try await store.columnNamesForTest(table: "historicalDataCommitJournal"))
        let cursorColumns = Set(try await store.columnNamesForTest(table: "historicalCursor"))
        let pairedDeviceColumns = Set(try await store.columnNamesForTest(table: "pairedDevice"))

        XCTAssertTrue(receiptColumns.isSuperset(of: [
            "fingerprint", "lineage", "cursorEpoch", "trimScope", "rawStatus", "rawRangeJSON",
        ]))
        XCTAssertTrue(cursorColumns.isSuperset(of: [
            "deviceId", "lineage", "cursorEpoch", "trimScope", "watermarkGeneration",
        ]))
        XCTAssertTrue(pairedDeviceColumns.isSuperset(of: ["historyLineage", "historyCursorEpoch"]))
    }

    func testV36MarksLegacyReceiptsBeforeNewFingerprintBinding() async throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v35-historical-data-commit-journal")
        let countsJSON = try JSONEncoder().encode(HistoricalStreamInsertCounts(hr: 1))

        try await dbQueue.write { db in
            let databaseInstanceId = try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT id FROM todayHealthSnapshotDatabase LIMIT 1")
            )
            try db.execute(sql: """
                INSERT INTO historicalDataCommitJournal
                    (receiptId, databaseInstanceId, deviceId, trim, chunkEndUnix, committedAt,
                     rawBatchId, insertedRowsJSON)
                VALUES (?, ?, ?, ?, ?, ?, NULL, ?)
                """, arguments: [
                    "legacy-receipt", databaseInstanceId, "my-whoop", 42, 100, 101, countsJSON,
                ])
        }

        try migrator.migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT fingerprint FROM historicalDataCommitJournal WHERE receiptId = 'legacy-receipt'"
                ),
                "legacy:legacy-receipt"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT rawStatus FROM historicalDataCommitJournal WHERE receiptId = 'legacy-receipt'"
                ),
                "disabled"
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM historicalCursor WHERE deviceId = 'my-whoop'"
                ),
                1
            )
        }
    }

    func testV37ScopesRawBatchIdentityAndSchemaVersion() async throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v36-historical-data-receipt-hardening")
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO rawBatch
                    (batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                     startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
                VALUES ('legacy-batch', 'legacy-device', 1, 2, 3, 4, 5, 0, 0, ?, NULL)
                """, arguments: [Data([0, 0, 0, 0])])
        }
        try migrator.migrate(dbQueue)

        try await dbQueue.read { db in
            let columns = Set(try db.columns(in: "rawBatch").map(\.name))
            XCTAssertTrue(columns.isSuperset(of: ["lineage", "cursorEpoch"]))
            XCTAssertEqual(
                try db.primaryKey("rawBatch").columns,
                ["batchId", "deviceId", "lineage", "cursorEpoch"]
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db, sql: "SELECT lineage FROM rawBatch WHERE batchId = 'legacy-batch'"
                ),
                "device:legacy-device"
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT cursorEpoch FROM rawBatch WHERE batchId = 'legacy-batch'"
                ),
                0
            )
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 56)
    }

    func testV37MigratesLegacyRawBatchIntoItsReceiptScope() async throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v35-historical-data-commit-journal")
        let countsJSON = try JSONEncoder().encode(HistoricalStreamInsertCounts(hr: 1))

        try await dbQueue.write { db in
            let databaseInstanceId = try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT id FROM todayHealthSnapshotDatabase LIMIT 1")
            )
            try db.execute(sql: """
                INSERT INTO rawBatch
                    (batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                     startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
                VALUES ('legacy-batch', 'my-whoop', 1, 2, 3, 4, 5, 0, 0, ?, NULL)
                """, arguments: [Data([0, 0, 0, 0])])
            try db.execute(sql: """
                INSERT INTO historicalDataCommitJournal
                    (receiptId, databaseInstanceId, deviceId, trim, chunkEndUnix, committedAt,
                     rawBatchId, insertedRowsJSON)
                VALUES ('legacy-receipt', ?, 'my-whoop', 42, 100, 101, 'legacy-batch', ?)
                """, arguments: [databaseInstanceId, countsJSON])
        }

        try migrator.migrate(dbQueue)

        try await dbQueue.read { db in
            let receiptLineage = try XCTUnwrap(String.fetchOne(
                db,
                sql: "SELECT lineage FROM historicalDataCommitJournal WHERE receiptId = 'legacy-receipt'"
            ))
            let receiptEpoch = try XCTUnwrap(Int.fetchOne(
                db,
                sql: "SELECT cursorEpoch FROM historicalDataCommitJournal WHERE receiptId = 'legacy-receipt'"
            ))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT lineage FROM rawBatch WHERE batchId = 'legacy-batch'"),
                receiptLineage
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT cursorEpoch FROM rawBatch WHERE batchId = 'legacy-batch'"),
                receiptEpoch
            )
        }
    }

    func testV36MigratesCursorTrimWithItsWatermarkGeneration() async throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v35-historical-data-commit-journal")
        let countsJSON = try JSONEncoder().encode(HistoricalStreamInsertCounts(hr: 1))

        try await dbQueue.write { db in
            let databaseInstanceId = try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT id FROM todayHealthSnapshotDatabase LIMIT 1")
            )
            for (receiptId, trim) in [("legacy-first", 90), ("legacy-second", 20)] {
                try db.execute(sql: """
                    INSERT INTO historicalDataCommitJournal
                        (receiptId, databaseInstanceId, deviceId, trim, chunkEndUnix, committedAt,
                         rawBatchId, insertedRowsJSON)
                    VALUES (?, ?, 'my-whoop', ?, 100, 101, NULL, ?)
                    """, arguments: [receiptId, databaseInstanceId, trim, countsJSON])
            }
        }

        try migrator.migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT trim FROM historicalCursor WHERE deviceId = 'my-whoop'"),
                20
            )
            XCTAssertEqual(
                try Int64.fetchOne(
                    db,
                    sql: "SELECT watermarkGeneration FROM historicalCursor WHERE deviceId = 'my-whoop'"
                ),
                2
            )
        }
    }

    func testV39RepairsPreviouslyRecordedRawAndCursorScopes() async throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v35-historical-data-commit-journal")
        let countsJSON = try JSONEncoder().encode(HistoricalStreamInsertCounts(hr: 1))

        try await dbQueue.write { db in
            let databaseInstanceId = try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT id FROM todayHealthSnapshotDatabase LIMIT 1")
            )
            try db.execute(sql: """
                INSERT INTO rawBatch
                    (batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                     startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
                VALUES ('legacy-batch', 'my-whoop', 1, 2, 3, 4, 5, 0, 0, ?, NULL)
                """, arguments: [Data([0, 0, 0, 0])])
            for (receiptId, trim, rawBatchId) in [
                ("legacy-first", 90, Optional("legacy-batch")),
                ("legacy-second", 20, Optional<String>.none),
            ] {
                try db.execute(sql: """
                    INSERT INTO historicalDataCommitJournal
                        (receiptId, databaseInstanceId, deviceId, trim, chunkEndUnix, committedAt,
                         rawBatchId, insertedRowsJSON)
                    VALUES (?, ?, 'my-whoop', ?, 100, 101, ?, ?)
                    """, arguments: [receiptId, databaseInstanceId, trim, rawBatchId, countsJSON])
            }
        }
        try migrator.migrate(dbQueue, upTo: "v38-historical-analysis-checkpoint")

        try await dbQueue.write { db in
            // Model the old v36/v37 result: an independently maxed cursor and raw evidence left in the
            // fallback device scope despite the registered receipt carrying its durable registry scope.
            try db.execute(sql: """
                UPDATE rawBatch
                SET lineage = 'device:my-whoop', cursorEpoch = 0
                WHERE batchId = 'legacy-batch' AND deviceId = 'my-whoop'
                """)
            try db.execute(sql: """
                UPDATE historicalCursor
                SET trim = 90, watermarkGeneration = 2
                WHERE deviceId = 'my-whoop'
                """)
        }

        try migrator.migrate(dbQueue)

        try await dbQueue.read { db in
            let receiptLineage = try XCTUnwrap(String.fetchOne(
                db,
                sql: "SELECT lineage FROM historicalDataCommitJournal WHERE receiptId = 'legacy-first'"
            ))
            let receiptEpoch = try XCTUnwrap(Int.fetchOne(
                db,
                sql: "SELECT cursorEpoch FROM historicalDataCommitJournal WHERE receiptId = 'legacy-first'"
            ))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT lineage FROM rawBatch WHERE batchId = 'legacy-batch'"),
                receiptLineage
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT cursorEpoch FROM rawBatch WHERE batchId = 'legacy-batch'"),
                receiptEpoch
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT trim FROM historicalCursor WHERE deviceId = 'my-whoop'"),
                20
            )
            XCTAssertEqual(
                try Int64.fetchOne(
                    db,
                    sql: "SELECT watermarkGeneration FROM historicalCursor WHERE deviceId = 'my-whoop'"
                ),
                2
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v39-historical-receipt-scope-repair'"
                ),
                1
            )
        }
    }

    func testHrSamplePrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("hrSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    func testRrIntervalPrimaryKeyIncludesSeq() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(cols, ["deviceId", "ts", "rrMs", "seq"])
    }

    func testV26KeepsEqualSameSecondBeatsAndReplayIsIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let batch = Streams(rr: [
            RRInterval(ts: 100, rrMs: 812),
            RRInterval(ts: 100, rrMs: 812),
            RRInterval(ts: 101, rrMs: 805),
        ])

        let first = try await store.insert(batch, deviceId: "dev1")
        let second = try await store.insert(batch, deviceId: "dev1")
        XCTAssertEqual(first.rr, 3)
        XCTAssertEqual(second.rr, 0)

        let rows = try await store.rrIntervals(
            deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        XCTAssertEqual(rows.filter { $0.ts == 100 && $0.rrMs == 812 }.count, 2)
    }

    /// v5 adds a `synced` column to all 8 decoded tables.
    func testV5AddsSyncedColumnToDecodedTables() async throws {
        let store = try await WhoopStore.inMemory()
        for table in ["hrSample", "rrInterval", "event", "battery",
                      "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
            let cols = try await store.columnNamesForTest(table: table)
            XCTAssertTrue(cols.contains("synced"), "\(table) missing synced column")
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 56)
    }

    func testV34AddsDurableTodayHealthSnapshotGeneration() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("todayHealthSnapshotGeneration"))
        let snapshotColumns = try await store.columnNamesForTest(table: "todayHealthSnapshot")
        XCTAssertTrue(snapshotColumns.contains("generation"))
        let generationColumns = try await store.columnNamesForTest(table: "todayHealthSnapshotGeneration")
        XCTAssertTrue(generationColumns.contains("value"))
    }

    func testV35CreatesHistoricalDataCommitJournal() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("historicalDataCommitJournal"))
        let columns = try await store.columnNamesForTest(table: "historicalDataCommitJournal")
        for column in [
            "generation", "receiptId", "databaseInstanceId", "deviceId", "trim", "chunkEndUnix",
            "committedAt", "rawBatchId", "insertedRowsJSON",
        ] {
            XCTAssertTrue(columns.contains(column), "historicalDataCommitJournal missing \(column)")
        }
    }

    func testV53PreservesExistingReceiptAndAllowsContentVersionAtSameTrim() async throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: PR29V52Migrations.identifier)

        try await dbQueue.write { db in
            let databaseInstanceId = try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT id FROM todayHealthSnapshotDatabase LIMIT 1")
            )
            let lineage = try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT historyLineage FROM pairedDevice WHERE id = 'my-whoop'")
            )
            try db.execute(sql: """
                INSERT INTO historicalDataCommitJournal
                    (generation, receiptId, databaseInstanceId, deviceId, lineage, cursorEpoch,
                     trimScope, trim, chunkEndUnix, committedAt, fingerprint, minDecodedTs,
                     maxDecodedTs, touchedDaysJSON, decodedRowsJSON, insertedRowsJSON, rawBatchId,
                     rawStatus, burstJSON, rawRangeJSON, timestampHealJSON, isFinal,
                     fingerprintVersion, timestampBucketsJSON, recordedTimeZoneIdentifier,
                     explicitAffectedDaysJSON)
                VALUES (113, 'receipt-v2-113', ?, 'my-whoop', ?, 0, 'historical', 57320,
                        1700000000, 1700000001, ?, NULL, NULL, ?, ?, ?, NULL, 'disabled', NULL,
                        ?, ?, 0, 2, ?, 'UTC', ?)
                """, arguments: [
                    databaseInstanceId,
                    lineage,
                    String(repeating: "a", count: 64),
                    Data("[]".utf8),
                    Data("{}".utf8),
                    Data("{}".utf8),
                    Data("{\"source\":\"receivedFrames\",\"minReceivedTs\":null,\"maxReceivedTs\":null,\"frameCount\":0,\"byteCount\":0,\"hasHistoryEnd\":true}".utf8),
                    Data("{\"droppedRecordCount\":0,\"rawRowsDeleted\":0,\"computedRowsDeleted\":0,\"didChange\":false}".utf8),
                    Data("[]".utf8),
                    Data("[]".utf8),
                ])
            try db.execute(sql: """
                INSERT INTO historicalCursor
                    (deviceId, lineage, cursorEpoch, trimScope, trim, watermarkGeneration)
                VALUES ('my-whoop', ?, 0, 'historical', 57320, 113)
                ON CONFLICT (deviceId, lineage, cursorEpoch, trimScope) DO UPDATE SET
                    trim = excluded.trim, watermarkGeneration = excluded.watermarkGeneration
                """, arguments: [lineage])
        }

        try migrator.migrate(dbQueue)

        try await dbQueue.write { db in
            let old = try Row.fetchOne(
                db,
                sql: "SELECT generation, receiptId, fingerprintVersion, trim FROM historicalDataCommitJournal WHERE generation = 113"
            )
            XCTAssertEqual(old?["receiptId"] as String?, "receipt-v2-113")
            XCTAssertEqual(old?["fingerprintVersion"] as Int?, 2)
            XCTAssertEqual(old?["trim"] as Int?, 57320)
            try db.execute(sql: """
                INSERT INTO historicalDataCommitJournal
                    (receiptId, databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope, trim,
                     chunkEndUnix, committedAt, fingerprint, touchedDaysJSON, decodedRowsJSON,
                     insertedRowsJSON, rawStatus, rawRangeJSON, timestampHealJSON, isFinal,
                     fingerprintVersion, timestampBucketsJSON, recordedTimeZoneIdentifier,
                     explicitAffectedDaysJSON)
                SELECT 'receipt-v3-new', databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope,
                       trim, chunkEndUnix, committedAt + 1, ?, touchedDaysJSON, decodedRowsJSON,
                       insertedRowsJSON, rawStatus, rawRangeJSON, timestampHealJSON, isFinal,
                       3, timestampBucketsJSON, recordedTimeZoneIdentifier, explicitAffectedDaysJSON
                FROM historicalDataCommitJournal WHERE generation = 113
                """, arguments: [String(repeating: "b", count: 64)])
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historicalDataCommitJournal WHERE trim = 57320"),
                2
            )
            XCTAssertGreaterThan(
                try XCTUnwrap(Int.fetchOne(db, sql: "SELECT generation FROM historicalDataCommitJournal WHERE receiptId = 'receipt-v3-new'")),
                113
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testV35RecoversJournalCreatedBeforeItsMigrationRecord() async throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v34-today-health-snapshot-generation")

        try await dbQueue.write { db in
            // Model the exact pre-release state: the v35 table exists, while GRDB has never recorded v35.
            try db.execute(sql: """
                CREATE TABLE historicalDataCommitJournal (
                    generation INTEGER PRIMARY KEY AUTOINCREMENT,
                    receiptId TEXT NOT NULL UNIQUE,
                    databaseInstanceId TEXT NOT NULL,
                    deviceId TEXT NOT NULL,
                    trim INTEGER NOT NULL,
                    chunkEndUnix INTEGER NOT NULL,
                    committedAt INTEGER NOT NULL,
                    rawBatchId TEXT,
                    insertedRowsJSON BLOB NOT NULL,
                    UNIQUE (databaseInstanceId, deviceId, trim)
                )
                """)
        }

        try migrator.migrate(dbQueue)

        try await dbQueue.read { db in
            let columns = Set(try db.columns(in: "historicalDataCommitJournal").map(\.name))
            XCTAssertTrue(columns.isSuperset(of: ["lineage", "cursorEpoch", "trimScope", "fingerprint"]))
            for identifier in [
                "v35-historical-data-commit-journal",
                "v36-historical-data-receipt-hardening",
                "v37-scoped-raw-batch-identity",
                "v38-historical-analysis-checkpoint",
                "v39-historical-receipt-scope-repair",
            ] {
                XCTAssertEqual(
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                        arguments: [identifier]
                    ),
                    1,
                    "missing migration record for \(identifier)"
                )
            }
        }
    }

    func testRecoveryChargeContextMigrationUpgradesExistingOverrideTable() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.write { db in
            // Model a database that already recorded the shipped recovery migrations,
            // before this follow-on added its five score-context columns. Running the
            // current `daily-v1` migration would create the modern fresh shape, so the
            // historical table is intentionally assembled here.
            try db.execute(sql: """
                CREATE TABLE sleepRecoveryDailyOverride (
                    deviceId TEXT NOT NULL,
                    day TEXT NOT NULL,
                    sessionStartTs INTEGER NOT NULL,
                    totalSleepMin DOUBLE,
                    efficiency DOUBLE,
                    deepMin DOUBLE,
                    remMin DOUBLE,
                    lightMin DOUBLE,
                    disturbances INTEGER,
                    restingHr INTEGER,
                    avgHrv DOUBLE,
                    recovery DOUBLE,
                    restScore DOUBLE,
                    updatedAt INTEGER NOT NULL,
                    PRIMARY KEY (deviceId, day)
                )
                """)
            for identifier in [
                "sleep-window-recovery-v1",
                "sleep-window-recovery-daily-v1",
                "sleep-window-recovery-invalidation-v1",
            ] {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [identifier])
            }
            let oldColumns = try Set(db.columns(in: "sleepRecoveryDailyOverride").map(\.name))
            XCTAssertFalse(oldColumns.contains("chargeWeightedSumWithoutSleep"))
            XCTAssertFalse(oldColumns.contains("chargeWeightWithoutSleep"))
            XCTAssertFalse(oldColumns.contains("chargeBaselineUsable"))
            XCTAssertFalse(oldColumns.contains("sleepNeedHours"))
            XCTAssertFalse(oldColumns.contains("sleepConsistency"))
            try db.execute(sql: """
                INSERT INTO sleepRecoveryDailyOverride
                    (deviceId, day, sessionStartTs, totalSleepMin, updatedAt)
                VALUES ('my-whoop-noop', '2026-07-26', 1000, 420, 10000)
                """)
        }

        try WhoopStore.makeSleepRecoveryMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            let columns = try Set(db.columns(in: "sleepRecoveryDailyOverride").map(\.name))
            XCTAssertTrue([
                "chargeWeightedSumWithoutSleep", "chargeWeightWithoutSleep",
                "chargeBaselineUsable", "sleepNeedHours", "sleepConsistency",
            ].allSatisfy(columns.contains))
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT chargeBaselineUsable FROM sleepRecoveryDailyOverride"),
                0)
            XCTAssertEqual(
                try Double.fetchOne(
                    db,
                    sql: "SELECT sleepNeedHours FROM sleepRecoveryDailyOverride"),
                8.0)
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: ["sleep-window-recovery-charge-context-v1"]),
                1)
        }
    }

    /// v13 adds the `userEdited` flag to sleepSession (user-corrected wake times survive re-sync).
    func testV13AddsUserEditedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("userEdited"), "sleepSession missing v13 userEdited column")
    }

    /// v14 adds `startTsAdjusted` (the user-corrected sleep onset; detected startTs stays the key).
    func testV14AddsStartTsAdjustedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("startTsAdjusted"), "sleepSession missing v14 startTsAdjusted column")
    }

    /// v16 adds `peripheralId` to pairedDevice (stable per-strap BLE identity for multi-WHOOP support).
    func testV16AddsPeripheralIdColumnToPairedDevice() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "pairedDevice")
        XCTAssertTrue(cols.contains("peripheralId"), "pairedDevice missing v16 peripheralId column")
    }

    func testPrivateCoachingMigrationsRemainPresent() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for table in [
            "coachingBehaviorSet", "coachingBehaviorMembership",
            "coachingStack", "coachingStackItem", "coachingStackUse",
        ] {
            XCTAssertTrue(tables.contains(table), "private migration lost table \(table)")
        }
    }

    func testV25AddsRawSpo2Columns() async throws {
        let store = try await WhoopStore.inMemory()
        let columns = try await store.columnNamesForTest(table: "dailyMetric")
        XCTAssertTrue(columns.contains("spo2Red"))
        XCTAssertTrue(columns.contains("spo2Ir"))
    }

    func testV27HealsEfficiencyPercentToFraction() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v26-rr-seq")
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency)
                VALUES ('my-whoop', 100, 200, 90), ('my-whoop', 300, 400, 0.90)
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, efficiency)
                VALUES ('my-whoop', '2026-01-01', 90), ('my-whoop', '2026-01-02', 0.90)
                """)
        }

        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 100"), 0.90)
            XCTAssertEqual(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 300"), 0.90)
            XCTAssertEqual(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-01-01'"), 0.90)
            XCTAssertEqual(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-01-02'"), 0.90)
        }
    }

    func testV28CreatesPpgWaveformTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        let primaryKey = try await store.primaryKeyColumns("ppgWaveformSample")
        let columns = try await store.columnNamesForTest(table: "ppgWaveformSample")

        XCTAssertTrue(tables.contains("ppgWaveformSample"))
        XCTAssertEqual(primaryKey, ["deviceId", "ts"])
        XCTAssertTrue(columns.contains("samples"))
    }

    /// A pre-release Strain V2 build added the provenance columns before the final migration
    /// identifier landed. Reopening that real-world database must finish v29 instead of leaving
    /// every app surface blank because the store cannot open.
    func testV29RecoversPartiallyAppliedStrainProvenanceSchema() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v28-ppg-waveform")
        try await dbQueue.write { db in
            try db.alter(table: "dailyMetric") { table in
                table.add(column: "strainVersion", .integer)
            }
            try db.alter(table: "workout") { table in
                table.add(column: "strainVersion", .integer)
            }
        }

        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertTrue(try db.columns(in: "dailyMetric").map(\.name).contains("strainVersion"))
            XCTAssertTrue(try db.columns(in: "workout").map(\.name).contains("strainVersion"))
            XCTAssertTrue(try db.tableExists("strainV2Shadow"))
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: ["v29-strain-v2-provenance"]
                ),
                1
            )
        }
    }
}
