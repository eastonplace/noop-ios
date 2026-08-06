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
        guard throughReceiptGeneration > 0,
              analysisGeneration > 0,
              !analyzedDays.isEmpty,
              rawFrontierTs.map({ $0 >= 0 }) ?? true,
              !algorithmBundleVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
    /// The zone used to interpret every civil-day key in this mutation. External writers must not reinterpret
    /// these days through the phone's later zone after travel or a daylight-saving transition.
    public let recordedTimeZoneIdentifier: String
    /// Immutable HealthKit mutations captured from the same post-analysis WAL snapshot as the projection.
    public let healthKitPayload: HistoricalHealthKitMutationPayload?
    public let projection: VerifiedHealthProjection

    public init(
        throughReceiptGeneration: Int64,
        analysisGeneration: Int64,
        snapshotGeneration: Int64,
        analyzedDays: Set<CivilDay>,
        recordedTimeZoneIdentifier: String = "UTC",
        healthKitPayload: HistoricalHealthKitMutationPayload? = nil,
        projection: VerifiedHealthProjection
    ) throws {
        guard throughReceiptGeneration > 0,
              analysisGeneration > 0,
              snapshotGeneration > 0,
              !analyzedDays.isEmpty,
              TimeZone(identifier: recordedTimeZoneIdentifier) != nil,
              healthKitPayload?.validates(
                  contextId: projection.contextId,
                  deviceId: projection.deviceId,
                  analysisGeneration: analysisGeneration,
                  changedDays: analyzedDays,
                  recordedTimeZoneIdentifier: recordedTimeZoneIdentifier
              ) ?? true,
              snapshotGeneration == projection.generation else {
            throw HistoricalWorkError.invalidGeneration
        }
        self.throughReceiptGeneration = throughReceiptGeneration
        self.analysisGeneration = analysisGeneration
        self.snapshotGeneration = snapshotGeneration
        self.analyzedDays = analyzedDays
        self.recordedTimeZoneIdentifier = recordedTimeZoneIdentifier
        self.healthKitPayload = healthKitPayload
        self.projection = projection
    }

    private enum CodingKeys: String, CodingKey {
        case throughReceiptGeneration, analysisGeneration, snapshotGeneration, analyzedDays
        case recordedTimeZoneIdentifier, healthKitPayload, projection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            throughReceiptGeneration: container.decode(Int64.self, forKey: .throughReceiptGeneration),
            analysisGeneration: container.decode(Int64.self, forKey: .analysisGeneration),
            snapshotGeneration: container.decode(Int64.self, forKey: .snapshotGeneration),
            analyzedDays: container.decode(Set<CivilDay>.self, forKey: .analyzedDays),
            recordedTimeZoneIdentifier: container.decodeIfPresent(
                String.self,
                forKey: .recordedTimeZoneIdentifier
            ) ?? "UTC",
            healthKitPayload: container.decodeIfPresent(
                HistoricalHealthKitMutationPayload.self,
                forKey: .healthKitPayload
            ),
            projection: container.decode(VerifiedHealthProjection.self, forKey: .projection)
        )
    }
}

public enum PipelineFailureDisposition: String, Codable, Equatable, Sendable {
    case retryable
    /// The durable item waits for an explicit environmental signal. Attempts do not accumulate.
    case blocked
    case permanent
}

public struct PipelineFailureClassification: Equatable, Sendable {
    public let code: String
    public let disposition: PipelineFailureDisposition

    public init(code: String, disposition: PipelineFailureDisposition) {
        self.code = code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : code
        self.disposition = disposition
    }

    /// Compatibility initializer for older call sites.
    public init(code: String, retryable: Bool) {
        self.init(code: code, disposition: retryable ? .retryable : .permanent)
    }

    public var retryable: Bool { disposition == .retryable }
}

