import Foundation
import GRDB

/// One metric carried by the durable dashboard first-paint snapshot.
///
/// `value` stays on its storage axis. In particular, Strain is the canonical NOOP 0...100 value;
/// presentation converts it to a WHOOP-style 0...21 value only at the UI boundary.
public struct TodayHealthMetricValue: Codable, Equatable, Sendable {
    public let value: Double
    /// Local calendar day this value describes. New snapshots always set this. Legacy snapshots may omit it.
    /// Recovery, Strain, and Sleep do not necessarily describe the same physiological day at rollover.
    public let metricDay: String?
    /// The source that supplied this exact value, such as `my-whoop-noop` or `apple-health`.
    public let sourceId: String
    /// When the source's own value was observed or computed, when known.
    public let observedAt: Int?
    /// The newest raw biometric timestamp consumed by the source calculation, when known.
    public let rawFrontierTs: Int?
    /// Explicit model/reducer identity. A reader must not treat a different algorithm as interchangeable.
    public let algorithmVersion: String?
    /// Present only for the canonical Strain V2 value.
    public let strainVersion: Int?

    public init(value: Double, metricDay: String? = nil, sourceId: String, observedAt: Int? = nil,
                rawFrontierTs: Int? = nil, algorithmVersion: String? = nil,
                strainVersion: Int? = nil) {
        self.value = value
        self.metricDay = metricDay
        self.sourceId = sourceId
        self.observedAt = observedAt
        self.rawFrontierTs = rawFrontierTs
        self.algorithmVersion = algorithmVersion
        self.strainVersion = strainVersion
    }
}

/// Identity of the source and database generation that produced a dashboard snapshot.
///
/// The SQLite instance identifier survives a normal backup/restore because it is stored in the database,
/// while a replacement database gets its own identifier. `sourceLineage` changes when the active input
/// changes, so a snapshot never bridges two unrelated dashboard inputs merely because they share the
/// canonical `my-whoop` namespace.
public struct TodayHealthSnapshotContext: Codable, Equatable, Sendable {
    public let databaseInstanceId: String
    public let dashboardProfileId: String
    public let sourceLineage: String
    public let algorithmBundleVersion: String

    public init(databaseInstanceId: String, dashboardProfileId: String, sourceLineage: String,
                algorithmBundleVersion: String) {
        self.databaseInstanceId = databaseInstanceId
        self.dashboardProfileId = dashboardProfileId
        self.sourceLineage = sourceLineage
        self.algorithmBundleVersion = algorithmBundleVersion
    }

    /// Stored alongside the payload so SQLite can reject a stale writer from another context atomically.
    public var identifier: String {
        [databaseInstanceId, dashboardProfileId, sourceLineage, algorithmBundleVersion]
            .joined(separator: "|")
    }
}

/// The one durable read model used to paint Recovery, Strain, and Sleep before a full dashboard refresh.
///
/// It is scoped to a logical dashboard owner, not a view instance. The saved `dailyMetric` lets the normal
/// day resolver keep its rollover rules, while the per-metric values preserve source and freshness evidence.
public struct TodayHealthSnapshot: Codable, Equatable, Sendable {
    /// Schema 3 adds source/database context, authoritative-nil semantics, and metric-level day identity.
    /// Earlier snapshots are accepted only long enough for Repository to repair or replace them safely.
    public static let currentSchemaVersion = 3

    public enum Metric: String, CaseIterable, Codable, Hashable, Sendable {
        case recovery
        case strain
        case sleepScore
        case sleepDurationMinutes
    }

