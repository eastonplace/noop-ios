import Foundation

enum AnalysisFenceValidationError: Error, Equatable, Sendable {
    case emptyAlgorithmBundleVersion
    case emptyDatabaseInstanceId
    case emptySourceId
    case invalidGeneration
}

private func hasFenceValue(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Stable source identity carried across the later analysis boundary.
///
/// `deviceId` is optional because some future committed sources may not be wearable-backed. A historical
/// WHOOP receipt should provide both values so restore, re-pair, and source replacement boundaries remain
/// fenced by the coordinator.
struct AnalysisSourceDeviceLineage: Codable, Equatable, Hashable, Sendable {
    let sourceId: String
    let deviceId: String?

    init(sourceId: String, deviceId: String? = nil) throws {
        guard hasFenceValue(sourceId) else {
            throw AnalysisFenceValidationError.emptySourceId
        }
        self.sourceId = sourceId
        self.deviceId = deviceId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sourceId: container.decode(String.self, forKey: .sourceId),
            deviceId: container.decodeIfPresent(String.self, forKey: .deviceId)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sourceId
        case deviceId
    }
}

/// The durable edge a mutation receipt advances. The timestamp is the source frontier associated with the
/// consumed receipt, when the source supplied one; generation remains the authoritative ordering key.
struct AnalysisReceiptFrontier: Codable, Equatable, Sendable {
    let generation: Int64
    let timestamp: Date?

    init(generation: Int64, timestamp: Date? = nil) throws {
        guard generation >= 0 else {
            throw AnalysisFenceValidationError.invalidGeneration
        }
        self.generation = generation
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            generation: container.decode(Int64.self, forKey: .generation),
            timestamp: container.decodeIfPresent(Date.self, forKey: .timestamp)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case generation
        case timestamp
    }
}

/// State of timestamp cleanup at admission time. This is intentionally separate from the explicit days that
/// cleanup touched: a completed heal can still require those days to be re-analyzed.
enum TimestampHealState: String, Codable, Equatable, Sendable {
    case notRequested
    case requested
    case completed
}

/// Typed seam between a durable committed-data edge and a future analysis coordinator.
///
/// This value does not run scoring or imply that any daily metric changed. It only carries the committed
/// source identity, timestamp envelope, explicit daily touch evidence, and the receipt edge that admitted it.
struct CommittedAnalysisRequest: Codable, Equatable, Sendable {
    let databaseInstanceId: String
    let sourceDeviceLineage: AnalysisSourceDeviceLineage
    let throughReceiptGeneration: Int64
    let minimumTimestamp: Date?
    let maximumTimestamp: Date?
    let touchedCivilDays: Set<AnalysisCivilDay>
    let timestampHealState: TimestampHealState
    let timestampHealDays: Set<AnalysisCivilDay>

    init(
        databaseInstanceId: String,
        sourceDeviceLineage: AnalysisSourceDeviceLineage,
        throughReceiptGeneration: Int64,
        minimumTimestamp: Date? = nil,
        maximumTimestamp: Date? = nil,
        touchedCivilDays: Set<AnalysisCivilDay> = [],
        timestampHealState: TimestampHealState = .notRequested,
        timestampHealDays: Set<AnalysisCivilDay> = []
    ) throws {
        guard hasFenceValue(databaseInstanceId) else {
            throw AnalysisFenceValidationError.emptyDatabaseInstanceId
        }
        guard throughReceiptGeneration >= 0 else {
            throw AnalysisFenceValidationError.invalidGeneration
        }
        self.databaseInstanceId = databaseInstanceId
        self.sourceDeviceLineage = sourceDeviceLineage
        self.throughReceiptGeneration = throughReceiptGeneration
        self.minimumTimestamp = minimumTimestamp
        self.maximumTimestamp = maximumTimestamp
        self.touchedCivilDays = touchedCivilDays
        self.timestampHealState = timestampHealState
        self.timestampHealDays = timestampHealDays
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            databaseInstanceId: container.decode(String.self, forKey: .databaseInstanceId),
            sourceDeviceLineage: container.decode(AnalysisSourceDeviceLineage.self, forKey: .sourceDeviceLineage),
            throughReceiptGeneration: container.decode(Int64.self, forKey: .throughReceiptGeneration),
            minimumTimestamp: container.decodeIfPresent(Date.self, forKey: .minimumTimestamp),
            maximumTimestamp: container.decodeIfPresent(Date.self, forKey: .maximumTimestamp),
            touchedCivilDays: container.decode(Set<AnalysisCivilDay>.self, forKey: .touchedCivilDays),
            timestampHealState: container.decode(TimestampHealState.self, forKey: .timestampHealState),
            timestampHealDays: container.decode(Set<AnalysisCivilDay>.self, forKey: .timestampHealDays)
        )
    }

    var window: CommittedAnalysisWindow {
        CommittedAnalysisWindow(
            minimumTimestamp: minimumTimestamp,
            maximumTimestamp: maximumTimestamp,
            touchedCivilDays: touchedCivilDays,
            timestampHealDays: timestampHealDays
        )
    }

    func affectedDays(using calendar: Calendar) throws -> Set<AnalysisCivilDay> {
        try window.affectedDays(using: calendar)
    }

    private enum CodingKeys: String, CodingKey {
        case databaseInstanceId
        case sourceDeviceLineage
        case throughReceiptGeneration
        case minimumTimestamp
        case maximumTimestamp
        case touchedCivilDays
        case timestampHealState
        case timestampHealDays
    }
}

