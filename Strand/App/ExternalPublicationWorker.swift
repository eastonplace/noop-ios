// Add to StrandiOS/App or a shared iOS target. One worker serializes durable downstream side effects.

#if os(iOS)
import Foundation
import NoopPhase34Core
import WhoopStore

struct ExternalPublicationWorkerDependencies: Sendable {
    let leaseNext: @Sendable @MainActor (
        _ owner: String,
        _ now: Date,
        _ leaseDuration: TimeInterval,
        _ preferredDestination: DownstreamDestination?
    ) async throws -> ExternalPublicationOutboxItem?
    let applyEvent: @Sendable @MainActor (_ key: String, _ event: ExternalPublicationEvent, _ now: Date) async throws -> ExternalPublicationOutboxItem
    let loadProjection: @Sendable @MainActor (_ contextId: String, _ generation: Int64) async throws -> VerifiedHealthProjection?
    /// Latest-state sinks must atomically ignore a projection older than the generation already stored.
    let publishWidget: @Sendable @MainActor (VerifiedHealthProjection) async throws -> ExternalSinkPublicationResult
    let publishLiveActivity: @Sendable @MainActor (VerifiedHealthProjection) async throws -> ExternalSinkPublicationResult
    /// HealthKit is historical mutation delivery. Query and write the exact durable score rows for
    /// `changedDays` at `analysisGeneration`; the current projection is only shared context and provenance.
    let publishHealthKitWriteOnly: @Sendable @MainActor (
        HistoricalHealthKitMutationPayload
    ) async throws -> ExternalSinkPublicationResult
    /// The watch sink must ignore generations older than its last accepted generation.
    let publishWatch: @Sendable @MainActor (VerifiedHealthProjection) async throws -> ExternalSinkPublicationResult
    let classifyError: @Sendable (any Error) -> PipelineFailureClassification
    let pruneCompleted: @Sendable @MainActor () async throws -> Void
    /// Privacy-safe diagnostic sink. It receives stable operation codes and error text only.
    let report: @Sendable (String) -> Void
    let now: @Sendable () -> Date
}

actor ExternalPublicationWorker {
    private let dependencies: ExternalPublicationWorkerDependencies
    private let quiescence = PipelineQuiescence()
    private let owner = UUID().uuidString
    private let leaseDuration: TimeInterval
    private var running = false
    private var rerunRequested = false
    private var activeTask: Task<Void, Never>?
    private var nonHistoricalItemsSinceFairnessYield = 0

    init(
        dependencies: ExternalPublicationWorkerDependencies,
        leaseDuration: TimeInterval = 60
    ) {
        self.dependencies = dependencies
        self.leaseDuration = max(15, leaseDuration)
    }

    func quiesce() async throws -> UInt64 {
        activeTask?.cancel()
        return try await quiescence.quiesce(cancelOwners: { })
    }

    func resume(expectedEpoch: UInt64) async throws {
        try await quiescence.resume(expectedEpoch: expectedEpoch)
    }

    func signal(maximumItems: Int = 32) async {
        guard !running else {
            rerunRequested = true
            return
        }
        running = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drain(maximumItems: maximumItems)
        }
        activeTask = task
        await task.value
        activeTask = nil
        running = false
    }

    private func drain(maximumItems: Int) async {
        let token: PipelineEpochToken
        do {
            token = try await quiescence.begin()
        } catch {
            return
        }
        defer { Task { await quiescence.end(token) } }

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
                    let preferredDestination: DownstreamDestination? =
                        nonHistoricalItemsSinceFairnessYield >= 3 ? .healthKit : nil
                    var next = try await dependencies.leaseNext(
                        owner,
                        dependencies.now(),
                        leaseDuration,
                        preferredDestination
                    )
                    if next == nil, preferredDestination != nil {
                        next = try await dependencies.leaseNext(
                            owner,
                            dependencies.now(),
                            leaseDuration,
                            nil
                        )
                    }
                    guard let next else {
                        exhaustedBatchBudget = false
                        break
                    }
                    leased = next
                    if leased.destination == .healthKit {
                        nonHistoricalItemsSinceFairnessYield = 0
                    } else {
                        nonHistoricalItemsSinceFairnessYield += 1
                    }
                } catch {
                    dependencies.report("external_outbox_lease_failed: \(error)")
                    exhaustedBatchBudget = false
                    break
                }

                await process(leased, token: token)
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

    private func process(
        _ leased: ExternalPublicationOutboxItem,
        token: PipelineEpochToken
    ) async {
        let leaseHealth = ExternalPublicationLeaseHealth()
        do {
            _ = try await dependencies.applyEvent(
                leased.idempotencyKey,
                .begin(owner: owner),
                dependencies.now()
            )
            try await quiescence.validate(token)

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
                        await leaseHealth.invalidate()
                        return
                    }
                }
            }
            defer { heartbeat.cancel() }

            try await quiescence.validate(token)
            try await leaseHealth.requireValid()

            let result: ExternalSinkPublicationResult
            if leased.destination == .healthKit {
                guard let payload = leased.healthKitPayload,
                      payload.validates(
                          contextId: leased.contextId,
                          deviceId: leased.deviceId,
                          analysisGeneration: leased.analysisGeneration,
                          changedDays: leased.changedDays,
                          recordedTimeZoneIdentifier: leased.recordedTimeZoneIdentifier
                      ) else {
                    throw ExternalPublicationWorkerError.payloadMissingOrMismatched
                }
                result = try await dependencies.publishHealthKitWriteOnly(payload)
            } else {
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
                    result = try await dependencies.publishWidget(projection)
                case .liveActivity:
                    result = try await dependencies.publishLiveActivity(projection)
                case .watch:
                    result = try await dependencies.publishWatch(projection)
                case .healthKit:
                    fatalError("healthKit is handled by the payload-only lane")
                }
            }

            // A writer that lost its durable lease may have completed an idempotent destination call,
            // but it is no longer allowed to acknowledge the outbox row. The next owner safely replays it.
            try await quiescence.validate(token)
            try await leaseHealth.requireValid()

            let event: ExternalPublicationEvent = result == .superseded
                ? .superseded(owner: owner)
                : .succeeded(owner: owner)
            _ = try await dependencies.applyEvent(leased.idempotencyKey, event, dependencies.now())
        } catch {
            if Task.isCancelled,
               let quiescenceError = error as? PipelineQuiescenceError,
               quiescenceError == .superseded || quiescenceError == .suspended {
                return
            }
            if Task.isCancelled { return }
            let classification = dependencies.classifyError(error)
            do {
                let event: ExternalPublicationEvent
                switch classification.disposition {
                case .blocked:
                    event = .blocked(owner: owner, code: classification.code)
                case .retryable:
                    event = .failed(owner: owner, code: classification.code, retryable: true)
                case .permanent:
                    event = .failed(owner: owner, code: classification.code, retryable: false)
                }
                _ = try await dependencies.applyEvent(
                    leased.idempotencyKey,
                    event,
                    dependencies.now()
                )
            } catch {
                // The lease remains durable and can expire. Surface the failure; never invent success.
                dependencies.report("external_outbox_failure_state_failed: \(error)")
            }
        }
    }
}

private actor ExternalPublicationLeaseHealth {
    private var valid = true

    func invalidate() { valid = false }

    func requireValid() throws {
        guard valid else { throw ExternalPublicationWorkerError.leaseRenewalFailed }
    }
}

enum ExternalPublicationWorkerError: Error {
    case projectionMissing
    case projectionMismatch
    case destinationUnavailable
    case payloadMissingOrMismatched
    case leaseRenewalFailed
}
#endif
