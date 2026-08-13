import XCTest
@testable import NOOP

@MainActor
final class BackfillPolicyTests: XCTestCase {
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
        XCTAssertEqual(BackfillContinuation.defaultMaxAutoContinues, 6)
        XCTAssertEqual(BackfillContinuation.defaultMaxContinuousRadioSeconds, 180)
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            wallNowUnix: 1_800_000_000,
            rowsPersistedThisSession: 1,
            lastTrimAdvanced: true,
            continuousRadioSeconds: 179,
            consecutiveCount: 5))
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            wallNowUnix: 1_800_000_000,
            rowsPersistedThisSession: 1,
            lastTrimAdvanced: true,
            continuousRadioSeconds: 179,
            consecutiveCount: 6))
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            wallNowUnix: 1_800_000_000,
            rowsPersistedThisSession: 1,
            lastTrimAdvanced: true,
            continuousRadioSeconds: 180,
            consecutiveCount: 0))
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
            consecutiveCount: 0),
            "a replayed receipt is ACK-safe but is not fresh radio progress")
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: base.newest,
            ourFrontierTs: base.frontier,
            wallNowUnix: base.newest,
            rowsPersistedThisSession: 1,
            lastTrimAdvanced: true,
            passSignatureRepeated: true,
            consecutiveCount: 0))
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

    func testMaterializationDrainContinuesOnlyAfterFullProductiveBatch() {
        XCTAssertTrue(HistoricalMaterializationWakeState.shouldRequestDrainFollowUp(
            claimed: 4, completed: 4, quarantined: 0))
        XCTAssertTrue(HistoricalMaterializationWakeState.shouldRequestDrainFollowUp(
            claimed: 4, completed: 0, quarantined: 4))
        XCTAssertFalse(HistoricalMaterializationWakeState.shouldRequestDrainFollowUp(
            claimed: 3, completed: 3, quarantined: 0),
            "a partial claim proves the eligible queue was exhausted")
        XCTAssertFalse(HistoricalMaterializationWakeState.shouldRequestDrainFollowUp(
            claimed: 4, completed: 0, quarantined: 0),
            "an all-retryable batch must not spin immediately")
    }
}