/// Durable acknowledgement of one later analysis mutation.
///
/// The receipt identifies the consumed committed-data edge and the days the coordinator examined. Changed
/// identifiers are opaque strings by design: the seam does not name or calculate scoring formulas.
struct AnalysisMutationReceipt: Codable, Equatable, Sendable {
    let databaseInstanceId: String
    let sourceDeviceLineage: AnalysisSourceDeviceLineage
    let consumedReceiptFrontier: AnalysisReceiptFrontier
    let analyzedDays: [AnalysisCivilDay]
    let algorithmBundleVersion: String
    let changedDailyMetricIdentifiers: [String]
    let changedScoreIdentifiers: [String]

    var consumedReceiptGeneration: Int64 { consumedReceiptFrontier.generation }
    var consumedReceiptTimestamp: Date? { consumedReceiptFrontier.timestamp }

    init(
        databaseInstanceId: String,
        sourceDeviceLineage: AnalysisSourceDeviceLineage,
        consumedReceiptFrontier: AnalysisReceiptFrontier,
        analyzedDays: [AnalysisCivilDay],
        algorithmBundleVersion: String,
        changedDailyMetricIdentifiers: [String] = [],
        changedScoreIdentifiers: [String] = []
    ) throws {
        guard hasFenceValue(databaseInstanceId) else {
            throw AnalysisFenceValidationError.emptyDatabaseInstanceId
        }
        guard hasFenceValue(algorithmBundleVersion) else {
            throw AnalysisFenceValidationError.emptyAlgorithmBundleVersion
        }
        self.databaseInstanceId = databaseInstanceId
        self.sourceDeviceLineage = sourceDeviceLineage
        self.consumedReceiptFrontier = consumedReceiptFrontier
        self.analyzedDays = Array(Set(analyzedDays)).sorted()
        self.algorithmBundleVersion = algorithmBundleVersion
        self.changedDailyMetricIdentifiers = Array(Set(changedDailyMetricIdentifiers)).sorted()
        self.changedScoreIdentifiers = Array(Set(changedScoreIdentifiers)).sorted()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            databaseInstanceId: container.decode(String.self, forKey: .databaseInstanceId),
            sourceDeviceLineage: container.decode(AnalysisSourceDeviceLineage.self, forKey: .sourceDeviceLineage),
            consumedReceiptFrontier: container.decode(AnalysisReceiptFrontier.self, forKey: .consumedReceiptFrontier),
            analyzedDays: container.decode([AnalysisCivilDay].self, forKey: .analyzedDays),
            algorithmBundleVersion: container.decode(String.self, forKey: .algorithmBundleVersion),
            changedDailyMetricIdentifiers: container.decode([String].self, forKey: .changedDailyMetricIdentifiers),
            changedScoreIdentifiers: container.decode([String].self, forKey: .changedScoreIdentifiers)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case databaseInstanceId
        case sourceDeviceLineage
        case consumedReceiptFrontier
        case analyzedDays
        case algorithmBundleVersion
        case changedDailyMetricIdentifiers
        case changedScoreIdentifiers
    }
}
