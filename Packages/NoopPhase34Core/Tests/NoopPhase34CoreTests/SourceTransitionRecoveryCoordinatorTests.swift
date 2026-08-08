import XCTest
@testable import NoopPhase34Core

private enum SourceTransitionProbeError: Error {
    case persistStoreCommitted
}

private actor SourceTransitionProbe {
    var record: SourceTransitionRecoveryRecord?
    var durableCommit: String?
    var failStoreCommittedPersist = false
    var restorePrecommitCount = 0
    var restartPreviousCount = 0
    var startCommittedCount = 0
    var activatedCommits: [String] = []
    var scheduledCommits: [String] = []

    func persist(_ next: SourceTransitionRecoveryRecord) throws {
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

    func noteRestorePrecommit() { restorePrecommitCount += 1 }
    func noteRestartPrevious() { restartPreviousCount += 1 }
    func noteStartCommitted() { startCommittedCount += 1 }
    func noteActivated(_ commit: String?) {
        if let commit { activatedCommits.append(commit) }
    }
    func noteScheduled(_ commit: String?) {
        if let commit { scheduledCommits.append(commit) }
    }
}

final class SourceTransitionRecoveryCoordinatorTests: XCTestCase {
    func testPostCommitJournalFailureNeverRunsPrecommitRollback() async throws {
        let probe = SourceTransitionProbe()
        await probe.failStoreCommittedPersist = true
        let dependencies = SourceTransitionRecoveryDependencies<String>(
            quiesceHistorical: { 7 },
            quiesceExternal: { 11 },
            stopAffectedLiveSource: {},
            restartPreviousSource: { await probe.noteRestartPrevious() },
            beginSinkTransition: { 13 },
            restorePrecommitSink: { _ in await probe.noteRestorePrecommit() },
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
            scheduleExactPostCommit: { commit in await probe.noteScheduled(commit) },
            classify: { _ in "persist_failed" }
        )
        let coordinator = SourceTransitionRecoveryCoordinator(dependencies: dependencies)

        do {
            try await coordinator.perform(
                mutationKind: "deleteData",
                sourceDeviceId: "source-A",
                targetDeviceId: nil
            )
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
        let recovery = SourceTransitionRecoveryRecord(
            mutationKind: "archive",
            sourceDeviceId: "source-A",
            targetDeviceId: "source-B",
            historicalEpoch: 3,
            externalEpoch: 5,
            sinkEpoch: 8,
            stage: .storeCommitted
        )
        await probe.record = recovery
        await probe.durableCommit = "durable-commit-A"

        let dependencies = SourceTransitionRecoveryDependencies<String>(
            quiesceHistorical: { 0 },
            quiesceExternal: { 0 },
            stopAffectedLiveSource: {},
            restartPreviousSource: { await probe.noteRestartPrevious() },
            beginSinkTransition: { 0 },
            restorePrecommitSink: { _ in await probe.noteRestorePrecommit() },
            persistRecovery: { record in try await probe.persist(record) },
            loadRecovery: { await probe.load() },
            commitStoreMutation: { (_: SourceTransitionRecoveryRecord) in "unused" },
            loadCommittedMutation: { id in await probe.loadCommit(id) },
            activateSink: { _, commit in await probe.noteActivated(commit) },
            resumeHistorical: { _ in },
            resumeExternal: { _ in },
            startCommittedSource: { _ in await probe.noteStartCommitted() },
            scheduleExactPostCommit: { commit in await probe.noteScheduled(commit) },
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

    func testPostCommitRecoveryWithoutDurableCommitFailsClosed() async throws {
        let probe = SourceTransitionProbe()
        let recovery = SourceTransitionRecoveryRecord(
            mutationKind: "archive",
            sourceDeviceId: "source-A",
            targetDeviceId: "source-B",
            historicalEpoch: 3,
            externalEpoch: 5,
            sinkEpoch: 8,
            stage: .storeCommitted
        )
        await probe.record = recovery

        let dependencies = SourceTransitionRecoveryDependencies<String>(
            quiesceHistorical: { 0 },
            quiesceExternal: { 0 },
            stopAffectedLiveSource: {},
            restartPreviousSource: {},
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
            scheduleExactPostCommit: { _ in },
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