public struct HistoricalPipelineDependencies: Sendable {
    public let leaseNext: @Sendable (
        _ owner: String,
        _ now: Date,
        _ leaseDuration: TimeInterval
    ) async throws -> HistoricalAnalysisWork?
    public let applyEvent: @Sendable (
        _ workId: UUID,
        _ event: HistoricalWorkEvent,
        _ now: Date
    ) async throws -> HistoricalAnalysisWork
    /// Must be idempotent by `(databaseInstanceId, workId, lastReceiptGeneration)`.
    public let analyze: @Sendable (_ work: HistoricalAnalysisWork) async throws -> AnalysisMutationReceipt
    public let loadAnalysis: @Sendable (
        _ work: HistoricalAnalysisWork
    ) async throws -> AnalysisMutationReceipt
    /// Must verify persisted score rows and build the projection from one post-analysis SQLite read snapshot.
    public let verifyAndCommitSnapshot: @Sendable (
        _ work: HistoricalAnalysisWork,
        _ analysis: AnalysisMutationReceipt
    ) async throws -> SnapshotCommitReceipt
    public let loadSnapshot: @Sendable (
        _ work: HistoricalAnalysisWork
    ) async throws -> SnapshotCommitReceipt
    public let publishRepository: @Sendable (
        _ work: HistoricalAnalysisWork,
        _ snapshot: SnapshotCommitReceipt
    ) async throws -> Void
    public let commitOutbox: @Sendable (
        _ snapshot: SnapshotCommitReceipt
    ) async throws -> Set<DownstreamDestination>
    public let classifyError: @Sendable (_ error: any Error) -> PipelineFailureClassification
    public let now: @Sendable () -> Date

    public init(
        leaseNext: @escaping @Sendable (
            _ owner: String,
            _ now: Date,
            _ leaseDuration: TimeInterval
        ) async throws -> HistoricalAnalysisWork?,
        applyEvent: @escaping @Sendable (
            _ workId: UUID,
            _ event: HistoricalWorkEvent,
            _ now: Date
        ) async throws -> HistoricalAnalysisWork,
        analyze: @escaping @Sendable (
            _ work: HistoricalAnalysisWork
        ) async throws -> AnalysisMutationReceipt,
        loadAnalysis: @escaping @Sendable (
            _ work: HistoricalAnalysisWork
        ) async throws -> AnalysisMutationReceipt,
        verifyAndCommitSnapshot: @escaping @Sendable (
            _ work: HistoricalAnalysisWork,
            _ analysis: AnalysisMutationReceipt
        ) async throws -> SnapshotCommitReceipt,
        loadSnapshot: @escaping @Sendable (
            _ work: HistoricalAnalysisWork
        ) async throws -> SnapshotCommitReceipt,
        publishRepository: @escaping @Sendable (
            _ work: HistoricalAnalysisWork,
            _ snapshot: SnapshotCommitReceipt
        ) async throws -> Void,
        commitOutbox: @escaping @Sendable (
            _ snapshot: SnapshotCommitReceipt
        ) async throws -> Set<DownstreamDestination>,
        classifyError: @escaping @Sendable (
            _ error: any Error
        ) -> PipelineFailureClassification,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.leaseNext = leaseNext
        self.applyEvent = applyEvent
        self.analyze = analyze
        self.loadAnalysis = loadAnalysis
        self.verifyAndCommitSnapshot = verifyAndCommitSnapshot
        self.loadSnapshot = loadSnapshot
        self.publishRepository = publishRepository
        self.commitOutbox = commitOutbox
        self.classifyError = classifyError
        self.now = now
    }

