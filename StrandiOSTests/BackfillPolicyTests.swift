import XCTest
@testable import NOOP
import WhoopStore

@MainActor
final class BackfillPolicyTests: XCTestCase {
    private actor MaterializationDueGate {
        private var entered = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func pause() async {
            entered = true
            enteredWaiters.forEach { $0.resume() }
            enteredWaiters.removeAll()
            await withCheckedContinuation { releaseContinuation = $0 }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private actor MaterializationWorkerRecorder {
        private var oldStoreRuns = 0
        private var reopenedStoreRuns = 0

        func record(store: WhoopStore, oldStore: WhoopStore, reopenedStore: WhoopStore) {
            if store === oldStore { oldStoreRuns += 1 }
            if store === reopenedStore { reopenedStoreRuns += 1 }
        }

        func counts() -> (oldStore: Int, reopenedStore: Int) {
            (oldStoreRuns, reopenedStoreRuns)
        }
    }

    func testWhoopFourBondWriteOwnsHandshakeCallback() {
        XCTAssertEqual(BLEManager.handshakeConfirmedWritePurpose(for: .whoop4), .bondHandshake)
    }

    func testWhoopFiveClientHelloOwnsHandshakeCallback() {
        XCTAssertEqual(BLEManager.handshakeConfirmedWritePurpose(for: .whoop5), .clientHello)
    }

    func testGenericConfirmedCommandCannotOwnBondCallback() {
        XCTAssertEqual(
            BLEManager.confirmedWritePurpose(command: .sendHistoricalData, isHistoricalAck: false),
            .genericCommand)
    }

    func testHistoricalAckKeepsDedicatedCallbackOwnership() {
        XCTAssertEqual(
            BLEManager.confirmedWritePurpose(command: .historicalDataResult, isHistoricalAck: true),
            .historicalAck)
    }

    func testStaleDisconnectCannotTearDownCurrentConnection() {
        let active = UUID()
        XCTAssertFalse(BLEManager.shouldApplyDisconnectEvent(
            eventPeripheralID: UUID(),
            activePeripheralID: active,
            activePeripheralIsConnected: false))
        XCTAssertFalse(BLEManager.shouldApplyDisconnectEvent(
            eventPeripheralID: active,
            activePeripheralID: active,
            activePeripheralIsConnected: true))
        XCTAssertTrue(BLEManager.shouldApplyDisconnectEvent(
            eventPeripheralID: active,
            activePeripheralID: active,
            activePeripheralIsConnected: false))

        XCTAssertFalse(BLEManager.shouldAcceptPeripheralCallback(
            eventPeripheralID: UUID(),
            activePeripheralID: active,
            activePeripheralIsConnected: true))
        XCTAssertFalse(BLEManager.shouldAcceptPeripheralCallback(
            eventPeripheralID: active,
            activePeripheralID: active,
            activePeripheralIsConnected: false))
        XCTAssertTrue(BLEManager.shouldAcceptPeripheralCallback(
            eventPeripheralID: active,
            activePeripheralID: active,
            activePeripheralIsConnected: true))
    }

    func testSamePeripheralDelayedConfirmedWriteCannotCrossConnectionGeneration() {
        let peripheral = UUID()
        let characteristic = BLEManager.cmdWriteChar

        XCTAssertFalse(BLEManager.shouldAcceptConfirmedWriteCallback(
            eventPeripheralID: peripheral,
            eventCharacteristicUUID: characteristic,
            activePeripheralID: peripheral,
            activePeripheralIsConnected: true,
            activeConnectGeneration: 2,
            queuedPeripheralID: peripheral,
            queuedCharacteristicUUID: characteristic,
            queuedConnectGeneration: 1),
            "A delayed callback from the old connection must consume its retired token, never confirm the new session")

        XCTAssertTrue(BLEManager.shouldAcceptConfirmedWriteCallback(
            eventPeripheralID: peripheral,
            eventCharacteristicUUID: characteristic,
            activePeripheralID: peripheral,
            activePeripheralIsConnected: true,
            activeConnectGeneration: 2,
            queuedPeripheralID: peripheral,
            queuedCharacteristicUUID: characteristic,
            queuedConnectGeneration: 2))
    }

    func testEmptyPeriodicCadenceBacksOffFromFifteenToThirtyToSixtyMinutes() {
        let last = 10_000.0

        XCTAssertEqual(BackfillPolicy.periodicFloorSeconds(powerSaving: false, emptyStreak: 0), 900)
        XCTAssertEqual(BackfillPolicy.periodicFloorSeconds(powerSaving: false, emptyStreak: 1), 1_800)
        XCTAssertEqual(BackfillPolicy.periodicFloorSeconds(powerSaving: false, emptyStreak: 2), 3_600)
        XCTAssertEqual(BackfillPolicy.periodicFloorSeconds(powerSaving: false, emptyStreak: 12), 3_600)
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: last + 3_599,
                                                lastBackfillAt: last, emptyStreak: 12))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: last + 3_600,
                                               lastBackfillAt: last, emptyStreak: 12))
    }

    func testStrapPromptCannotBypassEmptyBackoff() {
        let last = 10_000.0

        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: last + 90,
                                               lastBackfillAt: last, emptyStreak: 0))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: last + 3_599,
                                                lastBackfillAt: last, emptyStreak: 2))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: last + 3_600,
                                               lastBackfillAt: last, emptyStreak: 2))
    }

    func testLowBatteryPeriodicFloorMatchesItsOneShotTimer() {
        let last = 10_000.0

        XCTAssertEqual(BackfillPolicy.periodicFloorSeconds(powerSaving: true),
                       TimeInterval(BLEManager.lowBatteryBackfillIntervalSeconds))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: last + 2_699,
                                                lastBackfillAt: last, emptyStreak: 0,
                                                powerSaving: true))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: last + 2_700,
                                               lastBackfillAt: last, emptyStreak: 0,
                                               powerSaving: true))
        XCTAssertEqual(BackfillPolicy.periodicFloorSeconds(powerSaving: true, emptyStreak: 2), 3_600)
    }

    func testEnteringPowerSavingKeepsDeadlineAnchoredToLastAttempt() {
        let last = 10_000.0
        let normalTimerFire = last + BackfillPolicy.periodicFloorSeconds

        XCTAssertEqual(
            BackfillPolicy.periodicDeadline(
                now: normalTimerFire,
                lastBackfillAt: last,
                powerSaving: true),
            last + BackfillPolicy.lowPowerPeriodicFloorSeconds)
        XCTAssertEqual(
            BackfillPolicy.periodicDelaySeconds(
                now: normalTimerFire,
                lastBackfillAt: last,
                powerSaving: true),
            1_800,
            "15 -> 45 minutes must wait the remaining 30 minutes, not a fresh 45")
    }

    func testLeavingPowerSavingShortensAnAlreadyArmedTimerImmediately() {
        let last = 10_000.0
        let now = last + 1_200

        XCTAssertEqual(
            BackfillPolicy.periodicDelaySeconds(
                now: now,
                lastBackfillAt: last,
                powerSaving: false),
            0,
            "45 -> 15 minutes must attempt now when the normal deadline already passed")
    }

    func testOverdueRejectedAttemptUsesBoundedRetryInsteadOfZeroDelayLoop() {
        let last = 10_000.0

        XCTAssertEqual(
            BackfillPolicy.periodicDelaySeconds(
                now: last + 1_200,
                lastBackfillAt: last,
                powerSaving: false,
                minimumDelaySeconds: BLEManager.backfillRetryDelaySeconds),
            30)
    }

    func testManualAndBoundedAutoContinueRemainImmediate() {
        let last = 10_000.0

        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .manual, now: last,
                                               lastBackfillAt: last, emptyStreak: 12,
                                               clockUntrusted: true))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .autoContinue, now: last,
                                               lastBackfillAt: last, emptyStreak: 12,
                                               clockUntrusted: true))
    }

    func testDeepDrainUsesSixProgressAndRadioBoundedContinuations() {
        XCTAssertEqual(BackfillContinuation.defaultMaxTotalPasses, 6)
        XCTAssertEqual(BackfillContinuation.defaultMaxContinuousRadioSeconds, 180)
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            wallNowUnix: 1_800_000_000,
            rowsPersistedThisSession: 1,
            lastTrimAdvanced: true,
            continuousRadioSeconds: 150,
            totalPasses: 5))
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            wallNowUnix: 1_800_000_000,
            rowsPersistedThisSession: 1,
            lastTrimAdvanced: true,
            continuousRadioSeconds: 150,
            totalPasses: 6))
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            wallNowUnix: 1_800_000_000,
            rowsPersistedThisSession: 1,
            lastTrimAdvanced: true,
            continuousRadioSeconds: 180,
            totalPasses: 1))
    }

    func testContinuationRequiresMinimumUsefulRemainingRadioBudgetAtBoundary() {
        XCTAssertEqual(BackfillContinuation.defaultMinimumUsefulRemainingRadioSeconds, 30)
        XCTAssertTrue(BackfillContinuation.hasMinimumUsefulRemainingRadioBudget(30))
        XCTAssertFalse(BackfillContinuation.hasMinimumUsefulRemainingRadioBudget(29.999))

        let commonNewest = 1_800_000_000
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: commonNewest,
            ourFrontierTs: commonNewest - 86_400,
            wallNowUnix: commonNewest,
            rowsPersistedThisSession: 1,
            lastTrimAdvanced: true,
            continuousRadioSeconds: 150,
            totalPasses: 1))
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: commonNewest,
            ourFrontierTs: commonNewest - 86_400,
            wallNowUnix: commonNewest,
            rowsPersistedThisSession: 1,
            lastTrimAdvanced: true,
            continuousRadioSeconds: 150.001,
            totalPasses: 1))
    }

    func testReplayAndRepeatedDurableSignatureCannotAutoContinue() {
        let base = (
            newest: 1_800_000_000,
            frontier: 1_800_000_000 - 86_400
        )
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: base.newest,
            ourFrontierTs: base.frontier,
            wallNowUnix: base.newest,
            rowsPersistedThisSession: 0,
            lastTrimAdvanced: true,
            totalPasses: 1),
            "a replayed receipt is ACK-safe but is not fresh radio progress")
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: base.newest,
            ourFrontierTs: base.frontier,
            wallNowUnix: base.newest,
            rowsPersistedThisSession: 1,
            lastTrimAdvanced: true,
            passSignatureRepeated: true,
            totalPasses: 1))
    }

    func testRadioDeadlineUsesRemainingTimeAcrossSessions() {
        let deadline = HistoricalRadioDeadline(startedAt: 100, budgetSeconds: 180)

        XCTAssertEqual(deadline.sessionTimeout(at: 100, idleTimeout: 60), 60)
        XCTAssertEqual(deadline.sessionTimeout(at: 250, idleTimeout: 60), 30)
        XCTAssertEqual(deadline.sessionTimeout(at: 280, idleTimeout: 60), 0)
        XCTAssertEqual(deadline.uptimeDeadline, 280)
    }

    func testTotalPassesAndProductivePassesRemainSeparate() {
        var passes = HistoricalBurstPassTracker()
        passes.startPass()
        passes.finishPass(freshSourceProgress: false)
        passes.startPass()
        passes.finishPass(freshSourceProgress: true)

        XCTAssertEqual(passes.totalPasses, 2)
        XCTAssertEqual(passes.productivePasses, 1)
    }

    func testDisconnectContributesToAdaptiveBackoff() {
        var tracker = HistoricalEmptyBackoffTracker()
        tracker.recordDisconnect(inFlight: true, freshProgress: false)
        XCTAssertEqual(tracker.consecutiveEmpty, 1)
        tracker.recordDisconnect(inFlight: true, freshProgress: true)
        XCTAssertEqual(tracker.consecutiveEmpty, 0)
        tracker.recordDisconnect(inFlight: false, freshProgress: false)
        XCTAssertEqual(tracker.consecutiveEmpty, 0)
    }

    func testSourceFrontierExcludesOtherDatabaseLineageEpochAndTrimScope() {
        func receipt(
            generation: Int64,
            database: String = "database-a",
            lineage: String = "lineage-a",
            epoch: Int = 3,
            trimScope: String = "historical",
            maxTs: Int
        ) -> HistoricalDataCommitReceipt {
            HistoricalDataCommitReceipt(
                receiptId: "r-\(generation)", generation: generation,
                databaseInstanceId: database, deviceId: "strap-a", trim: Int(generation),
                chunkEndUnix: maxTs, committedAt: maxTs + 1, rawBatchId: nil,
                insertedRows: HistoricalStreamInsertCounts(hr: 1),
                fingerprint: String(repeating: "0", count: 64),
                lineage: lineage, cursorEpoch: epoch, trimScope: trimScope,
                maxDecodedTs: maxTs
            )
        }
        let scope = HistoricalCursorScope(
            deviceId: "strap-a", lineage: "lineage-a", cursorEpoch: 3,
            trimScope: "historical"
        )
        let frontier = HistoricalSourceFrontier.aggregate(
            receipts: [
                receipt(generation: 1, maxTs: 100),
                receipt(generation: 2, database: "database-b", maxTs: 900),
                receipt(generation: 3, lineage: "lineage-b", maxTs: 800),
                receipt(generation: 4, epoch: 4, maxTs: 700),
                receipt(generation: 5, trimScope: "replay", maxTs: 600),
            ],
            databaseInstanceId: "database-a",
            cursorScope: scope
        )

        XCTAssertEqual(frontier.maxTs, 100)
        XCTAssertEqual(frontier.scope.databaseInstanceId, "database-a")
        XCTAssertEqual(frontier.scope.sourceIdentity.deviceId, "strap-a")
        XCTAssertEqual(frontier.scope.sourceIdentity.lineage, "lineage-a")
        XCTAssertEqual(frontier.scope.sourceIdentity.epoch, 3)
        XCTAssertEqual(frontier.scope.sourceIdentity.trimScope, "historical")
    }

    func testMaterializationReplayStillWakesDueWork() {
        let receipt = HistoricalDataCommitReceipt(
            receiptId: "mapped", generation: 1, databaseInstanceId: "database-a",
            deviceId: "strap-a", trim: 1, chunkEndUnix: 100, committedAt: 101,
            rawBatchId: "batch-a", insertedRows: HistoricalStreamInsertCounts(),
            fingerprint: String(repeating: "0", count: 64),
            rawStatus: .materializationRequired(batchId: "batch-a")
        )

        XCTAssertTrue(HistoricalMaterializationWakeState.shouldWakeAfterAcknowledgment(
            receipt: receipt, outcome: .replayed, due: true
        ))
        XCTAssertFalse(HistoricalMaterializationWakeState.shouldWakeAfterAcknowledgment(
            receipt: receipt, outcome: .replayed, due: false
        ))
    }

    func testPausedAcknowledgmentCannotStartOldStoreWorkerAcrossRestore() async throws {
        let oldStore = try await WhoopStore.inMemory()
        let reopenedStore = try await WhoopStore.inMemory()
        let gate = MaterializationDueGate()
        let recorder = MaterializationWorkerRecorder()
        let manager = BLEManager(state: LiveState(), collector: nil)
        manager.setHistoricalMaterializationStoreForTesting(oldStore)
        manager.setHistoricalMaterializationSeamsForTesting(
            dueCheck: { _, _ in
                await gate.pause()
                return true
            },
            run: { store in
                await recorder.record(
                    store: store,
                    oldStore: oldStore,
                    reopenedStore: reopenedStore
                )
                return HistoricalMaterializationRunSummary()
            }
        )
        let receipt = HistoricalDataCommitReceipt(
            receiptId: "paused-ack", generation: 1, databaseInstanceId: "database-a",
            deviceId: "strap-a", trim: 1, chunkEndUnix: 100, committedAt: 101,
            rawBatchId: "batch-a", insertedRows: HistoricalStreamInsertCounts(),
            fingerprint: String(repeating: "0", count: 64),
            rawStatus: .materializationRequired(batchId: "batch-a")
        )

        let acknowledgment = Task { @MainActor in
            await manager.wakeHistoricalMaterializationAfterAcknowledgmentForTesting(
                receipt: receipt,
                outcome: .inserted,
                store: oldStore
            )
        }
        await gate.waitUntilEntered()

        try await manager.quiesceStoreForRestore()
        manager.setHistoricalMaterializationStoreForTesting(reopenedStore)
        manager.wakeHistoricalMaterializationForRecovery()
        await gate.release()
        await acknowledgment.value

        for _ in 0..<200 {
            let counts = await recorder.counts()
            if counts.reopenedStore == 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let counts = await recorder.counts()
        XCTAssertEqual(counts.oldStore, 0, "the resumed old ACK must not start a closed-store worker")
        XCTAssertEqual(counts.reopenedStore, 1, "the reopened store must own exactly one worker")
    }

    func testReceiptOnlyFrontierNeverPublishesUntrustedMappedRawRange() {
        let scope = HistoricalCursorScope(
            deviceId: "strap-a", lineage: "lineage-a", cursorEpoch: 3,
            trimScope: "historical"
        )
        let receipt = HistoricalDataCommitReceipt(
            receiptId: "mapped-future", generation: 1,
            databaseInstanceId: "database-a", deviceId: "strap-a", trim: 1,
            chunkEndUnix: 9_999, committedAt: 100, rawBatchId: "batch-a",
            insertedRows: HistoricalStreamInsertCounts(),
            fingerprint: String(repeating: "0", count: 64),
            lineage: "lineage-a", cursorEpoch: 3, trimScope: "historical",
            rawStatus: .materializationRequired(batchId: "batch-a"),
            rawRange: HistoricalRawRangeEvidence(
                source: .retainedRawBatch,
                minReceivedTs: 9_999,
                maxReceivedTs: 9_999,
                frameCount: 1,
                byteCount: 1_244,
                hasHistoryEnd: true
            )
        )

        let frontier = HistoricalSourceFrontier.aggregate(
            receipts: [receipt],
            databaseInstanceId: "database-a",
            cursorScope: scope
        )

        XCTAssertNil(frontier.mappedRawMaxTs)
        XCTAssertNil(frontier.maxTs)
    }

    func testEmptyBackoffTrackerSaturatesAndFreshReceiptClearsIt() {
        var tracker = HistoricalEmptyBackoffTracker()
        tracker.record(freshProgress: false)
        XCTAssertEqual(tracker.consecutiveEmpty, 1)
        tracker.record(freshProgress: false)
        tracker.record(freshProgress: false)
        XCTAssertEqual(tracker.consecutiveEmpty, 2)
        tracker.record(freshProgress: true)
        XCTAssertEqual(tracker.consecutiveEmpty, 0)
    }

    func testMaterializationWakeDuringActivePassSchedulesOneFollowUp() {
        var wake = HistoricalMaterializationWakeState()

        XCTAssertTrue(wake.request())
        XCTAssertTrue(wake.isRunning)
        XCTAssertFalse(wake.wakePending)

        XCTAssertFalse(wake.request())
        XCTAssertFalse(wake.request(), "multiple ACKs should coalesce while the bounded pass runs")
        XCTAssertTrue(wake.wakePending)

        XCTAssertTrue(wake.finish(), "the coalesced ACK wake must own one follow-up pass")
        XCTAssertTrue(wake.isRunning)
        XCTAssertFalse(wake.wakePending)
        XCTAssertFalse(wake.finish(), "the follow-up pass quiesces when no later ACK arrived")
        XCTAssertFalse(wake.isRunning)
    }

    func testMaterializationWakeCancelClearsRestoreState() {
        var wake = HistoricalMaterializationWakeState()
        XCTAssertTrue(wake.request())
        XCTAssertFalse(wake.request())

        wake.cancel()

        XCTAssertFalse(wake.isRunning)
        XCTAssertFalse(wake.wakePending)
        XCTAssertTrue(wake.request(), "a reopened store should get a fresh bounded worker pass")
    }

    func testMaterializationDrainUsesAuthoritativeDueWorkAndQueueProgress() {
        XCTAssertTrue(HistoricalMaterializationWakeState.shouldRequestDrainFollowUp(
            hasMoreDueWork: true, completed: 1, quarantined: 0),
            "the store's authoritative due-work result must continue even after a partial claim")
        XCTAssertTrue(HistoricalMaterializationWakeState.shouldRequestDrainFollowUp(
            hasMoreDueWork: true, completed: 0, quarantined: 1))
        XCTAssertFalse(HistoricalMaterializationWakeState.shouldRequestDrainFollowUp(
            hasMoreDueWork: false, completed: 4, quarantined: 0),
            "queue progress does not invent due work after the store reports exhaustion")
        XCTAssertFalse(HistoricalMaterializationWakeState.shouldRequestDrainFollowUp(
            hasMoreDueWork: true, completed: 0, quarantined: 0),
            "an all-retryable batch must not spin immediately")
    }

    func testMaterializationRetryTimingPrefersRunSummaryAndFallsBackToStore() {
        XCTAssertEqual(HistoricalMaterializationWakeState.nextRetryAttempt(
            resultAttemptAt: 200,
            storeAttemptAt: 300
        ), 200)
        XCTAssertEqual(HistoricalMaterializationWakeState.nextRetryAttempt(
            resultAttemptAt: nil,
            storeAttemptAt: 300
        ), 300)
        XCTAssertNil(HistoricalMaterializationWakeState.nextRetryAttempt(
            resultAttemptAt: nil,
            storeAttemptAt: nil
        ))
    }
}
