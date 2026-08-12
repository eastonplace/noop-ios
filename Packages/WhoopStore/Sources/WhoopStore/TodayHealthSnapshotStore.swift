import Foundation
import GRDB

/// Honest freshness for a visible Today metric. A completed prior-night Recovery or Sleep score may be
/// valid but aging; a current-day value with an old frontier, or a value from an older physiological day,
/// is stale and must be labelled before it is presented as current.
public enum TodayHealthMetricFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case aging
    case stale
}

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
    /// Monotonic snapshot generation that produced this evidence. It is the ordering authority when raw
    /// frontiers tie; wall-clock time is diagnostics only.
    public let generation: Int64
    /// Current presentation freshness. A reader may recompute this at display time when the logical day
    /// changes, but persisted evidence never claims a stale value is fresh.
    public let freshness: TodayHealthMetricFreshness?

    public init(value: Double, metricDay: String? = nil, sourceId: String, observedAt: Int? = nil,
                rawFrontierTs: Int? = nil, algorithmVersion: String? = nil,
                strainVersion: Int? = nil, generation: Int64 = 0,
                freshness: TodayHealthMetricFreshness? = nil) {
        self.value = value
        self.metricDay = metricDay
        self.sourceId = sourceId
        self.observedAt = observedAt
        self.rawFrontierTs = rawFrontierTs
        self.algorithmVersion = algorithmVersion
        self.strainVersion = strainVersion
        self.generation = generation
        self.freshness = freshness
    }

    private enum CodingKeys: String, CodingKey {
        case value, metricDay, sourceId, observedAt, rawFrontierTs, algorithmVersion
        case strainVersion, generation, freshness
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            value: try container.decode(Double.self, forKey: .value),
            metricDay: try container.decodeIfPresent(String.self, forKey: .metricDay),
            sourceId: try container.decode(String.self, forKey: .sourceId),
            observedAt: try container.decodeIfPresent(Int.self, forKey: .observedAt),
            rawFrontierTs: try container.decodeIfPresent(Int.self, forKey: .rawFrontierTs),
            algorithmVersion: try container.decodeIfPresent(String.self, forKey: .algorithmVersion),
            strainVersion: try container.decodeIfPresent(Int.self, forKey: .strainVersion),
            generation: try container.decodeIfPresent(Int64.self, forKey: .generation) ?? 0,
            freshness: try container.decodeIfPresent(TodayHealthMetricFreshness.self, forKey: .freshness)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encodeIfPresent(metricDay, forKey: .metricDay)
        try container.encode(sourceId, forKey: .sourceId)
        try container.encodeIfPresent(observedAt, forKey: .observedAt)
        try container.encodeIfPresent(rawFrontierTs, forKey: .rawFrontierTs)
        try container.encodeIfPresent(algorithmVersion, forKey: .algorithmVersion)
        try container.encodeIfPresent(strainVersion, forKey: .strainVersion)
        try container.encode(generation, forKey: .generation)
        try container.encodeIfPresent(freshness, forKey: .freshness)
    }

    public func replacing(
        metricDay: String? = nil,
        sourceId: String? = nil,
        observedAt: Int?? = nil,
        rawFrontierTs: Int?? = nil,
        algorithmVersion: String?? = nil,
        strainVersion: Int?? = nil,
        generation: Int64? = nil,
        freshness: TodayHealthMetricFreshness?? = nil
    ) -> TodayHealthMetricValue {
        TodayHealthMetricValue(
            value: value,
            metricDay: metricDay ?? self.metricDay,
            sourceId: sourceId ?? self.sourceId,
            observedAt: observedAt ?? self.observedAt,
            rawFrontierTs: rawFrontierTs ?? self.rawFrontierTs,
            algorithmVersion: algorithmVersion ?? self.algorithmVersion,
            strainVersion: strainVersion ?? self.strainVersion,
            generation: generation ?? self.generation,
            freshness: freshness ?? self.freshness
        )
    }

    public func withGeneration(_ generation: Int64) -> TodayHealthMetricValue {
        replacing(generation: generation)
    }
}

