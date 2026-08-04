import Foundation

public struct AnalysisMutationReceipt: Codable, Equatable, Sendable {
    public let throughReceiptGeneration: Int64
    public let analysisGeneration: Int64
    public let analyzedDays: Set<CivilDay>
    public let rawFrontierTs: Int?
    public let algorithmBundleVersion: String

    public init(
        throughReceiptGeneration: Int64,
        analysisGeneration: Int64,
        analyzedDays: Set<CivilDay>,
        rawFrontierTs: Int?,
        algorithmBundleVersion: String
    ) throws {
        // Receipt and analysis generations are separate monotonic domains. Both must be valid, but
        // comparing their numeric values would create a false ordering contract.
        guard throughReceiptGeneration > 0,
              analysisGeneration > 0,
              !algorithmBundleVersion.isEmpty else {
            throw HistoricalWorkError.invalidGeneration
        }
        self.throughReceiptGeneration = throughReceiptGeneration
        self.analysisGeneration = analysisGeneration
        self.analyzedDays = analyzedDays
        self.rawFrontierTs = rawFrontierTs
        self.algorithmBundleVersion = algorithmBundleVersion
    }
}

public struct SnapshotCommitReceipt: Codable, Equatable, Sendable {
    public let throughReceiptGeneration: Int64
    public let analysisGeneration: Int64
    public let snapshotGeneration: Int64
    public let analyzedDays: Set<CivilDay>
    public let projection: VerifiedHealthProjection

    public init(
        throughReceiptGeneration: Int64,
        analysisGeneration: Int64,
        snapshotGeneration: Int64,
        analyzedDays: Set<CivilDay>,
        projection: VerifiedHealthProjection
    ) throws {
        // Receipt, analysis, and snapshot generations are separate monotonic domains. Preserve all three
        // identities explicitly rather than comparing their numeric values. The projection's generation is
        // the one exception: it must exactly equal the committed snapshot generation used by the outbox.
        guard throughReceiptGeneration > 0,
              analysisGeneration > 0,
              snapshotGeneration > 0,
              !analyzedDays.isEmpty,
              snapshotGeneration == projection.generation else {
            throw HistoricalWorkError.invalidGeneration
        }
        self.throughReceiptGeneration = throughReceiptGeneration
        self.analysisGeneration = analysisGeneration
        self.snapshotGeneration = snapshotGeneration
        self.analyzedDays = analyzedDays
        self.projection = projection
    }
}

public struct PipelineFailureClassification: Equatable, Sendable {
    public let code: String
    public let retryable: Bool

    public init(code: String, retryable: Bool) {
        self.code = code.isEmpty ? "unknown" : code
        self.retryable = retryable
    }
}

public struct HistoricalPipelineDependencies: Sendable {
    public let leaseNext: @Sendable (_ owner: String, _ now: Date, _ leaseDuration: TimeInterval) async throws -> HistoricalAnalysisWork?
    public let applyEvent: @Sendable (_ workId: UUID, _ event: HistoricalWorkEvent, _ now: Date) async throws -> HistoricalAnalysisWork
    public let analyze: @Sendable (_ work: HistoricalAnalysisWork) async throws -> AnalysisMutationReceipt
    public let verifyAndCommitSnapshot: @Sendable (_ work: HistoricalAnalysisWork, _ analysis: AnalysisMutationReceipt) async throws -> SnapshotCommitReceipt
    public let publishRepository: @Sendable (_ work: HistoricalAnalysisWork, _ snapshot: SnapshotCommitReceipt) async throws -> Void
    public let commitOutbox: @Sendable (_ snapshot: SnapshotCommitReceipt) async throws -> Set<DownstreamDestination>
    public let classifyError: @Sendable (_ error: any Error) -> PipelineFailureClassification
    public let now: @Sendable () -> Date

    public init(
        leaseNext: @escaping @Sendable (_ owner: String, _ now: Date, _ leaseDuration: TimeInterval) async throws -> HistoricalAnalysisWork?,
        applyEvent: @escaping @Sendable (_ workId: UUID, _ event: HistoricalWorkEvent, _ now: Date) async throws -> HistoricalAnalysisWork,
        analyze: @escaping @Sendable (_ work: HistoricalAnalysisWork) async throws -> AnalysisMutationReceipt,
        verifyAndCommitSnapshot: @escaping @Sendable (_ work: HistoricalAnalysisWork, _ analysis: AnalysisMutationReceipt) async throws -> SnapshotCommitReceipt,
        publishRepository: @escaping @Sendable (_ work: HistoricalAnalysisWork, _ snapshot: SnapshotCommitReceipt) async throws -> Void,
        commitOutbox: @escaping @Sendable (_ snapshot: SnapshotCommitReceipt) async throws -> Set<DownstreamDestination>,
        classifyError: @escaping @Sendable (_ error: any Error) -> PipelineFailureClassification,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.leaseNext = leaseNext
        self.applyEvent = applyEvent
        self.analyze = analyze
        self.verifyAndCommitSnapshot = verifyAndCommitSnapshot
        self.publishRepository = publishRepository
        self.commitOutbox = commitOutbox
        self.classifyError = classifyError
        self.now = now
    }
}

