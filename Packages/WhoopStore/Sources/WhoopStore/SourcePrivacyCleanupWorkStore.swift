import Foundation
import GRDB

public enum SourcePrivacyCleanupCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case vitals
    case sleep
    case workouts
    case heartRate
}

public enum SourcePrivacyCleanupState: String, Codable, Equatable, Sendable {
    case pending
    case running
    case retryable
    case complete
    case quarantined

    public var isTerminal: Bool {
        self == .complete || self == .quarantined
    }
}

public enum SourcePrivacyCleanupPolicy {
    public static let minimumRearmInterval: TimeInterval = 24 * 60 * 60
    public static let authorizationRetryInterval: TimeInterval = 15 * 60
}

/// One independently leaseable bounded cleanup lane. Cursor bytes are opaque to
/// WhoopStore. The HealthKit adapter owns their Codable representation.
public struct SourcePrivacyCleanupWork: Equatable, Sendable {
    public let cleanupWorkId: UUID
    public let transitionId: UUID
    public let sourceDeviceId: String
    public let category: SourcePrivacyCleanupCategory
    public let remainingImportedIds: Set<String>
    public let remainingComputedIds: Set<String>
    public let firstDay: String
    public let throughDay: String
    public let recordedTimeZoneIdentifier: String
    /// Compatibility spelling for cleanup coordinators that do not persist the
    /// provenance-oriented column name.
    public var timeZoneIdentifier: String { recordedTimeZoneIdentifier }
    public var scanCursor: Data?
    public var cleanupCursor: Data?
    public var state: SourcePrivacyCleanupState
    public var attemptCount: Int
    public var rearmCount: Int
    public var lastRearmedAt: Date?
    public var authorizationBlockedAt: Date?
    public var nextAttemptAt: Date?
    public var leaseOwner: String?
    public var leaseExpiresAt: Date?
    public var lastErrorCode: String?
    public let createdAt: Date
    public var updatedAt: Date

    /// Nil means this lane is not quarantined or can rearm immediately.
    public var nextRearmEligibleAt: Date? {
        guard state == .quarantined, let lastRearmedAt else { return nil }
        return lastRearmedAt.addingTimeInterval(
            SourcePrivacyCleanupPolicy.minimumRearmInterval
        )
    }

    public var isAuthorizationBlocked: Bool {
        authorizationBlockedAt != nil
    }
}

public struct SourcePrivacyCleanupGroup: Equatable, Sendable {
    public let cleanupWorkId: UUID
    public let transitionId: UUID
    public let sourceDeviceId: String
    public let work: [SourcePrivacyCleanupWork]

    public var isTerminal: Bool {
        work.count == SourcePrivacyCleanupCategory.allCases.count
            && work.allSatisfy { $0.state.isTerminal }
    }

    public var completedSuccessfully: Bool {
        work.count == SourcePrivacyCleanupCategory.allCases.count
            && work.allSatisfy { $0.state == .complete }
    }

    public var hasQuarantinedWork: Bool {
        work.contains { $0.state == .quarantined }
    }

    public var hasAuthorizationBlockedWork: Bool {
        work.contains { $0.isAuthorizationBlocked }
    }

    /// A group is ready when its next bounded recovery action can start now.
    /// Quarantine recovery is group-wide, so every quarantined lane must have
    /// reached its cooldown before the group can rearm.
    public func isReadyForRecovery(at now: Date) -> Bool {
        if hasQuarantinedWork {
            return nextRearmEligibleAt.map { $0 <= now } ?? true
        }
        return work.contains { lane in
            switch lane.state {
            case .pending:
                return lane.leaseOwner == nil
            case .retryable:
                return lane.leaseOwner == nil
                    && (lane.nextAttemptAt.map { $0 <= now } ?? true)
            case .running:
                return lane.leaseExpiresAt.map { $0 <= now } ?? false
            case .complete, .quarantined:
                return false
            }
        }
    }

    /// Earliest durable time at which a currently deferred group can make
    /// progress. Nil means the group is ready now or has no timed deferral.
    public var nextRecoveryEligibleAt: Date? {
        if hasQuarantinedWork { return nextRearmEligibleAt }
        return work.compactMap { lane -> Date? in
            switch lane.state {
            case .retryable:
                return lane.nextAttemptAt
            case .running:
                return lane.leaseExpiresAt
            case .pending, .complete, .quarantined:
                return nil
            }
        }.min()
    }

    public var nextAuthorizationRetryAt: Date? {
        work.filter(\.isAuthorizationBlocked).compactMap(\.nextAttemptAt).min()
    }

    /// Latest lane cooldown in the group. Nil means no quarantine cooldown is
    /// active; a quarantined lane with no prior rearm is immediately eligible.
    public var nextRearmEligibleAt: Date? {
        work.compactMap(\.nextRearmEligibleAt).max()
    }
}

public enum SourcePrivacyCleanupStoreError: Error, Equatable, Sendable {
    case invalidWork
    case invalidRow
    case conflictingReplay
    case leaseLost
    case missingWork
    case nothingToRearm
    case rearmCooldownActive(until: Date)
}

struct SourcePrivacyCleanupEvidence: Equatable, Sendable {
    let firstDay: String
    let throughDay: String
    let recordedTimeZoneIdentifier: String
    let hasEvidence: Bool
}

extension WhoopStore {
    private static let sourcePrivacyMaximumAttempts = 12
    private static let sourcePrivacyMaximumCursorBytes = 64 * 1_024

