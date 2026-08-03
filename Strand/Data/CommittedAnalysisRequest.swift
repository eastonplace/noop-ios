import Foundation

/// Stable source identity carried across the later analysis boundary.
///
/// `deviceId` is optional because some future committed sources may not be wearable-backed. A historical
/// WHOOP receipt should provide both values so restore, re-pair, and source replacement boundaries remain
/// fenced by the coordinator.
struct AnalysisSourceDeviceLineage: Codable, Equatable, Hashable, Sendable {
    let sourceId: String
    let deviceId: String?

    init(sourceId: String, deviceId: String? = nil) {
        self.sourceId = sourceId
        self.deviceId = deviceId
    }
}

/// The durable edge a mutation receipt advances. The timestamp is the source frontier associated with the
/// consumed receipt, when the source supplied one; generation remains the authoritative ordering key.
struct AnalysisReceiptFrontier: Codable, Equatable, Sendable {
    let generation: Int64
    let timestamp: Date?

    init(generation: Int64, timestamp: Date? = nil) {
        self.generation = generation
        self.timestamp = timestamp
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
    ) {
        self.databaseInstanceId = databaseInstanceId
        self.sourceDeviceLineage = sourceDeviceLineage
        self.throughReceiptGeneration = throughReceiptGeneration
        self.minimumTimestamp = minimumTimestamp
        self.maximumTimestamp = maximumTimestamp
        self.touchedCivilDays = touchedCivilDays
        self.timestampHealState = timestampHealState
        self.timestampHealDays = timestampHealDays
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
    ) {
        self.databaseInstanceId = databaseInstanceId
        self.sourceDeviceLineage = sourceDeviceLineage
        self.consumedReceiptFrontier = consumedReceiptFrontier
        self.analyzedDays = Array(Set(analyzedDays)).sorted()
        self.algorithmBundleVersion = algorithmBundleVersion
        self.changedDailyMetricIdentifiers = Array(Set(changedDailyMetricIdentifiers)).sorted()
        self.changedScoreIdentifiers = Array(Set(changedScoreIdentifiers)).sorted()
    }
}
