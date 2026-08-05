import XCTest
import GRDB
@testable import WhoopStore

final class PR28RootFixMigrationTests: XCTestCase {
    func testRootFixMigrationPersistsDurableStateColumns() async throws {
        let store = try await WhoopStore.inMemory()

        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 45)
        let workColumns = Set(try await store.columnNamesForTest(table: "historicalAnalysisWork"))
        let snapshotColumns = Set(try await store.columnNamesForTest(table: "verifiedSnapshotCommit"))
        let outboxColumns = Set(try await store.columnNamesForTest(table: "externalPublicationOutbox"))
        XCTAssertTrue(
            workColumns.isSuperset(of: ["resumePhase", "recordedTimeZoneIdentifier"])
        )
        XCTAssertTrue(
            snapshotColumns.isSuperset(of: ["recordedTimeZoneIdentifier", "healthKitPayloadJSON"])
        )
        XCTAssertTrue(
            outboxColumns.isSuperset(of: ["recordedTimeZoneIdentifier", "destinationPayloadJSON"])
        )
    }

    func testV43RowsMigrateBlockedStatesResumePhaseAndRecordedZone() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v43-phase34-schema-validation")

        let affectedDays = Data("[\"2026-01-02\"]".utf8)
        let workKind = Data("{\"kind\":\"exactDays\"}".utf8)
        let pendingDestinations = Data("[]".utf8)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO historicalAnalysisWork (
                    workId, databaseInstanceId, sourceId, deviceId, lineage, cursorEpoch, trimScope,
                    firstReceiptGeneration, lastReceiptGeneration, minimumTs, maximumTs, affectedDaysJSON,
                    recordedTimeZoneIdentifier, workKindKey, workKindJSON, priority, state, attemptCount,
                    nextAttemptAt, leaseOwner, leaseExpiresAt, analyzedThroughReceiptGeneration,
                    analysisGeneration, snapshotGeneration, pendingDestinationsJSON, lastErrorCode,
                    createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "work-legacy", "db-legacy", "source", "device", "lineage", 0, "trim", 1, 1,
                    100, 200, affectedDays, "America/New_York", "exactDays", workKind, 4,
                    "repositoryPublished", 0, nil, "lease-owner", 200, 1, 3, 2, pendingDestinations,
                    nil, 100, 100,
                ])

            try db.execute(sql: """
                INSERT INTO analysisMutationJournal (
                    generation, workId, databaseInstanceId, sourceId, deviceId, lineage, cursorEpoch,
                    trimScope, throughReceiptGeneration, analyzedDaysJSON, rawFrontierTs,
                    algorithmBundleVersion, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    3, "work-legacy", "db-legacy", "source", "device", "lineage", 0, "trim", 1,
                    affectedDays, 200, "test", 100,
                ])

            try db.execute(sql: """
                INSERT INTO verifiedHealthProjection
                    (contextId, deviceId, snapshotGeneration, projectionJSON, createdAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: ["ctx", "device", 2, Data("{}".utf8), 100])

            try db.execute(sql: """
                INSERT INTO verifiedSnapshotCommit (
                    contextId, deviceId, analysisGeneration, throughReceiptGeneration,
                    snapshotGeneration, changedDaysJSON, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: ["ctx", "device", 3, 1, 2, affectedDays, 100])

            try db.execute(sql: """
                INSERT INTO externalPublicationOutbox (
                    idempotencyKey, contextId, deviceId, snapshotGeneration, analysisGeneration,
                    changedDaysJSON, destination, state, attemptCount, nextAttemptAt, leaseOwner,
                    leaseExpiresAt, lastErrorCode, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "hk-old", "ctx", "device", 2, 3, affectedDays, "healthKit", "inFlight", 0,
                    nil, "lease-owner", 200, nil, 100, 100,
                ])
        }

        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let work = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT state, resumePhase, leaseOwner FROM historicalAnalysisWork WHERE workId = ?",
                arguments: ["work-legacy"]
            ))
            XCTAssertEqual(work["state"] as String?, "repositoryPublished")
            XCTAssertEqual(work["resumePhase"] as String?, "outboxCommit")
            XCTAssertEqual(work["leaseOwner"] as String?, "lease-owner")

            let snapshot = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT recordedTimeZoneIdentifier FROM verifiedSnapshotCommit WHERE contextId = ?",
                arguments: ["ctx"]
            ))
            XCTAssertEqual(snapshot["recordedTimeZoneIdentifier"] as String?, "America/New_York")

            let outbox = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT state, recordedTimeZoneIdentifier, destinationPayloadJSON, leaseOwner, lastErrorCode FROM externalPublicationOutbox WHERE idempotencyKey = ?",
                arguments: ["hk-old"]
            ))
            XCTAssertEqual(outbox["state"] as String?, "blocked")
            XCTAssertEqual(outbox["recordedTimeZoneIdentifier"] as String?, "America/New_York")
            XCTAssertNil(outbox["destinationPayloadJSON"] as Data?)
            XCTAssertNil(outbox["leaseOwner"] as String?)
            XCTAssertEqual(outbox["lastErrorCode"] as String?, "legacy_healthkit_payload_requires_repair")
        }
    }
}
