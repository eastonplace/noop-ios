import Foundation

public enum SourceTransitionStage: String, Codable, Equatable, Sendable {
    case prepared
    case storeCommitted
    case sinkActivated
    case workersResumed
    case complete
    case aborted
}

public struct SourceTransitionRecoveryRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let mutationKind: String
    public let sourceDeviceId: String
    public let targetDeviceId: String?
    public let historicalEpoch: UInt64
    public let externalEpoch: UInt64
    public let sinkEpoch: UInt64
    public var stage: SourceTransitionStage
    public var lastErrorCode: String?

    public init(
        id: UUID = UUID(),
        mutationKind: String,
        sourceDeviceId: String,
        targetDeviceId: String?,
        historicalEpoch: UInt64,
        externalEpoch: UInt64,
        sinkEpoch: UInt64,
        stage: SourceTransitionStage = .prepared,
        lastErrorCode: String? = nil
    ) {
        self.id = id
        self.mutationKind = mutationKind
        self.sourceDeviceId = sourceDeviceId
        self.targetDeviceId = targetDeviceId
        self.historicalEpoch = historicalEpoch
        self.externalEpoch = externalEpoch
        self.sinkEpoch = sinkEpoch
        self.stage = stage
        self.lastErrorCode = lastErrorCode
    }
}

public struct SourceTransitionRecoveryDependencies<Commit: Sendable>: Sendable {
    public let quiesceHistorical: @Sendable () async throws -> UInt64
    public let quiesceExternal: @Sendable () async throws -> UInt64
    public let stopAffectedLiveSource: @Sendable () async -> Void
    public let restartPreviousSource: @Sendable () async -> Void
    public let beginSinkTransition: @Sendable () async throws -> UInt64
    /// Reopen the previous verified context at the newly allocated epoch after a
    /// precommit failure. Epochs never move backward.
    public let restorePrecommitSink: @Sendable (_ epoch: UInt64) async throws -> Void
    public let persistRecovery: @Sendable (SourceTransitionRecoveryRecord) async throws -> Void
    public let loadRecovery: @Sendable () async throws -> SourceTransitionRecoveryRecord?
    /// The production adapter must commit the source mutation, its exact `Commit` payload, and the
    /// `storeCommitted` recovery edge atomically. The prepared record carries the transition ID needed
    /// to make those writes one durable transaction.
    public let commitStoreMutation: @Sendable (_ prepared: SourceTransitionRecoveryRecord) async throws -> Commit
    /// Load the exact commit captured by `commitStoreMutation`. Launch recovery must never reconstruct
    /// this value from mutable current registry state.
    public let loadCommittedMutation: @Sendable (_ transitionId: UUID) async throws -> Commit?
    public let activateSink: @Sendable (_ epoch: UInt64, _ commit: Commit?) async throws -> Void
    public let resumeHistorical: @Sendable (_ epoch: UInt64) async throws -> Void
    public let resumeExternal: @Sendable (_ epoch: UInt64) async throws -> Void
    public let startCommittedSource: @Sendable (_ commit: Commit?) async -> Void
    public let scheduleExactPostCommit: @Sendable (_ commit: Commit?) async -> Void
    public let classify: @Sendable (any Error) -> String

    public init(
        quiesceHistorical: @escaping @Sendable () async throws -> UInt64,
        quiesceExternal: @escaping @Sendable () async throws -> UInt64,
        stopAffectedLiveSource: @escaping @Sendable () async -> Void,
        restartPreviousSource: @escaping @Sendable () async -> Void,
        beginSinkTransition: @escaping @Sendable () async throws -> UInt64,
        restorePrecommitSink: @escaping @Sendable (UInt64) async throws -> Void,
        persistRecovery: @escaping @Sendable (SourceTransitionRecoveryRecord) async throws -> Void,
        loadRecovery: @escaping @Sendable () async throws -> SourceTransitionRecoveryRecord?,
        commitStoreMutation: @escaping @Sendable (SourceTransitionRecoveryRecord) async throws -> Commit,
        loadCommittedMutation: @escaping @Sendable (UUID) async throws -> Commit? = { _ in nil },
        activateSink: @escaping @Sendable (UInt64, Commit?) async throws -> Void,
        resumeHistorical: @escaping @Sendable (UInt64) async throws -> Void,
        resumeExternal: @escaping @Sendable (UInt64) async throws -> Void,
        startCommittedSource: @escaping @Sendable (Commit?) async -> Void,
        scheduleExactPostCommit: @escaping @Sendable (Commit?) async -> Void,
        classify: @escaping @Sendable (any Error) -> String
    ) {
        self.quiesceHistorical = quiesceHistorical
        self.quiesceExternal = quiesceExternal
        self.stopAffectedLiveSource = stopAffectedLiveSource
        self.restartPreviousSource = restartPreviousSource
        self.beginSinkTransition = beginSinkTransition
        self.restorePrecommitSink = restorePrecommitSink
        self.persistRecovery = persistRecovery
        self.loadRecovery = loadRecovery
        self.commitStoreMutation = commitStoreMutation
        self.loadCommittedMutation = loadCommittedMutation
        self.activateSink = activateSink
        self.resumeHistorical = resumeHistorical
        self.resumeExternal = resumeExternal
        self.startCommittedSource = startCommittedSource
        self.scheduleExactPostCommit = scheduleExactPostCommit
        self.classify = classify
    }

