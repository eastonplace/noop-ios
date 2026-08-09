import Foundation
import GRDB
import NoopPhase34Core

public enum LatestStateDeliveryCheckpointStoreError: Error, Equatable, Sendable {
    case invalidRow
    case conflictingGeneration
}

extension WhoopStore {
    public func latestStateDeliveryCheckpoint(
        contextId: String,
        destination: DownstreamDestination
    ) async throws -> LatestStateDeliveryCheckpoint? {
        guard destination != .healthKit else {
            throw LatestStateDeliveryCheckpointStoreError.invalidRow
        }
        return try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT destination, deviceId, snapshotGeneration,
                       presentationJSON, widgetCoreJSON, logicalDay, deliveredAt
                FROM latestStateDeliveryCheckpoint
                WHERE contextId = ? AND destination = ?
                """, arguments: [contextId, destination.rawValue]) else {
                return nil
            }
            return try Self.decodeLatestStateCheckpoint(
                row: row,
                contextId: contextId,
                expectedDestination: destination,
                expectedDeviceId: nil
            )
        }
    }

    /// V49 compatibility. An unqualified checkpoint always means Widget.
    public func latestStateDeliveryCheckpoint(
        contextId: String
    ) async throws -> LatestStateDeliveryCheckpoint? {
        try await latestStateDeliveryCheckpoint(
            contextId: contextId,
            destination: .widget
        )
    }

    /// Record one destination's delivery identity. Equal-generation replay is
    /// idempotent only when every destination-specific identity field matches.
    public func recordLatestStateDeliveryCheckpoint(
        projection: VerifiedHealthProjection,
        widgetCore: VerifiedWidgetCorePayload,
        destination: DownstreamDestination = .widget,
        deliveredAt: Date
    ) async throws {
        guard let identity = LatestStateDeliveryIdentity.make(
            destination: destination,
            projection: projection,
            widgetCore: widgetCore
        ) else {
            throw LatestStateDeliveryCheckpointStoreError.invalidRow
        }
        let incoming = LatestStateDeliveryCheckpoint(
            contextId: projection.contextId,
            identity: identity,
            logicalDay: projection.logicalDay,
            deliveredAt: deliveredAt
        )
        let presentationData = try JSONEncoder().encode(identity.presentationIdentity)
        let widgetData = try identity.widgetCore.map(JSONEncoder().encode)
        let deliveredAtSeconds = Int(deliveredAt.timeIntervalSince1970)
        guard deliveredAtSeconds >= 0 else {
            throw LatestStateDeliveryCheckpointStoreError.invalidRow
        }

        try syncWrite { db in
            if let row = try Row.fetchOne(db, sql: """
                SELECT destination, deviceId, snapshotGeneration,
                       presentationJSON, widgetCoreJSON, logicalDay, deliveredAt
                FROM latestStateDeliveryCheckpoint
                WHERE contextId = ? AND destination = ?
                """, arguments: [projection.contextId, destination.rawValue]) {
                let existingDevice: String = row["deviceId"]
                let existingGeneration: Int64 = row["snapshotGeneration"]
                guard existingDevice == projection.deviceId else {
                    throw LatestStateDeliveryCheckpointStoreError.conflictingGeneration
                }
                if existingGeneration > projection.generation { return }
                if existingGeneration == projection.generation {
                    let existing = try Self.decodeLatestStateCheckpoint(
                        row: row,
                        contextId: projection.contextId,
                        expectedDestination: destination,
                        expectedDeviceId: projection.deviceId
                    )
                    guard existing.identity == incoming.identity,
                          existing.logicalDay == incoming.logicalDay else {
                        throw LatestStateDeliveryCheckpointStoreError.conflictingGeneration
                    }
                    try db.execute(sql: """
                        UPDATE latestStateDeliveryCheckpoint
                        SET deliveredAt = MAX(deliveredAt, ?)
                        WHERE contextId = ? AND destination = ?
                        """, arguments: [
                            deliveredAtSeconds,
                            projection.contextId,
                            destination.rawValue,
                        ])
                    return
                }
                try db.execute(sql: """
                    UPDATE latestStateDeliveryCheckpoint
                    SET snapshotGeneration = ?, presentationJSON = ?,
                        widgetCoreJSON = ?, logicalDay = ?, deliveredAt = ?
                    WHERE contextId = ? AND destination = ? AND deviceId = ?
                    """, arguments: [
                        projection.generation,
                        presentationData,
                        widgetData,
                        projection.logicalDay.key,
                        deliveredAtSeconds,
                        projection.contextId,
                        destination.rawValue,
                        projection.deviceId,
                    ])
                guard db.changesCount == 1 else {
                    throw LatestStateDeliveryCheckpointStoreError.conflictingGeneration
                }
                return
            }
            try db.execute(sql: """
                INSERT INTO latestStateDeliveryCheckpoint (
                    contextId, destination, deviceId, snapshotGeneration,
                    presentationJSON, widgetCoreJSON, logicalDay, deliveredAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    projection.contextId,
                    destination.rawValue,
                    projection.deviceId,
                    projection.generation,
                    presentationData,
                    widgetData,
                    projection.logicalDay.key,
                    deliveredAtSeconds,
                ])
        }
    }

    @discardableResult
    public func clearLatestStateDeliveryCheckpoint(
        contextId: String,
        destination: DownstreamDestination
    ) async throws -> Bool {
        guard destination != .healthKit else { return false }
        return try syncWrite { db in
            try db.execute(
                sql: "DELETE FROM latestStateDeliveryCheckpoint WHERE contextId = ? AND destination = ?",
                arguments: [contextId, destination.rawValue]
            )
            return db.changesCount > 0
        }
    }

    /// Compatibility and privacy boundary: clear every destination for context.
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

    static func decodeLatestStateCheckpoint(
        row: Row,
        contextId: String,
        expectedDestination: DownstreamDestination,
        expectedDeviceId: String?
    ) throws -> LatestStateDeliveryCheckpoint {
        let storedDestinationRaw: String = row["destination"]
        let storedDeviceId: String = row["deviceId"]
        let presentationData: Data = row["presentationJSON"]
        let widgetData: Data? = row["widgetCoreJSON"]
        let logicalDayKey: String = row["logicalDay"]
        let deliveredAtSeconds: Int = row["deliveredAt"]
        guard let storedDestination = DownstreamDestination(rawValue: storedDestinationRaw),
              storedDestination == expectedDestination,
              storedDestination != .healthKit,
              expectedDeviceId.map({ $0 == storedDeviceId }) ?? true,
              let presentation = try? JSONDecoder().decode(
                  SnapshotPresentationIdentity.self,
                  from: presentationData
              ),
              let logicalDay = try? CivilDay(key: logicalDayKey),
              deliveredAtSeconds >= 0 else {
            throw LatestStateDeliveryCheckpointStoreError.invalidRow
        }
        let identity: LatestStateDeliveryIdentity
        switch storedDestination {
        case .widget:
            guard let widgetData,
                  let widgetCore = try? JSONDecoder().decode(
                      VerifiedWidgetCorePayload.self,
                      from: widgetData
                  ) else {
                throw LatestStateDeliveryCheckpointStoreError.invalidRow
            }
            identity = .widget(
                presentationIdentity: presentation,
                widgetCore: widgetCore
            )
        case .liveActivity:
            guard widgetData == nil else {
                throw LatestStateDeliveryCheckpointStoreError.invalidRow
            }
            identity = .liveActivity(presentationIdentity: presentation)
        case .watch:
            guard widgetData == nil else {
                throw LatestStateDeliveryCheckpointStoreError.invalidRow
            }
            identity = .watch(presentationIdentity: presentation)
        case .healthKit:
            throw LatestStateDeliveryCheckpointStoreError.invalidRow
        }
        return LatestStateDeliveryCheckpoint(
            contextId: contextId,
            identity: identity,
            logicalDay: logicalDay,
            deliveredAt: Date(timeIntervalSince1970: TimeInterval(deliveredAtSeconds))
        )
    }
}
