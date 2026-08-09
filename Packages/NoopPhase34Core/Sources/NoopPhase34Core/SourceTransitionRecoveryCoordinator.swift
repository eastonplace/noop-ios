import Foundation

public enum SourceTransitionStage: String, Codable, Equatable, Sendable {
    case planned
    case prepared
    case storeCommitted
    case sinkActivated
    case workersResumed
    case complete
    case aborted
}

public struct SourceTransitionRecoveryRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public let version: Int
    public let id: UUID
    public let mutationKind: String
    public let sourceDeviceId: String
    public let targetDeviceId: String?
    public let previousActiveDeviceId: String?
    public let previousSinkContextId: String?
    public let previousSinkEpoch: UInt64?
    public let contributorIds: Set<String>
    public let transitionScope: SourceTransitionScope
    public let cleanupWorkId: UUID?
    public var historicalEpoch: UInt64?
    public var externalEpoch: UInt64?
    public var sinkEpoch: UInt64?
    public var stage: SourceTransitionStage
    public var lastErrorCode: String?

    public init(
        version: Int = SourceTransitionRecoveryRecord.currentVersion,
        id: UUID = UUID(),
        mutationKind: String,
        sourceDeviceId: String,
        targetDeviceId: String?,
        previousActiveDeviceId: String?,
        previousSinkContextId: String?,
        previousSinkEpoch: UInt64?,
        contributorIds: Set<String>,
        transitionScope: SourceTransitionScope,
        cleanupWorkId: UUID?,
        historicalEpoch: UInt64? = nil,
        externalEpoch: UInt64? = nil,
        sinkEpoch: UInt64? = nil,
        stage: SourceTransitionStage = .planned,
        lastErrorCode: String? = nil
    ) {
        self.version = version
        self.id = id
        self.mutationKind = mutationKind
        self.sourceDeviceId = sourceDeviceId
        self.targetDeviceId = targetDeviceId
        self.previousActiveDeviceId = previousActiveDeviceId
        self.previousSinkContextId = previousSinkContextId
        self.previousSinkEpoch = previousSinkEpoch
        self.contributorIds = ActiveProjectionContributorSet(
            deviceIds: contributorIds
        ).deviceIds
        self.transitionScope = transitionScope
        self.cleanupWorkId = cleanupWorkId
        self.historicalEpoch = historicalEpoch
        self.externalEpoch = externalEpoch
        self.sinkEpoch = sinkEpoch
        self.stage = stage
        self.lastErrorCode = lastErrorCode
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case mutationKind
        case sourceDeviceId
        case targetDeviceId
        case previousActiveDeviceId
        case previousSinkContextId
        case previousSinkEpoch
        case contributorIds
        case transitionScope
        case cleanupWorkId
        case historicalEpoch
        case externalEpoch
        case sinkEpoch
        case stage
        case lastErrorCode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard decodedVersion > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Source transition recovery version must be positive."
            )
        }

        version = decodedVersion
        id = try container.decode(UUID.self, forKey: .id)
        mutationKind = try container.decode(String.self, forKey: .mutationKind)
        sourceDeviceId = try container.decode(String.self, forKey: .sourceDeviceId)
        targetDeviceId = try container.decodeIfPresent(String.self, forKey: .targetDeviceId)
        historicalEpoch = try container.decodeIfPresent(UInt64.self, forKey: .historicalEpoch)
        externalEpoch = try container.decodeIfPresent(UInt64.self, forKey: .externalEpoch)
        sinkEpoch = try container.decodeIfPresent(UInt64.self, forKey: .sinkEpoch)
        stage = try container.decode(SourceTransitionStage.self, forKey: .stage)
        lastErrorCode = try container.decodeIfPresent(String.self, forKey: .lastErrorCode)

        if decodedVersion == 1 {
            // V48/V49 did not persist projection ownership. Preserve their
            // historical AppModel sentinel rule while new records stay exact.
            let inferredScope: SourceTransitionScope = (historicalEpoch ?? 0) > 1
                ? .activeProjection
                : .targetOnly
            transitionScope = inferredScope
            contributorIds = ActiveProjectionContributorSet(
                deviceIds: [sourceDeviceId]
            ).deviceIds
            previousActiveDeviceId = inferredScope == .activeProjection ? sourceDeviceId : nil
            previousSinkContextId = nil
            // V48/V49 allocated the next sink epoch from every surviving
            // surface record. `sinkEpoch - 1` is not necessarily the previous
            // active epoch, so do not fabricate rollback identity.
            previousSinkEpoch = nil
            cleanupWorkId = nil
        } else {
            previousActiveDeviceId = try container.decodeIfPresent(
                String.self,
                forKey: .previousActiveDeviceId
            )
            previousSinkContextId = try container.decodeIfPresent(
                String.self,
                forKey: .previousSinkContextId
            )
            previousSinkEpoch = try container.decodeIfPresent(
                UInt64.self,
                forKey: .previousSinkEpoch
            )
            contributorIds = ActiveProjectionContributorSet(
                deviceIds: try container.decode(Set<String>.self, forKey: .contributorIds)
            ).deviceIds
            transitionScope = try container.decode(
                SourceTransitionScope.self,
                forKey: .transitionScope
            )
            cleanupWorkId = try container.decodeIfPresent(UUID.self, forKey: .cleanupWorkId)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(mutationKind, forKey: .mutationKind)
        try container.encode(sourceDeviceId, forKey: .sourceDeviceId)
        try container.encodeIfPresent(targetDeviceId, forKey: .targetDeviceId)
        try container.encodeIfPresent(previousActiveDeviceId, forKey: .previousActiveDeviceId)
        try container.encodeIfPresent(previousSinkContextId, forKey: .previousSinkContextId)
        try container.encodeIfPresent(previousSinkEpoch, forKey: .previousSinkEpoch)
        try container.encode(contributorIds.sorted(), forKey: .contributorIds)
        try container.encode(transitionScope, forKey: .transitionScope)
        try container.encodeIfPresent(cleanupWorkId, forKey: .cleanupWorkId)
        try container.encodeIfPresent(historicalEpoch, forKey: .historicalEpoch)
        try container.encodeIfPresent(externalEpoch, forKey: .externalEpoch)
        try container.encodeIfPresent(sinkEpoch, forKey: .sinkEpoch)
        try container.encode(stage, forKey: .stage)
        try container.encodeIfPresent(lastErrorCode, forKey: .lastErrorCode)
    }
}