    /// Source-compatible initializer for tests. Production must use the full initializer so crash recovery can
    /// load durable artifacts without restarting analysis.
    public init(
        leaseNext: @escaping @Sendable (
            _ owner: String,
            _ now: Date,
            _ leaseDuration: TimeInterval
        ) async throws -> HistoricalAnalysisWork?,
        applyEvent: @escaping @Sendable (
            _ workId: UUID,
            _ event: HistoricalWorkEvent,
            _ now: Date
        ) async throws -> HistoricalAnalysisWork,
        analyze: @escaping @Sendable (
            _ work: HistoricalAnalysisWork
        ) async throws -> AnalysisMutationReceipt,
        verifyAndCommitSnapshot: @escaping @Sendable (
            _ work: HistoricalAnalysisWork,
            _ analysis: AnalysisMutationReceipt
        ) async throws -> SnapshotCommitReceipt,
        publishRepository: @escaping @Sendable (
            _ work: HistoricalAnalysisWork,
            _ snapshot: SnapshotCommitReceipt
        ) async throws -> Void,
        commitOutbox: @escaping @Sendable (
            _ snapshot: SnapshotCommitReceipt
        ) async throws -> Set<DownstreamDestination>,
        classifyError: @escaping @Sendable (
            _ error: any Error
        ) -> PipelineFailureClassification,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            leaseNext: leaseNext,
            applyEvent: applyEvent,
            analyze: analyze,
            loadAnalysis: { _ in throw HistoricalPipelineArtifactError.missingAnalysisReceipt },
            verifyAndCommitSnapshot: verifyAndCommitSnapshot,
            loadSnapshot: { _ in throw HistoricalPipelineArtifactError.missingSnapshotReceipt },
            publishRepository: publishRepository,
            commitOutbox: commitOutbox,
            classifyError: classifyError,
            now: now
        )
    }
}

public enum HistoricalPipelineArtifactError: Error, Equatable, Sendable {
    case missingAnalysisReceipt
    case missingSnapshotReceipt
}

public struct HistoricalPipelineDrainResult: Equatable, Sendable {
    public let completedWorkCount: Int
    public let deferredWorkCount: Int
    public let alreadyDraining: Bool

    public static let alreadyActive = Self(
        completedWorkCount: 0,
        deferredWorkCount: 0,
        alreadyDraining: true
    )
}

private actor PipelineLeaseHealth {
    private var failure: (any Error)?

    func invalidate(_ error: any Error) {
        if failure == nil { failure = error }
    }

    func requireValid() throws {
        if let failure { throw failure }
    }
}

public enum HistoricalPipelineLeaseError: Error, Equatable, Sendable {
    case renewalFailed
}

