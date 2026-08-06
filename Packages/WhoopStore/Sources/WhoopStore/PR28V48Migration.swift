import Foundation
import GRDB
import NoopPhase34Core

/// Register after v47. Also replace v47's throwing backfill loop with
/// `backfillHealthKitWatermarksFailClosed` below so a malformed legacy row
/// cannot prevent v47 from completing before v48 is reached.
public enum PR28V48Migrations {
    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v48-pr28-final-hardening") { db in
            try createSourceTransitionJournal(db)
            try createHistoricalScopeLifecycle(db)
            try createHistoricalMaintenanceWork(db)
            try addVerifiedWidgetCorePayload(db)
            try createPerformanceIndexes(db)
            try backfillHealthKitWatermarksFailClosed(db)
            try validate(db)
        }
    }

    private static func createSourceTransitionJournal(_ db: Database) throws {
        try db.create(table: "sourceTransitionJournal", options: [.ifNotExists]) { table in
            table.column("transitionId", .text).primaryKey()
            table.column("mutationKind", .text).notNull()
            table.column("sourceDeviceId", .text).notNull()
            table.column("targetDeviceId", .text)
            table.column("historicalEpoch", .integer).notNull()
            table.column("externalEpoch", .integer).notNull()
            table.column("sinkEpoch", .integer).notNull()
            table.column("stage", .text).notNull()
            table.column("commitJSON", .blob)
            table.column("lastErrorCode", .text)
            table.column("createdAt", .integer).notNull()
            table.column("updatedAt", .integer).notNull()
            table.check(sql: "length(transitionId) > 0")
            table.check(sql: "length(sourceDeviceId) > 0")
            table.check(sql: "historicalEpoch > 0 AND externalEpoch > 0 AND sinkEpoch > 0")
            table.check(sql: "stage IN ('prepared','storeCommitted','sinkActivated','workersResumed','complete','aborted')")
        }
        try db.create(
            index: "idx_sourceTransitionJournal_incomplete",
            on: "sourceTransitionJournal",
            columns: ["stage", "updatedAt"],
            options: [.ifNotExists]
        )
    }

    private static func createHistoricalScopeLifecycle(_ db: Database) throws {
        try db.create(table: "historicalReceiptScopeLifecycle", options: [.ifNotExists]) { table in
            table.column("databaseInstanceId", .text).notNull()
            table.column("deviceId", .text).notNull()
            table.column("lineage", .text).notNull()
            table.column("cursorEpoch", .integer).notNull()
            table.column("trimScope", .text).notNull()
            table.column("state", .text).notNull()
            table.column("closedThroughGeneration", .integer).notNull().defaults(to: 0)
            table.column("reason", .text).notNull()
            table.column("updatedAt", .integer).notNull()
            table.primaryKey([
                "databaseInstanceId", "deviceId", "lineage",
                "cursorEpoch", "trimScope",
            ])
            table.check(sql: "cursorEpoch >= 0")
            table.check(sql: "closedThroughGeneration >= 0")
            table.check(sql: "state IN ('open','draining','drained','discarded')")
        }
        try db.create(
            index: "idx_historicalReceiptScopeLifecycle_draining",
            on: "historicalReceiptScopeLifecycle",
            columns: ["databaseInstanceId", "state", "updatedAt"],
            options: [.ifNotExists]
        )
    }

    private static func createHistoricalMaintenanceWork(_ db: Database) throws {
        try db.create(table: "historicalMaintenanceWork", options: [.ifNotExists]) { table in
            table.column("workId", .text).primaryKey()
            table.column("databaseInstanceId", .text).notNull()
            table.column("sourceId", .text).notNull()
            table.column("deviceId", .text).notNull()
            table.column("lineage", .text).notNull()
            table.column("cursorEpoch", .integer).notNull()
            table.column("trimScope", .text).notNull()
            table.column("throughReceiptGeneration", .integer).notNull()
            table.column("recordedTimeZoneIdentifier", .text).notNull().defaults(to: "UTC")
            table.column("reasonsJSON", .blob).notNull()
            table.column("nextStartDay", .text)
            table.column("state", .text).notNull()
            table.column("attemptCount", .integer).notNull().defaults(to: 0)
            table.column("nextAttemptAt", .integer)
            table.column("leaseOwner", .text)
            table.column("leaseExpiresAt", .integer)
            table.column("lastErrorCode", .text)
            table.column("createdAt", .integer).notNull()
            table.column("updatedAt", .integer).notNull()
            table.check(sql: "throughReceiptGeneration > 0")
            table.check(sql: "attemptCount >= 0")
            table.check(sql: "state IN ('pending','running','retryable','complete','quarantined')")
        }
        try db.create(
            index: "idx_historicalMaintenanceWork_ready",
            on: "historicalMaintenanceWork",
            columns: ["state", "nextAttemptAt", "leaseExpiresAt", "updatedAt"],
            options: [.ifNotExists]
        )
    }


    private static func addVerifiedWidgetCorePayload(_ db: Database) throws {
        guard try db.tableExists("verifiedHealthProjection") else { return }
        let columns = Set(try db.columns(in: "verifiedHealthProjection").map(\.name))
        if !columns.contains("widgetCoreJSON") {
            try db.alter(table: "verifiedHealthProjection") { table in
                table.add(column: "widgetCoreJSON", .blob)
            }
        }
        if try db.tableExists("externalPublicationOutbox") {
            try db.execute(sql: """
                UPDATE externalPublicationOutbox
                SET state = 'superseded', leaseOwner = NULL, leaseExpiresAt = NULL,
                    lastErrorCode = 'v48_missing_immutable_widget_core', updatedAt = updatedAt
                WHERE destination = 'widget'
                  AND state IN ('pending','retryable','inFlight','blocked')
                  AND NOT EXISTS (
                    SELECT 1 FROM verifiedHealthProjection p
                    WHERE p.contextId = externalPublicationOutbox.contextId
                      AND p.snapshotGeneration = externalPublicationOutbox.snapshotGeneration
                      AND p.widgetCoreJSON IS NOT NULL
                  )
                """)
        }
    }

    private static func createPerformanceIndexes(_ db: Database) throws {
        try db.create(
            index: "idx_sleepSession_device_end",
            on: "sleepSession",
            columns: ["deviceId", "endTs"],
            options: [.ifNotExists]
        )
        try db.create(
            index: "idx_externalPublicationOutbox_expiry",
            on: "externalPublicationOutbox",
            columns: ["leaseExpiresAt", "state"],
            options: [.ifNotExists]
        )
        try db.create(
            index: "idx_externalPublicationOutbox_terminal",
            on: "externalPublicationOutbox",
            columns: ["state", "updatedAt"],
            options: [.ifNotExists]
        )
        try db.create(
            index: "idx_historicalAnalysisWork_terminal",
            on: "historicalAnalysisWork",
            columns: ["state", "updatedAt"],
            options: [.ifNotExists]
        )
    }

    /// Safe replacement for v47's current all-or-nothing legacy evidence loop.
    /// Invalid side-effect rows are quarantined; valid rows continue to rebuild
    /// the maximum delivered generation. Core health rows are untouched.
    static func backfillHealthKitWatermarksFailClosed(_ db: Database) throws {
        guard try db.tableExists("externalPublicationOutbox"),
              try db.tableExists("healthKitMutationWatermark") else { return }

        let rows = try Row.fetchAll(db, sql: """
            SELECT idempotencyKey, contextId, deviceId, analysisGeneration,
                   changedDaysJSON, updatedAt
            FROM externalPublicationOutbox
            WHERE destination = 'healthKit' AND state = 'succeeded'
            ORDER BY analysisGeneration ASC, updatedAt ASC
            """)

        struct Winner {
            let deviceId: String
            let generation: Int64
            let updatedAt: Int
        }
        var winners: [String: Winner] = [:]

        for row in rows {
            let key: String = row["idempotencyKey"]
            let contextId: String = row["contextId"]
            let deviceId: String = row["deviceId"]
            let generation: Int64 = row["analysisGeneration"]
            let updatedAt: Int = row["updatedAt"]
            let data: Data = row["changedDaysJSON"]

            let days = try? JSONDecoder().decode(Set<CivilDay>.self, from: data)
            guard !contextId.isEmpty, !deviceId.isEmpty, generation > 0,
                  let days, !days.isEmpty else {
                try quarantineLegacyOutbox(
                    key: key,
                    code: "v48_malformed_succeeded_healthkit_evidence",
                    updatedAt: updatedAt,
                    in: db
                )
                continue
            }

            for day in days {
                let mapKey = "\(contextId)|\(day.key)"
                if let current = winners[mapKey] {
                    if generation < current.generation { continue }
                    if generation == current.generation,
                       deviceId != current.deviceId {
                        try quarantineLegacyOutbox(
                            key: key,
                            code: "v48_conflicting_healthkit_device_identity",
                            updatedAt: updatedAt,
                            in: db
                        )
                        continue
                    }
                }
                winners[mapKey] = Winner(
                    deviceId: deviceId,
                    generation: generation,
                    updatedAt: updatedAt
                )
            }
        }

        for (mapKey, winner) in winners {
            guard let split = mapKey.lastIndex(of: "|") else { continue }
            let contextId = String(mapKey[..<split])
            let day = String(mapKey[mapKey.index(after: split)...])

            if let existing = try Row.fetchOne(db, sql: """
                SELECT deviceId, analysisGeneration, updatedAt
                FROM healthKitMutationWatermark
                WHERE contextId = ? AND day = ?
                """, arguments: [contextId, day]) {
                let existingDevice: String = existing["deviceId"]
                let existingGeneration: Int64 = existing["analysisGeneration"]
                if existingGeneration > winner.generation { continue }
                if existingGeneration == winner.generation,
                   existingDevice != winner.deviceId {
                    // Preserve the already-delivered fence and surface the conflict.
                    continue
                }
            }

            try db.execute(sql: """
                INSERT INTO healthKitMutationWatermark
                    (contextId, deviceId, day, analysisGeneration, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(contextId, day) DO UPDATE SET
                    deviceId = excluded.deviceId,
                    analysisGeneration = excluded.analysisGeneration,
                    updatedAt = MAX(
                        healthKitMutationWatermark.updatedAt,
                        excluded.updatedAt
                    )
                WHERE excluded.analysisGeneration >
                      healthKitMutationWatermark.analysisGeneration
                   OR (excluded.analysisGeneration =
                       healthKitMutationWatermark.analysisGeneration
                       AND excluded.deviceId =
                           healthKitMutationWatermark.deviceId)
                """, arguments: [
                    contextId, winner.deviceId, day,
                    winner.generation, winner.updatedAt,
                ])
        }
    }

    private static func quarantineLegacyOutbox(
        key: String,
        code: String,
        updatedAt: Int,
        in db: Database
    ) throws {
        try db.execute(sql: """
            UPDATE externalPublicationOutbox
            SET state = 'quarantined', leaseOwner = NULL, leaseExpiresAt = NULL,
                lastErrorCode = ?, updatedAt = ?
            WHERE idempotencyKey = ?
            """, arguments: [code, updatedAt, key])
    }

    private static func validate(_ db: Database) throws {
        let required = [
            "sourceTransitionJournal",
            "healthKitMutationWatermark",
            "healthKitSleepDayLedger",
            "healthKitSleepKeyLedger",
            "historicalReceiptScopeLifecycle",
            "historicalMaintenanceWork",
        ]
        for table in required where try !db.tableExists(table) {
            throw PR28V48MigrationError.invalidSchema
        }
        if try db.tableExists("verifiedHealthProjection") {
            let projectionColumns = Set(
                try db.columns(in: "verifiedHealthProjection").map(\.name)
            )
            guard projectionColumns.contains("widgetCoreJSON") else {
                throw PR28V48MigrationError.invalidSchema
            }
        }
        let indexes = [
            "idx_sleepSession_device_end",
            "idx_externalPublicationOutbox_expiry",
            "idx_externalPublicationOutbox_terminal",
            "idx_historicalAnalysisWork_terminal",
            "idx_sourceTransitionJournal_incomplete",
            "idx_historicalReceiptScopeLifecycle_draining",
            "idx_historicalMaintenanceWork_ready",
        ]
        for index in indexes {
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'index' AND name = ?
                """, arguments: [index]) ?? 0
            guard count == 1 else { throw PR28V48MigrationError.invalidSchema }
        }
        guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
            throw PR28V48MigrationError.invalidSchema
        }
    }
}

public enum PR28V48MigrationError: Error, Equatable, Sendable {
    case invalidSchema
}