public struct SourceTransitionRecoveryDependencies<Commit: Sendable>: Sendable {
    public let quiesceHistorical: @Sendable () async throws -> UInt64
    public let quiesceExternal: @Sendable () async throws -> UInt64
    public let stopAffectedLiveSource: @Sendable () async -> Void
    public let restartPreviousSource: @Sendable (SourceTransitionRecoveryRecord) async -> Void
    public let beginSinkTransition: @Sendable () async throws -> UInt64
    /// Reopen the exact persisted previous verified context at a safe forward
    /// epoch after a precommit failure. Epochs never move backward.
    public let restorePrecommitSink: @Sendable (SourceTransitionRecoveryRecord) async throws -> Void
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
    /// Schedule exact follow-up work and await any durable cleanup group carried
    /// by the recovery record. Throw while that group is not terminal.
    public let scheduleExactPostCommit: @Sendable (
        SourceTransitionRecoveryRecord,
        _ commit: Commit?
    ) async throws -> Void
    public let classify: @Sendable (any Error) -> String

    public init(
        quiesceHistorical: @escaping @Sendable () async throws -> UInt64,
        quiesceExternal: @escaping @Sendable () async throws -> UInt64,
        stopAffectedLiveSource: @escaping @Sendable () async -> Void,
        restartPreviousSource: @escaping @Sendable (SourceTransitionRecoveryRecord) async -> Void,
        beginSinkTransition: @escaping @Sendable () async throws -> UInt64,
        restorePrecommitSink: @escaping @Sendable (SourceTransitionRecoveryRecord) async throws -> Void,
        persistRecovery: @escaping @Sendable (SourceTransitionRecoveryRecord) async throws -> Void,
        loadRecovery: @escaping @Sendable () async throws -> SourceTransitionRecoveryRecord?,
        commitStoreMutation: @escaping @Sendable (SourceTransitionRecoveryRecord) async throws -> Commit,
        loadCommittedMutation: @escaping @Sendable (UUID) async throws -> Commit? = { _ in nil },
        activateSink: @escaping @Sendable (UInt64, Commit?) async throws -> Void,
        resumeHistorical: @escaping @Sendable (UInt64) async throws -> Void,
        resumeExternal: @escaping @Sendable (UInt64) async throws -> Void,
        startCommittedSource: @escaping @Sendable (Commit?) async -> Void,
        scheduleExactPostCommit: @escaping @Sendable (
            SourceTransitionRecoveryRecord,
            Commit?
        ) async throws -> Void,
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

    /// Compatibility initializer for adapters that do not need the prepared
    /// recovery ID. Rollback closures still receive the durable identity.
    public init(
        quiesceHistorical: @escaping @Sendable () async throws -> UInt64,
        quiesceExternal: @escaping @Sendable () async throws -> UInt64,
        stopAffectedLiveSource: @escaping @Sendable () async -> Void,
        restartPreviousSource: @escaping @Sendable (SourceTransitionRecoveryRecord) async -> Void,
        beginSinkTransition: @escaping @Sendable () async throws -> UInt64,
        restorePrecommitSink: @escaping @Sendable (SourceTransitionRecoveryRecord) async throws -> Void,
        persistRecovery: @escaping @Sendable (SourceTransitionRecoveryRecord) async throws -> Void,
        loadRecovery: @escaping @Sendable () async throws -> SourceTransitionRecoveryRecord?,
        commitStoreMutation: @escaping @Sendable () async throws -> Commit,
        loadCommittedMutation: @escaping @Sendable (UUID) async throws -> Commit? = { _ in nil },
        activateSink: @escaping @Sendable (UInt64, Commit?) async throws -> Void,
        resumeHistorical: @escaping @Sendable (UInt64) async throws -> Void,
        resumeExternal: @escaping @Sendable (UInt64) async throws -> Void,
        startCommittedSource: @escaping @Sendable (Commit?) async -> Void,
        scheduleExactPostCommit: @escaping @Sendable (
            SourceTransitionRecoveryRecord,
            Commit?
        ) async throws -> Void,
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

    /// Persist `plannedRecord` before any worker, live source, or App Group
    /// sink side effect. The caller must snapshot all rollback identity first.
    public func perform(
        plannedRecord: SourceTransitionRecoveryRecord
    ) async throws {
        guard !running else { throw SourceTransitionRecoveryError.alreadyRunning }
        running = true
        defer { running = false }

        let contributors = ActiveProjectionContributorSet(
            deviceIds: plannedRecord.contributorIds
        )
        guard plannedRecord.version == SourceTransitionRecoveryRecord.currentVersion,
              plannedRecord.stage == .planned,
              plannedRecord.historicalEpoch == nil,
              plannedRecord.externalEpoch == nil,
              plannedRecord.sinkEpoch == nil,
              !(plannedRecord.transitionScope == .targetOnly
                && contributors.contains(plannedRecord.sourceDeviceId)),
              plannedRecord.previousActiveDeviceId.map(
                contributors.contains
              ) ?? true else {
            throw SourceTransitionRecoveryError.invalidPlan
        }

        var record = plannedRecord
        try await dependencies.persistRecovery(record)

        var stoppedLiveSource = false
        var attemptedSinkTransition = false
        do {
            let historicalEpoch = try await dependencies.quiesceHistorical()
            guard historicalEpoch > 0 else {
                throw SourceTransitionRecoveryError.invalidRecoveryRecord
            }
            record.historicalEpoch = historicalEpoch

            let externalEpoch = try await dependencies.quiesceExternal()
            guard externalEpoch > 0 else {
                throw SourceTransitionRecoveryError.invalidRecoveryRecord
            }
            record.externalEpoch = externalEpoch

            await dependencies.stopAffectedLiveSource()
            stoppedLiveSource = true

            attemptedSinkTransition = true
            let sinkEpoch = try await dependencies.beginSinkTransition()
            guard sinkEpoch > 0 else {
                throw SourceTransitionRecoveryError.invalidRecoveryRecord
            }
            record.sinkEpoch = sinkEpoch
            record.stage = .prepared
            record.lastErrorCode = nil
            try await dependencies.persistRecovery(record)
        } catch {
            await rollbackAfterFailedPreparation(
                record: &record,
                restoreSink: attemptedSinkTransition,
                restartSource: stoppedLiveSource,
                cause: error
            )
            throw error
        }

        guard let historicalEpoch = record.historicalEpoch,
              let externalEpoch = record.externalEpoch,
              let sinkEpoch = record.sinkEpoch else {
            throw SourceTransitionRecoveryError.invalidRecoveryRecord
        }

        let commit: Commit
        do {
            commit = try await dependencies.commitStoreMutation(record)
        } catch {
            // The production commit closure is transactionally all-or-nothing with `storeCommitted`.
            // A thrown error therefore means the source mutation did not durably commit.
            await rollbackAfterFailedPreparation(
                record: &record,
                restoreSink: true,
                restartSource: true,
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
            try await dependencies.scheduleExactPostCommit(record, commit)
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

    private func rollbackAfterFailedPreparation(
        record: inout SourceTransitionRecoveryRecord,
        restoreSink: Bool,
        restartSource: Bool,
        cause: any Error
    ) async {
        var rollbackError: (any Error)?

        if restoreSink {
            do {
                try await dependencies.restorePrecommitSink(record)
            } catch {
                rollbackError = error
            }
        }
        if let historicalEpoch = record.historicalEpoch {
            do {
                try await dependencies.resumeHistorical(historicalEpoch)
            } catch {
                rollbackError = rollbackError ?? error
            }
        }
        if let externalEpoch = record.externalEpoch {
            do {
                try await dependencies.resumeExternal(externalEpoch)
            } catch {
                rollbackError = rollbackError ?? error
            }
        }
        if restartSource {
            await dependencies.restartPreviousSource(record)
        }

        if let rollbackError {
            record.lastErrorCode = dependencies.classify(rollbackError)
        } else {
            record.stage = .aborted
            record.lastErrorCode = dependencies.classify(cause)
        }
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

        guard record.version <= SourceTransitionRecoveryRecord.currentVersion else {
            throw SourceTransitionRecoveryError.unsupportedRecoveryVersion
        }

        if record.stage == .planned || record.stage == .prepared {
            try await recoverPrecommit(record: &record)
            return
        }

        guard let historicalEpoch = record.historicalEpoch,
              let externalEpoch = record.externalEpoch,
              let sinkEpoch = record.sinkEpoch,
              historicalEpoch > 0,
              externalEpoch > 0,
              sinkEpoch > 0 else {
            throw SourceTransitionRecoveryError.invalidRecoveryRecord
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
            try await dependencies.activateSink(sinkEpoch, commit)
            record.stage = .sinkActivated
            try await dependencies.persistRecovery(record)
        }
        if record.stage == .sinkActivated {
            try await dependencies.resumeHistorical(historicalEpoch)
            try await dependencies.resumeExternal(externalEpoch)
            record.stage = .workersResumed
            try await dependencies.persistRecovery(record)
        }
        await dependencies.startCommittedSource(commit)
        do {
            try await dependencies.scheduleExactPostCommit(record, commit)
            record.stage = .complete
            record.lastErrorCode = nil
            try await dependencies.persistRecovery(record)
        } catch {
            record.lastErrorCode = dependencies.classify(error)
            try? await dependencies.persistRecovery(record)
            throw SourceTransitionRecoveryError.postCommitRecoveryPending
        }
    }

    private func recoverPrecommit(
        record: inout SourceTransitionRecoveryRecord
    ) async throws {
        do {
            // A `.planned` process may have terminated after the App Group
            // write but before the `.prepared` update. Restoring is idempotent.
            try await dependencies.restorePrecommitSink(record)
            if let historicalEpoch = record.historicalEpoch {
                try await dependencies.resumeHistorical(historicalEpoch)
            }
            if let externalEpoch = record.externalEpoch {
                try await dependencies.resumeExternal(externalEpoch)
            }
            await dependencies.restartPreviousSource(record)
        } catch {
            record.lastErrorCode = dependencies.classify(error)
            try? await dependencies.persistRecovery(record)
            throw error
        }

        record.stage = .aborted
        record.lastErrorCode = record.lastErrorCode ?? "recovered_precommit_abort"
        try await dependencies.persistRecovery(record)
    }
}

public enum SourceTransitionRecoveryError: Error, Equatable, Sendable {
    case alreadyRunning
    case invalidPlan
    case invalidRecoveryRecord
    case missingCommittedMutation
    case postCommitRecoveryPending
    case unsupportedRecoveryVersion
}
