// Copy into Packages/WhoopStore/Sources/WhoopStore after NoopPhase34Core is available.
// This is the idempotency seam between a durable analysis generation and its committed Today projection.

import Foundation
import GRDB
import NoopPhase34Core

extension WhoopStore {
    /// Persist one verified analysis -> snapshot mapping. A retry after process death returns the original
    /// mapping. It never assigns another snapshot generation for the same analysis generation.
    public func recordVerifiedSnapshotCommit(
        _ receipt: SnapshotCommitReceipt,
        now: Date,
        widgetCore: VerifiedWidgetCorePayload? = nil
    ) async throws -> SnapshotCommitReceipt {
        try syncWrite { db in
            if let existing = try Self.decodeVerifiedSnapshotCommit(
                contextId: receipt.projection.contextId,
                analysisGeneration: receipt.analysisGeneration,
                in: db
            ) {
                guard existing == receipt else {
                    throw VerifiedSnapshotCommitStoreError.conflictingReplay
                }
                return existing
            }

            if let widgetCore {
                let bundle = try VerifiedExternalProjectionBundle(
                    projection: receipt.projection,
                    widgetCore: widgetCore
                )
                try Self.persistVerifiedExternalProjectionBundle(bundle, now: now, in: db)
            } else {
                try Self.persistVerifiedProjection(receipt.projection, now: now, in: db)
            }
            let changedDays = try JSONEncoder().encode(receipt.analyzedDays)
            let healthKitPayload = try receipt.healthKitPayload.map(JSONEncoder().encode)
            try db.execute(sql: """
                INSERT INTO verifiedSnapshotCommit (
                    contextId, deviceId, analysisGeneration, throughReceiptGeneration,
                    snapshotGeneration, changedDaysJSON, recordedTimeZoneIdentifier,
                    healthKitPayloadJSON, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    receipt.projection.contextId,
                    receipt.projection.deviceId,
                    receipt.analysisGeneration,
                    receipt.throughReceiptGeneration,
                    receipt.snapshotGeneration,
                    changedDays,
                    receipt.recordedTimeZoneIdentifier,
                    healthKitPayload,
                    Int(now.timeIntervalSince1970),
                ])
            return receipt
        }
    }

    public func verifiedSnapshotCommit(
        contextId: String,
        analysisGeneration: Int64
    ) async throws -> SnapshotCommitReceipt? {
        try syncRead { db in
            try Self.decodeVerifiedSnapshotCommit(
                contextId: contextId,
                analysisGeneration: analysisGeneration,
                in: db
            )
        }
    }

    /// Load the durable receipt by the immutable snapshot generation when a caller owns a verified
    /// projection but does not have the original analysis lease row.
    public func verifiedSnapshotCommit(
        contextId: String,
        snapshotGeneration: Int64
    ) async throws -> SnapshotCommitReceipt? {
        try syncRead { db in
            try Self.decodeVerifiedSnapshotCommit(
                contextId: contextId,
                snapshotGeneration: snapshotGeneration,
                in: db
            )
        }
    }

    private static func decodeVerifiedSnapshotCommit(
        contextId: String,
        analysisGeneration: Int64? = nil,
        snapshotGeneration: Int64? = nil,
        in db: Database
    ) throws -> SnapshotCommitReceipt? {
        let predicate: String
        let argument: Int64
        if let analysisGeneration {
            predicate = "c.analysisGeneration = ?"
            argument = analysisGeneration
        } else if let snapshotGeneration {
            predicate = "c.snapshotGeneration = ?"
            argument = snapshotGeneration
        } else {
            return nil
        }
        guard let row = try Row.fetchOne(db, sql: """
            SELECT c.*, p.projectionJSON
            FROM verifiedSnapshotCommit c
            JOIN verifiedHealthProjection p
              ON p.contextId = c.contextId
             AND p.snapshotGeneration = c.snapshotGeneration
            WHERE c.contextId = ? AND \(predicate)
            LIMIT 1
            """, arguments: [contextId, argument]) else {
            return nil
        }
        let daysData: Data = row["changedDaysJSON"]
        let projectionData: Data = row["projectionJSON"]
        let payloadData: Data? = row["healthKitPayloadJSON"]
        let days: Set<CivilDay>
        let projection: VerifiedHealthProjection
        do {
            days = try JSONDecoder().decode(Set<CivilDay>.self, from: daysData)
            projection = try JSONDecoder().decode(VerifiedHealthProjection.self, from: projectionData)
        } catch {
            throw VerifiedSnapshotCommitStoreError.invalidStoredRow
        }
        let payload: HistoricalHealthKitMutationPayload?
        do {
            payload = try payloadData.map {
                try JSONDecoder().decode(HistoricalHealthKitMutationPayload.self, from: $0)
            }
        } catch {
            throw VerifiedSnapshotCommitStoreError.invalidStoredRow
        }
        guard projection.contextId == contextId,
              projection.deviceId == (row["deviceId"] as String),
              projection.generation == (row["snapshotGeneration"] as Int64) else {
            throw VerifiedSnapshotCommitStoreError.invalidStoredRow
        }
        do {
            return try SnapshotCommitReceipt(
                throughReceiptGeneration: row["throughReceiptGeneration"],
                analysisGeneration: row["analysisGeneration"],
                snapshotGeneration: row["snapshotGeneration"],
                analyzedDays: days,
                recordedTimeZoneIdentifier: row["recordedTimeZoneIdentifier"],
                healthKitPayload: payload,
                projection: projection
            )
        } catch {
            throw VerifiedSnapshotCommitStoreError.invalidStoredRow
        }
    }
}

public enum VerifiedSnapshotCommitStoreError: Error {
    case conflictingReplay
    case invalidStoredRow
}
