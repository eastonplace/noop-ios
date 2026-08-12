import Foundation

public enum LatestStateDeliveryIdentity: Codable, Equatable, Sendable {
    case widget(
        presentationIdentity: SnapshotPresentationIdentity,
        widgetCore: VerifiedWidgetCorePayload
    )
    case liveActivity(presentationIdentity: SnapshotPresentationIdentity)
    case watch(presentationIdentity: SnapshotPresentationIdentity)

    public var destination: DownstreamDestination {
        switch self {
        case .widget: return .widget
        case .liveActivity: return .liveActivity
        case .watch: return .watch
        }
    }

    public var presentationIdentity: SnapshotPresentationIdentity {
        switch self {
        case let .widget(presentationIdentity, _),
             let .liveActivity(presentationIdentity),
             let .watch(presentationIdentity):
            return presentationIdentity
        }
    }

    public var widgetCore: VerifiedWidgetCorePayload? {
        guard case let .widget(_, widgetCore) = self else { return nil }
        return widgetCore
    }

    public static func make(
        destination: DownstreamDestination,
        projection: VerifiedHealthProjection,
        widgetCore: VerifiedWidgetCorePayload
    ) -> LatestStateDeliveryIdentity? {
        switch destination {
        case .widget:
            return .widget(
                presentationIdentity: projection.presentationIdentity,
                widgetCore: widgetCore
            )
        case .liveActivity:
            return .liveActivity(
                presentationIdentity: liveActivityPresentationIdentity(
                    projection: projection
                )
            )
        case .watch:
            return .watch(presentationIdentity: projection.presentationIdentity)
        case .healthKit:
            return nil
        }
    }

    private static func liveActivityPresentationIdentity(
        projection: VerifiedHealthProjection
    ) -> SnapshotPresentationIdentity {
        let full = projection.presentationIdentity
        return SnapshotPresentationIdentity(
            logicalDay: projection.logicalDay,
            metrics: Dictionary(uniqueKeysWithValues: [
                HealthMetricKind.recovery,
                .strain,
            ].compactMap { kind in
                full.metrics[kind].map { (kind, $0) }
            })
        )
    }
}

public struct LatestStateDeliveryCheckpoint: Codable, Equatable, Sendable {
    public let contextId: String
    public let identity: LatestStateDeliveryIdentity
    public let logicalDay: CivilDay
    public let deliveredAt: Date

    public var destination: DownstreamDestination { identity.destination }
    public var presentationIdentity: SnapshotPresentationIdentity {
        identity.presentationIdentity
    }
    public var widgetCore: VerifiedWidgetCorePayload? { identity.widgetCore }

    public init(
        contextId: String,
        identity: LatestStateDeliveryIdentity,
        logicalDay: CivilDay,
        deliveredAt: Date
    ) {
        self.contextId = contextId
        self.identity = identity
        self.logicalDay = logicalDay
        self.deliveredAt = deliveredAt
    }

    /// Source compatibility for v49 Widget-only checkpoint callers.
    public init(
        contextId: String,
        presentationIdentity: SnapshotPresentationIdentity,
        widgetCore: VerifiedWidgetCorePayload,
        logicalDay: CivilDay,
        deliveredAt: Date
    ) {
        self.init(
            contextId: contextId,
            identity: .widget(
                presentationIdentity: presentationIdentity,
                widgetCore: widgetCore
            ),
            logicalDay: logicalDay,
            deliveredAt: deliveredAt
        )
    }
}

public enum SelectiveExternalPublicationPlan {
    public static let heartbeatInterval: TimeInterval = 60 * 60

    public static func destinations(
        snapshot: SnapshotCommitReceipt,
        bundle: VerifiedExternalProjectionBundle,
        previousLatestState: [DownstreamDestination: LatestStateDeliveryCheckpoint],
        now: Date
    ) -> Set<DownstreamDestination> {
        var result: Set<DownstreamDestination> = [.healthKit]
        let projection = snapshot.projection
        guard bundle.projection == projection else { return result }

        for destination in [DownstreamDestination.widget, .liveActivity] {
            guard let incomingIdentity = LatestStateDeliveryIdentity.make(
                destination: destination,
                projection: projection,
                widgetCore: bundle.widgetCore
            ) else { continue }
            let previous = previousLatestState[destination]
            let identityChanged = previous?.contextId != projection.contextId
                || previous?.destination != destination
                || previous?.identity != incomingIdentity
                || previous?.logicalDay != projection.logicalDay
            let heartbeatDue = previous.map {
                now.timeIntervalSince($0.deliveredAt) >= heartbeatInterval
            } ?? true
            if identityChanged || heartbeatDue {
                result.insert(destination)
            }
        }
        return result
    }

    /// Compatibility bridge for callers that only have v49 Widget evidence.
    public static func destinations(
        snapshot: SnapshotCommitReceipt,
        bundle: VerifiedExternalProjectionBundle,
        previousLatestState: LatestStateDeliveryCheckpoint?,
        now: Date
    ) -> Set<DownstreamDestination> {
        destinations(
            snapshot: snapshot,
            bundle: bundle,
            previousLatestState: previousLatestState.map {
                [$0.destination: $0]
            } ?? [:],
            now: now
        )
    }
}

/*
Outbox integration:

- Persist one latest-state checkpoint per active context only after Widget/Live
  delivery succeeds or reports alreadyCurrent.
- `commitOutbox` loads the immutable projection bundle and this checkpoint.
- Historical-only unchanged work therefore enqueues HealthKit only.
- Auxiliary-only Widget core changes still enqueue Widget because they are part
  of the checkpoint identity.
- Do not compare analysisGeneration and snapshotGeneration numerically.
*/
