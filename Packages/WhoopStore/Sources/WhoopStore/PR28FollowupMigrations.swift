import Foundation
import GRDB

/// Durable follow-up fixes for PR #28.  This migration is deliberately after v45:
/// old leases are recovered before any worker can select a row, and the HealthKit
/// generation fence exists before an exact mutation can be delivered.
public enum PR28FollowupMigrations {
    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v46-pr28-followup-delivery-ordering") { db in
            try recoverLeaseLessInFlightRows(db)
            try createHealthKitWatermark(db)
            try validate(db)
        }
    }

    private static func recoverLeaseLessInFlightRows(_ db: Database) throws {
        guard try db.tableExists("externalPublicationOutbox") else { return }
        try db.execute(sql: """
            UPDATE externalPublicationOutbox
            SET state = 'retryable',
                nextAttemptAt = NULL,
                leaseOwner = NULL,
                leaseExpiresAt = NULL,
                lastErrorCode = COALESCE(lastErrorCode, 'v46_recovered_inflight_without_lease'),
                updatedAt = updatedAt
            WHERE state = 'inFlight'
              AND leaseOwner IS NULL
        """)
    }

    private static func createHealthKitWatermark(_ db: Database) throws {
        try db.create(table: "healthKitMutationWatermark", options: [.ifNotExists]) { table in
            table.column("contextId", .text).notNull()
            table.column("deviceId", .text).notNull()
            table.column("day", .text).notNull()
            table.column("analysisGeneration", .integer).notNull()
            table.column("updatedAt", .integer).notNull()
            table.primaryKey(["contextId", "day"])
            table.check(sql: "length(contextId) > 0")
            table.check(sql: "length(deviceId) > 0")
            table.check(sql: "length(day) = 10")
            table.check(sql: "analysisGeneration > 0")
        }
        try db.create(
            index: "idx_healthKitMutationWatermark_device_day",
            on: "healthKitMutationWatermark",
            columns: ["deviceId", "day", "analysisGeneration"],
            options: [.ifNotExists]
        )
    }

    private static func validate(_ db: Database) throws {
        guard try db.tableExists("healthKitMutationWatermark") else {
            throw PR28FollowupMigrationError.invalidSchema
        }
        let columns = Set(try db.columns(in: "healthKitMutationWatermark").map(\.name))
        guard columns.isSuperset(of: ["contextId", "deviceId", "day", "analysisGeneration", "updatedAt"]) else {
            throw PR28FollowupMigrationError.invalidSchema
        }
        let stranded = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM externalPublicationOutbox
            WHERE state = 'inFlight' AND leaseOwner IS NULL
        """) ?? 0
        guard stranded == 0 else { throw PR28FollowupMigrationError.invalidSchema }
    }
}

public enum PR28FollowupMigrationError: Error {
    case invalidSchema
}