/// Why a metric is known to be unavailable. A read failure is deliberately not represented here: failures
/// remain `.unknown` so a transient SQLite error cannot clear a previously verified visible value.
public enum TodayHealthUnavailableReason: String, Codable, Equatable, Sendable {
    case absent
    case deleted
    case sourceUnavailable
}

/// Durable evidence that a complete precedence read found no value for one metric.
public struct TodayHealthUnavailableEvidence: Codable, Equatable, Sendable {
    public let metricDay: String
    public let sourceId: String
    public let reason: TodayHealthUnavailableReason
    public let observedAt: Int
    public let rawFrontierTs: Int?
    public let algorithmVersion: String
    public let generation: Int64

    public init(metricDay: String, sourceId: String, reason: TodayHealthUnavailableReason,
                observedAt: Int, rawFrontierTs: Int?, algorithmVersion: String, generation: Int64) {
        self.metricDay = metricDay
        self.sourceId = sourceId
        self.reason = reason
        self.observedAt = observedAt
        self.rawFrontierTs = rawFrontierTs
        self.algorithmVersion = algorithmVersion
        self.generation = generation
    }

    private enum CodingKeys: String, CodingKey {
        case metricDay, sourceId, reason, observedAt, rawFrontierTs, algorithmVersion, generation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            metricDay: try container.decode(String.self, forKey: .metricDay),
            sourceId: try container.decode(String.self, forKey: .sourceId),
            reason: try container.decode(TodayHealthUnavailableReason.self, forKey: .reason),
            observedAt: try container.decode(Int.self, forKey: .observedAt),
            rawFrontierTs: try container.decodeIfPresent(Int.self, forKey: .rawFrontierTs),
            algorithmVersion: try container.decode(String.self, forKey: .algorithmVersion),
            generation: try container.decodeIfPresent(Int64.self, forKey: .generation) ?? 0
        )
    }

    public func withGeneration(_ generation: Int64) -> TodayHealthUnavailableEvidence {
        TodayHealthUnavailableEvidence(
            metricDay: metricDay,
            sourceId: sourceId,
            reason: reason,
            observedAt: observedAt,
            rawFrontierTs: rawFrontierTs,
            algorithmVersion: algorithmVersion,
            generation: generation
        )
    }
}

/// Explicit three-state metric contract. It replaces the ambiguous combination of an optional value plus
/// `authoritativeMetrics`: only a completed read can create `.unavailable`; a read failure stays unknown.
public enum TodayHealthMetricState: Codable, Equatable, Sendable {
    case unknown
    case value(TodayHealthMetricValue)
    case unavailable(TodayHealthUnavailableEvidence)

