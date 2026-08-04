// Add to Strand/Data and use inside TodayHealthSnapshot.hasSamePresentation(as:).
// Metadata-only updates must not rebuild value-fed SwiftUI surfaces.

import Foundation
import NoopPhase34Core
import WhoopStore

enum TodaySnapshotPresentationIdentityBuilder {
    static func build(_ snapshot: TodayHealthSnapshot) throws -> SnapshotPresentationIdentity {
        let logicalDay = try CivilDay(key: snapshot.logicalDay)
        let metrics = Dictionary(uniqueKeysWithValues: metricMap.map { snapshotMetric, coreMetric in
            let identity: PresentedHealthMetricIdentity
            switch snapshot.state(for: snapshotMetric) {
            case .unknown:
                identity = PresentedHealthMetricIdentity(
                    kind: coreMetric,
                    value: nil,
                    metricDay: nil,
                    sourceLabel: nil,
                    freshness: nil,
                    displayModel: "unknown"
                )
            case .unavailable(let evidence):
                identity = PresentedHealthMetricIdentity(
                    kind: coreMetric,
                    value: nil,
                    metricDay: try? CivilDay(key: evidence.metricDay),
                    sourceLabel: evidence.sourceId,
                    freshness: .stale,
                    displayModel: "unavailable:\(evidence.reason.rawValue)"
                )
            case .value(let value):
                identity = PresentedHealthMetricIdentity(
                    kind: coreMetric,
                    value: value.value,
                    metricDay: value.metricDay.flatMap { try? CivilDay(key: $0) },
                    sourceLabel: value.sourceId,
                    freshness: coreFreshness(value.freshness),
                    displayModel: value.algorithmVersion
                )
            }
            return (coreMetric, identity)
        })
        return SnapshotPresentationIdentity(logicalDay: logicalDay, metrics: metrics)
    }

    private static let metricMap: [(TodayHealthSnapshot.Metric, HealthMetricKind)] = [
        (.recovery, .recovery),
        (.strain, .strain),
        (.sleepScore, .sleepScore),
        (.sleepDurationMinutes, .sleepDurationMinutes),
    ]

    private static func coreFreshness(
        _ freshness: TodayHealthMetricFreshness?
    ) -> HealthMetricFreshness? {
        switch freshness {
        case .fresh: return .fresh
        case .aging: return .aging
        case .stale: return .stale
        case .none: return nil
        }
    }
}

/*
Replace `TodayHealthSnapshot.hasSamePresentation(as:)` with:

    public func hasSamePresentation(as other: TodayHealthSnapshot) -> Bool {
        guard scopeId == other.scopeId,
              context == other.context,
              deviceId == other.deviceId,
              displayDay == other.displayDay,
              dailyMetric == other.dailyMetric else { return false }
        return (try? TodaySnapshotPresentationIdentityBuilder.build(self))
            == (try? TodaySnapshotPresentationIdentityBuilder.build(other))
    }

Do not compare `TodayHealthMetricValue` directly. Its Equatable graph contains generation, observedAt, and raw
frontier metadata. Those fields are useful for evidence ordering but are not visible presentation identity.
*/
