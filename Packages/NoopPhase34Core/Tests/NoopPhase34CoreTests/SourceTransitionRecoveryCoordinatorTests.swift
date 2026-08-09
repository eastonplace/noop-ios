import XCTest
@testable import NoopPhase34Core

private enum SourceTransitionProbeError: Error {
    case beforeSinkMutation
    case cleanupPending
    case persistPrepared
    case persistStoreCommitted
}

private func makeSourceTransitionRecord(
    id: UUID = UUID(),
    mutationKind: String = "archive",
    sourceDeviceId: String = "source-A",
    targetDeviceId: String? = "source-B",
    previousActiveDeviceId: String? = "source-A",
    previousSinkContextId: String? = "context-A",
    previousSinkEpoch: UInt64? = 2,
    contributorIds: Set<String> = ["source-A", "canonical-A"],
    transitionScope: SourceTransitionScope = .activeProjection,
    cleanupWorkId: UUID? = nil,
    historicalEpoch: UInt64? = 3,
    externalEpoch: UInt64? = 5,
    sinkEpoch: UInt64? = 8,
    stage: SourceTransitionStage = .prepared,
    lastErrorCode: String? = nil
) -> SourceTransitionRecoveryRecord {
    SourceTransitionRecoveryRecord(
        id: id,
        mutationKind: mutationKind,
        sourceDeviceId: sourceDeviceId,
        targetDeviceId: targetDeviceId,
        previousActiveDeviceId: previousActiveDeviceId,
        previousSinkContextId: previousSinkContextId,
        previousSinkEpoch: previousSinkEpoch,
        contributorIds: contributorIds,
        transitionScope: transitionScope,
        cleanupWorkId: cleanupWorkId,
        historicalEpoch: historicalEpoch,
        externalEpoch: externalEpoch,
        sinkEpoch: sinkEpoch,
        stage: stage,
        lastErrorCode: lastErrorCode
    )
}

private actor SourceTransitionProbe {
    var record: SourceTransitionRecoveryRecord?
    var durableCommit: String?
    var failPreparedPersist = false
    var failStoreCommittedPersist = false
    var restorePrecommitCount = 0
    var restartPreviousCount = 0
    var startCommittedCount = 0
    var activatedCommits: [String] = []
    var scheduledCommits: [String] = []
    var historicalResumeEpochs: [UInt64] = []
    var externalResumeEpochs: [UInt64] = []
    var persistedRecords: [SourceTransitionRecoveryRecord] = []
    var restoredRecords: [SourceTransitionRecoveryRecord] = []
    var restartedRecords: [SourceTransitionRecoveryRecord] = []
    var sinkTransitionCount = 0
    var postCommitFailuresRemaining = 0
    var postCommitRecords: [SourceTransitionRecoveryRecord] = []

    func failStoreCommittedPersistence() {
        failStoreCommittedPersist = true
    }

    func failPreparedPersistence() {
        failPreparedPersist = true
    }

    func failNextPostCommitCompletion() {
        postCommitFailuresRemaining += 1
    }

    func seed(record: SourceTransitionRecoveryRecord, durableCommit: String? = nil) {
        self.record = record
        self.durableCommit = durableCommit
    }

    func persist(_ next: SourceTransitionRecoveryRecord) throws {
        persistedRecords.append(next)
        if failPreparedPersist, next.stage == .prepared {
            throw SourceTransitionProbeError.persistPrepared
        }
        if failStoreCommittedPersist, next.stage == .storeCommitted {
            throw SourceTransitionProbeError.persistStoreCommitted
        }
        record = next
    }

    func load() -> SourceTransitionRecoveryRecord? { record }

    func loadCommit(_ id: UUID) -> String? {
        guard record?.id == id else { return nil }
        return durableCommit
    }

    func commit(_ prepared: SourceTransitionRecoveryRecord, value: String) {
        durableCommit = value
        var committed = prepared
        committed.stage = .storeCommitted
        record = committed
    }

    func noteRestorePrecommit(_ record: SourceTransitionRecoveryRecord) {
        restorePrecommitCount += 1
        restoredRecords.append(record)
    }
    func noteRestartPrevious(_ record: SourceTransitionRecoveryRecord) {
        restartPreviousCount += 1
        restartedRecords.append(record)
    }
    func noteSinkTransition() { sinkTransitionCount += 1 }
    func noteStartCommitted() { startCommittedCount += 1 }
    func noteActivated(_ commit: String?) {
        if let commit { activatedCommits.append(commit) }
    }
    func noteScheduled(_ commit: String?) {
        if let commit { scheduledCommits.append(commit) }
    }
    func awaitPostCommit(
        record: SourceTransitionRecoveryRecord,
        commit: String?
    ) throws {
        postCommitRecords.append(record)
        if postCommitFailuresRemaining > 0 {
            postCommitFailuresRemaining -= 1
            throw SourceTransitionProbeError.cleanupPending
        }
        if let commit { scheduledCommits.append(commit) }
    }
    func noteHistoricalResume(_ epoch: UInt64) { historicalResumeEpochs.append(epoch) }
    func noteExternalResume(_ epoch: UInt64) { externalResumeEpochs.append(epoch) }
}

