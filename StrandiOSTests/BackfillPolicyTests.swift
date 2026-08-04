import XCTest
@testable import NOOP

@MainActor
final class BackfillPolicyTests: XCTestCase {
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

    func testDefaultPeriodicCadenceStaysAtFifteenMinutesAfterEmptyStreak() {
        let last = 10_000.0

        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: last + 899,
                                                lastBackfillAt: last, emptyStreak: 12))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: last + 900,
                                               lastBackfillAt: last, emptyStreak: 12))
    }

    func testDefaultStrapCadenceStaysAtNinetySecondsAfterEmptyStreak() {
        let last = 10_000.0

        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: last + 89,
                                                lastBackfillAt: last, emptyStreak: 12))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: last + 90,
                                               lastBackfillAt: last, emptyStreak: 12))
    }

    func testLowBatteryPeriodicFloorMatchesItsOneShotTimer() {
        let last = 10_000.0

        XCTAssertEqual(BackfillPolicy.periodicFloorSeconds(powerSaving: true),
                       TimeInterval(BLEManager.lowBatteryBackfillIntervalSeconds))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: last + 2_699,
                                                lastBackfillAt: last, emptyStreak: 12,
                                                powerSaving: true))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: last + 2_700,
                                               lastBackfillAt: last, emptyStreak: 12,
                                               powerSaving: true))
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
}