    /// Capture the immutable request envelope before privacy deletion removes
    /// its local evidence. The range includes the deleted source and every
    /// remaining contributor because cleanup must distinguish NOOP-owned
    /// objects from still-valid projected objects in the same HealthKit window.
    static func deriveSourcePrivacyCleanupEvidence(
        deviceIds: Set<String>,
        now: Date,
        in db: Database
    ) throws -> SourcePrivacyCleanupEvidence {
        let sources = deviceIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        guard !sources.isEmpty else {
            throw SourcePrivacyCleanupStoreError.invalidWork
        }
        let tables = Set(try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
        ))
        let placeholders = Array(repeating: "?", count: sources.count)
            .joined(separator: ",")
        let sourceArguments = StatementArguments(sources)

        var timeZoneIdentifier: String?
        let timeZoneTables: [(String, String)] = [
            ("verifiedSnapshotCommit", "createdAt"),
            ("externalPublicationOutbox", "updatedAt"),
            ("historicalAnalysisWork", "updatedAt"),
        ]
        for (table, orderColumn) in timeZoneTables where tables.contains(table) {
            let columns = Set(try db.columns(in: table).map(\.name))
            guard columns.isSuperset(of: [
                "deviceId", "recordedTimeZoneIdentifier", orderColumn,
            ]) else { continue }
            let candidate: String? = try String.fetchOne(db, sql: """
                SELECT recordedTimeZoneIdentifier FROM \(table)
                WHERE deviceId IN (\(placeholders))
                ORDER BY \(orderColumn) DESC LIMIT 1
                """, arguments: sourceArguments)
            if let candidate, TimeZone(identifier: candidate) != nil {
                timeZoneIdentifier = candidate
                break
            }
        }
        let resolvedTimeZoneIdentifier = timeZoneIdentifier
            ?? (TimeZone(identifier: TimeZone.current.identifier) != nil
                ? TimeZone.current.identifier
                : "UTC")
        guard let timeZone = TimeZone(identifier: resolvedTimeZoneIdentifier) else {
            throw SourcePrivacyCleanupStoreError.invalidWork
        }

        var firstDay: String?
        var throughDay: String?
        func admit(first: String?, through: String?) {
            if let first, Self.isValidPrivacyCleanupDay(first) {
                firstDay = firstDay.map { min($0, first) } ?? first
            }
            if let through, Self.isValidPrivacyCleanupDay(through) {
                throughDay = throughDay.map { max($0, through) } ?? through
            }
        }

        let dayColumns: [(String, String)] = [
            ("dailyMetric", "day"),
            ("appleDaily", "day"),
            ("metricSeries", "day"),
            ("journal", "day"),
            ("sleepRecoveryDailyOverride", "day"),
            ("healthKitSleepDayLedger", "wakeDay"),
            ("healthKitSleepKeyLedger", "wakeDay"),
            ("todayHealthSnapshot", "displayDay"),
            ("todayHealthSnapshot", "logicalDay"),
            ("todayHealthSnapshot", "localDay"),
            ("latestStateDeliveryCheckpoint", "logicalDay"),
            ("healthKitMutationWatermark", "day"),
        ]
        for (table, dayColumn) in dayColumns where tables.contains(table) {
            let columns = Set(try db.columns(in: table).map(\.name))
            guard columns.isSuperset(of: ["deviceId", dayColumn]) else { continue }
            if let row = try Row.fetchOne(db, sql: """
                SELECT MIN(\(dayColumn)) AS firstDay,
                       MAX(\(dayColumn)) AS throughDay
                FROM \(table)
                WHERE deviceId IN (\(placeholders))
                  AND date(\(dayColumn)) IS NOT NULL
                """, arguments: sourceArguments) {
                admit(first: row["firstDay"], through: row["throughDay"])
            }
        }

        var firstTimestamp: Int?
        var throughTimestamp: Int?
        let timestampColumns: [(String, String, String)] = [
            ("sleepSession", "startTs", "endTs"),
            ("workout", "startTs", "endTs"),
            ("healthKitObjectIndex", "startTs", "endTs"),
            ("sleepRecoveryAttempt", "requestedStartTs", "requestedEndTs"),
            ("hrSample", "ts", "ts"),
            ("ppgHrSample", "ts", "ts"),
        ]
        for (table, startColumn, endColumn) in timestampColumns where tables.contains(table) {
            let columns = Set(try db.columns(in: table).map(\.name))
            guard columns.isSuperset(of: ["deviceId", startColumn, endColumn]) else { continue }
            if let row = try Row.fetchOne(db, sql: """
                SELECT MIN(\(startColumn)) AS firstTimestamp,
                       MAX(\(endColumn)) AS throughTimestamp
                FROM \(table)
                WHERE deviceId IN (\(placeholders))
                  AND \(startColumn) >= 0 AND \(endColumn) >= 0
                """, arguments: sourceArguments) {
                let first: Int? = row["firstTimestamp"]
                let through: Int? = row["throughTimestamp"]
                if let first {
                    firstTimestamp = firstTimestamp.map { min($0, first) } ?? first
                }
                if let through {
                    throughTimestamp = throughTimestamp.map { max($0, through) } ?? through
                }
            }
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        if let firstTimestamp {
            admit(
                first: formatter.string(from: Date(
                    timeIntervalSince1970: TimeInterval(firstTimestamp)
                )),
                through: nil
            )
        }
        if let throughTimestamp {
            admit(
                first: nil,
                through: formatter.string(from: Date(
                    timeIntervalSince1970: TimeInterval(throughTimestamp)
                ))
            )
        }

        let hasEvidence = firstDay != nil || throughDay != nil
        let currentDay = formatter.string(from: now)
        let resolvedFirst = firstDay ?? throughDay ?? currentDay
        let resolvedThrough = throughDay ?? firstDay ?? currentDay
        guard Self.isValidPrivacyCleanupDay(resolvedFirst),
              Self.isValidPrivacyCleanupDay(resolvedThrough),
              resolvedFirst <= resolvedThrough else {
            throw SourcePrivacyCleanupStoreError.invalidWork
        }
        return SourcePrivacyCleanupEvidence(
            firstDay: resolvedFirst,
            throughDay: resolvedThrough,
            recordedTimeZoneIdentifier: resolvedTimeZoneIdentifier,
            hasEvidence: hasEvidence
        )
    }

