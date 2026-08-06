// Copy into Packages/WhoopStore/Sources/WhoopStore after adding NoopPhase34Core.

import Foundation
import GRDB
import NoopPhase34Core

extension WhoopStore {
    @discardableResult
    public func resumeBlockedExternalPublications(
        destinations: Set<DownstreamDestination>,
        now: Date
    ) async throws -> Int {
        try await resumeEnvironmentalBlockedExternalPublications(destinations: destinations, now: now)
    }

    @discardableResult
    public func resumeEnvironmentalBlockedExternalPublications(
        destinations: Set<DownstreamDestination>,
        now: Date
    ) async throws -> Int {
        guard !destinations.isEmpty else { return 0 }
        return try syncWrite { db in
            let values = destinations.map(\.rawValue).sorted()
            let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM externalPublicationOutbox WHERE state = 'blocked' AND leaseOwner IS NULL AND destination IN (\(placeholders))",
                arguments: StatementArguments(values)
            )
            for row in rows {
                guard PR28BlockedRearmPolicy.mayRearm(code: row["lastErrorCode"]) else { continue }
                var item = try Self.decodeExternalPublication(row)
                try ExternalPublicationReducer.apply(.resumeBlocked, to: &item, now: now)
                try Self.updateExternalPublication(item, in: db)
            }
            return rows.reduce(into: 0) { count, row in
                if PR28BlockedRearmPolicy.mayRearm(code: row["lastErrorCode"]) { count += 1 }
            }
        }
    }

    /// Persist the verified current projection and all destination rows in one transaction.
    /// Latest-state surfaces are keyed by snapshot generation. HealthKit is keyed by analysis generation and
    /// retains the exact analyzed days, so a historical-only mutation is not lost when the current Today
    /// snapshot is unchanged or reused.
    public func enqueueExternalPublications(
        snapshot: SnapshotCommitReceipt,
        destinations: Set<DownstreamDestination>,
        now: Date
    ) async throws -> Set<DownstreamDestination> {
        try syncWrite { db in
            try Self.persistVerifiedProjection(snapshot.projection, now: now, in: db)
            for destination in destinations {
                try HealthKitPayloadAdmissionGuard.validate(destination: destination, snapshot: snapshot)
                let item = try ExternalPublicationOutboxItem(
                    contextId: snapshot.projection.contextId,
                    deviceId: snapshot.projection.deviceId,
                    snapshotGeneration: snapshot.snapshotGeneration,
                    analysisGeneration: snapshot.analysisGeneration,
                    changedDays: snapshot.analyzedDays,
                    recordedTimeZoneIdentifier: snapshot.recordedTimeZoneIdentifier,
                    healthKitPayload: destination == .healthKit ? snapshot.healthKitPayload : nil,
                    destination: destination,
                    createdAt: now
                )
                if item.isLatestStateDestination {
                    try Self.supersedeOlderLatestStateItems(before: item, now: now, in: db)
                }
                try Self.insertExternalPublication(item, in: db)
            }
            return destinations
        }
    }

    /// HealthKit is always exact-work delivery. Latest-state sinks are admitted only when the immutable
    /// presentation or Widget core changes, the logical day changes, or the bounded heartbeat is due.
    /// The compact checkpoint survives projection pruning and process death.
    public func selectiveExternalPublicationDestinations(
        snapshot: SnapshotCommitReceipt,
        bundle: VerifiedExternalProjectionBundle,
        now: Date
    ) async throws -> Set<DownstreamDestination> {
        try syncRead { db in
            let previous = try Self.decodeLatestStateCheckpoint(
                contextId: snapshot.projection.contextId,
                expectedDeviceId: snapshot.projection.deviceId,
                in: db
            )
            return SelectiveExternalPublicationPlan.destinations(
                snapshot: snapshot,
                bundle: bundle,
                previousLatestState: previous,
                now: now
            )
        }
    }

    public func verifiedHealthProjection(
        contextId: String,
        generation: Int64
    ) async throws -> VerifiedHealthProjection? {
        try syncRead { db in
            guard let payload: Data = try Data.fetchOne(db, sql: """
                SELECT projectionJSON FROM verifiedHealthProjection
                WHERE contextId = ? AND snapshotGeneration = ?
                """, arguments: [contextId, generation]) else {
                return nil
            }
            do { return try JSONDecoder().decode(VerifiedHealthProjection.self, from: payload) }
            catch { throw ExternalPublicationStoreError.invalidProjection }
        }
    }

    public func leaseNextExternalPublication(
        owner: String,
        now: Date,
        leaseDuration: TimeInterval = 60,
        preferredDestination: DownstreamDestination? = nil
    ) async throws -> ExternalPublicationOutboxItem? {
        try syncWrite { db in
            let nowTs = Int(now.timeIntervalSince1970)
            let expired = try Row.fetchAll(db, sql: """
                SELECT * FROM externalPublicationOutbox
                WHERE leaseExpiresAt IS NOT NULL AND leaseExpiresAt <= ?
                  AND state NOT IN ('succeeded', 'superseded', 'quarantined')
                """, arguments: [nowTs])
            for row in expired {
                var item = try Self.decodeExternalPublication(row)
                try ExternalPublicationReducer.apply(.leaseExpired, to: &item, now: now)
                try Self.updateExternalPublication(item, in: db)
            }

            let destinationPredicate = preferredDestination.map { "AND destination = '\($0.rawValue)'" } ?? ""
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM externalPublicationOutbox
                WHERE state IN ('pending', 'retryable')
                  AND leaseOwner IS NULL
                  \(destinationPredicate)
                  AND (nextAttemptAt IS NULL OR nextAttemptAt <= ?)
                ORDER BY
                  CASE destination
                    WHEN 'widget' THEN 0
                    WHEN 'liveActivity' THEN 1
                    WHEN 'watch' THEN 2
                    WHEN 'healthKit' THEN 3
                    ELSE 4
                  END ASC,
                  CASE WHEN destination IN ('widget', 'liveActivity', 'watch')
                       THEN snapshotGeneration ELSE 0 END DESC,
                  CASE WHEN destination = 'healthKit'
                       THEN analysisGeneration ELSE 0 END ASC,
                  createdAt ASC
                LIMIT 1
                """, arguments: [nowTs]) else {
                return nil
            }
            var item = try Self.decodeExternalPublication(row)
            try ExternalPublicationReducer.apply(
                .acquire(owner: owner, expiresAt: now.addingTimeInterval(max(15, leaseDuration))),
                to: &item,
                now: now
            )
            try Self.updateExternalPublication(item, in: db)
            return item
        }
    }

    public func applyExternalPublicationEvent(
        idempotencyKey: String,
        event: ExternalPublicationEvent,
        now: Date
    ) async throws -> ExternalPublicationOutboxItem {
        try syncWrite { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM externalPublicationOutbox WHERE idempotencyKey = ?",
                arguments: [idempotencyKey]
            ) else {
                throw ExternalPublicationStoreError.missingItem
            }
            var item = try Self.decodeExternalPublication(row)
            try ExternalPublicationReducer.apply(event, to: &item, now: now)
            try Self.updateExternalPublication(item, in: db)
            if item.state == .succeeded, item.isLatestStateDestination {
                try Self.recordLatestStateCheckpoint(for: item, deliveredAt: now, in: db)
            }
            return item
        }
    }

    /// Privacy/source lifecycle boundary. Call from the same logical device-family deletion used for raw rows,
    /// analysis work, snapshots, and receipt consumers.
    public func deleteExternalPublicationState(deviceId: String) async throws {
        try syncWrite { db in
            let contexts = try String.fetchAll(db, sql: """
                SELECT DISTINCT contextId FROM verifiedHealthProjection WHERE deviceId = ?
                UNION
                SELECT DISTINCT contextId FROM externalPublicationOutbox WHERE deviceId = ?
                """, arguments: [deviceId, deviceId])
            try db.execute(sql: "DELETE FROM externalPublicationOutbox WHERE deviceId = ?", arguments: [deviceId])
            try db.execute(sql: "DELETE FROM verifiedSnapshotCommit WHERE deviceId = ?", arguments: [deviceId])
            try db.execute(sql: "DELETE FROM verifiedHealthProjection WHERE deviceId = ?", arguments: [deviceId])
            for contextId in contexts {
                try db.execute(
                    sql: "DELETE FROM latestStateDeliveryCheckpoint WHERE contextId = ?",
                    arguments: [contextId]
                )
            }
            if try db.tableExists("healthKitMutationWatermark") {
                try db.execute(sql: "DELETE FROM healthKitMutationWatermark WHERE deviceId = ?", arguments: [deviceId])
            }
            if try db.tableExists("healthKitSleepKeyLedger") {
                try db.execute(sql: "DELETE FROM healthKitSleepKeyLedger WHERE deviceId = ?", arguments: [deviceId])
            }
            if try db.tableExists("healthKitSleepDayLedger") {
                try db.execute(sql: "DELETE FROM healthKitSleepDayLedger WHERE deviceId = ?", arguments: [deviceId])
            }
        }
    }

    /// Invalidate only latest-state sinks for an old verified context. Historical HealthKit rows and their
    /// watermarks are intentionally untouched; ordinary A->B selection must preserve that durable history.
    @discardableResult
    public func retireLatestStatePublications(contextId: String?) async throws -> Int {
        guard let contextId, !contextId.isEmpty else { return 0 }
        return try syncWrite { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM externalPublicationOutbox
                WHERE contextId = ?
                  AND destination IN ('widget', 'liveActivity', 'watch')
                  AND state IN ('pending', 'retryable')
                  AND leaseOwner IS NULL
                """, arguments: [contextId])
            var retired = 0
            for row in rows {
                var item = try Self.decodeExternalPublication(row)
                try ExternalPublicationReducer.apply(.supersede, to: &item, now: Date())
                try Self.updateExternalPublication(item, in: db)
                retired += 1
            }
            return retired
        }
    }

    /// Retain a small completed projection history for diagnostics. Never delete a payload referenced by a
    /// pending, in-flight, retryable, or quarantined outbox item. The compact latest-state checkpoint is a
    /// standalone table and is intentionally unaffected by this pruning.
    public func pruneCompletedVerifiedProjections(keepMostRecent: Int = 8) async throws -> Int {
        try syncWrite { db in
            let keep = max(1, keepMostRecent)
            let contexts = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT contextId FROM verifiedHealthProjection ORDER BY contextId"
            )
            var deleted = 0
            for contextId in contexts {
                let retained = try Int64.fetchAll(db, sql: """
                    SELECT snapshotGeneration FROM verifiedHealthProjection
                    WHERE contextId = ?
                    ORDER BY snapshotGeneration DESC
                    LIMIT ?
                    """, arguments: [contextId, keep])
                guard !retained.isEmpty else { continue }
                let placeholders = Array(repeating: "?", count: retained.count).joined(separator: ",")
                var arguments: [DatabaseValueConvertible] = [contextId]
                arguments.append(contentsOf: retained)
                try db.execute(sql: """
                    DELETE FROM verifiedHealthProjection
                    WHERE contextId = ?
                      AND snapshotGeneration NOT IN (\(placeholders))
                      AND NOT EXISTS (
                          SELECT 1 FROM externalPublicationOutbox o
                          WHERE o.contextId = verifiedHealthProjection.contextId
                            AND o.snapshotGeneration = verifiedHealthProjection.snapshotGeneration
                            AND o.state NOT IN ('succeeded', 'superseded')
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM verifiedSnapshotCommit c
                          JOIN analysisMutationJournal m
                            ON m.generation = c.analysisGeneration
                          JOIN historicalAnalysisWork w
                            ON w.workId = m.workId
                          WHERE c.contextId = verifiedHealthProjection.contextId
                            AND c.snapshotGeneration = verifiedHealthProjection.snapshotGeneration
                            AND w.state NOT IN ('complete', 'quarantined')
                      )
                    """, arguments: StatementArguments(arguments))
                deleted += db.changesCount
            }
            return deleted
        }
    }

    static func persistVerifiedProjection(
        _ projection: VerifiedHealthProjection,
        now: Date,
        in db: Database
    ) throws {
        let payload = try JSONEncoder().encode(projection)
        if let row = try Row.fetchOne(db, sql: """
            SELECT deviceId, projectionJSON FROM verifiedHealthProjection
            WHERE contextId = ? AND snapshotGeneration = ?
            """, arguments: [projection.contextId, projection.generation]) {
            let deviceId: String = row["deviceId"]
            let existingPayload: Data = row["projectionJSON"]
            let existingProjection: VerifiedHealthProjection
            do {
                existingProjection = try JSONDecoder().decode(
                    VerifiedHealthProjection.self,
                    from: existingPayload
                )
            } catch {
                throw ExternalPublicationStoreError.invalidProjection
            }
            guard deviceId == projection.deviceId, existingProjection == projection else {
                throw ExternalPublicationStoreError.conflictingProjection
            }
            return
        }
        try db.execute(sql: """
            INSERT INTO verifiedHealthProjection
                (contextId, deviceId, snapshotGeneration, projectionJSON, createdAt)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [
                projection.contextId,
                projection.deviceId,
                projection.generation,
                payload,
                Int(now.timeIntervalSince1970),
            ])
    }

    private static func decodeLatestStateCheckpoint(
        contextId: String,
        expectedDeviceId: String,
        in db: Database
    ) throws -> LatestStateDeliveryCheckpoint? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT deviceId, presentationJSON, widgetCoreJSON, logicalDay, deliveredAt
            FROM latestStateDeliveryCheckpoint
            WHERE contextId = ?
            """, arguments: [contextId]) else { return nil }
        let deviceId: String = row["deviceId"]
        let presentationData: Data = row["presentationJSON"]
        let widgetData: Data = row["widgetCoreJSON"]
        let logicalDayKey: String = row["logicalDay"]
        let deliveredAtSeconds: Int = row["deliveredAt"]
        guard deviceId == expectedDeviceId,
              let presentation = try? JSONDecoder().decode(
                SnapshotPresentationIdentity.self,
                from: presentationData
              ),
              let widgetCore = try? JSONDecoder().decode(
                VerifiedWidgetCorePayload.self,
                from: widgetData
              ),
              let logicalDay = try? CivilDay(key: logicalDayKey),
              deliveredAtSeconds >= 0 else {
            throw ExternalPublicationStoreError.invalidCheckpoint
        }
        return LatestStateDeliveryCheckpoint(
            contextId: contextId,
            presentationIdentity: presentation,
            widgetCore: widgetCore,
            logicalDay: logicalDay,
            deliveredAt: Date(timeIntervalSince1970: TimeInterval(deliveredAtSeconds))
        )
    }

    private static func recordLatestStateCheckpoint(
        for item: ExternalPublicationOutboxItem,
        deliveredAt: Date,
        in db: Database
    ) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT projectionJSON, widgetCoreJSON
            FROM verifiedHealthProjection
            WHERE contextId = ? AND snapshotGeneration = ?
            """, arguments: [item.contextId, item.snapshotGeneration]) else {
            throw ExternalPublicationStoreError.invalidProjection
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
              ),
              projection.contextId == item.contextId,
              projection.deviceId == item.deviceId,
              projection.generation == item.snapshotGeneration else {
            throw ExternalPublicationStoreError.invalidProjection
        }
        let presentationData = try JSONEncoder().encode(projection.presentationIdentity)
        let widgetCoreData = try JSONEncoder().encode(widgetCore)
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
                widgetCoreData,
                projection.logicalDay.key,
                Int(deliveredAt.timeIntervalSince1970),
            ])
    }

    private static func supersedeOlderLatestStateItems(
        before incoming: ExternalPublicationOutboxItem,
        now: Date,
        in db: Database
    ) throws {
        guard incoming.isLatestStateDestination else { return }
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM externalPublicationOutbox
            WHERE contextId = ? AND deviceId = ? AND destination = ?
              AND snapshotGeneration < ?
              AND state IN ('pending', 'retryable')
              AND leaseOwner IS NULL
            ORDER BY snapshotGeneration DESC
            """, arguments: [
                incoming.contextId,
                incoming.deviceId,
                incoming.destination.rawValue,
                incoming.snapshotGeneration,
            ])
        for row in rows {
            var old = try decodeExternalPublication(row)
            try ExternalPublicationReducer.apply(.supersede, to: &old, now: now)
            try updateExternalPublication(old, in: db)
        }
    }

    private static func insertExternalPublication(
        _ item: ExternalPublicationOutboxItem,
        in db: Database
    ) throws {
        if let existing = try Row.fetchOne(
            db,
            sql: "SELECT * FROM externalPublicationOutbox WHERE idempotencyKey = ?",
            arguments: [item.idempotencyKey]
        ) {
            let decoded = try decodeExternalPublication(existing)
            guard decoded.contextId == item.contextId,
                  decoded.deviceId == item.deviceId,
                  decoded.analysisGeneration == item.analysisGeneration,
                  decoded.changedDays == item.changedDays,
                  decoded.recordedTimeZoneIdentifier == item.recordedTimeZoneIdentifier,
                  decoded.healthKitPayload == item.healthKitPayload,
                  decoded.destination == item.destination else {
                throw ExternalPublicationStoreError.conflictingItem
            }
            if decoded.isLatestStateDestination,
               decoded.snapshotGeneration != item.snapshotGeneration {
                throw ExternalPublicationStoreError.conflictingItem
            }
            return
        }
        try db.execute(sql: """
            INSERT INTO externalPublicationOutbox (
                idempotencyKey, contextId, deviceId, snapshotGeneration, analysisGeneration,
                changedDaysJSON, recordedTimeZoneIdentifier, destinationPayloadJSON,
                destination, state, attemptCount, nextAttemptAt,
                leaseOwner, leaseExpiresAt, lastErrorCode, createdAt, updatedAt
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: Self.externalPublicationArguments(item))
    }

    private static func updateExternalPublication(
        _ item: ExternalPublicationOutboxItem,
        in db: Database
    ) throws {
        try db.execute(sql: """
            UPDATE externalPublicationOutbox SET
                state = ?, attemptCount = ?, nextAttemptAt = ?, leaseOwner = ?, leaseExpiresAt = ?,
                lastErrorCode = ?, updatedAt = ?
            WHERE idempotencyKey = ?
            """, arguments: [
                item.state.rawValue,
                item.attemptCount,
                item.nextAttemptAt.map { Int($0.timeIntervalSince1970) },
                item.lease?.owner,
                item.lease.map { Int($0.expiresAt.timeIntervalSince1970) },
                item.lastErrorCode,
                Int(item.updatedAt.timeIntervalSince1970),
                item.idempotencyKey,
            ])
        guard db.changesCount == 1 else { throw ExternalPublicationStoreError.missingItem }
    }

    private static func decodeExternalPublication(_ row: Row) throws -> ExternalPublicationOutboxItem {
        guard let destination = DownstreamDestination(rawValue: row["destination"]),
              let state = ExternalPublicationState(rawValue: row["state"]) else {
            throw ExternalPublicationStoreError.invalidRow
        }
        let changedDaysData: Data = row["changedDaysJSON"]
        let payloadData: Data? = row["destinationPayloadJSON"]
        let changedDays: Set<CivilDay>
        do {
            changedDays = try JSONDecoder().decode(Set<CivilDay>.self, from: changedDaysData)
        } catch {
            throw ExternalPublicationStoreError.invalidRow
        }
        let payload: HistoricalHealthKitMutationPayload?
        do {
            payload = try payloadData.map {
                try JSONDecoder().decode(HistoricalHealthKitMutationPayload.self, from: $0)
            }
        } catch {
            throw ExternalPublicationStoreError.invalidRow
        }
        let createdAt = Date(timeIntervalSince1970: TimeInterval(row["createdAt"] as Int))
        let updatedAt = Date(timeIntervalSince1970: TimeInterval(row["updatedAt"] as Int))
        let attemptCount: Int = row["attemptCount"]
        let nextAttemptAt = (row["nextAttemptAt"] as Int?).map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        let leaseOwner: String? = row["leaseOwner"]
        let leaseExpiryRaw: Int? = row["leaseExpiresAt"]
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              attemptCount >= 0,
              nextAttemptAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              (leaseOwner == nil) == (leaseExpiryRaw == nil) else {
            throw ExternalPublicationStoreError.invalidRow
        }

        var item: ExternalPublicationOutboxItem
        do {
            item = try ExternalPublicationOutboxItem(
                contextId: row["contextId"],
                deviceId: row["deviceId"],
                snapshotGeneration: row["snapshotGeneration"],
                analysisGeneration: row["analysisGeneration"],
                changedDays: changedDays,
                recordedTimeZoneIdentifier: row["recordedTimeZoneIdentifier"],
                healthKitPayload: payload,
                destination: destination,
                createdAt: createdAt
            )
        } catch {
            throw ExternalPublicationStoreError.invalidRow
        }
        guard item.idempotencyKey == (row["idempotencyKey"] as String) else {
            throw ExternalPublicationStoreError.invalidRow
        }
        item.state = state
        item.attemptCount = attemptCount
        item.nextAttemptAt = nextAttemptAt
        if let owner = leaseOwner, let expiryRaw = leaseExpiryRaw {
            do {
                item.lease = try HistoricalWorkLease(
                    owner: owner,
                    expiresAt: Date(timeIntervalSince1970: TimeInterval(expiryRaw))
                )
            } catch {
                throw ExternalPublicationStoreError.invalidRow
            }
        }
        item.lastErrorCode = row["lastErrorCode"]
        item.updatedAt = updatedAt

        guard (state != .inFlight || item.lease != nil),
              (!item.isTerminal || item.lease == nil) else {
            throw ExternalPublicationStoreError.invalidRow
        }
        return item
    }

    private static func externalPublicationArguments(
        _ item: ExternalPublicationOutboxItem
    ) throws -> StatementArguments {
        let changedDays = try JSONEncoder().encode(item.changedDays)
        let payload = try item.healthKitPayload.map(JSONEncoder().encode)
        return [
            item.idempotencyKey,
            item.contextId,
            item.deviceId,
            item.snapshotGeneration,
            item.analysisGeneration,
            changedDays,
            item.recordedTimeZoneIdentifier,
            payload,
            item.destination.rawValue,
            item.state.rawValue,
            item.attemptCount,
            item.nextAttemptAt.map { Int($0.timeIntervalSince1970) },
            item.lease?.owner,
            item.lease.map { Int($0.expiresAt.timeIntervalSince1970) },
            item.lastErrorCode,
            Int(item.createdAt.timeIntervalSince1970),
            Int(item.updatedAt.timeIntervalSince1970),
        ]
    }
}

public enum ExternalPublicationStoreError: Error {
    case missingItem
    case invalidRow
    case invalidProjection
    case invalidCheckpoint
    case conflictingProjection
    case conflictingItem
}