    /// Compatibility initializer for isolated tests/adapters that do not yet need the prepared recovery ID.
    /// Production source-lifecycle integration should use the record-aware initializer above.
    public init(
        quiesceHistorical: @escaping @Sendable () async throws -> UInt64,
        quiesceExternal: @escaping @Sendable () async throws -> UInt64,
        stopAffectedLiveSource: @escaping @Sendable () async -> Void,
        restartPreviousSource: @escaping @Sendable () async -> Void,
        beginSinkTransition: @escaping @Sendable () async throws -> UInt64,
        restorePrecommitSink: @escaping @Sendable (UInt64) async throws -> Void,
        persistRecovery: @escaping @Sendable (SourceTransitionRecoveryRecord) async throws -> Void,
        loadRecovery: @escaping @Sendable () async throws -> SourceTransitionRecoveryRecord?,
        commitStoreMutation: @escaping @Sendable () async throws -> Commit,
        loadCommittedMutation: @escaping @Sendable (UUID) async throws -> Commit? = { _ in nil },
        activateSink: @escaping @Sendable (UInt64, Commit?) async throws -> Void,
        resumeHistorical: @escaping @Sendable (UInt64) async throws -> Void,
        resumeExternal: @escaping @Sendable (UInt64) async throws -> Void,
        startCommittedSource: @escaping @Sendable (Commit?) async -> Void,
        scheduleExactPostCommit: @escaping @Sendable (Commit?) async -> Void,
        classify: @escaping @Sendable (any Error) -> String
    ) {
        self.init(
            quiesceHistorical: quiesceHistorical,
            quiesceExternal: quiesceExternal,
            stopAffectedLiveSource: stopAffectedLiveSource,
            restartPreviousSource: restartPreviousSource,
            beginSinkTransition: beginSinkTransition,
            restorePrecommitSink: restorePrecommitSink,
            persistRecovery: persistRecovery,
            loadRecovery: loadRecovery,
            commitStoreMutation: { _ in try await commitStoreMutation() },
            loadCommittedMutation: loadCommittedMutation,
            activateSink: activateSink,
            resumeHistorical: resumeHistorical,
            resumeExternal: resumeExternal,
            startCommittedSource: startCommittedSource,
            scheduleExactPostCommit: scheduleExactPostCommit,
            classify: classify
        )
    }
}