    private enum CodingKeys: String, CodingKey { case kind, value, unavailable }
    private enum Kind: String, Codable { case unknown, value, unavailable }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .unknown:
            self = .unknown
        case .value:
            self = .value(try container.decode(TodayHealthMetricValue.self, forKey: .value))
        case .unavailable:
            self = .unavailable(try container.decode(TodayHealthUnavailableEvidence.self, forKey: .unavailable))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unknown:
            try container.encode(Kind.unknown, forKey: .kind)
        case let .value(value):
            try container.encode(Kind.value, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .unavailable(evidence):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(evidence, forKey: .unavailable)
        }
    }

    public var value: TodayHealthMetricValue? {
        guard case let .value(value) = self else { return nil }
        return value
    }

    public var unavailableEvidence: TodayHealthUnavailableEvidence? {
        guard case let .unavailable(evidence) = self else { return nil }
        return evidence
    }

    public var isAuthoritative: Bool {
        if case .unknown = self { return false }
        return true
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    public var metricDay: String? {
        switch self {
        case .unknown: return nil
        case let .value(value): return value.metricDay
        case let .unavailable(evidence): return evidence.metricDay
        }
    }

    public func withGeneration(_ generation: Int64) -> TodayHealthMetricState {
        switch self {
        case .unknown:
            return .unknown
        case let .value(value):
            return .value(value.withGeneration(generation))
        case let .unavailable(evidence):
            return .unavailable(evidence.withGeneration(generation))
        }
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
    /// Schema 4 stores an explicit state for every metric. Schema 3 records are decoded and upgraded in
    /// memory; schema 1/2 records remain readable so the repository can perform its existing repair path.
    public static let currentSchemaVersion = 4

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
    /// Write time, in Unix seconds. This is diagnostics only and never orders snapshot writes.
    public let generatedAt: Int
    /// Monotonic generation assigned by SQLite when this snapshot is accepted.
    public let generation: Int64
    /// Newest raw biometric timestamp known to the snapshot producer, if it has one.
    public let rawFrontierTs: Int?
    public let schemaVersion: Int
    /// Explicit state and evidence for every visible metric. Missing dictionary entries read as `.unknown`.
    public let metricStates: [Metric: TodayHealthMetricState]
    /// Compatibility contract for producers that still report which reads completed. The explicit state
    /// remains authoritative: `.value` and `.unavailable` are authoritative, while `.unknown` is never
    /// authoritative even if a legacy producer left the metric in this set.
    public let authoritativeMetrics: Set<Metric>
    /// The complete displayed daily row, used as the non-hero first-paint fallback.
    public let dailyMetric: DailyMetric

    /// Compatibility aliases. New code should use `state(for:)` when it must distinguish unknown from
    /// unavailable. These accessors intentionally keep the old value-only API working.
    public var recovery: TodayHealthMetricValue? { state(for: .recovery).value }
    public var strain: TodayHealthMetricValue? { state(for: .strain).value }
    public var sleepScore: TodayHealthMetricValue? { state(for: .sleepScore).value }
    public var sleepDurationMinutes: TodayHealthMetricValue? { state(for: .sleepDurationMinutes).value }
    public var states: [Metric: TodayHealthMetricState] { metricStates }
    public var recoveryState: TodayHealthMetricState { state(for: .recovery) }
    public var strainState: TodayHealthMetricState { state(for: .strain) }
    public var sleepScoreState: TodayHealthMetricState { state(for: .sleepScore) }
    public var sleepDurationMinutesState: TodayHealthMetricState { state(for: .sleepDurationMinutes) }
    public init(scopeId: String, context: TodayHealthSnapshotContext? = nil, deviceId: String,
                displayDay: String, logicalDay: String,
                localDay: String, generatedAt: Int, rawFrontierTs: Int? = nil,
                generation: Int64 = 0,
                schemaVersion: Int = TodayHealthSnapshot.currentSchemaVersion,
                authoritativeMetrics: Set<Metric> = [],
                dailyMetric: DailyMetric, recovery: TodayHealthMetricValue? = nil,
                strain: TodayHealthMetricValue? = nil, sleepScore: TodayHealthMetricValue? = nil,
                sleepDurationMinutes: TodayHealthMetricValue? = nil,
                metricStates: [Metric: TodayHealthMetricState]? = nil) {
        self.scopeId = scopeId
        self.context = context
        self.deviceId = deviceId
        self.displayDay = displayDay
        self.logicalDay = logicalDay
        self.localDay = localDay
        self.generatedAt = generatedAt
        self.generation = generation
        self.rawFrontierTs = rawFrontierTs
        self.schemaVersion = schemaVersion
        let states = Self.makeMetricStates(
            explicit: metricStates,
            authoritativeMetrics: authoritativeMetrics,
            recovery: recovery,
            strain: strain,
            sleepScore: sleepScore,
            sleepDurationMinutes: sleepDurationMinutes,
            displayDay: displayDay,
            generatedAt: generatedAt,
            rawFrontierTs: rawFrontierTs,
            generation: generation,
            schemaVersion: schemaVersion
        )
        self.metricStates = states
        self.authoritativeMetrics = authoritativeMetrics.union(
            Metric.allCases.filter { states[$0]?.isUnavailable == true }
        )
        self.dailyMetric = Self.projectedDailyMetric(dailyMetric, displayDay: displayDay, states: states)
    }

    private enum CodingKeys: String, CodingKey {
        case scopeId, context, deviceId, displayDay, logicalDay, localDay, generatedAt
        case generation, rawFrontierTs, schemaVersion, metricStates, authoritativeMetrics, dailyMetric
        case recovery, strain, sleepScore, sleepDurationMinutes
    }

    /// Schema 3 carried optional values plus `authoritativeMetrics`. Decode it into explicit states and
    /// promote it to schema 4. The old value accessors remain populated for `.value` states.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let context = try container.decodeIfPresent(TodayHealthSnapshotContext.self, forKey: .context)
        let scopeId = try container.decode(String.self, forKey: .scopeId)
        let deviceId = try container.decode(String.self, forKey: .deviceId)
        let displayDay = try container.decode(String.self, forKey: .displayDay)
        let logicalDay = try container.decode(String.self, forKey: .logicalDay)
        let localDay = try container.decode(String.self, forKey: .localDay)
        let generatedAt = try container.decode(Int.self, forKey: .generatedAt)
        let generation = try container.decodeIfPresent(Int64.self, forKey: .generation) ?? 0
        let rawFrontierTs = try container.decodeIfPresent(Int.self, forKey: .rawFrontierTs)
        let authoritativeMetrics = try container.decodeIfPresent(Set<Metric>.self,
                                                                  forKey: .authoritativeMetrics) ?? []
        let dailyMetric = try container.decode(DailyMetric.self, forKey: .dailyMetric)
        let recovery = try container.decodeIfPresent(TodayHealthMetricValue.self, forKey: .recovery)
        let strain = try container.decodeIfPresent(TodayHealthMetricValue.self, forKey: .strain)
        let sleepScore = try container.decodeIfPresent(TodayHealthMetricValue.self, forKey: .sleepScore)
        let sleepDurationMinutes = try container.decodeIfPresent(TodayHealthMetricValue.self,
                                                                  forKey: .sleepDurationMinutes)
        let encodedStates = try container.decodeIfPresent([Metric: TodayHealthMetricState].self,
                                                          forKey: .metricStates)
        let states = Self.makeMetricStates(
            explicit: encodedStates,
            authoritativeMetrics: authoritativeMetrics,
            recovery: recovery,
            strain: strain,
            sleepScore: sleepScore,
            sleepDurationMinutes: sleepDurationMinutes,
            displayDay: displayDay,
            generatedAt: generatedAt,
            rawFrontierTs: rawFrontierTs,
            generation: generation,
            schemaVersion: decodedSchemaVersion
        )
        // Current schema 3 includes context. Keep context-less schema 3 records on their legacy path so
        // Repository can still admit and repair them exactly like the existing v2 records.
        let migratedSchemaVersion = decodedSchemaVersion == 3 && context != nil
            ? TodayHealthSnapshot.currentSchemaVersion
            : decodedSchemaVersion
        self.init(
            scopeId: scopeId,
            context: context,
            deviceId: deviceId,
            displayDay: displayDay,
            logicalDay: logicalDay,
            localDay: localDay,
            generatedAt: generatedAt,
            rawFrontierTs: rawFrontierTs,
            generation: generation,
            schemaVersion: migratedSchemaVersion,
            authoritativeMetrics: authoritativeMetrics,
            dailyMetric: dailyMetric,
            recovery: recovery,
            strain: strain,
            sleepScore: sleepScore,
            sleepDurationMinutes: sleepDurationMinutes,
            metricStates: states
        )
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
        if schemaVersion >= TodayHealthSnapshot.currentSchemaVersion {
            try container.encode(generation, forKey: .generation)
            try container.encode(metricStates, forKey: .metricStates)
        }
    }

    public func state(for metric: Metric) -> TodayHealthMetricState {
        metricStates[metric] ?? .unknown
    }

    public func metric(_ metric: Metric) -> TodayHealthMetricValue? {
        state(for: metric).value
    }

    public func isAuthoritative(_ metric: Metric) -> Bool {
        state(for: metric).isAuthoritative
    }

    /// Return a copy with the database-issued generation applied to the top-level snapshot and every
    /// evidence-bearing metric. `generatedAt` remains untouched for diagnostics.
    public func withGeneration(_ generation: Int64) -> TodayHealthSnapshot {
        let states = Dictionary(uniqueKeysWithValues: Metric.allCases.map { metric in
            (metric, state(for: metric).withGeneration(generation))
        })
        let upgradedSchema = schemaVersion == 3 && context != nil
            ? TodayHealthSnapshot.currentSchemaVersion
            : schemaVersion
        return TodayHealthSnapshot(
            scopeId: scopeId,
            context: context,
            deviceId: deviceId,
            displayDay: displayDay,
            logicalDay: logicalDay,
            localDay: localDay,
            generatedAt: generatedAt,
            rawFrontierTs: rawFrontierTs,
            generation: generation,
            schemaVersion: upgradedSchema,
            authoritativeMetrics: authoritativeMetrics,
            dailyMetric: dailyMetric,
            metricStates: states
        )
    }

    /// Fields that can change the visible Today projection. Metadata-only updates (frontier, write time,
    /// generation bookkeeping) must not force SwiftUI to rebuild the hero.
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

    private static func makeMetricStates(
        explicit: [Metric: TodayHealthMetricState]?,
        authoritativeMetrics: Set<Metric>,
        recovery: TodayHealthMetricValue?,
        strain: TodayHealthMetricValue?,
        sleepScore: TodayHealthMetricValue?,
        sleepDurationMinutes: TodayHealthMetricValue?,
        displayDay: String,
        generatedAt: Int,
        rawFrontierTs: Int?,
        generation: Int64,
        schemaVersion: Int
    ) -> [Metric: TodayHealthMetricState] {
        func legacyValue(_ metric: Metric) -> TodayHealthMetricValue? {
            switch metric {
            case .recovery: return recovery
            case .strain: return strain
            case .sleepScore: return sleepScore
            case .sleepDurationMinutes: return sleepDurationMinutes
            }
        }

        return Dictionary(uniqueKeysWithValues: Metric.allCases.map { metric in
            let state: TodayHealthMetricState
            if let explicitState = explicit?[metric] {
                state = explicitState
            } else if let value = legacyValue(metric) {
                state = .value(value)
            } else if authoritativeMetrics.contains(metric) {
                state = .unavailable(legacyUnavailableEvidence(
                    metric: metric,
                    displayDay: displayDay,
                    generatedAt: generatedAt,
                    rawFrontierTs: rawFrontierTs,
                    generation: generation,
                    schemaVersion: schemaVersion
                ))
            } else {
                state = .unknown
            }
            return (metric, migratedState(state, metric: metric, displayDay: displayDay,
                                          schemaVersion: schemaVersion))
        })
    }

    private static func migratedState(
        _ state: TodayHealthMetricState,
        metric: Metric,
        displayDay: String,
        schemaVersion: Int
    ) -> TodayHealthMetricState {
        guard schemaVersion < TodayHealthSnapshot.currentSchemaVersion else { return state }
        guard case let .value(value) = state else { return state }
        let metricDay = value.metricDay ?? displayDay
        let algorithmVersion = value.algorithmVersion ?? defaultAlgorithmVersion(for: metric)
        guard metricDay != value.metricDay || algorithmVersion != value.algorithmVersion else {
            return state
        }
        return .value(value.replacing(metricDay: metricDay, algorithmVersion: algorithmVersion))
    }

    private static func legacyUnavailableEvidence(
        metric: Metric,
        displayDay: String,
        generatedAt: Int,
        rawFrontierTs: Int?,
        generation: Int64,
        schemaVersion: Int
    ) -> TodayHealthUnavailableEvidence {
        TodayHealthUnavailableEvidence(
            metricDay: displayDay,
            sourceId: "legacy-snapshot-v\(schemaVersion)",
            reason: .absent,
            observedAt: max(0, generatedAt),
            rawFrontierTs: rawFrontierTs,
            algorithmVersion: "legacy-snapshot-v\(schemaVersion)-\(metric.rawValue)",
            generation: generation
        )
    }

    private static func defaultAlgorithmVersion(for metric: Metric) -> String {
        switch metric {
        case .recovery: return "daily-recovery-v1"
        case .strain: return "strain-v2-daily"
        case .sleepScore: return "sleep-performance-v1"
        case .sleepDurationMinutes: return "daily-sleep-duration-v1"
        }
    }

    private static func projectedDailyMetric(
        _ dailyMetric: DailyMetric,
        displayDay: String,
        states: [Metric: TodayHealthMetricState]
    ) -> DailyMetric {
        func currentDayValue(_ metric: Metric) -> Double? {
            guard let value = states[metric]?.value, value.metricDay == displayDay else { return nil }
            return value.value
        }
        let strainState = states[.strain]
        let currentStrain = currentDayValue(.strain)
        let currentStrainVersion = currentStrain == nil ? nil : strainState?.value?.strainVersion
        return dailyMetric.replacing(
            totalSleepMin: .some(currentDayValue(.sleepDurationMinutes)),
            recovery: .some(currentDayValue(.recovery)),
            strain: .some(currentStrain),
            strainVersion: .some(currentStrainVersion)
        )
    }
}

