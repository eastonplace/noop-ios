import Foundation
import GRDB
import NoopPhase34Core

public enum VerifiedExternalProjectionBundleStoreError: Error, Equatable, Sendable {
    case invalidBundle
    case conflictingReplay
    case missingBundle
}

extension WhoopStore {
    /// Persist the verified health projection and immutable Widget auxiliaries in
    /// the same row/transaction. A delayed outbox item can then load one exact
    /// generation without consulting mutable Repository caches.
    static func persistVerifiedExternalProjectionBundle(
        _ bundle: VerifiedExternalProjectionBundle,
        now: Date,
        in db: Database
    ) throws {
        let projection = bundle.projection
        guard projection.contextId == bundle.widgetCore.contextId,
              projection.generation == bundle.widgetCore.projectionGeneration,
              projection.logicalDay == bundle.widgetCore.logicalDay else {
            throw VerifiedExternalProjectionBundleStoreError.invalidBundle
        }
        let projectionJSON = try JSONEncoder().encode(projection)
        let widgetJSON = try JSONEncoder().encode(bundle.widgetCore)

        if let row = try Row.fetchOne(db, sql: """
            SELECT deviceId, projectionJSON, widgetCoreJSON
            FROM verifiedHealthProjection
            WHERE contextId = ? AND snapshotGeneration = ?
            """, arguments: [projection.contextId, projection.generation]) {
            let existingDevice: String = row["deviceId"]
            let existingProjectionData: Data = row["projectionJSON"]
            let existingWidgetData: Data? = row["widgetCoreJSON"]
            guard existingDevice == projection.deviceId,
                  let existingProjection = try? JSONDecoder().decode(
                    VerifiedHealthProjection.self,
                    from: existingProjectionData
                  ),
                  existingProjection == projection else {
                throw VerifiedExternalProjectionBundleStoreError.conflictingReplay
            }
            if let existingWidgetData {
                guard let existingWidget = try? JSONDecoder().decode(
                    VerifiedWidgetCorePayload.self,
                    from: existingWidgetData
                ), existingWidget == bundle.widgetCore else {
                    throw VerifiedExternalProjectionBundleStoreError.conflictingReplay
                }
                return
            }
            try db.execute(sql: """
                UPDATE verifiedHealthProjection
                SET widgetCoreJSON = ?
                WHERE contextId = ? AND snapshotGeneration = ?
                  AND widgetCoreJSON IS NULL
                """, arguments: [
                    widgetJSON, projection.contextId, projection.generation,
                ])
            guard db.changesCount == 1 else {
                throw VerifiedExternalProjectionBundleStoreError.conflictingReplay
            }
            return
        }

        try db.execute(sql: """
            INSERT INTO verifiedHealthProjection
                (contextId, deviceId, snapshotGeneration,
                 projectionJSON, widgetCoreJSON, createdAt)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [
                projection.contextId,
                projection.deviceId,
                projection.generation,
                projectionJSON,
                widgetJSON,
                Int(now.timeIntervalSince1970),
            ])
    }

    /// Missing immutable artifacts are a durable pipeline error. Returning nil
    /// allowed the caller to report HealthKit as enqueued without inserting any
    /// outbox row. The optional return remains source-compatible, but absence now
    /// fails closed through `missingBundle`.
    public func verifiedExternalProjectionBundle(
        contextId: String,
        generation: Int64
    ) async throws -> VerifiedExternalProjectionBundle? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT projectionJSON, widgetCoreJSON
                FROM verifiedHealthProjection
                WHERE contextId = ? AND snapshotGeneration = ?
                """, arguments: [contextId, generation]) else {
                throw VerifiedExternalProjectionBundleStoreError.missingBundle
            }
            let projectionData: Data = row["projectionJSON"]
            let widgetData: Data? = row["widgetCoreJSON"]
            guard let widgetData,
                  let projection = try? JSONDecoder().decode(
                    VerifiedHealthProjection.self,
                    from: projectionData
                  ),
                  let widgetCore = try? JSONDecoder().decode(
                    VerifiedWidgetCorePayload.self,
                    from: widgetData
                  ) else {
                throw VerifiedExternalProjectionBundleStoreError.missingBundle
            }
            return try VerifiedExternalProjectionBundle(
                projection: projection,
                widgetCore: widgetCore
            )
        }
    }
}
