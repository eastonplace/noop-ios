// Copy into Packages/WhoopStore/Sources/WhoopStore and register from Database.swift after current v39.
// These migrations are additive. They do not rewrite the existing historical receipt tables.

import Foundation
import GRDB

public enum Phase34DatabaseMigrations {
    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v40-phase34-exact-receipt-evidence") { db in
            var columns = Set(try db.columns(in: "historicalDataCommitJournal").map(\.name))
            if !columns.contains("fingerprintVersion") {
                try db.alter(table: "historicalDataCommitJournal") { table in
                    table.add(column: "fingerprintVersion", .integer).notNull().defaults(to: 1)
                }
                columns.insert("fingerprintVersion")
            }
            if !columns.contains("timestampBucketsJSON") {
                try db.alter(table: "historicalDataCommitJournal") { table in
                    table.add(column: "timestampBucketsJSON", .blob)
                }
                columns.insert("timestampBucketsJSON")
            }
            if !columns.contains("recordedTimeZoneIdentifier") {
                try db.alter(table: "historicalDataCommitJournal") { table in
                    table.add(column: "recordedTimeZoneIdentifier", .text)
                }
                columns.insert("recordedTimeZoneIdentifier")
            }
            if !columns.contains("explicitAffectedDaysJSON") {
                try db.alter(table: "historicalDataCommitJournal") { table in
                    // Local Gregorian day keys supplied only by a producer that owns exact heal/edit evidence.
                    // Legacy `touchedDaysJSON` is UTC-derived and is not local health-day authority.
                    table.add(column: "explicitAffectedDaysJSON", .blob)
                }
            }
            try db.create(
                index: "idx_historicalDataCommitJournal_scope_generation_v40",
                on: "historicalDataCommitJournal",
                columns: [
                    "databaseInstanceId", "deviceId", "lineage", "cursorEpoch", "trimScope", "generation",
                ],
                options: [.ifNotExists]
            )
        }

        migrator.registerMigration("v41-phase34-analysis-work") { db in
            try db.create(table: "historicalReceiptConsumer", options: [.ifNotExists]) { table in
                table.column("consumerId", .text).notNull()
                table.column("databaseInstanceId", .text).notNull()
                table.column("deviceId", .text).notNull()
                table.column("lineage", .text).notNull()
                table.column("cursorEpoch", .integer).notNull()
                table.column("trimScope", .text).notNull()
                table.column("throughGeneration", .integer).notNull().defaults(to: 0)
                table.column("updatedAt", .integer).notNull()
                table.primaryKey([
                    "consumerId", "databaseInstanceId", "deviceId", "lineage", "cursorEpoch", "trimScope",
                ])
                table.check(sql: "cursorEpoch >= 0")
                table.check(sql: "throughGeneration >= 0")
            }

            try db.create(table: "historicalAnalysisWork", options: [.ifNotExists]) { table in
                table.column("workId", .text).primaryKey()
                table.column("databaseInstanceId", .text).notNull()
                table.column("sourceId", .text).notNull()
                table.column("deviceId", .text).notNull()
                table.column("lineage", .text).notNull()
                table.column("cursorEpoch", .integer).notNull()
                table.column("trimScope", .text).notNull()
                table.column("firstReceiptGeneration", .integer).notNull()
                table.column("lastReceiptGeneration", .integer).notNull()
                table.column("minimumTs", .integer)
                table.column("maximumTs", .integer)
                table.column("affectedDaysJSON", .blob).notNull()
                table.column("recordedTimeZoneIdentifier", .text).notNull()
                // Stable identity used in SQL. `workKindJSON` remains the Codable payload.
                table.column("workKindKey", .text).notNull()
                table.column("workKindJSON", .blob).notNull()
                table.column("priority", .integer).notNull().defaults(to: 0)
                table.column("state", .text).notNull()
                table.column("attemptCount", .integer).notNull().defaults(to: 0)
                table.column("nextAttemptAt", .integer)
                table.column("leaseOwner", .text)
                table.column("leaseExpiresAt", .integer)
                table.column("analyzedThroughReceiptGeneration", .integer)
                table.column("analysisGeneration", .integer)
                table.column("snapshotGeneration", .integer)
                table.column("pendingDestinationsJSON", .blob).notNull()
                table.column("lastErrorCode", .text)
                table.column("createdAt", .integer).notNull()
                table.column("updatedAt", .integer).notNull()
                table.check(sql: "cursorEpoch >= 0")
                table.check(sql: "firstReceiptGeneration > 0")
                table.check(sql: "lastReceiptGeneration >= firstReceiptGeneration")
                table.check(sql: "minimumTs IS NULL OR maximumTs IS NULL OR minimumTs <= maximumTs")
                table.check(sql: "attemptCount >= 0")
                table.check(sql: "length(workKindKey) > 0")
                table.check(sql: "state IN ('pending','analyzing','verifying','snapshotCommitted','repositoryPublished','complete','retryable','quarantined')")
            }
            try Self.requireColumns(
                [
                    "workId", "databaseInstanceId", "sourceId", "deviceId", "lineage", "cursorEpoch",
                    "trimScope", "firstReceiptGeneration", "lastReceiptGeneration", "minimumTs", "maximumTs",
                    "affectedDaysJSON", "recordedTimeZoneIdentifier", "workKindKey", "workKindJSON", "priority",
                    "state", "attemptCount", "nextAttemptAt", "leaseOwner", "leaseExpiresAt",
                    "analyzedThroughReceiptGeneration", "analysisGeneration", "snapshotGeneration",
                    "pendingDestinationsJSON", "lastErrorCode", "createdAt", "updatedAt",
                ],
                in: "historicalAnalysisWork",
                db: db
            )
            try db.create(
                index: "idx_historicalAnalysisWork_ready",
                on: "historicalAnalysisWork",
                columns: ["state", "nextAttemptAt", "priority", "createdAt"],
                options: [.ifNotExists]
            )
            try db.create(
                index: "idx_historicalAnalysisWork_scope_kind_generation",
                on: "historicalAnalysisWork",
                columns: [
                    "databaseInstanceId", "deviceId", "lineage", "cursorEpoch", "trimScope",
                    "recordedTimeZoneIdentifier", "workKindKey", "lastReceiptGeneration",
                ],
                options: [.ifNotExists]
            )

            // A separate monotonic domain created only after score writes commit. Do not reuse receipt,
            // Repository, or snapshot generations as an analysis generation.
            try db.create(table: "analysisMutationJournal", options: [.ifNotExists]) { table in
                table.column("generation", .integer).primaryKey(autoincrement: true)
                table.column("workId", .text).notNull()
                table.column("databaseInstanceId", .text).notNull()
                table.column("sourceId", .text).notNull()
                table.column("deviceId", .text).notNull()
                table.column("lineage", .text).notNull()
                table.column("cursorEpoch", .integer).notNull()
                table.column("trimScope", .text).notNull()
                table.column("throughReceiptGeneration", .integer).notNull()
                table.column("analyzedDaysJSON", .blob).notNull()
                table.column("rawFrontierTs", .integer)
                table.column("algorithmBundleVersion", .text).notNull()
                table.column("createdAt", .integer).notNull()
                table.uniqueKey(["workId", "throughReceiptGeneration"])
                table.check(sql: "cursorEpoch >= 0")
                table.check(sql: "throughReceiptGeneration > 0")
                table.check(sql: "rawFrontierTs IS NULL OR rawFrontierTs >= 0")
                table.check(sql: "length(algorithmBundleVersion) > 0")
            }
            try db.create(
                index: "idx_analysisMutationJournal_scope_generation",
                on: "analysisMutationJournal",
                columns: [
                    "databaseInstanceId", "deviceId", "lineage", "cursorEpoch", "trimScope", "generation",
                ],
                options: [.ifNotExists]
            )
        }

        migrator.registerMigration("v42-phase34-external-publication-outbox") { db in
            try db.create(table: "verifiedHealthProjection", options: [.ifNotExists]) { table in
                table.column("contextId", .text).notNull()
                table.column("deviceId", .text).notNull()
                table.column("snapshotGeneration", .integer).notNull()
                table.column("projectionJSON", .blob).notNull()
                table.column("createdAt", .integer).notNull()
                table.primaryKey(["contextId", "snapshotGeneration"])
                table.check(sql: "snapshotGeneration > 0")
            }
            try db.create(
                index: "idx_verifiedHealthProjection_device",
                on: "verifiedHealthProjection",
                columns: ["deviceId", "contextId", "snapshotGeneration"],
                options: [.ifNotExists]
            )

            try db.create(table: "verifiedSnapshotCommit", options: [.ifNotExists]) { table in
                table.column("contextId", .text).notNull()
                table.column("deviceId", .text).notNull()
                table.column("analysisGeneration", .integer).notNull()
                table.column("throughReceiptGeneration", .integer).notNull()
                table.column("snapshotGeneration", .integer).notNull()
                table.column("changedDaysJSON", .blob).notNull()
                table.column("createdAt", .integer).notNull()
                table.primaryKey(["contextId", "analysisGeneration"])
                table.foreignKey(
                    ["contextId", "snapshotGeneration"],
                    references: "verifiedHealthProjection",
                    columns: ["contextId", "snapshotGeneration"],
                    onDelete: .cascade
                )
                table.check(sql: "analysisGeneration > 0")
                table.check(sql: "throughReceiptGeneration > 0")
                table.check(sql: "snapshotGeneration > 0")
            }
            try db.create(
                index: "idx_verifiedSnapshotCommit_device",
                on: "verifiedSnapshotCommit",
                columns: ["deviceId", "contextId", "analysisGeneration"],
                options: [.ifNotExists]
            )

            try db.create(table: "externalPublicationOutbox", options: [.ifNotExists]) { table in
                table.column("idempotencyKey", .text).primaryKey()
                table.column("contextId", .text).notNull()
                table.column("deviceId", .text).notNull()
                table.column("snapshotGeneration", .integer).notNull()
                table.column("analysisGeneration", .integer).notNull()
                table.column("changedDaysJSON", .blob).notNull()
                table.column("destination", .text).notNull()
                table.column("state", .text).notNull()
                table.column("attemptCount", .integer).notNull().defaults(to: 0)
                table.column("nextAttemptAt", .integer)
                table.column("leaseOwner", .text)
                table.column("leaseExpiresAt", .integer)
                table.column("lastErrorCode", .text)
                table.column("createdAt", .integer).notNull()
                table.column("updatedAt", .integer).notNull()
                table.foreignKey(
                    ["contextId", "snapshotGeneration"],
                    references: "verifiedHealthProjection",
                    columns: ["contextId", "snapshotGeneration"],
                    onDelete: .cascade
                )
                table.check(sql: "snapshotGeneration > 0")
                table.check(sql: "analysisGeneration > 0")
                table.check(sql: "attemptCount >= 0")
                table.check(sql: "destination IN ('widget','liveActivity','healthKit','watch')")
                table.check(sql: "state IN ('pending','inFlight','retryable','succeeded','superseded','quarantined')")
            }
            try Self.requireColumns(
                [
                    "idempotencyKey", "contextId", "deviceId", "snapshotGeneration", "analysisGeneration",
                    "changedDaysJSON", "destination", "state", "attemptCount", "nextAttemptAt", "leaseOwner",
                    "leaseExpiresAt", "lastErrorCode", "createdAt", "updatedAt",
                ],
                in: "externalPublicationOutbox",
                db: db
            )
            try db.create(
                index: "idx_externalPublicationOutbox_ready",
                on: "externalPublicationOutbox",
                columns: ["state", "nextAttemptAt", "destination", "snapshotGeneration", "analysisGeneration", "createdAt"],
                options: [.ifNotExists]
            )
            try db.create(
                index: "idx_externalPublicationOutbox_device",
                on: "externalPublicationOutbox",
                columns: ["deviceId", "contextId", "snapshotGeneration"],
                options: [.ifNotExists]
            )
        }

        // Fail clearly when a local prerelease build created only part of the draft schema. The release base
        // has none of these tables, so a partial table signals interrupted or incompatible prerelease work.
        // Silent `ifNotExists` acceptance would move corruption into runtime code and make recovery harder.
        migrator.registerMigration("v43-phase34-schema-validation") { db in
            try Self.requireColumns(
                ["consumerId", "databaseInstanceId", "deviceId", "lineage", "cursorEpoch", "trimScope",
                 "throughGeneration", "updatedAt"],
                in: "historicalReceiptConsumer",
                db: db
            )
            try Self.requireColumns(
                ["workId", "databaseInstanceId", "sourceId", "deviceId", "lineage", "cursorEpoch",
                 "trimScope", "firstReceiptGeneration", "lastReceiptGeneration", "affectedDaysJSON",
                 "recordedTimeZoneIdentifier", "workKindKey", "workKindJSON", "state", "attemptCount",
                 "leaseOwner", "leaseExpiresAt", "analysisGeneration", "snapshotGeneration",
                 "pendingDestinationsJSON", "createdAt", "updatedAt"],
                in: "historicalAnalysisWork",
                db: db
            )
            try Self.requireColumns(
                ["generation", "workId", "databaseInstanceId", "sourceId", "deviceId", "lineage",
                 "cursorEpoch", "trimScope", "throughReceiptGeneration", "analyzedDaysJSON",
                 "algorithmBundleVersion", "createdAt"],
                in: "analysisMutationJournal",
                db: db
            )
            try Self.requireColumns(
                ["contextId", "deviceId", "snapshotGeneration", "projectionJSON", "createdAt"],
                in: "verifiedHealthProjection",
                db: db
            )
            try Self.requireColumns(
                ["contextId", "deviceId", "analysisGeneration", "throughReceiptGeneration",
                 "snapshotGeneration", "changedDaysJSON", "createdAt"],
                in: "verifiedSnapshotCommit",
                db: db
            )
            try Self.requireColumns(
                ["idempotencyKey", "contextId", "deviceId", "snapshotGeneration", "analysisGeneration",
                 "changedDaysJSON", "destination", "state", "attemptCount", "nextAttemptAt", "leaseOwner",
                 "leaseExpiresAt", "lastErrorCode", "createdAt", "updatedAt"],
                in: "externalPublicationOutbox",
                db: db
            )
            let tableSQL = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'externalPublicationOutbox'"
            ) ?? ""
            let normalized = tableSQL.lowercased().filter { !$0.isWhitespace && $0 != "\"" }
            guard normalized.contains("superseded"),
                  !normalized.contains("unique(contextid,snapshotgeneration,destination)") else {
                throw Phase34MigrationError.incompatiblePrereleaseSchema(
                    table: "externalPublicationOutbox"
                )
            }
        }
    }

    private static func requireColumns(
        _ required: Set<String>,
        in table: String,
        db: Database
    ) throws {
        let exists = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            arguments: [table]
        ) ?? false
        guard exists else { throw Phase34MigrationError.missingTable(table) }
        let actual = Set(try db.columns(in: table).map(\.name))
        let missing = required.subtracting(actual)
        guard missing.isEmpty else {
            throw Phase34MigrationError.missingColumns(table: table, columns: missing.sorted())
        }
    }
}

public enum Phase34MigrationError: Error, LocalizedError {
    case missingTable(String)
    case missingColumns(table: String, columns: [String])
    case incompatiblePrereleaseSchema(table: String)

    public var errorDescription: String? {
        switch self {
        case .missingTable(let table):
            return "Phase 3/4 migration did not create required table: \(table)."
        case .missingColumns(let table, let columns):
            return "Phase 3/4 prerelease schema is incomplete for \(table). Missing: \(columns.joined(separator: ", "))."
        case .incompatiblePrereleaseSchema(let table):
            return "Phase 3/4 prerelease schema is incompatible for \(table). Rebuild from the verified v39 base."
        }
    }
}
