import Foundation

public enum VerifiedHealthProjectionError: Error, Equatable, Sendable {
    case invalidContext
    case invalidGeneration
    case invalidValue(HealthMetricKind)
    case metricKindMismatch
}

public struct VerifiedHealthMetric: Codable, Equatable, Sendable {
    public let kind: HealthMetricKind
    public let value: Double
    public let metricDay: CivilDay
    public let sourceId: String
    public let algorithmVersion: String
    public let generation: Int64
    public let observedAt: Int?
    public let rawFrontierTs: Int?
    public let freshness: HealthMetricFreshness

    public init(
        kind: HealthMetricKind,
        value: Double,
        metricDay: CivilDay,
        sourceId: String,
        algorithmVersion: String,
        generation: Int64,
        observedAt: Int? = nil,
        rawFrontierTs: Int? = nil,
        freshness: HealthMetricFreshness
    ) throws {
        guard !sourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !algorithmVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              generation > 0,
              observedAt.map({ $0 >= 0 }) ?? true,
              rawFrontierTs.map({ $0 >= 0 }) ?? true else {
            throw VerifiedHealthProjectionError.invalidContext
        }
        guard Self.isValid(value: value, for: kind) else {
            throw VerifiedHealthProjectionError.invalidValue(kind)
        }
        self.kind = kind
        self.value = value
        self.metricDay = metricDay
        self.sourceId = sourceId
        self.algorithmVersion = algorithmVersion
        self.generation = generation
        self.observedAt = observedAt
        self.rawFrontierTs = rawFrontierTs
        self.freshness = freshness
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                kind: container.decode(HealthMetricKind.self, forKey: .kind),
                value: container.decode(Double.self, forKey: .value),
                metricDay: container.decode(CivilDay.self, forKey: .metricDay),
                sourceId: container.decode(String.self, forKey: .sourceId),
                algorithmVersion: container.decode(String.self, forKey: .algorithmVersion),
                generation: container.decode(Int64.self, forKey: .generation),
                observedAt: container.decodeIfPresent(Int.self, forKey: .observedAt),
                rawFrontierTs: container.decodeIfPresent(Int.self, forKey: .rawFrontierTs),
                freshness: container.decode(HealthMetricFreshness.self, forKey: .freshness)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "VerifiedHealthMetric failed validation."
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case metricDay
        case sourceId
        case algorithmVersion
        case generation
        case observedAt
        case rawFrontierTs
        case freshness
    }

    public var presentationIdentity: PresentedHealthMetricIdentity {
        PresentedHealthMetricIdentity(
            kind: kind,
            value: value,
            metricDay: metricDay,
            sourceLabel: sourceId,
            freshness: freshness,
            displayModel: algorithmVersion
        )
    }

    private static func isValid(value: Double, for kind: HealthMetricKind) -> Bool {
        guard value.isFinite else { return false }
        switch kind {
        case .recovery, .sleepScore, .strain:
            return (0...100).contains(value)
        case .sleepDurationMinutes:
            return (0...1_440).contains(value)
        }
    }
}

/// One verified generation for every user-facing surface. A surface may render a subset, but it may not
/// independently select a different score generation.
public struct VerifiedHealthProjection: Codable, Equatable, Sendable {
    public let contextId: String
    /// Device/source deletion uses this explicit owner. Do not parse ownership from contextId.
    public let deviceId: String
    public let generation: Int64
    public let logicalDay: CivilDay
    public let metrics: [HealthMetricKind: VerifiedHealthMetric]

    public init(
        contextId: String,
        deviceId: String,
        generation: Int64,
        logicalDay: CivilDay,
        metrics: [HealthMetricKind: VerifiedHealthMetric]
    ) throws {
        guard !contextId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VerifiedHealthProjectionError.invalidContext
        }
        guard generation > 0 else { throw VerifiedHealthProjectionError.invalidGeneration }
        guard metrics.allSatisfy({ $0.key == $0.value.kind && $0.value.generation <= generation }) else {
            throw VerifiedHealthProjectionError.metricKindMismatch
        }
        self.contextId = contextId
        self.deviceId = deviceId
        self.generation = generation
        self.logicalDay = logicalDay
        self.metrics = metrics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                contextId: container.decode(String.self, forKey: .contextId),
                deviceId: container.decode(String.self, forKey: .deviceId),
                generation: container.decode(Int64.self, forKey: .generation),
                logicalDay: container.decode(CivilDay.self, forKey: .logicalDay),
                metrics: container.decode([HealthMetricKind: VerifiedHealthMetric].self, forKey: .metrics)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .generation,
                in: container,
                debugDescription: "VerifiedHealthProjection failed validation."
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case contextId
        case deviceId
        case generation
        case logicalDay
        case metrics
    }

    /// Strain is intraday and cannot be carried from a prior physiological day. Recovery and Sleep may stay
    /// visible as the latest scored night, provided their freshness label remains honest.
    public func visibleMetric(_ kind: HealthMetricKind) -> VerifiedHealthMetric? {
        guard let metric = metrics[kind] else { return nil }
        if kind == .strain, metric.metricDay != logicalDay { return nil }
        return metric
    }

    /// Shared external-surface accessor. Keeping the day-validity rule here prevents Widget, Live Activity,
    /// and HealthKit adapters from each re-implementing the current-day Strain guard.
    public var visibleStrainValue: Double? {
        guard let entry = metrics.first(where: { $0.key.rawValue == "strain" }),
              entry.value.metricDay == logicalDay else { return nil }
        return entry.value.value
    }

    public var presentationIdentity: SnapshotPresentationIdentity {
        SnapshotPresentationIdentity(
            logicalDay: logicalDay,
            metrics: Dictionary(uniqueKeysWithValues: HealthMetricKind.allCases.map { kind in
                let identity = visibleMetric(kind)?.presentationIdentity
                    ?? PresentedHealthMetricIdentity(
                        kind: kind,
                        value: nil,
                        metricDay: nil,
                        sourceLabel: nil,
                        freshness: nil
                    )
                return (kind, identity)
            })
        )
    }
}