    /// Read the four category rows as one transition-owned cleanup group.
    public func sourcePrivacyCleanupGroup(
        cleanupWorkId: UUID
    ) async throws -> SourcePrivacyCleanupGroup? {
        try syncRead { db in
            try Self.decodeSourcePrivacyCleanupGroup(
                cleanupWorkId: cleanupWorkId,
                in: db
            )
        }
    }

    /// Count every unresolved row. Quarantined work remains visible so launch
    /// recovery and background scheduling cannot mistake it for completion.
    public func unresolvedSourcePrivacyCleanupCount() async throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sourcePrivacyCleanupWork
                WHERE state != 'complete'
                """) ?? 0
        }
    }

    /// Compatibility spelling. "Pending" means durable work that is not
    /// complete, including a quarantined row that requires bounded rearming.
    public func pendingSourcePrivacyCleanupCount() async throws -> Int {
        try await unresolvedSourcePrivacyCleanupCount()
    }

    /// Return transition-owned groups with at least one unresolved category.
    /// The limit bounds both the SQL result and group decoding work.
    public func unresolvedSourcePrivacyCleanupGroups(
        limit: Int = 100
    ) async throws -> [SourcePrivacyCleanupGroup] {
        guard (1...1_000).contains(limit) else {
            throw SourcePrivacyCleanupStoreError.invalidWork
        }
        return try syncRead { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT cleanupWorkId
                FROM sourcePrivacyCleanupWork
                GROUP BY cleanupWorkId
                HAVING SUM(CASE WHEN state != 'complete' THEN 1 ELSE 0 END) > 0
                ORDER BY MIN(createdAt) ASC, cleanupWorkId ASC
                LIMIT ?
                """, arguments: [limit])
            return try ids.map { rawId in
                guard let cleanupWorkId = UUID(uuidString: rawId),
                      let group = try Self.decodeSourcePrivacyCleanupGroup(
                          cleanupWorkId: cleanupWorkId,
                          in: db
                      ) else {
                    throw SourcePrivacyCleanupStoreError.invalidRow
                }
                return group
            }
        }
    }

    /// Return a bounded recovery page with ready groups first. This prevents
    /// an older authorization or quarantine delay from starving newer ready
    /// privacy work. Deferred groups are ordered by their next durable retry.
    public func sourcePrivacyCleanupDrainCandidates(
        now: Date = Date(),
        limit: Int = 100
    ) async throws -> [SourcePrivacyCleanupGroup] {
        let nowInterval = now.timeIntervalSince1970
        guard nowInterval.isFinite, nowInterval >= 0,
              nowInterval <= Double(Int.max),
              (1...1_000).contains(limit) else {
            throw SourcePrivacyCleanupStoreError.invalidWork
        }
        let nowSeconds = Int(nowInterval)
        let rearmInterval = Int(SourcePrivacyCleanupPolicy.minimumRearmInterval)
        return try syncRead { db in
            let ids = try String.fetchAll(db, sql: """
                WITH cleanupGroups AS (
                    SELECT cleanupWorkId,
                           MIN(createdAt) AS groupCreatedAt,
                           SUM(CASE WHEN state = 'quarantined' THEN 1 ELSE 0 END)
                               AS quarantinedCount,
                           SUM(CASE
                               WHEN state = 'quarantined'
                                AND lastRearmedAt IS NOT NULL
                                AND lastRearmedAt + ? > ?
                               THEN 1 ELSE 0 END) AS blockedQuarantineCount,
                           SUM(CASE
                               WHEN state = 'pending' AND leaseOwner IS NULL THEN 1
                               WHEN state = 'retryable' AND leaseOwner IS NULL
                                AND (nextAttemptAt IS NULL OR nextAttemptAt <= ?) THEN 1
                               WHEN state = 'running' AND leaseExpiresAt IS NOT NULL
                                AND leaseExpiresAt <= ? THEN 1
                               ELSE 0 END) AS readyLaneCount,
                           MAX(CASE
                               WHEN state = 'quarantined' AND lastRearmedAt IS NOT NULL
                               THEN lastRearmedAt + ? ELSE ? END)
                               AS quarantineEligibleAt,
                           MIN(CASE
                               WHEN state = 'retryable'
                               THEN COALESCE(nextAttemptAt, ?)
                               WHEN state = 'running'
                               THEN COALESCE(leaseExpiresAt, 9223372036854775807)
                               WHEN state = 'pending' THEN ?
                               ELSE 9223372036854775807 END)
                               AS laneEligibleAt
                    FROM sourcePrivacyCleanupWork
                    WHERE state != 'complete'
                    GROUP BY cleanupWorkId
                )
                SELECT cleanupWorkId FROM cleanupGroups
                ORDER BY CASE
                    WHEN quarantinedCount > 0
                    THEN CASE WHEN blockedQuarantineCount = 0 THEN 0 ELSE 1 END
                    WHEN readyLaneCount > 0 THEN 0
                    ELSE 1 END ASC,
                    CASE WHEN quarantinedCount > 0
                         THEN quarantineEligibleAt ELSE laneEligibleAt END ASC,
                    groupCreatedAt ASC,
                    cleanupWorkId ASC
                LIMIT ?
                """, arguments: [
                    rearmInterval,
                    nowSeconds,
                    nowSeconds,
                    nowSeconds,
                    rearmInterval,
                    nowSeconds,
                    nowSeconds,
                    nowSeconds,
                    limit,
                ])
            return try ids.map { rawId in
                guard let cleanupWorkId = UUID(uuidString: rawId),
                      let group = try Self.decodeSourcePrivacyCleanupGroup(
                          cleanupWorkId: cleanupWorkId,
                          in: db
                      ) else {
                    throw SourcePrivacyCleanupStoreError.invalidRow
                }
                return group
            }
        }
    }

    /// Rearm only quarantined lanes in one group. A durable cooldown bounds
    /// automatic churn without creating a lifetime cap. Complete lanes and all
    /// immutable request evidence stay unchanged. The transaction either
    /// rearms every quarantined lane or none.
    public func rearmQuarantinedSourcePrivacyCleanupGroup(
        cleanupWorkId: UUID,
        now: Date = Date()
    ) async throws -> SourcePrivacyCleanupGroup {
        let nowInterval = now.timeIntervalSince1970
        guard nowInterval.isFinite, nowInterval >= 0,
              nowInterval <= Double(Int.max) else {
            throw SourcePrivacyCleanupStoreError.invalidWork
        }
        let nowSeconds = Int(nowInterval)
        return try syncWrite { db in
            guard let group = try Self.decodeSourcePrivacyCleanupGroup(
                cleanupWorkId: cleanupWorkId,
                in: db
            ) else {
                throw SourcePrivacyCleanupStoreError.missingWork
            }
            let quarantined = group.work.filter { $0.state == .quarantined }
            guard !quarantined.isEmpty else {
                throw SourcePrivacyCleanupStoreError.nothingToRearm
            }
            if let nextEligibleAt = quarantined
                .compactMap(\.nextRearmEligibleAt)
                .max(), nextEligibleAt > now {
                throw SourcePrivacyCleanupStoreError.rearmCooldownActive(
                    until: nextEligibleAt
                )
            }

            try db.execute(sql: """
                UPDATE sourcePrivacyCleanupWork
                SET state = 'retryable', attemptCount = 0,
                    rearmCount = CASE
                        WHEN rearmCount < 9223372036854775807
                        THEN rearmCount + 1 ELSE rearmCount END,
                    lastRearmedAt = ?,
                    nextAttemptAt = NULL, leaseOwner = NULL,
                    leaseExpiresAt = NULL, updatedAt = ?
                WHERE cleanupWorkId = ? AND state = 'quarantined'
                """, arguments: [
                    nowSeconds,
                    nowSeconds,
                    cleanupWorkId.uuidString,
                ])
            guard db.changesCount == quarantined.count,
                  let rearmed = try Self.decodeSourcePrivacyCleanupGroup(
                      cleanupWorkId: cleanupWorkId,
                      in: db
                  ) else {
                throw SourcePrivacyCleanupStoreError.conflictingReplay
            }
            return rearmed
        }
    }

    /// Persist an environmental authorization gate without consuming a retry.
    /// The same bounded lane becomes eligible again after the durable delay.
    public func blockSourcePrivacyCleanupWorkForAuthorization(
        _ work: SourcePrivacyCleanupWork,
        owner: String,
        now: Date = Date()
    ) async throws -> SourcePrivacyCleanupWork {
        let normalizedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let nowInterval = now.timeIntervalSince1970
        guard !normalizedOwner.isEmpty,
              nowInterval.isFinite, nowInterval >= 0,
              nowInterval <= Double(Int.max)
                - SourcePrivacyCleanupPolicy.authorizationRetryInterval else {
            throw SourcePrivacyCleanupStoreError.invalidWork
        }
        let nowSeconds = Int(nowInterval)
        let nextAttemptAt = Int(now.addingTimeInterval(
            SourcePrivacyCleanupPolicy.authorizationRetryInterval
        ).timeIntervalSince1970)
        return try syncWrite { db in
            try db.execute(sql: """
                UPDATE sourcePrivacyCleanupWork
                SET state = 'retryable', nextAttemptAt = ?,
                    leaseOwner = NULL, leaseExpiresAt = NULL,
                    authorizationBlockedAt = ?,
                    lastErrorCode = 'authorization_unavailable', updatedAt = ?
                WHERE cleanupWorkId = ? AND category = ?
                  AND state = 'running' AND leaseOwner = ?
                  AND leaseExpiresAt > ?
                """, arguments: [
                    nextAttemptAt,
                    nowSeconds,
                    nowSeconds,
                    work.cleanupWorkId.uuidString,
                    work.category.rawValue,
                    normalizedOwner,
                    nowSeconds,
                ])
            guard db.changesCount == 1 else {
                throw SourcePrivacyCleanupStoreError.leaseLost
            }
            return try Self.fetchSourcePrivacyCleanupWork(
                cleanupWorkId: work.cleanupWorkId,
                category: work.category,
                in: db
            )
        }
    }

    /// Lease one category only. A single worker call therefore cannot expand
    /// into an unbounded full-history HealthKit operation.
    public func leaseNextSourcePrivacyCleanupWork(
        owner: String,
        now: Date = Date(),
        leaseDuration: TimeInterval = 90,
        cleanupWorkId: UUID? = nil
    ) async throws -> SourcePrivacyCleanupWork? {
        let normalizedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOwner.isEmpty, now.timeIntervalSinceReferenceDate.isFinite else {
            throw SourcePrivacyCleanupStoreError.invalidWork
        }
        let nowSeconds = Int(now.timeIntervalSince1970)
        let boundedLease = min(5 * 60, max(15, leaseDuration))
        let leaseExpiresAt = Int(now.addingTimeInterval(boundedLease).timeIntervalSince1970)

        return try syncWrite { db in
            let expired = try Row.fetchAll(db, sql: """
                SELECT * FROM sourcePrivacyCleanupWork
                WHERE state = 'running' AND leaseExpiresAt IS NOT NULL
                  AND leaseExpiresAt <= ?
                """, arguments: [nowSeconds])
            for row in expired {
                let work = try Self.decodeSourcePrivacyCleanupWork(row)
                try Self.failSourcePrivacyCleanupWork(
                    work,
                    owner: work.leaseOwner,
                    code: "lease_expired",
                    retryable: true,
                    now: now,
                    requireUnexpiredLease: false,
                    in: db
                )
            }

            let row: Row?
            if let cleanupWorkId {
                row = try Row.fetchOne(db, sql: """
                    SELECT * FROM sourcePrivacyCleanupWork
                    WHERE cleanupWorkId = ?
                      AND state IN ('pending','retryable')
                      AND leaseOwner IS NULL
                      AND (nextAttemptAt IS NULL OR nextAttemptAt <= ?)
                    ORDER BY CASE category
                        WHEN 'vitals' THEN 0 WHEN 'sleep' THEN 1
                        WHEN 'workouts' THEN 2 ELSE 3 END,
                        createdAt ASC
                    LIMIT 1
                    """, arguments: [cleanupWorkId.uuidString, nowSeconds])
            } else {
                row = try Row.fetchOne(db, sql: """
                    SELECT * FROM sourcePrivacyCleanupWork
                    WHERE state IN ('pending','retryable')
                      AND leaseOwner IS NULL
                      AND (nextAttemptAt IS NULL OR nextAttemptAt <= ?)
                    ORDER BY createdAt ASC, CASE category
                        WHEN 'vitals' THEN 0 WHEN 'sleep' THEN 1
                        WHEN 'workouts' THEN 2 ELSE 3 END
                    LIMIT 1
                    """, arguments: [nowSeconds])
            }
            guard let row else { return nil }
            let candidate = try Self.decodeSourcePrivacyCleanupWork(row)
            try db.execute(sql: """
                UPDATE sourcePrivacyCleanupWork
                SET state = 'running', leaseOwner = ?, leaseExpiresAt = ?,
                    authorizationBlockedAt = NULL, updatedAt = ?
                WHERE cleanupWorkId = ? AND category = ?
                  AND state IN ('pending','retryable') AND leaseOwner IS NULL
                """, arguments: [
                    normalizedOwner,
                    leaseExpiresAt,
                    nowSeconds,
                    candidate.cleanupWorkId.uuidString,
                    candidate.category.rawValue,
                ])
            guard db.changesCount == 1 else { return nil }
            guard let leased = try Row.fetchOne(db, sql: """
                SELECT * FROM sourcePrivacyCleanupWork
                WHERE cleanupWorkId = ? AND category = ?
                """, arguments: [
                    candidate.cleanupWorkId.uuidString,
                    candidate.category.rawValue,
                ]) else {
                throw SourcePrivacyCleanupStoreError.missingWork
            }
            return try Self.decodeSourcePrivacyCleanupWork(leased)
        }
    }

    /// Persist one bounded batch and release its lease. The caller must report
    /// both limits. This rejects accidental full-history or unlimited queries.
    public func persistSourcePrivacyCleanupCursors(
        _ work: SourcePrivacyCleanupWork,
        owner: String,
        scanCursor: Data?,
        cleanupCursor: Data?,
        batchDayCount: Int,
        batchObjectCount: Int,
        hasMore: Bool,
        now: Date = Date()
    ) async throws -> SourcePrivacyCleanupWork {
        guard (0...30).contains(batchDayCount),
              (0...5_000).contains(batchObjectCount),
              scanCursor.map({ $0.count <= Self.sourcePrivacyMaximumCursorBytes }) ?? true,
              cleanupCursor.map({ $0.count <= Self.sourcePrivacyMaximumCursorBytes }) ?? true,
              !hasMore || scanCursor != nil || cleanupCursor != nil else {
            throw SourcePrivacyCleanupStoreError.invalidWork
        }
        let normalizedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOwner.isEmpty else {
            throw SourcePrivacyCleanupStoreError.invalidWork
        }
        let state: SourcePrivacyCleanupState = hasMore ? .retryable : .complete
        let nowSeconds = Int(now.timeIntervalSince1970)
        return try syncWrite { db in
            try db.execute(sql: """
                UPDATE sourcePrivacyCleanupWork
                SET scanCursorJSON = ?, cleanupCursorJSON = ?, state = ?,
                    nextAttemptAt = ?, leaseOwner = NULL, leaseExpiresAt = NULL,
                    authorizationBlockedAt = NULL,
                    lastErrorCode = NULL, updatedAt = ?
                WHERE cleanupWorkId = ? AND category = ?
                  AND state = 'running' AND leaseOwner = ?
                  AND leaseExpiresAt > ?
                """, arguments: [
                    scanCursor,
                    cleanupCursor,
                    state.rawValue,
                    hasMore ? nowSeconds : nil,
                    nowSeconds,
                    work.cleanupWorkId.uuidString,
                    work.category.rawValue,
                    normalizedOwner,
                    nowSeconds,
                ])
            guard db.changesCount == 1 else {
                throw SourcePrivacyCleanupStoreError.leaseLost
            }
            return try Self.fetchSourcePrivacyCleanupWork(
                cleanupWorkId: work.cleanupWorkId,
                category: work.category,
                in: db
            )
        }
    }

    public func completeSourcePrivacyCleanupWork(
        _ work: SourcePrivacyCleanupWork,
        owner: String,
        now: Date = Date()
    ) async throws -> SourcePrivacyCleanupWork {
        try await persistSourcePrivacyCleanupCursors(
            work,
            owner: owner,
            scanCursor: work.scanCursor,
            cleanupCursor: work.cleanupCursor,
            batchDayCount: 0,
            batchObjectCount: 0,
            hasMore: false,
            now: now
        )
    }

    public func failSourcePrivacyCleanupWork(
        _ work: SourcePrivacyCleanupWork,
        owner: String,
        code: String,
        retryable: Bool,
        now: Date = Date()
    ) async throws -> SourcePrivacyCleanupWork {
        let normalizedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOwner.isEmpty, !normalizedCode.isEmpty,
              normalizedCode.count <= 256 else {
            throw SourcePrivacyCleanupStoreError.invalidWork
        }
        return try syncWrite { db in
            try Self.failSourcePrivacyCleanupWork(
                work,
                owner: normalizedOwner,
                code: normalizedCode,
                retryable: retryable,
                now: now,
                requireUnexpiredLease: true,
                in: db
            )
            return try Self.fetchSourcePrivacyCleanupWork(
                cleanupWorkId: work.cleanupWorkId,
                category: work.category,
                in: db
            )
        }
    }

    public func cancelSourcePrivacyCleanupLease(
        _ work: SourcePrivacyCleanupWork,
        owner: String,
        now: Date = Date()
    ) async throws -> SourcePrivacyCleanupWork {
        let normalizedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOwner.isEmpty else {
            throw SourcePrivacyCleanupStoreError.invalidWork
        }
        let nowSeconds = Int(now.timeIntervalSince1970)
        return try syncWrite { db in
            try db.execute(sql: """
                UPDATE sourcePrivacyCleanupWork
                SET state = 'retryable', nextAttemptAt = NULL,
                    leaseOwner = NULL, leaseExpiresAt = NULL,
                    authorizationBlockedAt = NULL,
                    lastErrorCode = 'owner_cancelled', updatedAt = ?
                WHERE cleanupWorkId = ? AND category = ?
                  AND state = 'running' AND leaseOwner = ?
                """, arguments: [
                    nowSeconds,
                    work.cleanupWorkId.uuidString,
                    work.category.rawValue,
                    normalizedOwner,
                ])
            guard db.changesCount == 1 else {
                throw SourcePrivacyCleanupStoreError.leaseLost
            }
            return try Self.fetchSourcePrivacyCleanupWork(
                cleanupWorkId: work.cleanupWorkId,
                category: work.category,
                in: db
            )
        }
    }

    /// Called only inside `commitSourceLifecycleMutation`'s writer transaction.
    /// All four rows appear with the lifecycle commit or none appear.
    static func enqueueSourcePrivacyCleanupGroup(
        cleanupWorkId: UUID,
        transitionId: UUID,
        sourceDeviceId: String,
        remainingImportedIds: Set<String>,
        remainingComputedIds: Set<String>,
        evidence: SourcePrivacyCleanupEvidence,
        now: Date,
        in db: Database
    ) throws {
        let source = sourceDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty,
              remainingImportedIds.allSatisfy({ !$0.isEmpty }),
              remainingComputedIds.allSatisfy({ !$0.isEmpty }),
              remainingImportedIds.isDisjoint(with: remainingComputedIds),
              !remainingImportedIds.contains(source),
              !remainingComputedIds.contains(source + "-noop"),
              Self.isValidPrivacyCleanupDay(evidence.firstDay),
              Self.isValidPrivacyCleanupDay(evidence.throughDay),
              evidence.firstDay <= evidence.throughDay,
              TimeZone(identifier: evidence.recordedTimeZoneIdentifier) != nil else {
            throw SourcePrivacyCleanupStoreError.invalidWork
        }
        guard let transition = try Row.fetchOne(db, sql: """
            SELECT mutationKind, sourceDeviceId, cleanupWorkId
            FROM sourceTransitionJournal WHERE transitionId = ?
            """, arguments: [transitionId.uuidString]) else {
            throw SourcePrivacyCleanupStoreError.invalidWork
        }
        let storedCleanupWorkId: String? = transition["cleanupWorkId"]
        guard (transition["mutationKind"] as String) == "deleteData",
              (transition["sourceDeviceId"] as String) == source,
              storedCleanupWorkId == cleanupWorkId.uuidString else {
            throw SourcePrivacyCleanupStoreError.conflictingReplay
        }

        let existing = try Row.fetchAll(db, sql: """
            SELECT * FROM sourcePrivacyCleanupWork WHERE cleanupWorkId = ?
            """, arguments: [cleanupWorkId.uuidString])
        if !existing.isEmpty {
            guard existing.count == SourcePrivacyCleanupCategory.allCases.count else {
                throw SourcePrivacyCleanupStoreError.conflictingReplay
            }
            let decoded = try existing.map(Self.decodeSourcePrivacyCleanupWork)
            guard decoded.allSatisfy({
                $0.transitionId == transitionId
                    && $0.sourceDeviceId == source
                    && $0.remainingImportedIds == remainingImportedIds
                    && $0.remainingComputedIds == remainingComputedIds
                    && $0.firstDay == evidence.firstDay
                    && $0.throughDay == evidence.throughDay
                    && $0.recordedTimeZoneIdentifier == evidence.recordedTimeZoneIdentifier
            }), Set(decoded.map(\.category)) == Set(SourcePrivacyCleanupCategory.allCases) else {
                throw SourcePrivacyCleanupStoreError.conflictingReplay
            }
            return
        }

        let timestamp = Int(now.timeIntervalSince1970)
        let remainingImportedJSON = try JSONEncoder().encode(remainingImportedIds)
        let remainingComputedJSON = try JSONEncoder().encode(remainingComputedIds)
        for category in SourcePrivacyCleanupCategory.allCases {
            try db.execute(sql: """
                INSERT INTO sourcePrivacyCleanupWork (
                    cleanupWorkId, transitionId, sourceDeviceId, category,
                    remainingImportedIdsJSON, remainingComputedIdsJSON,
                    firstDay, throughDay, recordedTimeZoneIdentifier,
                    scanCursorJSON, cleanupCursorJSON, state, attemptCount,
                    nextAttemptAt, leaseOwner, leaseExpiresAt, lastErrorCode,
                    createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, 0,
                          NULL, NULL, NULL, NULL, ?, ?)
                """, arguments: [
                    cleanupWorkId.uuidString,
                    transitionId.uuidString,
                    source,
                    category.rawValue,
                    remainingImportedJSON,
                    remainingComputedJSON,
                    evidence.firstDay,
                    evidence.throughDay,
                    evidence.recordedTimeZoneIdentifier,
                    evidence.hasEvidence
                        ? SourcePrivacyCleanupState.pending.rawValue
                        : SourcePrivacyCleanupState.complete.rawValue,
                    timestamp,
                    timestamp,
                ])
        }
    }

    private static func failSourcePrivacyCleanupWork(
        _ work: SourcePrivacyCleanupWork,
        owner: String?,
        code: String,
        retryable: Bool,
        now: Date,
        requireUnexpiredLease: Bool,
        in db: Database
    ) throws {
        let nextAttemptCount = work.attemptCount + 1
        let mayRetry = retryable && nextAttemptCount < sourcePrivacyMaximumAttempts
        let state: SourcePrivacyCleanupState = mayRetry ? .retryable : .quarantined
        let delay = min(6 * 60 * 60, pow(2.0, Double(min(work.attemptCount, 8))) * 30)
        let nextAttemptAt = mayRetry
            ? Int(now.addingTimeInterval(delay).timeIntervalSince1970)
            : nil
        var sql = """
            UPDATE sourcePrivacyCleanupWork
            SET state = ?, attemptCount = attemptCount + 1,
                nextAttemptAt = ?, leaseOwner = NULL, leaseExpiresAt = NULL,
                authorizationBlockedAt = NULL, lastErrorCode = ?, updatedAt = ?
            WHERE cleanupWorkId = ? AND category = ?
              AND state = 'running'
            """
        var arguments: [DatabaseValueConvertible?] = [
            state.rawValue,
            nextAttemptAt,
            mayRetry ? code : "retry_limit_exceeded:" + code,
            Int(now.timeIntervalSince1970),
            work.cleanupWorkId.uuidString,
            work.category.rawValue,
        ]
        if let owner {
            sql += " AND leaseOwner = ?"
            arguments.append(owner)
        }
        if requireUnexpiredLease {
            sql += " AND leaseExpiresAt > ?"
            arguments.append(Int(now.timeIntervalSince1970))
        }
        try db.execute(sql: sql, arguments: StatementArguments(arguments))
        guard db.changesCount == 1 else {
            throw SourcePrivacyCleanupStoreError.leaseLost
        }
    }

    private static func decodeSourcePrivacyCleanupGroup(
        cleanupWorkId: UUID,
        in db: Database
    ) throws -> SourcePrivacyCleanupGroup? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM sourcePrivacyCleanupWork
            WHERE cleanupWorkId = ?
            ORDER BY CASE category
                WHEN 'vitals' THEN 0 WHEN 'sleep' THEN 1
                WHEN 'workouts' THEN 2 ELSE 3 END
            """, arguments: [cleanupWorkId.uuidString])
        guard !rows.isEmpty else { return nil }
        let work = try rows.map(Self.decodeSourcePrivacyCleanupWork)
        guard work.count == SourcePrivacyCleanupCategory.allCases.count,
              Set(work.map(\.category)) == Set(SourcePrivacyCleanupCategory.allCases),
              let first = work.first,
              work.allSatisfy({
                  $0.cleanupWorkId == cleanupWorkId
                    && $0.transitionId == first.transitionId
                    && $0.sourceDeviceId == first.sourceDeviceId
              }) else {
            throw SourcePrivacyCleanupStoreError.invalidRow
        }
        return SourcePrivacyCleanupGroup(
            cleanupWorkId: cleanupWorkId,
            transitionId: first.transitionId,
            sourceDeviceId: first.sourceDeviceId,
            work: work
        )
    }

    private static func fetchSourcePrivacyCleanupWork(
        cleanupWorkId: UUID,
        category: SourcePrivacyCleanupCategory,
        in db: Database
    ) throws -> SourcePrivacyCleanupWork {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT * FROM sourcePrivacyCleanupWork
            WHERE cleanupWorkId = ? AND category = ?
            """, arguments: [cleanupWorkId.uuidString, category.rawValue]) else {
            throw SourcePrivacyCleanupStoreError.missingWork
        }
        return try decodeSourcePrivacyCleanupWork(row)
    }

    private static func decodeSourcePrivacyCleanupWork(
        _ row: Row
    ) throws -> SourcePrivacyCleanupWork {
        let cleanupIdRaw: String = row["cleanupWorkId"]
        let transitionIdRaw: String = row["transitionId"]
        let sourceDeviceId: String = row["sourceDeviceId"]
        let attemptCount: Int = row["attemptCount"]
        let rearmCount: Int = row["rearmCount"]
        let lastRearmedSeconds: Int? = row["lastRearmedAt"]
        let authorizationBlockedSeconds: Int? = row["authorizationBlockedAt"]
        let createdAtSeconds: Int = row["createdAt"]
        let updatedAtSeconds: Int = row["updatedAt"]
        let nextAttemptSeconds: Int? = row["nextAttemptAt"]
        let leaseOwner: String? = row["leaseOwner"]
        let leaseExpiresSeconds: Int? = row["leaseExpiresAt"]
        let scanCursor: Data? = row["scanCursorJSON"]
        let cleanupCursor: Data? = row["cleanupCursorJSON"]
        let importedData: Data = row["remainingImportedIdsJSON"]
        let computedData: Data = row["remainingComputedIdsJSON"]
        let firstDay: String = row["firstDay"]
        let throughDay: String = row["throughDay"]
        let recordedTimeZoneIdentifier: String = row["recordedTimeZoneIdentifier"]
        guard let remainingImportedIds = try? JSONDecoder().decode(
                  Set<String>.self,
                  from: importedData
              ), let remainingComputedIds = try? JSONDecoder().decode(
                  Set<String>.self,
                  from: computedData
              ) else {
            throw SourcePrivacyCleanupStoreError.invalidRow
        }
        guard let cleanupWorkId = UUID(uuidString: cleanupIdRaw),
              let transitionId = UUID(uuidString: transitionIdRaw),
              !sourceDeviceId.isEmpty,
              let category = SourcePrivacyCleanupCategory(rawValue: row["category"]),
              let state = SourcePrivacyCleanupState(rawValue: row["state"]),
              attemptCount >= 0,
              rearmCount >= 0,
              (rearmCount == 0) == (lastRearmedSeconds == nil),
              lastRearmedSeconds.map({ $0 >= 0 }) ?? true,
              authorizationBlockedSeconds.map({ $0 >= 0 }) ?? true,
              createdAtSeconds >= 0,
              updatedAtSeconds >= 0,
              scanCursor.map({ $0.count <= sourcePrivacyMaximumCursorBytes }) ?? true,
              cleanupCursor.map({ $0.count <= sourcePrivacyMaximumCursorBytes }) ?? true,
              remainingImportedIds.isDisjoint(with: remainingComputedIds),
              !remainingImportedIds.contains(sourceDeviceId),
              !remainingComputedIds.contains(sourceDeviceId + "-noop"),
              isValidPrivacyCleanupDay(firstDay),
              isValidPrivacyCleanupDay(throughDay),
              firstDay <= throughDay,
              TimeZone(identifier: recordedTimeZoneIdentifier) != nil,
              (leaseOwner == nil) == (leaseExpiresSeconds == nil),
              (state != .running || leaseOwner != nil),
              (authorizationBlockedSeconds == nil
                || state == .retryable || state == .running),
              (authorizationBlockedSeconds == nil
                || nextAttemptSeconds != nil || state == .running),
              (!state.isTerminal || leaseOwner == nil) else {
            throw SourcePrivacyCleanupStoreError.invalidRow
        }
        return SourcePrivacyCleanupWork(
            cleanupWorkId: cleanupWorkId,
            transitionId: transitionId,
            sourceDeviceId: sourceDeviceId,
            category: category,
            remainingImportedIds: remainingImportedIds,
            remainingComputedIds: remainingComputedIds,
            firstDay: firstDay,
            throughDay: throughDay,
            recordedTimeZoneIdentifier: recordedTimeZoneIdentifier,
            scanCursor: scanCursor,
            cleanupCursor: cleanupCursor,
            state: state,
            attemptCount: attemptCount,
            rearmCount: rearmCount,
            lastRearmedAt: lastRearmedSeconds.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            authorizationBlockedAt: authorizationBlockedSeconds.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            nextAttemptAt: nextAttemptSeconds.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            leaseOwner: leaseOwner,
            leaseExpiresAt: leaseExpiresSeconds.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            lastErrorCode: row["lastErrorCode"],
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtSeconds)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAtSeconds))
        )
    }

    private static func isValidPrivacyCleanupDay(_ day: String) -> Bool {
        guard day.utf8.count == 10 else { return false }
        let bytes = Array(day.utf8)
        guard bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (48...57).contains(byte)
              }) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            year: Int(day.prefix(4)),
            month: Int(day.dropFirst(5).prefix(2)),
            day: Int(day.suffix(2))
        )
        guard let date = calendar.date(from: components) else { return false }
        let recovered = calendar.dateComponents([.year, .month, .day], from: date)
        return recovered.year == components.year
            && recovered.month == components.month
            && recovered.day == components.day
    }
}