    /// Stable key for one dashboard owner. A keyed lookup is the entire startup read.
    public let scopeId: String
    /// The database/profile/source context that is allowed to consume this snapshot.
    public let context: TodayHealthSnapshotContext?
    /// Device namespace whose delete-data action also deletes this snapshot.
    public let deviceId: String
    /// The row that the Today resolver displayed when this snapshot was generated.
    public let displayDay: String
    /// Both day keys are stored so the pre-04:00 rollover decision is auditable and reproducible.
    public let logicalDay: String
    public let localDay: String
    /// Write time, in Unix seconds.
    public let generatedAt: Int
    /// Newest raw biometric timestamp known to the snapshot producer, if it has one.
    public let rawFrontierTs: Int?
    public let schemaVersion: Int
    /// A field in this set was fully resolved by the live producer. If its corresponding value is nil,
    /// that nil is an authoritative unavailable/deleted result rather than an unfinished load.
    public let authoritativeMetrics: Set<Metric>
    /// The complete displayed daily row, used as the non-hero first-paint fallback.
    public let dailyMetric: DailyMetric
    public let recovery: TodayHealthMetricValue?
    /// Canonical NOOP Strain, on the 0...100 storage axis.
    public let strain: TodayHealthMetricValue?
    /// The displayed Sleep/Rest score, not a substituted sleep duration.
    public let sleepScore: TodayHealthMetricValue?
    public let sleepDurationMinutes: TodayHealthMetricValue?

    public init(scopeId: String, context: TodayHealthSnapshotContext? = nil, deviceId: String,
                displayDay: String, logicalDay: String,
                localDay: String, generatedAt: Int, rawFrontierTs: Int? = nil,
                schemaVersion: Int = TodayHealthSnapshot.currentSchemaVersion,
                authoritativeMetrics: Set<Metric> = [],
                dailyMetric: DailyMetric, recovery: TodayHealthMetricValue? = nil,
                strain: TodayHealthMetricValue? = nil, sleepScore: TodayHealthMetricValue? = nil,
                sleepDurationMinutes: TodayHealthMetricValue? = nil) {
        self.scopeId = scopeId
        self.context = context
        self.deviceId = deviceId
        self.displayDay = displayDay
        self.logicalDay = logicalDay
        self.localDay = localDay
        self.generatedAt = generatedAt
        self.rawFrontierTs = rawFrontierTs
        self.schemaVersion = schemaVersion
        self.authoritativeMetrics = authoritativeMetrics
        self.dailyMetric = dailyMetric
        self.recovery = recovery
        self.strain = strain
        self.sleepScore = sleepScore
        self.sleepDurationMinutes = sleepDurationMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case scopeId, context, deviceId, displayDay, logicalDay, localDay, generatedAt, rawFrontierTs
        case schemaVersion, authoritativeMetrics, dailyMetric, recovery, strain, sleepScore
        case sleepDurationMinutes
    }

    /// Schema 1/2 records do not contain context or authoritative metric states. Decode them as an
    /// explicitly non-authoritative legacy record; Repository will either repair it into schema 3 or discard it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scopeId = try container.decode(String.self, forKey: .scopeId)
        context = try container.decodeIfPresent(TodayHealthSnapshotContext.self, forKey: .context)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        displayDay = try container.decode(String.self, forKey: .displayDay)
        logicalDay = try container.decode(String.self, forKey: .logicalDay)
        localDay = try container.decode(String.self, forKey: .localDay)
        generatedAt = try container.decode(Int.self, forKey: .generatedAt)
        rawFrontierTs = try container.decodeIfPresent(Int.self, forKey: .rawFrontierTs)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        authoritativeMetrics = try container.decodeIfPresent(Set<Metric>.self, forKey: .authoritativeMetrics) ?? []
        dailyMetric = try container.decode(DailyMetric.self, forKey: .dailyMetric)
        recovery = try container.decodeIfPresent(TodayHealthMetricValue.self, forKey: .recovery)
        strain = try container.decodeIfPresent(TodayHealthMetricValue.self, forKey: .strain)
        sleepScore = try container.decodeIfPresent(TodayHealthMetricValue.self, forKey: .sleepScore)
        sleepDurationMinutes = try container.decodeIfPresent(TodayHealthMetricValue.self, forKey: .sleepDurationMinutes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scopeId, forKey: .scopeId)
        try container.encodeIfPresent(context, forKey: .context)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(displayDay, forKey: .displayDay)
        try container.encode(logicalDay, forKey: .logicalDay)
        try container.encode(localDay, forKey: .localDay)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encodeIfPresent(rawFrontierTs, forKey: .rawFrontierTs)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(authoritativeMetrics, forKey: .authoritativeMetrics)
        try container.encode(dailyMetric, forKey: .dailyMetric)
        try container.encodeIfPresent(recovery, forKey: .recovery)
        try container.encodeIfPresent(strain, forKey: .strain)
        try container.encodeIfPresent(sleepScore, forKey: .sleepScore)
        try container.encodeIfPresent(sleepDurationMinutes, forKey: .sleepDurationMinutes)
    }

    public func metric(_ metric: Metric) -> TodayHealthMetricValue? {
        switch metric {
        case .recovery: return recovery
        case .strain: return strain
        case .sleepScore: return sleepScore
        case .sleepDurationMinutes: return sleepDurationMinutes
        }
    }

    public func isAuthoritative(_ metric: Metric) -> Bool {
        authoritativeMetrics.contains(metric)
    }

    /// Fields that can change the visible Today projection. Metadata-only updates (frontier, write time,
    /// authority bookkeeping) must not force SwiftUI to rebuild the hero.
    public func hasSamePresentation(as other: TodayHealthSnapshot) -> Bool {
        scopeId == other.scopeId
            && context == other.context
            && deviceId == other.deviceId
            && displayDay == other.displayDay
            && dailyMetric == other.dailyMetric
            && recovery == other.recovery
            && strain == other.strain
            && sleepScore == other.sleepScore
            && sleepDurationMinutes == other.sleepDurationMinutes
    }
}