final class SourceTransitionRecoveryCoordinatorTests: XCTestCase {
    func testActiveProjectionContributorSetNormalizesDurableIdentity() throws {
        let contributors = ActiveProjectionContributorSet(
            activeLiveDeviceId: " source-B ",
            canonicalContributorIds: ["source-A\n", "", "source-A"]
        )

        XCTAssertEqual(contributors.deviceIds, ["source-A", "source-B"])
        XCTAssertEqual(contributors.scope(affecting: "source-A"), .activeProjection)
        XCTAssertEqual(contributors.scope(affecting: " source-B\n"), .activeProjection)
        XCTAssertEqual(contributors.scope(affecting: "source-C"), .targetOnly)

        let encoded = try JSONEncoder().encode(contributors)
        let decoded = try JSONDecoder().decode(
            ActiveProjectionContributorSet.self,
            from: encoded
        )
        XCTAssertEqual(decoded, contributors)
    }

    func testVersionOneRecoveryRecordDecodesWithLegacyDefaults() throws {
        let transitionId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let json = """
        {
          "id": "\(transitionId.uuidString)",
          "mutationKind": "archive",
          "sourceDeviceId": "source-A",
          "targetDeviceId": "source-B",
          "historicalEpoch": 3,
          "externalEpoch": 5,
          "sinkEpoch": 8,
          "stage": "prepared"
        }
        """

        let record = try JSONDecoder().decode(
            SourceTransitionRecoveryRecord.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(record.version, 1)
        XCTAssertEqual(record.id, transitionId)
        XCTAssertEqual(record.transitionScope, .activeProjection)
        XCTAssertEqual(record.contributorIds, ["source-A"])
        XCTAssertEqual(record.previousActiveDeviceId, "source-A")
        XCTAssertNil(record.previousSinkEpoch)
        XCTAssertNil(record.previousSinkContextId)
        XCTAssertNil(record.cleanupWorkId)
    }

    func testVersionTwoRecoveryRecordRoundTripsFullIdentity() throws {
        let cleanupWorkId = UUID()
        let planned = makeSourceTransitionRecord(
            mutationKind: "deleteData",
            targetDeviceId: nil,
            previousActiveDeviceId: "source-B",
            previousSinkContextId: "verified-context-A",
            previousSinkEpoch: 21,
            contributorIds: [" source-A ", "source-B", ""],
            cleanupWorkId: cleanupWorkId,
            historicalEpoch: nil,
            externalEpoch: nil,
            sinkEpoch: nil,
            stage: .planned
        )

        let data = try JSONEncoder().encode(planned)
        let decoded = try JSONDecoder().decode(
            SourceTransitionRecoveryRecord.self,
            from: data
        )

        XCTAssertEqual(decoded, planned)
        XCTAssertEqual(decoded.version, SourceTransitionRecoveryRecord.currentVersion)
        XCTAssertEqual(decoded.contributorIds, ["source-A", "source-B"])
        XCTAssertEqual(decoded.cleanupWorkId, cleanupWorkId)
    }

    func testPlannedRecordPersistsBeforeFailureBeforeSinkMutation() async throws {
        let probe = SourceTransitionProbe()
        let dependencies = SourceTransitionRecoveryDependencies<String>(
            quiesceHistorical: {
                let persisted = await probe.persistedRecords
                XCTAssertEqual(persisted.first?.stage, .planned)
                XCTAssertNil(persisted.first?.historicalEpoch)
                throw SourceTransitionProbeError.beforeSinkMutation
            },
            quiesceExternal: {
                XCTFail("external work quiesced after historical preparation failed")
                return 1
            },
            stopAffectedLiveSource: {
                XCTFail("live source stopped after historical preparation failed")
            },
            restartPreviousSource: { _ in
                XCTFail("untouched live source was restarted")
            },
            beginSinkTransition: {
                await probe.noteSinkTransition()
                return 1
            },
            restorePrecommitSink: { _ in
                XCTFail("untouched sink was restored")
            },
            persistRecovery: { record in try await probe.persist(record) },
            loadRecovery: { await probe.load() },
            commitStoreMutation: { (_: SourceTransitionRecoveryRecord) in
                XCTFail("store mutation ran after preparation failed")
                return "unused"
            },
            activateSink: { _, _ in XCTFail("sink activated after preparation failed") },
            resumeHistorical: { _ in },
            resumeExternal: { _ in },
            startCommittedSource: { _ in XCTFail("committed source started") },
            scheduleExactPostCommit: { _, _ in XCTFail("postcommit work scheduled") },
            classify: { _ in "before_sink_mutation" }
        )
        let coordinator = SourceTransitionRecoveryCoordinator(dependencies: dependencies)
        let planned = makeSourceTransitionRecord(
            historicalEpoch: nil,
            externalEpoch: nil,
            sinkEpoch: nil,
            stage: .planned
        )

        do {
            try await coordinator.perform(plannedRecord: planned)
            XCTFail("pre-sink failure was reported as success")
        } catch SourceTransitionProbeError.beforeSinkMutation {
            // Expected.
        }

        let persistedRecords = await probe.persistedRecords
        let persistedStages = persistedRecords.map(\.stage)
        let sinkTransitionCount = await probe.sinkTransitionCount
        let finalRecord = await probe.record
        XCTAssertEqual(persistedStages, [.planned, .aborted])
        XCTAssertEqual(sinkTransitionCount, 0)
        XCTAssertEqual(finalRecord?.stage, .aborted)
    }

    func testPreparedPersistenceFailureRollsBackUsingFullDurableIdentity() async throws {
        let probe = SourceTransitionProbe()
        await probe.failPreparedPersistence()
        let cleanupWorkId = UUID()
        let dependencies = SourceTransitionRecoveryDependencies<String>(
            quiesceHistorical: { 3 },
            quiesceExternal: { 5 },
            stopAffectedLiveSource: {},
            restartPreviousSource: { record in await probe.noteRestartPrevious(record) },
            beginSinkTransition: {
                await probe.noteSinkTransition()
                return 8
            },
            restorePrecommitSink: { record in await probe.noteRestorePrecommit(record) },
            persistRecovery: { record in try await probe.persist(record) },
            loadRecovery: { await probe.load() },
            commitStoreMutation: { (_: SourceTransitionRecoveryRecord) in
                XCTFail("store mutation ran without durable prepared state")
                return "unused"
            },
            activateSink: { _, _ in XCTFail("sink activated without a store commit") },
            resumeHistorical: { epoch in await probe.noteHistoricalResume(epoch) },
            resumeExternal: { epoch in await probe.noteExternalResume(epoch) },
            startCommittedSource: { _ in XCTFail("committed source started") },
            scheduleExactPostCommit: { _, _ in XCTFail("postcommit work scheduled") },
            classify: { _ in "prepared_persist_failed" }
        )
        let coordinator = SourceTransitionRecoveryCoordinator(dependencies: dependencies)
        let planned = makeSourceTransitionRecord(
            mutationKind: "deleteData",
            targetDeviceId: nil,
            previousActiveDeviceId: "source-B",
            previousSinkContextId: "verified-context-A",
            previousSinkEpoch: 7,
            contributorIds: ["source-A", "source-B"],
            cleanupWorkId: cleanupWorkId,
            historicalEpoch: nil,
            externalEpoch: nil,
            sinkEpoch: nil,
            stage: .planned
        )

        do {
            try await coordinator.perform(plannedRecord: planned)
            XCTFail("prepared persistence failure was reported as success")
        } catch SourceTransitionProbeError.persistPrepared {
            // Expected.
        }

        let persistedRecords = await probe.persistedRecords
        let persistedStages = persistedRecords.map(\.stage)
        let restored = await probe.restoredRecords
        let restarted = await probe.restartedRecords
        let historicalResumes = await probe.historicalResumeEpochs
        let externalResumes = await probe.externalResumeEpochs
        XCTAssertEqual(persistedStages, [.planned, .prepared, .aborted])
        XCTAssertEqual(restored.first?.previousActiveDeviceId, "source-B")
        XCTAssertEqual(restored.first?.previousSinkContextId, "verified-context-A")
        XCTAssertEqual(restored.first?.previousSinkEpoch, 7)
        XCTAssertEqual(restored.first?.contributorIds, ["source-A", "source-B"])
        XCTAssertEqual(restored.first?.cleanupWorkId, cleanupWorkId)
        XCTAssertEqual(restarted.first, restored.first)
        XCTAssertEqual(historicalResumes, [3])
        XCTAssertEqual(externalResumes, [5])
    }

    func testRelaunchFromPlannedRestoresPersistedRollbackIdentity() async throws {
        let probe = SourceTransitionProbe()
        let cleanupWorkId = UUID()
        let recovery = makeSourceTransitionRecord(
            mutationKind: "deleteData",
            targetDeviceId: nil,
            previousActiveDeviceId: "source-B",
            previousSinkContextId: "verified-context-A",
            previousSinkEpoch: 21,
            contributorIds: ["source-A", "source-B", "canonical-A"],
            cleanupWorkId: cleanupWorkId,
            historicalEpoch: nil,
            externalEpoch: nil,
            sinkEpoch: nil,
            stage: .planned
        )
        await probe.seed(record: recovery)

        let dependencies = SourceTransitionRecoveryDependencies<String>(
            quiesceHistorical: { 0 },
            quiesceExternal: { 0 },
            stopAffectedLiveSource: {},
            restartPreviousSource: { record in await probe.noteRestartPrevious(record) },
            beginSinkTransition: { 0 },
            restorePrecommitSink: { record in await probe.noteRestorePrecommit(record) },
            persistRecovery: { record in try await probe.persist(record) },
            loadRecovery: { await probe.load() },
            commitStoreMutation: { (_: SourceTransitionRecoveryRecord) in
                XCTFail("planned recovery attempted a store mutation")
                return "unused"
            },
            loadCommittedMutation: { _ in
                XCTFail("planned recovery loaded a durable commit")
                return nil
            },
            activateSink: { _, _ in XCTFail("planned recovery activated a committed sink") },
            resumeHistorical: { _ in XCTFail("planned recovery resumed an unknown epoch") },
            resumeExternal: { _ in XCTFail("planned recovery resumed an unknown epoch") },
            startCommittedSource: { _ in XCTFail("planned recovery started a committed source") },
            scheduleExactPostCommit: { _, _ in XCTFail("planned recovery scheduled postcommit work") },
            classify: { _ in "error" }
        )
        let coordinator = SourceTransitionRecoveryCoordinator(dependencies: dependencies)

        try await coordinator.recoverPending()

        let restored = await probe.restoredRecords
        let restarted = await probe.restartedRecords
        let finalRecord = await probe.record
        XCTAssertEqual(restored, [recovery])
        XCTAssertEqual(restarted, [recovery])
        XCTAssertEqual(finalRecord?.stage, .aborted)
        XCTAssertEqual(finalRecord?.cleanupWorkId, cleanupWorkId)
    }

    func testActiveSelectionPlanMayTargetSourceOutsidePreviousContributors() async throws {
        let probe = SourceTransitionProbe()
        let dependencies = SourceTransitionRecoveryDependencies<String>(
            quiesceHistorical: { 3 },
            quiesceExternal: { 5 },
            stopAffectedLiveSource: {},
            restartPreviousSource: { _ in },
            beginSinkTransition: { 8 },
            restorePrecommitSink: { _ in },
            persistRecovery: { record in try await probe.persist(record) },
            loadRecovery: { await probe.load() },
            commitStoreMutation: { prepared in
                await probe.commit(prepared, value: "commit-B")
                return "commit-B"
            },
            loadCommittedMutation: { id in await probe.loadCommit(id) },
            activateSink: { _, commit in await probe.noteActivated(commit) },
            resumeHistorical: { _ in },
            resumeExternal: { _ in },
            startCommittedSource: { _ in await probe.noteStartCommitted() },
            scheduleExactPostCommit: { _, commit in await probe.noteScheduled(commit) },
            classify: { _ in "error" }
        )
        let coordinator = SourceTransitionRecoveryCoordinator(dependencies: dependencies)
        let planned = makeSourceTransitionRecord(
            mutationKind: "selectExisting",
            sourceDeviceId: "source-B",
            targetDeviceId: "source-B",
            previousActiveDeviceId: "source-A",
            contributorIds: ["source-A", "canonical-A"],
            transitionScope: .activeProjection,
            historicalEpoch: nil,
            externalEpoch: nil,
            sinkEpoch: nil,
            stage: .planned
        )

        try await coordinator.perform(plannedRecord: planned)

        let finalRecord = await probe.record
        XCTAssertEqual(finalRecord?.stage, .complete)
        XCTAssertEqual(finalRecord?.sourceDeviceId, "source-B")
    }

    func testCleanupFailureKeepsPostcommitPendingUntilRecoverySucceeds() async throws {
        let probe = SourceTransitionProbe()
        await probe.failNextPostCommitCompletion()
        let cleanupWorkId = UUID()
        let dependencies = SourceTransitionRecoveryDependencies<String>(
            quiesceHistorical: { 3 },
            quiesceExternal: { 5 },
            stopAffectedLiveSource: {},
            restartPreviousSource: { _ in },
            beginSinkTransition: { 8 },
            restorePrecommitSink: { _ in },
            persistRecovery: { record in try await probe.persist(record) },
            loadRecovery: { await probe.load() },
            commitStoreMutation: { prepared in
                await probe.commit(prepared, value: "delete-commit-A")
                return "delete-commit-A"
            },
            loadCommittedMutation: { id in await probe.loadCommit(id) },
            activateSink: { _, commit in await probe.noteActivated(commit) },
            resumeHistorical: { _ in },
            resumeExternal: { _ in },
            startCommittedSource: { _ in await probe.noteStartCommitted() },
            scheduleExactPostCommit: { record, commit in
                try await probe.awaitPostCommit(record: record, commit: commit)
            },
            classify: { error in
                error is SourceTransitionProbeError ? "cleanup_pending" : "error"
            }
        )
        let coordinator = SourceTransitionRecoveryCoordinator(dependencies: dependencies)
        let planned = makeSourceTransitionRecord(
            mutationKind: "deleteData",
            targetDeviceId: nil,
            cleanupWorkId: cleanupWorkId,
            historicalEpoch: nil,
            externalEpoch: nil,
            sinkEpoch: nil,
            stage: .planned
        )

        do {
            try await coordinator.perform(plannedRecord: planned)
            XCTFail("incomplete cleanup allowed the transition to complete")
        } catch SourceTransitionRecoveryError.postCommitRecoveryPending {
            // Expected.
        }

        let pendingRecord = await probe.record
        let firstPostCommitRecords = await probe.postCommitRecords
        XCTAssertEqual(pendingRecord?.stage, .workersResumed)
        XCTAssertEqual(pendingRecord?.lastErrorCode, "cleanup_pending")
        XCTAssertEqual(firstPostCommitRecords.count, 1)
        XCTAssertEqual(firstPostCommitRecords.first?.cleanupWorkId, cleanupWorkId)

        try await coordinator.recoverPending()

        let finalRecord = await probe.record
        let postCommitRecords = await probe.postCommitRecords
        let scheduled = await probe.scheduledCommits
        XCTAssertEqual(finalRecord?.stage, .complete)
        XCTAssertNil(finalRecord?.lastErrorCode)
        XCTAssertEqual(postCommitRecords.map(\.cleanupWorkId), [cleanupWorkId, cleanupWorkId])
        XCTAssertEqual(scheduled, ["delete-commit-A"])
    }

    func testPostCommitJournalFailureNeverRunsPrecommitRollback() async throws {
        let probe = SourceTransitionProbe()
        await probe.failStoreCommittedPersistence()
        let dependencies = SourceTransitionRecoveryDependencies<String>(
            quiesceHistorical: { 7 },
            quiesceExternal: { 11 },
            stopAffectedLiveSource: {},
            restartPreviousSource: { record in await probe.noteRestartPrevious(record) },
            beginSinkTransition: { 13 },
            restorePrecommitSink: { record in await probe.noteRestorePrecommit(record) },
            persistRecovery: { record in try await probe.persist(record) },
            loadRecovery: { await probe.load() },
            commitStoreMutation: { prepared in
                await probe.commit(prepared, value: "commit-A")
                return "commit-A"
            },
            loadCommittedMutation: { id in await probe.loadCommit(id) },
            activateSink: { _, commit in await probe.noteActivated(commit) },
            resumeHistorical: { _ in },
            resumeExternal: { _ in },
            startCommittedSource: { _ in await probe.noteStartCommitted() },
            scheduleExactPostCommit: { _, commit in await probe.noteScheduled(commit) },
            classify: { _ in "persist_failed" }
        )
        let coordinator = SourceTransitionRecoveryCoordinator(dependencies: dependencies)
        let planned = makeSourceTransitionRecord(
            mutationKind: "deleteData",
            targetDeviceId: nil,
            historicalEpoch: nil,
            externalEpoch: nil,
            sinkEpoch: nil,
            stage: .planned
        )

        do {
            try await coordinator.perform(plannedRecord: planned)
            XCTFail("postcommit recovery failure was reported as success")
        } catch SourceTransitionRecoveryError.postCommitRecoveryPending {
            // Expected.
        }

        let restoreCount = await probe.restorePrecommitCount
        let restartCount = await probe.restartPreviousCount
        let startCount = await probe.startCommittedCount
        XCTAssertEqual(restoreCount, 0)
        XCTAssertEqual(restartCount, 0)
        XCTAssertEqual(startCount, 1)
    }

    func testRelaunchRecoveryLoadsExactDurableCommitByTransitionId() async throws {
        let probe = SourceTransitionProbe()
        let recovery = makeSourceTransitionRecord(stage: .storeCommitted)
        await probe.seed(record: recovery, durableCommit: "durable-commit-A")

        let dependencies = SourceTransitionRecoveryDependencies<String>(
            quiesceHistorical: { 0 },
            quiesceExternal: { 0 },
            stopAffectedLiveSource: {},
            restartPreviousSource: { record in await probe.noteRestartPrevious(record) },
            beginSinkTransition: { 0 },
            restorePrecommitSink: { record in await probe.noteRestorePrecommit(record) },
            persistRecovery: { record in try await probe.persist(record) },
            loadRecovery: { await probe.load() },
            commitStoreMutation: { (_: SourceTransitionRecoveryRecord) in "unused" },
            loadCommittedMutation: { id in await probe.loadCommit(id) },
            activateSink: { _, commit in await probe.noteActivated(commit) },
            resumeHistorical: { _ in },
            resumeExternal: { _ in },
            startCommittedSource: { _ in await probe.noteStartCommitted() },
            scheduleExactPostCommit: { _, commit in await probe.noteScheduled(commit) },
            classify: { _ in "error" }
        )
        let coordinator = SourceTransitionRecoveryCoordinator(dependencies: dependencies)

        try await coordinator.recoverPending()

        let activated = await probe.activatedCommits
        let scheduled = await probe.scheduledCommits
        let finalRecord = await probe.record
        XCTAssertEqual(activated, ["durable-commit-A"])
        XCTAssertEqual(scheduled, ["durable-commit-A"])
        XCTAssertEqual(finalRecord?.stage, .complete)
    }

    func testRelaunchFromPreparedAbortsAndRestoresPrecommitState() async throws {
        let probe = SourceTransitionProbe()
        let recovery = makeSourceTransitionRecord(
            mutationKind: "deleteData",
            stage: .prepared
        )
        await probe.seed(record: recovery)

        let dependencies = SourceTransitionRecoveryDependencies<String>(
            quiesceHistorical: { 0 },
            quiesceExternal: { 0 },
            stopAffectedLiveSource: {},
            restartPreviousSource: { record in await probe.noteRestartPrevious(record) },
            beginSinkTransition: { 0 },
            restorePrecommitSink: { record in await probe.noteRestorePrecommit(record) },
            persistRecovery: { record in try await probe.persist(record) },
            loadRecovery: { await probe.load() },
            commitStoreMutation: { (_: SourceTransitionRecoveryRecord) in
                XCTFail("prepared relaunch attempted a store mutation")
                return "unused"
            },
            loadCommittedMutation: { _ in
                XCTFail("prepared relaunch attempted to load a durable commit")
                return nil
            },
            activateSink: { _, _ in XCTFail("prepared relaunch activated the committed sink") },
            resumeHistorical: { epoch in await probe.noteHistoricalResume(epoch) },
            resumeExternal: { epoch in await probe.noteExternalResume(epoch) },
            startCommittedSource: { _ in XCTFail("prepared relaunch started the committed source") },
            scheduleExactPostCommit: { _, _ in XCTFail("prepared relaunch scheduled postcommit work") },
            classify: { _ in "error" }
        )
        let coordinator = SourceTransitionRecoveryCoordinator(dependencies: dependencies)

        try await coordinator.recoverPending()

        let finalRecord = await probe.record
        let restoreCount = await probe.restorePrecommitCount
        let restartCount = await probe.restartPreviousCount
        let historicalResumes = await probe.historicalResumeEpochs
        let externalResumes = await probe.externalResumeEpochs
        XCTAssertEqual(finalRecord?.stage, .aborted)
        XCTAssertEqual(finalRecord?.lastErrorCode, "recovered_precommit_abort")
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(historicalResumes, [3])
        XCTAssertEqual(externalResumes, [5])
    }

    func testRelaunchFromSinkActivatedResumesWorkersWithoutReactivatingSink() async throws {
        let probe = SourceTransitionProbe()
        let recovery = makeSourceTransitionRecord(stage: .sinkActivated)
        await probe.seed(record: recovery, durableCommit: "durable-commit-A")

        let dependencies = SourceTransitionRecoveryDependencies<String>(
            quiesceHistorical: { 0 },
            quiesceExternal: { 0 },
            stopAffectedLiveSource: {},
            restartPreviousSource: { _ in },
            beginSinkTransition: { 0 },
            restorePrecommitSink: { _ in },
            persistRecovery: { record in try await probe.persist(record) },
            loadRecovery: { await probe.load() },
            commitStoreMutation: { (_: SourceTransitionRecoveryRecord) in "unused" },
            loadCommittedMutation: { id in await probe.loadCommit(id) },
            activateSink: { _, _ in XCTFail("sinkActivated relaunch reactivated the sink") },
            resumeHistorical: { epoch in await probe.noteHistoricalResume(epoch) },
            resumeExternal: { epoch in await probe.noteExternalResume(epoch) },
            startCommittedSource: { _ in await probe.noteStartCommitted() },
            scheduleExactPostCommit: { _, commit in await probe.noteScheduled(commit) },
            classify: { _ in "error" }
        )
        let coordinator = SourceTransitionRecoveryCoordinator(dependencies: dependencies)

        try await coordinator.recoverPending()

        let finalRecord = await probe.record
        let historicalResumes = await probe.historicalResumeEpochs
        let externalResumes = await probe.externalResumeEpochs
        let startCount = await probe.startCommittedCount
        let scheduled = await probe.scheduledCommits
        XCTAssertEqual(finalRecord?.stage, .complete)
        XCTAssertEqual(historicalResumes, [3])
        XCTAssertEqual(externalResumes, [5])
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(scheduled, ["durable-commit-A"])
    }

    func testRelaunchFromWorkersResumedOnlyStartsSourceAndSchedulesPostcommit() async throws {
        let probe = SourceTransitionProbe()
        let recovery = makeSourceTransitionRecord(stage: .workersResumed)
        await probe.seed(record: recovery, durableCommit: "durable-commit-A")

        let dependencies = SourceTransitionRecoveryDependencies<String>(
            quiesceHistorical: { 0 },
            quiesceExternal: { 0 },
            stopAffectedLiveSource: {},
            restartPreviousSource: { _ in },
            beginSinkTransition: { 0 },
            restorePrecommitSink: { _ in },
            persistRecovery: { record in try await probe.persist(record) },
            loadRecovery: { await probe.load() },
            commitStoreMutation: { (_: SourceTransitionRecoveryRecord) in "unused" },
            loadCommittedMutation: { id in await probe.loadCommit(id) },
            activateSink: { _, _ in XCTFail("workersResumed relaunch reactivated the sink") },
            resumeHistorical: { _ in XCTFail("workersResumed relaunch resumed historical work twice") },
            resumeExternal: { _ in XCTFail("workersResumed relaunch resumed external work twice") },
            startCommittedSource: { _ in await probe.noteStartCommitted() },
            scheduleExactPostCommit: { _, commit in await probe.noteScheduled(commit) },
            classify: { _ in "error" }
        )
        let coordinator = SourceTransitionRecoveryCoordinator(dependencies: dependencies)

        try await coordinator.recoverPending()

        let finalRecord = await probe.record
        let startCount = await probe.startCommittedCount
        let scheduled = await probe.scheduledCommits
        XCTAssertEqual(finalRecord?.stage, .complete)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(scheduled, ["durable-commit-A"])
    }

    func testPostCommitRecoveryWithoutDurableCommitFailsClosed() async throws {
        let probe = SourceTransitionProbe()
        let recovery = makeSourceTransitionRecord(stage: .storeCommitted)
        await probe.seed(record: recovery)

        let dependencies = SourceTransitionRecoveryDependencies<String>(
            quiesceHistorical: { 0 },
            quiesceExternal: { 0 },
            stopAffectedLiveSource: {},
            restartPreviousSource: { _ in },
            beginSinkTransition: { 0 },
            restorePrecommitSink: { _ in },
            persistRecovery: { record in try await probe.persist(record) },
            loadRecovery: { await probe.load() },
            commitStoreMutation: { (_: SourceTransitionRecoveryRecord) in "unused" },
            loadCommittedMutation: { _ in nil },
            activateSink: { _, _ in XCTFail("sink activated without durable commit") },
            resumeHistorical: { _ in },
            resumeExternal: { _ in },
            startCommittedSource: { _ in XCTFail("committed source started without durable commit") },
            scheduleExactPostCommit: { _, _ in },
            classify: { _ in "error" }
        )
        let coordinator = SourceTransitionRecoveryCoordinator(dependencies: dependencies)

        do {
            try await coordinator.recoverPending()
            XCTFail("missing durable commit was accepted")
        } catch SourceTransitionRecoveryError.missingCommittedMutation {
            // Expected.
        }

        let finalRecord = await probe.record
        XCTAssertEqual(finalRecord, recovery)
    }
}