public struct HistoricalPipelineDrainResult: Equatable, Sendable {
    public let completedWorkCount: Int
    public let deferredWorkCount: Int
    public let alreadyDraining: Bool

    public static let alreadyActive = Self(completedWorkCount: 0, deferredWorkCount: 0, alreadyDraining: true)
}

/// Single durable scoring owner. Every state transition is persisted through `applyEvent`; cancellation or a
/// process death therefore leaves a lease that can expire and resume rather than losing the work edge.
public actor HistoricalPipelineCoordinator {
    private let dependencies: HistoricalPipelineDependencies
    private let owner: String
    private let leaseDuration: TimeInterval
    private let maximumItemsPerDrain: Int
    private var draining = false
    private var rerunRequested = false

    public init(
        dependencies: HistoricalPipelineDependencies,
        owner: String = UUID().uuidString,
        leaseDuration: TimeInterval = 90,
        maximumItemsPerDrain: Int = 64
    ) {
        self.dependencies = dependencies
        self.owner = owner
        self.leaseDuration = max(15, leaseDuration)
        self.maximumItemsPerDrain = max(1, maximumItemsPerDrain)
    }

    public func signal() async -> HistoricalPipelineDrainResult {
        guard !draining else {
            rerunRequested = true
            return .alreadyActive
        }
        draining = true
        defer { draining = false }

        var completed = 0
        var deferred = 0
        repeat {
            rerunRequested = false
            var exhaustedBatchBudget = true
            for _ in 0..<maximumItemsPerDrain {
                if Task.isCancelled {
                    deferred += 1
                    exhaustedBatchBudget = false
                    break
                }
                let now = dependencies.now()
                let leased: HistoricalAnalysisWork
                do {
                    guard let next = try await dependencies.leaseNext(owner, now, leaseDuration) else {
                        exhaustedBatchBudget = false
                        break
                    }
                    leased = next
                } catch {
                    deferred += 1
                    exhaustedBatchBudget = false
                    break
                }

                do {
                    try await process(leased)
                    completed += 1
                } catch {
                    let failure = dependencies.classifyError(error)
                    do {
                        _ = try await dependencies.applyEvent(
                            leased.id,
                            .failed(owner: owner, code: failure.code, retryable: failure.retryable),
                            dependencies.now()
                        )
                    } catch {
                        // The durable lease remains recoverable. Do not acknowledge or invent completion.
                    }
                    deferred += 1
                }
            }
            // A batch limit is a cooperative-yield boundary, not a reason to leave durable ready work idle
            // until some unrelated lifecycle signal arrives. One extra empty lease query terminates cleanly
            // when the batch contained exactly the final N items.
            if exhaustedBatchBudget && !Task.isCancelled {
                rerunRequested = true
                await Task.yield()
            }
        } while rerunRequested

        return HistoricalPipelineDrainResult(
            completedWorkCount: completed,
            deferredWorkCount: deferred,
            alreadyDraining: false
        )
    }
    private func process(_ leased: HistoricalAnalysisWork) async throws {
        // Exact analysis and Health snapshot verification can outlive the initial lease on large libraries.
        // Renew the same durable lease while the owner is suspended so another lifecycle signal cannot recover
        // and run the same work concurrently. A failed heartbeat does not invent success; the next persisted
        // transition still validates ownership and expiry and will fail closed.
        let heartbeatInterval = max(1, leaseDuration / 3)
        let heartbeat = Task { [dependencies, owner, leaseDuration] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(heartbeatInterval))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                do {
                    _ = try await dependencies.applyEvent(
                        leased.id,
                        .renewLease(
                            owner: owner,
                            expiresAt: dependencies.now().addingTimeInterval(leaseDuration)
                        ),
                        dependencies.now()
                    )
                } catch {
                    return
                }
            }
        }
        defer { heartbeat.cancel() }

        var work = try await dependencies.applyEvent(
            leased.id,
            .beginAnalysis(owner: owner),
            dependencies.now()
        )
        let analysis = try await dependencies.analyze(work)
        work = try await dependencies.applyEvent(
            work.id,
            .analysisSucceeded(
                owner: owner,
                throughReceiptGeneration: analysis.throughReceiptGeneration,
                analysisGeneration: analysis.analysisGeneration,
                analyzedDays: analysis.analyzedDays
            ),
            dependencies.now()
        )
        let snapshot = try await dependencies.verifyAndCommitSnapshot(work, analysis)
        work = try await dependencies.applyEvent(
            work.id,
            .verificationSucceeded(
                owner: owner,
                throughReceiptGeneration: snapshot.throughReceiptGeneration,
                analysisGeneration: snapshot.analysisGeneration,
                snapshotGeneration: snapshot.snapshotGeneration
            ),
            dependencies.now()
        )
        try await dependencies.publishRepository(work, snapshot)
        work = try await dependencies.applyEvent(
            work.id,
            .repositoryPublished(owner: owner),
            dependencies.now()
        )
        // The dependency must durably insert the exact projection and every outbox row before this event
        // marks analysis work complete. Destination retries belong to the outbox worker, not this lease.
        let destinations = try await dependencies.commitOutbox(snapshot)
        _ = try await dependencies.applyEvent(
            work.id,
            .outboxCommitted(owner: owner, destinations: destinations),
            dependencies.now()
        )
    }

}