public enum TodayHealthSnapshotStoreError: Error, Equatable {
    case invalidSnapshot
    case generationExhausted
}

extension WhoopStore {
    /// Atomically save a dashboard first-paint snapshot. SQLite assigns the accepted row's generation;
    /// wall-clock `generatedAt` never orders writes. A lower raw frontier is rejected. Equal-frontier
    /// writes require the caller's generation to match the row generation, so a stale value cannot replace
    /// a newer unavailable state. A greater raw frontier remains accepted regardless of generation.
    /// Returns true only when the database accepted the write.
    @discardableResult
    public func saveTodayHealthSnapshot(_ snapshot: TodayHealthSnapshot) async throws -> Bool {
        try Self.validate(snapshot)
        let contextId = snapshot.context?.identifier
        return try syncWrite { db in
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT contextId, rawFrontierTs, generation FROM todayHealthSnapshot WHERE scopeId = ?",
                arguments: [snapshot.scopeId]
            ) {
                let existingContextId: String? = existing["contextId"]
                guard existingContextId == contextId else { return false }
                let existingFrontier: Int? = existing["rawFrontierTs"]
                let incomingFrontier = snapshot.rawFrontierTs ?? -1
                let storedFrontier = existingFrontier ?? -1
                guard incomingFrontier >= storedFrontier else {
                    return false
                }
                if incomingFrontier == storedFrontier {
                    let existingGeneration: Int64 = existing["generation"] ?? 0
                    guard snapshot.generation == existingGeneration else { return false }
                }
            }

            let generation = try Self.nextSnapshotGeneration(db)
            let storedSnapshot = snapshot.withGeneration(generation)
            try Self.validate(storedSnapshot)
            let payload = try JSONEncoder().encode(storedSnapshot)
            try db.execute(sql: """
                INSERT INTO todayHealthSnapshot
                    (scopeId, deviceId, displayDay, logicalDay, localDay, generatedAt, rawFrontierTs,
                     schemaVersion, contextId, generation, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(scopeId) DO UPDATE SET
                    deviceId = excluded.deviceId,
                    displayDay = excluded.displayDay,
                    logicalDay = excluded.logicalDay,
                    localDay = excluded.localDay,
                    generatedAt = excluded.generatedAt,
                    rawFrontierTs = excluded.rawFrontierTs,
                    schemaVersion = excluded.schemaVersion,
                    contextId = excluded.contextId,
                    generation = excluded.generation,
                    payload = excluded.payload
                """, arguments: [snapshot.scopeId, snapshot.deviceId, snapshot.displayDay,
                                   snapshot.logicalDay, snapshot.localDay, snapshot.generatedAt,
                                   snapshot.rawFrontierTs, storedSnapshot.schemaVersion, contextId,
                                   generation, payload])
            return db.changesCount > 0
        }
    }

    /// Read exactly one keyed snapshot. The caller can begin its normal repository refresh in parallel.
    public func todayHealthSnapshot(scopeId: String) async throws -> TodayHealthSnapshot? {
        try syncRead { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT contextId, generation, payload FROM todayHealthSnapshot WHERE scopeId = ? LIMIT 1",
                arguments: [scopeId]
            ) else { return nil }
            let payload: Data = row["payload"]
            let snapshot = try JSONDecoder().decode(TodayHealthSnapshot.self, from: payload)
            let storedContextId: String? = row["contextId"]
            guard snapshot.context?.identifier == storedContextId else {
                throw TodayHealthSnapshotStoreError.invalidSnapshot
            }
            let storedGeneration: Int64 = row["generation"] ?? 0
            let hydrated = snapshot.generation == storedGeneration
                ? snapshot
                : snapshot.withGeneration(storedGeneration)
            try Self.validate(hydrated)
            return hydrated
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

    private static func nextSnapshotGeneration(_ db: Database) throws -> Int64 {
        let current = Int64(try Int.fetchOne(
            db,
            sql: "SELECT value FROM todayHealthSnapshotGeneration WHERE id = 1"
        ) ?? 0)
        guard current < Int64.max else { throw TodayHealthSnapshotStoreError.generationExhausted }
        let next = current + 1
        try db.execute(
            sql: "UPDATE todayHealthSnapshotGeneration SET value = ? WHERE id = 1",
            arguments: [next]
        )
        return next
    }

    private static func validate(_ snapshot: TodayHealthSnapshot) throws {
        guard !snapshot.scopeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !snapshot.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !snapshot.displayDay.isEmpty,
              !snapshot.logicalDay.isEmpty,
              !snapshot.localDay.isEmpty,
              snapshot.displayDay == snapshot.dailyMetric.day,
              snapshot.generatedAt >= 0,
              snapshot.generation >= 0,
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

            // The duplicated daily fields are only a same-day presentation row. Carried Recovery/Sleep
            // evidence remains available above, but must not contaminate the current-day DailyMetric.
            guard snapshot.dailyMetric.recovery == Self.currentDayValue(snapshot, metric: .recovery),
                  snapshot.dailyMetric.strain == Self.currentDayValue(snapshot, metric: .strain),
                  snapshot.dailyMetric.strainVersion == Self.currentDayStrainVersion(snapshot),
                  snapshot.dailyMetric.totalSleepMin == Self.currentDayValue(snapshot,
                                                                              metric: .sleepDurationMinutes)
            else { throw TodayHealthSnapshotStoreError.invalidSnapshot }
        }

        for kind in TodayHealthSnapshot.Metric.allCases {
            switch snapshot.state(for: kind) {
            case .unknown:
                continue
            case let .value(metric):
                guard metric.value.isFinite,
                      !metric.sourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      metric.observedAt.map({ $0 >= 0 }) ?? true,
                      metric.rawFrontierTs.map({ $0 >= 0 }) ?? true,
                      metric.generation >= 0,
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
            case let .unavailable(evidence):
                guard !evidence.metricDay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !evidence.sourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      evidence.observedAt >= 0,
                      evidence.rawFrontierTs.map({ $0 >= 0 }) ?? true,
                      !evidence.algorithmVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      evidence.generation >= 0
                else { throw TodayHealthSnapshotStoreError.invalidSnapshot }
            }
        }
    }

    private static func currentDayValue(
        _ snapshot: TodayHealthSnapshot,
        metric: TodayHealthSnapshot.Metric
    ) -> Double? {
        guard let value = snapshot.state(for: metric).value,
              value.metricDay == snapshot.displayDay
        else { return nil }
        return value.value
    }

    private static func currentDayStrainVersion(_ snapshot: TodayHealthSnapshot) -> Int? {
        guard currentDayValue(snapshot, metric: .strain) != nil else { return nil }
        return snapshot.strain?.strainVersion
    }
}
