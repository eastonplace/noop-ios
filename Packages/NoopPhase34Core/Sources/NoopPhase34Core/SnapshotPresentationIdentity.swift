import Foundation

public enum HealthMetricKind: String, Codable, CaseIterable, Hashable, Sendable {
    case recovery
    case strain
    case sleepScore
    case sleepDurationMinutes
}

public enum HealthMetricFreshness: String, Codable, Sendable {
    case fresh
    case aging
    case stale
}

/// Only fields that can change what the user sees belong here. Raw frontiers, database generations, write
/// times, and retry bookkeeping deliberately do not participate in SwiftUI invalidation.
public struct PresentedHealthMetricIdentity: Codable, Equatable, Sendable {
    public let kind: HealthMetricKind
    public let value: Double?
    public let metricDay: CivilDay?
    public let sourceLabel: String?
    public let freshness: HealthMetricFreshness?
    public let displayModel: String?

    public init(
        kind: HealthMetricKind,
        value: Double?,
        metricDay: CivilDay?,
        sourceLabel: String?,
        freshness: HealthMetricFreshness?,
        displayModel: String? = nil
    ) {
        self.kind = kind
        self.value = value
        self.metricDay = metricDay
        self.sourceLabel = sourceLabel
        self.freshness = freshness
        self.displayModel = displayModel
    }
}

public struct SnapshotPresentationIdentity: Codable, Equatable, Sendable {
    public let logicalDay: CivilDay
    public let metrics: [HealthMetricKind: PresentedHealthMetricIdentity]

    public init(logicalDay: CivilDay, metrics: [HealthMetricKind: PresentedHealthMetricIdentity]) {
        self.logicalDay = logicalDay
        self.metrics = metrics
    }
}
