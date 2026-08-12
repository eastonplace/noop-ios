import Foundation
import GRDB
import NoopPhase34Core

public enum VerifiedExternalProjectionBundleStoreError: Error, Equatable, Sendable {
    case invalidBundle
    case conflictingReplay
    case missingBundle
    case invalidStoredRow
}

/// Immutable projection state used to repair an older commit whose Widget
/// auxiliary payload is absent.
public struct VerifiedExternalProjectionArtifacts: Equatable, Sendable {
    public let projection: VerifiedHealthProjection
    public let widgetCore: VerifiedWidgetCorePayload?
}

extension WhoopStore {
    /// Read the verified projection even when its Widget auxiliary is absent.
    /// A non-null corrupt payload fails closed and is never treated as missing.
    public func verifiedExternalProjectionArtifacts(
        contextId: String,
        generation: Int64
    ) async throws -> VerifiedExternalProjectionArtifacts {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT deviceId, projectionJSON, widgetCoreJSON
                FROM verifiedHealthProjection
                WHERE contextId = ? AND snapshotGeneration = ?
                """, arguments: [contextId, generation]) else {
                throw VerifiedExternalProjectionBundleStoreError.missingBundle
            }
            let deviceId: String = row["deviceId"]
            let projectionData: Data = row["projectionJSON"]
            guard let projection = try? JSONDecoder().decode(
                      VerifiedHealthProjection.self,
                      from: projectionData
                  ), projection.contextId == contextId,
                  projection.deviceId == deviceId,
                  projection.generation == generation else {
                throw VerifiedExternalProjectionBundleStoreError.invalidStoredRow
            }
            let widgetData: Data? = row["widgetCoreJSON"]
            let widgetCore: VerifiedWidgetCorePayload?
            if let widgetData {
                guard let decoded = try? JSONDecoder().decode(
                          VerifiedWidgetCorePayload.self,
                          from: widgetData
                      ), decoded.contextId == projection.contextId,
                      decoded.projectionGeneration == projection.generation,
                      decoded.logicalDay == projection.logicalDay else {
                    throw VerifiedExternalProjectionBundleStoreError.invalidStoredRow
                }
                widgetCore = decoded
            } else {
                widgetCore = nil
            }
            return VerifiedExternalProjectionArtifacts(
                projection: projection,
                widgetCore: widgetCore
            )
        }
    }

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