/// Distinguishes precommit rollback from postcommit recovery. Once the store
/// mutation commits, failure recovery always moves forward to the committed source.
public actor SourceTransitionRecoveryCoordinator<Commit: Sendable> {
    private let dependencies: SourceTransitionRecoveryDependencies<Commit>
    private var running = false

    public init(dependencies: SourceTransitionRecoveryDependencies<Commit>) {
        self.dependencies = dependencies
    }

    public func perform(
        mutationKind: String,
        sourceDeviceId: String,
        targetDeviceId: String?
    ) async throws {
        guard !running else { throw SourceTransitionRecoveryError.alreadyRunning }
        running = true
        defer { running = false }

        let historicalEpoch = try await dependencies.quiesceHistorical()
        let externalEpoch: UInt64
        do {
            externalEpoch = try await dependencies.quiesceExternal()
        } catch {
            try? await dependencies.resumeHistorical(historicalEpoch)
            throw error
        }

        await dependencies.stopAffectedLiveSource()
        let sinkEpoch: UInt64
        do {
            sinkEpoch = try await dependencies.beginSinkTransition()
        } catch {
            try? await dependencies.resumeHistorical(historicalEpoch)
            try? await dependencies.resumeExternal(externalEpoch)
            await dependencies.restartPreviousSource()
            throw error
        }

        var record = SourceTransitionRecoveryRecord(
            mutationKind: mutationKind,
            sourceDeviceId: sourceDeviceId,
            targetDeviceId: targetDeviceId,
            historicalEpoch: historicalEpoch,
            externalEpoch: externalEpoch,
            sinkEpoch: sinkEpoch
        )

        do {
            try await dependencies.persistRecovery(record)
        } catch {
            await abortPrecommit(
                record: &record,
                historicalEpoch: historicalEpoch,
                externalEpoch: externalEpoch,
                sinkEpoch: sinkEpoch,
                cause: error
            )
            throw error
        }

        let commit: Commit
        do {
            commit = try await dependencies.commitStoreMutation(record)
        } catch {
            // The production commit closure is transactionally all-or-nothing with `storeCommitted`.
            // A thrown error therefore means the source mutation did not durably commit.
            await abortPrecommit(
                record: &record,
                historicalEpoch: historicalEpoch,
                externalEpoch: externalEpoch,
                sinkEpoch: sinkEpoch,
                cause: error
            )
            throw error
        }

        // From this line forward the store mutation is durable. Never call precommit rollback again,
        // including when a redundant journal write or downstream activation fails.
        record.stage = .storeCommitted
        record.lastErrorCode = nil
        do {
            try await dependencies.persistRecovery(record)
        } catch {
            record.lastErrorCode = dependencies.classify(error)
            try? await dependencies.persistRecovery(record)
            await dependencies.startCommittedSource(commit)
            throw SourceTransitionRecoveryError.postCommitRecoveryPending
        }

        do {
            try await dependencies.activateSink(sinkEpoch, commit)
            record.stage = .sinkActivated
            try await dependencies.persistRecovery(record)

            try await dependencies.resumeHistorical(historicalEpoch)
            try await dependencies.resumeExternal(externalEpoch)
            record.stage = .workersResumed
            try await dependencies.persistRecovery(record)

            await dependencies.startCommittedSource(commit)
            await dependencies.scheduleExactPostCommit(commit)
            record.stage = .complete
            record.lastErrorCode = nil
            try await dependencies.persistRecovery(record)
        } catch {
            record.lastErrorCode = dependencies.classify(error)
            try? await dependencies.persistRecovery(record)
            await dependencies.startCommittedSource(commit)
            throw SourceTransitionRecoveryError.postCommitRecoveryPending
        }
    }

    private func abortPrecommit(
        record: inout SourceTransitionRecoveryRecord,
        historicalEpoch: UInt64,
        externalEpoch: UInt64,
        sinkEpoch: UInt64,
        cause: any Error
    ) async {
        record.stage = .aborted
        record.lastErrorCode = dependencies.classify(cause)
        try? await dependencies.restorePrecommitSink(sinkEpoch)
        try? await dependencies.resumeHistorical(historicalEpoch)
        try? await dependencies.resumeExternal(externalEpoch)
        await dependencies.restartPreviousSource()
        try? await dependencies.persistRecovery(record)
    }

    /// Call at store-open and foreground. This loads the exact committed mutation by transition ID.
    public func recoverPending() async throws {
        try await recoverPending(explicitCommit: nil)
    }

    /// Compatibility hook for tests that already hold the exact durable commit.
    public func recoverPending(commit: Commit?) async throws {
        try await recoverPending(explicitCommit: commit)
    }

    private func recoverPending(explicitCommit: Commit?) async throws {
        guard var record = try await dependencies.loadRecovery(),
              record.stage != .complete,
              record.stage != .aborted else { return }

        if record.stage == .prepared {
            try? await dependencies.restorePrecommitSink(record.sinkEpoch)
            try? await dependencies.resumeHistorical(record.historicalEpoch)
            try? await dependencies.resumeExternal(record.externalEpoch)
            await dependencies.restartPreviousSource()
            record.stage = .aborted
            record.lastErrorCode = record.lastErrorCode ?? "recovered_precommit_abort"
            try await dependencies.persistRecovery(record)
            return
        }

        let commit: Commit
        if let explicitCommit {
            commit = explicitCommit
        } else if let durableCommit = try await dependencies.loadCommittedMutation(record.id) {
            commit = durableCommit
        } else {
            throw SourceTransitionRecoveryError.missingCommittedMutation
        }

        if record.stage == .storeCommitted {
            try await dependencies.activateSink(record.sinkEpoch, commit)
            record.stage = .sinkActivated
            try await dependencies.persistRecovery(record)
        }
        if record.stage == .sinkActivated {
            try await dependencies.resumeHistorical(record.historicalEpoch)
            try await dependencies.resumeExternal(record.externalEpoch)
            record.stage = .workersResumed
            try await dependencies.persistRecovery(record)
        }
        await dependencies.startCommittedSource(commit)
        await dependencies.scheduleExactPostCommit(commit)
        record.stage = .complete
        record.lastErrorCode = nil
        try await dependencies.persistRecovery(record)
    }
}

public enum SourceTransitionRecoveryError: Error, Equatable, Sendable {
    case alreadyRunning
    case missingCommittedMutation
    case postCommitRecoveryPending
}