/// Single durable scoring owner. The persisted `resumePhase` prevents failures in publication or delivery from
/// restarting analysis. Every repeated side effect has an idempotency key for the crash seam between the side
/// effect and its following state transition.
public actor HistoricalPipelineCoordinator {
    private let dependencies: HistoricalPipelineDependencies
    private let quiescence = PipelineQuiescence()
    private let owner: String
    private let leaseDuration: TimeInterval
    private let maximumItemsPerDrain: Int
    private lazy var drainGate = LosslessDrainSignalGate<HistoricalPipelineDrainResult> { [weak self] in
        await self?.drainSignal() ?? HistoricalPipelineDrainResult(
            completedWorkCount: 0,
            deferredWorkCount: 1,
            alreadyDraining: false
        )
    }

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

    /// Close admission, cancel the active drain task, and await every in-flight operation before a source
    /// transition mutates lineage or Repository state.
    public func quiesce() async throws -> UInt64 {
        await drainGate.suspendAndCancel()
        return try await quiescence.quiesce(cancelOwners: { })
    }

    public func resume(expectedEpoch: UInt64) async throws {
        try await quiescence.resume(expectedEpoch: expectedEpoch)
        await drainGate.resume()
    }

    public func signal() async -> HistoricalPipelineDrainResult {
        await drainGate.signal()
    }

    private func drainSignal() async -> HistoricalPipelineDrainResult {
        let token: PipelineEpochToken
        do {
            token = try await quiescence.begin()
        } catch {
            return HistoricalPipelineDrainResult(
                completedWorkCount: 0,
                deferredWorkCount: 1,
                alreadyDraining: false)
        }
        defer { Task { await quiescence.end(token) } }

        var completed = 0
        var deferred = 0
        while !Task.isCancelled {
            var exhaustedBatchBudget = true
            for _ in 0..<maximumItemsPerDrain {
                if Task.isCancelled {
                    deferred += 1
                    exhaustedBatchBudget = false
                    break
                }
                let leased: HistoricalAnalysisWork
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
                    deferred += 1
                    exhaustedBatchBudget = false
                    break
                }

                do {
                    try await process(leased, token: token)
                    completed += 1
                } catch {
                    let failure = dependencies.classifyError(error)
                    do {
                        if Task.isCancelled || error is CancellationError {
                            _ = try? await dependencies.applyEvent(
                                leased.id,
                                .cancelOwnedLease(owner: owner),
                                dependencies.now()
                            )
                            deferred += 1
                            continue
                        }
                        let event: HistoricalWorkEvent
                        switch failure.disposition {
                        case .blocked:
                            event = .blocked(owner: owner, code: failure.code)
                        case .retryable:
                            event = .failed(owner: owner, code: failure.code, retryable: true)
                        case .permanent:
                            event = .failed(owner: owner, code: failure.code, retryable: false)
                        }
                        _ = try await dependencies.applyEvent(
                            leased.id, event, dependencies.now()
                        )
                    } catch {
                        // The durable lease remains recoverable. Do not acknowledge or invent completion.
                    }
                    deferred += 1
                }
            }
            if exhaustedBatchBudget && !Task.isCancelled {
                await Task.yield()
                continue
            }
            break
        }

        return HistoricalPipelineDrainResult(
            completedWorkCount: completed,
            deferredWorkCount: deferred,
            alreadyDraining: false
        )
    }

    private func process(
        _ leased: HistoricalAnalysisWork,
        token: PipelineEpochToken
    ) async throws {
        let leaseHealth = PipelineLeaseHealth()
        let heartbeatInterval = max(1, leaseDuration / 3)
        let heartbeat = Task { [dependencies, owner, leaseDuration, leaseHealth] in
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
                    await leaseHealth.invalidate(HistoricalPipelineLeaseError.renewalFailed)
                    return
                }
            }
        }
        defer { heartbeat.cancel() }

        var work = try await dependencies.applyEvent(
            leased.id,
            .beginCurrentPhase(owner: owner),
            dependencies.now()
        )
        var analysis: AnalysisMutationReceipt?
        var snapshot: SnapshotCommitReceipt?

        while true {
            try Task.checkCancellation()
            try await quiescence.validate(token)
            try await leaseHealth.requireValid()
            switch work.resumePhase {
            case .analysis:
                let result = try await dependencies.analyze(work)
                try await quiescence.validate(token)
                try await leaseHealth.requireValid()
                analysis = result
                work = try await dependencies.applyEvent(
                    work.id,
                    .analysisSucceeded(
                        owner: owner,
                        throughReceiptGeneration: result.throughReceiptGeneration,
                        analysisGeneration: result.analysisGeneration,
                        analyzedDays: result.analyzedDays
                    ),
                    dependencies.now()
                )

            case .verification:
                let result: AnalysisMutationReceipt
                if let analysis {
                    result = analysis
                } else {
                    result = try await dependencies.loadAnalysis(work)
                }
                let committed = try await dependencies.verifyAndCommitSnapshot(work, result)
                try await quiescence.validate(token)
                try await leaseHealth.requireValid()
                snapshot = committed
                work = try await dependencies.applyEvent(
                    work.id,
                    .verificationSucceeded(
                        owner: owner,
                        throughReceiptGeneration: committed.throughReceiptGeneration,
                        analysisGeneration: committed.analysisGeneration,
                        snapshotGeneration: committed.snapshotGeneration
                    ),
                    dependencies.now()
                )

            case .repositoryPublication:
                let committed: SnapshotCommitReceipt
                if let snapshot {
                    committed = snapshot
                } else {
                    committed = try await dependencies.loadSnapshot(work)
                }
                try await dependencies.publishRepository(work, committed)
                try await quiescence.validate(token)
                try await leaseHealth.requireValid()
                work = try await dependencies.applyEvent(
                    work.id,
                    .repositoryPublished(owner: owner),
                    dependencies.now()
                )

            case .outboxCommit:
                let committed: SnapshotCommitReceipt
                if let snapshot {
                    committed = snapshot
                } else {
                    committed = try await dependencies.loadSnapshot(work)
                }
                let destinations = try await dependencies.commitOutbox(committed)
                try await quiescence.validate(token)
                try await leaseHealth.requireValid()
                _ = try await dependencies.applyEvent(
                    work.id,
                    .outboxCommitted(owner: owner, destinations: destinations),
                    dependencies.now()
                )
                return

            case .done:
                return
            }
        }
    }
}
