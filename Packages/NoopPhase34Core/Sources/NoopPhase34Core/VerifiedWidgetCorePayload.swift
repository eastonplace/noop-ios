import Foundation

/// Immutable auxiliary fields rendered by the durable Widget core. These values are captured from the
/// same WAL/snapshot generation as the headline projection; a delayed outbox item never reads whatever
/// Repository rows happen to be current when delivery finally runs.
public struct VerifiedWidgetCorePayload: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let contextId: String
    public let projectionGeneration: Int64
    public let logicalDay: CivilDay
    public let restingHR: Int?
    public let sleepMinutes: Int?
    public let steps: Int?
    public let calories: Int?
    public let recoveryDelta: Int?
    /// Time zone that defined `logicalDay` for this exact generation. Legacy rows omit it; optional
    /// enrichment must then fail closed instead of deriving a new day from the current device zone.
    public let recordedTimeZoneIdentifier: String?
    /// Exact source namespaces that may supply optional Widget enrichment for this immutable generation.
    /// Older payloads decode this as an empty list and fall back to the verified projection owner.
    public let enrichmentSourceIds: [String]

    public init(
        contextId: String,
        projectionGeneration: Int64,
        logicalDay: CivilDay,
        restingHR: Int?,
        sleepMinutes: Int?,
        steps: Int?,
        calories: Int?,
        recoveryDelta: Int?,
        recordedTimeZoneIdentifier: String? = nil,
        enrichmentSourceIds: [String] = []
    ) throws {
        var seenSourceIds = Set<String>()
        let normalizedSourceIds = enrichmentSourceIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenSourceIds.insert($0).inserted }
        guard !contextId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              projectionGeneration > 0,
              restingHR.map({ (20...300).contains($0) }) ?? true,
              sleepMinutes.map({ (0...1_440).contains($0) }) ?? true,
              steps.map({ $0 >= 0 }) ?? true,
              calories.map({ $0 >= 0 }) ?? true,
              recordedTimeZoneIdentifier.map({ TimeZone(identifier: $0) != nil }) ?? true else {
            throw VerifiedWidgetCorePayloadError.invalidPayload
        }
        version = Self.currentVersion
        self.contextId = contextId
        self.projectionGeneration = projectionGeneration
        self.logicalDay = logicalDay
        self.restingHR = restingHR
        self.sleepMinutes = sleepMinutes
        self.steps = steps
        self.calories = calories
        self.recoveryDelta = recoveryDelta
        self.recordedTimeZoneIdentifier = recordedTimeZoneIdentifier
        self.enrichmentSourceIds = normalizedSourceIds
    }

    private enum CodingKeys: String, CodingKey {
        case version, contextId, projectionGeneration, logicalDay
        case restingHR, sleepMinutes, steps, calories, recoveryDelta
        case recordedTimeZoneIdentifier, enrichmentSourceIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw VerifiedWidgetCorePayloadError.unsupportedVersion(version)
        }
        try self.init(
            contextId: container.decode(String.self, forKey: .contextId),
            projectionGeneration: container.decode(Int64.self, forKey: .projectionGeneration),
            logicalDay: container.decode(CivilDay.self, forKey: .logicalDay),
            restingHR: container.decodeIfPresent(Int.self, forKey: .restingHR),
            sleepMinutes: container.decodeIfPresent(Int.self, forKey: .sleepMinutes),
            steps: container.decodeIfPresent(Int.self, forKey: .steps),
            calories: container.decodeIfPresent(Int.self, forKey: .calories),
            recoveryDelta: container.decodeIfPresent(Int.self, forKey: .recoveryDelta),
            recordedTimeZoneIdentifier: container.decodeIfPresent(
                String.self,
                forKey: .recordedTimeZoneIdentifier
            ),
            enrichmentSourceIds: container.decodeIfPresent(
                [String].self,
                forKey: .enrichmentSourceIds
            ) ?? []
        )
    }
}

public enum VerifiedWidgetCorePayloadError: Error, Equatable, Sendable {
    case invalidPayload
    case unsupportedVersion(Int)
}

public struct VerifiedExternalProjectionBundle: Codable, Equatable, Sendable {
    public let projection: VerifiedHealthProjection
    public let widgetCore: VerifiedWidgetCorePayload

    public init(
        projection: VerifiedHealthProjection,
        widgetCore: VerifiedWidgetCorePayload
    ) throws {
        guard projection.contextId == widgetCore.contextId,
              projection.generation == widgetCore.projectionGeneration,
              projection.logicalDay == widgetCore.logicalDay else {
            throw VerifiedWidgetCorePayloadError.invalidPayload
        }
        self.projection = projection
        self.widgetCore = widgetCore
    }

    /// Optional enrichment must stay inside the immutable source set captured with this generation.
    /// The projection owner is the compatibility fallback for payloads written before this field existed.
    public var verifiedEnrichmentSourceIds: [String] {
        if !widgetCore.enrichmentSourceIds.isEmpty {
            return widgetCore.enrichmentSourceIds
        }
        return [projection.deviceId]
    }
}

/*
Integration:

- Build this payload in `buildAndCommitVerifiedHistoricalSnapshotDurableOnly` from
  the same canonical WAL snapshot and stored Today snapshot used for the projection.
- Persist it beside `verifiedHealthProjection` or as the latest-state destination payload.
- `ExternalPublicationWorker.loadBundle` returns VerifiedExternalProjectionBundle.
- `WidgetCorePublication.makeCoreSnapshot` uses `bundle.widgetCore`; it may use only
  current live BPM/battery/bonded as an explicit overlay. It must not read `repo.days`.
- Include widget-core rendered identity in the latest-state delivery checkpoint so an
  auxiliary-only current-day change schedules Widget delivery without forcing unrelated
  history reads.
*/
