// Copy into Strand/Data. Build the one surface projection only from a verified, schema-current snapshot.

import Foundation
import NoopPhase34Core
import WhoopStore

enum VerifiedHealthProjectionBuilderError: Error {
    case missingContext
    case unsupportedSnapshotSchema
    case missingAlgorithm(TodayHealthSnapshot.Metric)
    case invalidDay(String)
}

enum VerifiedHealthProjectionBuilder {
    static func build(from snapshot: TodayHealthSnapshot) throws -> VerifiedHealthProjection {
        guard snapshot.schemaVersion == TodayHealthSnapshot.currentSchemaVersion else {
            throw VerifiedHealthProjectionBuilderError.unsupportedSnapshotSchema
        }
        guard let context = snapshot.context else {
            throw VerifiedHealthProjectionBuilderError.missingContext
        }
        let logicalDay: CivilDay
        do { logicalDay = try CivilDay(key: snapshot.logicalDay) }
        catch { throw VerifiedHealthProjectionBuilderError.invalidDay(snapshot.logicalDay) }

        var metrics: [HealthMetricKind: VerifiedHealthMetric] = [:]
        for (snapshotKind, coreKind) in metricMap {
            guard case .value(let value) = snapshot.state(for: snapshotKind) else { continue }
            guard let metricDayKey = value.metricDay else {
                throw VerifiedHealthProjectionBuilderError.invalidDay("missing")
            }
            let metricDay: CivilDay
            do { metricDay = try CivilDay(key: metricDayKey) }
            catch { throw VerifiedHealthProjectionBuilderError.invalidDay(metricDayKey) }
            let algorithm = value.algorithmVersion
                ?? importedAlgorithmLabel(sourceId: value.sourceId)
            guard let algorithm, !algorithm.isEmpty else {
                throw VerifiedHealthProjectionBuilderError.missingAlgorithm(snapshotKind)
            }
            metrics[coreKind] = try VerifiedHealthMetric(
                kind: coreKind,
                value: value.value,
                metricDay: metricDay,
                sourceId: value.sourceId,
                algorithmVersion: algorithm,
                generation: value.generation,
                observedAt: value.observedAt,
                rawFrontierTs: value.rawFrontierTs,
                freshness: coreFreshness(value.freshness)
            )
        }
        return try VerifiedHealthProjection(
            contextId: context.identifier,
            deviceId: snapshot.deviceId,
            generation: snapshot.generation,
            logicalDay: logicalDay,
            metrics: metrics
        )
    }

    private static let metricMap: [(TodayHealthSnapshot.Metric, HealthMetricKind)] = [
        (.recovery, .recovery),
        (.strain, .strain),
        (.sleepScore, .sleepScore),
        (.sleepDurationMinutes, .sleepDurationMinutes),
    ]

    private static func coreFreshness(
        _ freshness: TodayHealthMetricFreshness?
    ) -> HealthMetricFreshness {
        switch freshness {
        case .fresh: return .fresh
        case .aging: return .aging
        case .stale, .none: return .stale
        }
    }

    private static func importedAlgorithmLabel(sourceId: String) -> String? {
        let normalized = sourceId.lowercased()
        if normalized.contains("whoop") { return "imported-whoop" }
        if normalized.contains("apple") { return "imported-apple-health" }
        return nil
    }
}
