import Foundation
import GRDB

/// One metric carried by the durable dashboard first-paint snapshot.
///
/// `value` stays on its storage axis. In particular, Strain is the canonical NOOP 0...100 value;
/// presentation converts it to a WHOOP-style 0...21 value only at the UI boundary.
public struct TodayHealthMetricValue: Codable, Equatable, Sendable {
    public let value: Double
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

    public init(value: Double, sourceId: String, observedAt: Int? = nil,
                rawFrontierTs: Int? = nil, algorithmVersion: String? = nil,
                strainVersion: Int? = nil) {
        self.value = value
        self.sourceId = sourceId
        self.observedAt = observedAt
        self.rawFrontierTs = rawFrontierTs
        self.algorithmVersion = algorithmVersion
        self.strainVersion = strainVersion
    }
}

/// The one durable read model used to paint Recovery, Strain, and Sleep before a full dashboard refresh.
///
/// It is scoped to a logical dashboard owner, not a view instance. The saved `dailyMetric` lets the normal
/// day resolver keep its rollover rules, while the per-metric values preserve source and freshness evidence.
public struct TodayHealthSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public enum Metric: String, CaseIterable, Codable, Sendable {
        case recovery
        case strain
        case sleepScore
        case sleepDurationMinutes
    }

    /// Stable key for one dashboard owner. A keyed lookup is the entire startup read.
    public let scopeId: String
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
    /// The complete displayed daily row, used as the non-hero first-paint fallback.
    public let dailyMetric: DailyMetric
    public let recovery: TodayHealthMetricValue?
    /// Canonical NOOP Strain, on the 0...100 storage axis.
    public let strain: TodayHealthMetricValue?
    /// The displayed Sleep/Rest score, not a substituted sleep duration.
    public let sleepScore: TodayHealthMetricValue?
    public let sleepDurationMinutes: TodayHealthMetricValue?

    public init(scopeId: String, deviceId: String, displayDay: String, logicalDay: String,
                localDay: String, generatedAt: Int, rawFrontierTs: Int? = nil,
                schemaVersion: Int = TodayHealthSnapshot.currentSchemaVersion,
                dailyMetric: DailyMetric, recovery: TodayHealthMetricValue? = nil,
                strain: TodayHealthMetricValue? = nil, sleepScore: TodayHealthMetricValue? = nil,
                sleepDurationMinutes: TodayHealthMetricValue? = nil) {
        self.scopeId = scopeId
        self.deviceId = deviceId
        self.displayDay = displayDay
        self.logicalDay = logicalDay
        self.localDay = localDay
        self.generatedAt = generatedAt
        self.rawFrontierTs = rawFrontierTs
        self.schemaVersion = schemaVersion
        self.dailyMetric = dailyMetric
        self.recovery = recovery
        self.strain = strain
        self.sleepScore = sleepScore
        self.sleepDurationMinutes = sleepDurationMinutes
    }

    public func metric(_ metric: Metric) -> TodayHealthMetricValue? {
        switch metric {
        case .recovery: return recovery
        case .strain: return strain
        case .sleepScore: return sleepScore
        case .sleepDurationMinutes: return sleepDurationMinutes
        }
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
        return try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO todayHealthSnapshot
                    (scopeId, deviceId, displayDay, logicalDay, localDay, generatedAt, rawFrontierTs,
                     schemaVersion, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(scopeId) DO UPDATE SET
                    deviceId = excluded.deviceId,
                    displayDay = excluded.displayDay,
                    logicalDay = excluded.logicalDay,
                    localDay = excluded.localDay,
                    generatedAt = excluded.generatedAt,
                    rawFrontierTs = excluded.rawFrontierTs,
                    schemaVersion = excluded.schemaVersion,
                    payload = excluded.payload
                WHERE excluded.generatedAt > todayHealthSnapshot.generatedAt
                   OR (excluded.generatedAt = todayHealthSnapshot.generatedAt
                       AND COALESCE(excluded.rawFrontierTs, -1)
                           >= COALESCE(todayHealthSnapshot.rawFrontierTs, -1))
                """, arguments: [snapshot.scopeId, snapshot.deviceId, snapshot.displayDay,
                                   snapshot.logicalDay, snapshot.localDay, snapshot.generatedAt,
                                   snapshot.rawFrontierTs, snapshot.schemaVersion, payload])
            return db.changesCount > 0
        }
    }

    /// Read exactly one keyed snapshot. The caller can begin its normal repository refresh in parallel.
    public func todayHealthSnapshot(scopeId: String) async throws -> TodayHealthSnapshot? {
        try syncRead { db in
            guard let payload = try Data.fetchOne(
                db,
                sql: "SELECT payload FROM todayHealthSnapshot WHERE scopeId = ? LIMIT 1",
                arguments: [scopeId]
            ) else { return nil }
            return try JSONDecoder().decode(TodayHealthSnapshot.self, from: payload)
        }
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
              snapshot.rawFrontierTs.map({ $0 >= 0 }) ?? true
        else { throw TodayHealthSnapshotStoreError.invalidSnapshot }

        for metric in TodayHealthSnapshot.Metric.allCases.compactMap(snapshot.metric) {
            guard metric.value.isFinite,
                  !metric.sourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  metric.observedAt.map({ $0 >= 0 }) ?? true,
                  metric.rawFrontierTs.map({ $0 >= 0 }) ?? true,
                  metric.strainVersion.map({ $0 > 0 }) ?? true
            else { throw TodayHealthSnapshotStoreError.invalidSnapshot }
        }
    }
}
