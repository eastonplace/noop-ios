import Foundation
import GRDB
import NoopPhase34Core

public enum LatestStateDeliveryCheckpointStoreError: Error, Equatable, Sendable {
    case invalidRow
    case conflictingGeneration
}

extension WhoopStore {
    public func latestStateDeliveryCheckpoint(
        contextId: String
    ) async throws -> LatestStateDeliveryCheckpoint? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT deviceId, snapshotGeneration, presentationJSON,
                       widgetCoreJSON, logicalDay, deliveredAt
                FROM latestStateDeliveryCheckpoint
                WHERE contextId = ?
                """, arguments: [contextId]) else {
                return nil
            }
            let presentationData: Data = row["presentationJSON"]
            let widgetData: Data = row["widgetCoreJSON"]
            let logicalDayKey: String = row["logicalDay"]
            let deliveredAt: Int = row["deliveredAt"]
            guard let presentation = try? JSONDecoder().decode(
                    SnapshotPresentationIdentity.self,
                    from: presentationData
                  ),
                  let widget = try? JSONDecoder().decode(
                    VerifiedWidgetCorePayload.self,
                    from: widgetData
                  ),
                  let logicalDay = try? CivilDay(key: logicalDayKey),
                  deliveredAt >= 0 else {
                throw LatestStateDeliveryCheckpointStoreError.invalidRow
            }
            return LatestStateDeliveryCheckpoint(
                contextId: contextId,
                presentationIdentity: presentation,
                widgetCore: widget,
                logicalDay: logicalDay,
                deliveredAt: Date(timeIntervalSince1970: TimeInterval(deliveredAt))
            )
        }
    }

    /// Record the latest successfully delivered latest-state generation. Older
    /// delayed completions cannot move the checkpoint backward.
    public func recordLatestStateDeliveryCheckpoint(
        projection: VerifiedHealthProjection,
        widgetCore: VerifiedWidgetCorePayload,
        deliveredAt: Date
    ) async throws {
        let presentationData = try JSONEncoder().encode(projection.presentationIdentity)
        let widgetData = try JSONEncoder().encode(widgetCore)
        try syncWrite { db in
            if let row = try Row.fetchOne(db, sql: """
                SELECT deviceId, snapshotGeneration
                FROM latestStateDeliveryCheckpoint
                WHERE contextId = ?
                """, arguments: [projection.contextId]) {
                let existingDevice: String = row["deviceId"]
                let existingGeneration: Int64 = row["snapshotGeneration"]
                guard existingDevice == projection.deviceId else {
                    throw LatestStateDeliveryCheckpointStoreError.conflictingGeneration
                }
                if existingGeneration > projection.generation { return }
            }
            try db.execute(sql: """
                INSERT INTO latestStateDeliveryCheckpoint (
                    contextId, deviceId, snapshotGeneration, presentationJSON,
                    widgetCoreJSON, logicalDay, deliveredAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(contextId) DO UPDATE SET
                    deviceId = excluded.deviceId,
                    snapshotGeneration = excluded.snapshotGeneration,
                    presentationJSON = excluded.presentationJSON,
                    widgetCoreJSON = excluded.widgetCoreJSON,
                    logicalDay = excluded.logicalDay,
                    deliveredAt = excluded.deliveredAt
                WHERE excluded.snapshotGeneration >=
                      latestStateDeliveryCheckpoint.snapshotGeneration
                  AND excluded.deviceId = latestStateDeliveryCheckpoint.deviceId
                """, arguments: [
                    projection.contextId,
                    projection.deviceId,
                    projection.generation,
                    presentationData,
                    widgetData,
                    projection.logicalDay.key,
                    Int(deliveredAt.timeIntervalSince1970),
                ])
        }
    }

    @discardableResult
    public func clearLatestStateDeliveryCheckpoint(
        contextId: String
    ) async throws -> Bool {
        try syncWrite { db in
            try db.execute(
                sql: "DELETE FROM latestStateDeliveryCheckpoint WHERE contextId = ?",
                arguments: [contextId]
            )
            return db.changesCount > 0
        }
    }
}
