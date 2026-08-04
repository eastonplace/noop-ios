// Add to StrandiOS/App or a shared iOS target. One worker serializes durable downstream side effects.

#if os(iOS)
import Foundation
import NoopPhase34Core
import WhoopStore

struct ExternalPublicationWorkerDependencies: Sendable {
    let leaseNext: @Sendable @MainActor (_ owner: String, _ now: Date, _ leaseDuration: TimeInterval) async throws -> ExternalPublicationOutboxItem?
    let applyEvent: @Sendable @MainActor (_ key: String, _ event: ExternalPublicationEvent, _ now: Date) async throws -> ExternalPublicationOutboxItem
    let loadProjection: @Sendable @MainActor (_ contextId: String, _ generation: Int64) async throws -> VerifiedHealthProjection?
    /// Latest-state sinks must atomically ignore a projection older than the generation already stored.
    let publishWidget: @Sendable @MainActor (VerifiedHealthProjection) async throws -> Void
    let publishLiveActivity: @Sendable @MainActor (VerifiedHealthProjection) async throws -> Void
    /// HealthKit is historical mutation delivery. Query and write the exact durable score rows for
    /// `changedDays` at `analysisGeneration`; the current projection is only shared context and provenance.
    let publishHealthKitWriteOnly: @Sendable @MainActor (
        _ projection: VerifiedHealthProjection,
        _ analysisGeneration: Int64,
        _ changedDays: Set<CivilDay>,
        _ recordedTimeZoneIdentifier: String
    ) async throws -> Void
    /// The watch sink must ignore generations older than its last accepted generation.
    let publishWatch: @Sendable @MainActor (VerifiedHealthProjection) async throws -> Void
    let classifyError: @Sendable (any Error) -> PipelineFailureClassification
    let pruneCompleted: @Sendable @MainActor () async throws -> Void
    /// Privacy-safe diagnostic sink. It receives stable operation codes and error text only.
    let report: @Sendable (String) -> Void
    let now: @Sendable () -> Date
}

actor ExternalPublicationWorker {
    private let dependencies: ExternalPublicationWorkerDependencies
    private let owner = UUID().uuidString
    private let leaseDuration: TimeInterval
    private var running = false
    private var rerunRequested = false

    init(
        dependencies: ExternalPublicationWorkerDependencies,
        leaseDuration: TimeInterval = 60
    ) {
        self.dependencies = dependencies
        self.leaseDuration = max(15, leaseDuration)
    }

    func signal(maximumItems: Int = 32) async {
        guard !running else {
            rerunRequested = true
            return
        }
        running = true
        defer { running = false }

        repeat {
            rerunRequested = false
            var exhaustedBatchBudget = true
            for _ in 0..<max(1, maximumItems) {
                if Task.isCancelled {
                    exhaustedBatchBudget = false
                    break
                }

                let leased: ExternalPublicationOutboxItem
                do {
                    guard let next = try await dependencies.leaseNext(
                        owner,
                        dependencies.now(),
                        leaseDuration
                    ) else {
                        exhaustedBatchBudget = false
                        break
                    }
                    leased = next
                } catch {
                    dependencies.report("external_outbox_lease_failed: \(error)")
                    exhaustedBatchBudget = false
                    break
                }

                await process(leased)
            }

            // A batch cap yields to the app. It does not strand ready durable work until another lifecycle event.
            if exhaustedBatchBudget && !Task.isCancelled {
                rerunRequested = true
                await Task.yield()
            }
        } while rerunRequested && !Task.isCancelled

        do {
            try await dependencies.pruneCompleted()
        } catch {
            dependencies.report("external_projection_prune_failed: \(error)")
        }
    }

    private func process(_ leased: ExternalPublicationOutboxItem) async {
        do {
            _ = try await dependencies.applyEvent(
                leased.idempotencyKey,
                .begin(owner: owner),
                dependencies.now()
            )

            // HealthKit and Watch can suspend beyond the first lease on a busy phone. Keep the same durable
            // owner alive. A failed renewal ends the heartbeat; the next state transition still fails closed.
            let heartbeatInterval = max(1, leaseDuration / 3)
            let heartbeat = Task {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(heartbeatInterval))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    do {
                        _ = try await dependencies.applyEvent(
                            leased.idempotencyKey,
                            .renew(
                                owner: owner,
                                expiresAt: dependencies.now().addingTimeInterval(leaseDuration)
                            ),
                            dependencies.now()
                        )
                    } catch {
                        dependencies.report("external_outbox_lease_renew_failed: \(error)")
                        return
                    }
                }
            }
            defer { heartbeat.cancel() }

            guard let projection = try await dependencies.loadProjection(
                leased.contextId,
                leased.snapshotGeneration
            ) else {
                throw ExternalPublicationWorkerError.projectionMissing
            }
            guard projection.contextId == leased.contextId,
                  projection.deviceId == leased.deviceId,
                  projection.generation == leased.snapshotGeneration else {
                throw ExternalPublicationWorkerError.projectionMismatch
            }

            switch leased.destination {
            case .widget:
                try await dependencies.publishWidget(projection)
            case .liveActivity:
                try await dependencies.publishLiveActivity(projection)
            case .healthKit:
                try await dependencies.publishHealthKitWriteOnly(
                    projection,
                    leased.analysisGeneration,
                    leased.changedDays,
                    leased.recordedTimeZoneIdentifier
                )
            case .watch:
                try await dependencies.publishWatch(projection)
            }

            _ = try await dependencies.applyEvent(
                leased.idempotencyKey,
                .succeeded(owner: owner),
                dependencies.now()
            )
        } catch {
            let classification = dependencies.classifyError(error)
            do {
                _ = try await dependencies.applyEvent(
                    leased.idempotencyKey,
                    .failed(
                        owner: owner,
                        code: classification.code,
                        retryable: classification.retryable
                    ),
                    dependencies.now()
                )
            } catch {
                // The lease remains durable and can expire. Surface the failure; never invent success.
                dependencies.report("external_outbox_failure_state_failed: \(error)")
            }
        }
    }
}

enum ExternalPublicationWorkerError: Error {
    case projectionMissing
    case projectionMismatch
    case destinationUnavailable
}
#endif
