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
    let loadBundle: @Sendable @MainActor (_ contextId: String, _ generation: Int64) async throws -> VerifiedExternalProjectionBundle?
    /// Latest-state sinks must atomically ignore a projection older than the generation already stored.
    let publishWidget: @Sendable @MainActor (VerifiedExternalProjectionBundle) async throws -> ExternalSinkPublicationResult
    let publishLiveActivity: @Sendable @MainActor (VerifiedExternalProjectionBundle) async throws -> ExternalSinkPublicationResult
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
    private var nonHistoricalItemsSinceFairnessYield = 0
    private lazy var drainGate = LosslessDrainSignalGate<Void> { [weak self] in
        await self?.drain(maximumItems: self?.maximumItemsPerDrain ?? 32)
    }
    private var maximumItemsPerDrain = 32

    init(
        dependencies: ExternalPublicationWorkerDependencies,
        leaseDuration: TimeInterval = 60
    ) {
        self.dependencies = dependencies
        self.leaseDuration = max(15, leaseDuration)
        self.maximumItemsPerDrain = 32
    }

    func quiesce() async throws -> UInt64 {
        await drainGate.suspendAndCancel()
        return try await quiescence.quiesce(cancelOwners: { })
    }

    func resume(expectedEpoch: UInt64) async throws {
        // A durable transition can survive process death, but this worker's epoch cannot. A fresh worker is
        // already open and must not reject the previous process's persisted epoch. If this worker is locally
        // suspended, keep the exact-epoch check so a stale resume cannot reopen a newer transition.
        if await quiescence.isAccepting { return }
        try await quiescence.resume(expectedEpoch: expectedEpoch)
        await drainGate.resume()
    }

    func signal(maximumItems: Int = 32) async {
        maximumItemsPerDrain = max(1, maximumItems)
        _ = await drainGate.signal()
    }

    private func drain(maximumItems: Int) async {
        let token: PipelineEpochToken
        do {
            token = try await quiescence.begin()
        } catch {
            return
        }
        defer { Task { await quiescence.end(token) } }

        while !Task.isCancelled {
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

                do {
                    try await TargetScopedPipelineFence.shared.withLease(
                        sourceId: leased.deviceId
                    ) { [self] in
                        await self.process(leased, token: token)
                    }
                } catch {
                    // The source entered archive/privacy quiescence after this durable row was leased.
                    // Release ownership without mutating failure state; the row will either be deleted by
                    // privacy cleanup or safely replayed after an archive transition resumes the source.
                    _ = try? await dependencies.applyEvent(
                        leased.idempotencyKey,
                        .cancelOwnedLease(owner: owner),
                        dependencies.now()
                    )
                    await Task.yield()
                }
            }

            // A batch cap yields to the app. It does not strand ready durable work until another lifecycle event.
            if exhaustedBatchBudget && !Task.isCancelled {
                await Task.yield()
                continue
            }
            break
        }

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
                guard let bundle = try await dependencies.loadBundle(
                    leased.contextId,
                    leased.snapshotGeneration
                ) else {
                    throw ExternalPublicationWorkerError.bundleMissing
                }
                let projection = bundle.projection
                guard projection.contextId == leased.contextId,
                      projection.deviceId == leased.deviceId,
                      projection.generation == leased.snapshotGeneration else {
                    throw ExternalPublicationWorkerError.projectionMismatch
                }

                switch leased.destination {
                case .widget:
                    result = try await dependencies.publishWidget(bundle)
                case .liveActivity:
                    result = try await dependencies.publishLiveActivity(bundle)
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
            if Task.isCancelled || error is CancellationError {
                _ = try? await dependencies.applyEvent(
                    leased.idempotencyKey,
                    .cancelOwnedLease(owner: owner),
                    dependencies.now()
                )
                return
            }
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
    case bundleMissing
    case projectionMismatch
    case destinationUnavailable
    case payloadMissingOrMismatched
    case leaseRenewalFailed
}
#endif