public enum TodayHealthSnapshotStoreError: Error, Equatable {
    case invalidSnapshot
}

extension WhoopStore {
    /// Atomically save a dashboard first-paint snapshot. An older writer can never replace newer evidence.
    /// Returns true only when the database accepted the write.
    @discardableResult
    public func saveTodayHealthSnapshot(_ snapshot: TodayHealthSnapshot) async throws -> Bool {
        try Self.validate(snapshot)
        let payload = try JSONEncoder().encode(snapshot)
        let contextId = snapshot.context?.identifier
        return try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO todayHealthSnapshot
                    (scopeId, deviceId, displayDay, logicalDay, localDay, generatedAt, rawFrontierTs,
                     schemaVersion, contextId, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(scopeId) DO UPDATE SET
                    deviceId = excluded.deviceId,
                    displayDay = excluded.displayDay,
                    logicalDay = excluded.logicalDay,
                    localDay = excluded.localDay,
                    generatedAt = excluded.generatedAt,
                    rawFrontierTs = excluded.rawFrontierTs,
                    schemaVersion = excluded.schemaVersion,
                    contextId = excluded.contextId,
                    payload = excluded.payload
                WHERE COALESCE(excluded.contextId, '') = COALESCE(todayHealthSnapshot.contextId, '')
                  AND (
                      COALESCE(excluded.rawFrontierTs, -1)
                          > COALESCE(todayHealthSnapshot.rawFrontierTs, -1)
                      OR (
                          COALESCE(excluded.rawFrontierTs, -1)
                              = COALESCE(todayHealthSnapshot.rawFrontierTs, -1)
                          AND excluded.generatedAt >= todayHealthSnapshot.generatedAt
                      )
                  )
                """, arguments: [snapshot.scopeId, snapshot.deviceId, snapshot.displayDay,
                                   snapshot.logicalDay, snapshot.localDay, snapshot.generatedAt,
                                   snapshot.rawFrontierTs, snapshot.schemaVersion, contextId, payload])
            return db.changesCount > 0
        }
    }

    /// Read exactly one keyed snapshot. The caller can begin its normal repository refresh in parallel.
    public func todayHealthSnapshot(scopeId: String) async throws -> TodayHealthSnapshot? {
        try syncRead { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT contextId, payload FROM todayHealthSnapshot WHERE scopeId = ? LIMIT 1",
                arguments: [scopeId]
            ) else { return nil }
            let payload: Data = row["payload"]
            let snapshot = try JSONDecoder().decode(TodayHealthSnapshot.self, from: payload)
            let storedContextId: String? = row["contextId"]
            guard snapshot.context?.identifier == storedContextId else {
                throw TodayHealthSnapshotStoreError.invalidSnapshot
            }
            try Self.validate(snapshot)
            return snapshot
        }
    }

    /// Clear one dashboard snapshot after a destructive source mutation or an incompatible context change.
    @discardableResult
    public func clearTodayHealthSnapshot(scopeId: String, matchingContextId: String? = nil) async throws -> Bool {
        try syncWrite { db in
            if let matchingContextId {
                try db.execute(sql: "DELETE FROM todayHealthSnapshot WHERE scopeId = ? AND contextId = ?",
                               arguments: [scopeId, matchingContextId])
            } else {
                try db.execute(sql: "DELETE FROM todayHealthSnapshot WHERE scopeId = ?", arguments: [scopeId])
            }
            return db.changesCount > 0
        }
    }

    /// Stable UUID generated in the database itself. It changes only when the database is replaced.
    public func todayHealthSnapshotDatabaseInstanceId() async throws -> String {
        try await databaseInstanceId()
    }

    private static func validate(_ snapshot: TodayHealthSnapshot) throws {
        guard !snapshot.scopeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !snapshot.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !snapshot.displayDay.isEmpty,
              !snapshot.logicalDay.isEmpty,
              !snapshot.localDay.isEmpty,
              snapshot.displayDay == snapshot.dailyMetric.day,
              snapshot.generatedAt >= 0,
              snapshot.schemaVersion > 0,
              snapshot.schemaVersion <= TodayHealthSnapshot.currentSchemaVersion,
              snapshot.rawFrontierTs.map({ $0 >= 0 }) ?? true
        else { throw TodayHealthSnapshotStoreError.invalidSnapshot }

        if snapshot.schemaVersion >= 3 {
            guard let context = snapshot.context,
                  !context.databaseInstanceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !context.dashboardProfileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !context.sourceLineage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !context.algorithmBundleVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw TodayHealthSnapshotStoreError.invalidSnapshot }

            // The duplicated daily fields are only a presentation row. They must agree with the typed
            // metric evidence so the UI cannot render one value while the resolver persists another.
            guard snapshot.dailyMetric.recovery == snapshot.recovery?.value,
                  snapshot.dailyMetric.strain == snapshot.strain?.value,
                  snapshot.dailyMetric.strainVersion == snapshot.strain?.strainVersion,
                  snapshot.dailyMetric.totalSleepMin == snapshot.sleepDurationMinutes?.value
            else { throw TodayHealthSnapshotStoreError.invalidSnapshot }
        }

        for kind in TodayHealthSnapshot.Metric.allCases {
            guard let metric = snapshot.metric(kind) else { continue }
            guard metric.value.isFinite,
                  !metric.sourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  metric.observedAt.map({ $0 >= 0 }) ?? true,
                  metric.rawFrontierTs.map({ $0 >= 0 }) ?? true,
                  metric.strainVersion.map({ $0 > 0 }) ?? true
            else { throw TodayHealthSnapshotStoreError.invalidSnapshot }

            if snapshot.schemaVersion >= 3 {
                guard let metricDay = metric.metricDay,
                      !metricDay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let algorithm = metric.algorithmVersion,
                      !algorithm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw TodayHealthSnapshotStoreError.invalidSnapshot }
            }

            switch kind {
            case .recovery, .sleepScore:
                guard (0 ... 100).contains(metric.value), metric.strainVersion == nil
                else { throw TodayHealthSnapshotStoreError.invalidSnapshot }
            case .strain:
                guard (0 ... 100).contains(metric.value), metric.strainVersion == 2
                else { throw TodayHealthSnapshotStoreError.invalidSnapshot }
            case .sleepDurationMinutes:
                guard (0 ... 1_440).contains(metric.value), metric.strainVersion == nil
                else { throw TodayHealthSnapshotStoreError.invalidSnapshot }
            }
        }
    }
}
