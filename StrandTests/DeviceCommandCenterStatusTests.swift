import XCTest
@testable import Strand

final class DeviceCommandCenterStatusTests: XCTestCase {
    private func input() -> DeviceCommandCenterInput {
        .init(isWhoop: true, supportsR22: true, connected: true, encryptedBond: true,
              bluetoothUnavailableMessage: nil, reconnectGuide: nil, pairingHint: nil,
              rtcWarning: nil, lastSyncError: nil, strapNeedsReboot: false, batteryPct: 60,
              historySyncExperimental: false, standardHRMode: nil, backfilling: false,
              syncChunksThisSession: 0, lastSyncedAt: 900, historicalDataFrontierAt: 880,
              historicalSyncSessionState: .completed, liveHeartRateAvailable: true,
              deepDataEnabled: false,
              r22FlagsAccepted: 0, r22FlagCount: 15, now: 1_000)
    }

    func testHealthyFullBond() {
        let snapshot = DeviceCommandCenterStatusResolver.resolve(input())
        XCTAssertEqual(snapshot.health.level, .healthy)
        XCTAssertEqual(snapshot.bondLabel, "Full bond")
        XCTAssertTrue(snapshot.commands.syncEnabled)
    }

    func testLiveHROnlyIsWarningAndBlocksEncryptedCommands() {
        var value = input(); value.encryptedBond = false
        let snapshot = DeviceCommandCenterStatusResolver.resolve(value)
        XCTAssertEqual(snapshot.health.level, .warning)
        XCTAssertEqual(snapshot.bondLabel, "Live HR only")
        XCTAssertFalse(snapshot.commands.syncEnabled)
        XCTAssertFalse(snapshot.commands.vibrationEnabled)
    }

    func testHealthPriorityUsesReconnectBeforeClockAndSync() {
        var value = input()
        value.reconnectGuide = "Reconnect the strap."
        value.rtcWarning = "Clock failed."
        value.lastSyncError = "Sync failed."
        let health = DeviceCommandCenterStatusResolver.health(value)
        XCTAssertEqual(health.level, .critical)
        XCTAssertEqual(health.issueCount, 3)
        XCTAssertEqual(health.primaryIssue, "Reconnect the strap.")
    }

    func testExperimentalHistoryIsInformational() {
        var value = input(); value.historySyncExperimental = true
        XCTAssertEqual(DeviceCommandCenterStatusResolver.health(value).level, .informational)
        XCTAssertEqual(DeviceCommandCenterStatusResolver.syncLabel(value), "History sync experimental")
    }

    func testSyncUsesChunkCountNotPercentage() {
        var value = input(); value.backfilling = true; value.historicalSyncSessionState = .syncing
        value.syncChunksThisSession = 12
        let label = DeviceCommandCenterStatusResolver.syncLabel(value)
        XCTAssertEqual(label, "Syncing history · 12 chunks received")
        XCTAssertFalse(label.contains("%"))
    }

    func testHandshakeIncompleteWithOldSyncNeverClaimsCaughtUp() {
        var value = input()
        value.historicalSyncSessionState = .waitingForSecureHandshake
        value.lastSyncedAt = 900
        value.historicalDataFrontierAt = 880
        let label = DeviceCommandCenterStatusResolver.syncLabel(value)
        XCTAssertEqual(label, "Live HR only · History sync waiting for secure link")
        XCTAssertFalse(label.localizedCaseInsensitiveContains("caught up"))
        XCTAssertFalse(label.localizedCaseInsensitiveContains("history synced"))
    }

    func testHandshakeIncompleteKeepsSavedHistorySeparate() {
        let status = HistoricalSyncStatusResolver.resolve(
            connected: true,
            liveHeartRateAvailable: true,
            sessionState: .waitingForSecureHandshake,
            lastSuccessfulBackfillAt: 900,
            historicalDataFrontierAt: 880,
            lastSyncError: nil,
            historySyncExperimental: false,
            chunks: 0,
            now: 1_000)
        XCTAssertEqual(status.primary, "Live HR only · History sync waiting for secure link")
        XCTAssertTrue(status.savedHistory?.hasPrefix("Showing saved history through ") == true)
        XCTAssertFalse(status.isCurrentSuccess)
    }

    func testHistoryCompleteAllowsCurrentHistorySynced() {
        var value = input()
        value.historicalSyncSessionState = .completed
        XCTAssertEqual(DeviceCommandCenterStatusResolver.syncLabel(value), "History synced · 1 min ago")
    }

    func testFailedHandshakeProducesVisibleNonSuccessState() {
        var value = input()
        value.historicalSyncSessionState = .failed
        value.lastSyncError = "Secure handshake failed."
        let status = DeviceCommandCenterStatusResolver.syncLabel(value)
        XCTAssertEqual(status, "Secure handshake failed.")
        XCTAssertFalse(status.localizedCaseInsensitiveContains("synced"))
    }

    func testNonWhoopOmitsBondAndR22() {
        var value = input(); value.isWhoop = false; value.encryptedBond = false
        let snapshot = DeviceCommandCenterStatusResolver.resolve(value)
        XCTAssertNil(snapshot.bondLabel)
        XCTAssertNil(snapshot.r22Label)
        XCTAssertFalse(snapshot.commands.vibrationEnabled)
    }

    func testWhoopFourOmitsUnsupportedR22() {
        var value = input(); value.supportsR22 = false; value.deepDataEnabled = true
        let snapshot = DeviceCommandCenterStatusResolver.resolve(value)
        XCTAssertNil(snapshot.r22Label)
        XCTAssertEqual(snapshot.bondLabel, "Full bond", "Full bond is a WHOOP link state, not an R22 capability")
    }

    func testR22States() {
        var value = input(); value.deepDataEnabled = true; value.r22FlagsAccepted = 6
        XCTAssertEqual(DeviceCommandCenterStatusResolver.r22Label(value), "Applying 6/15")
        value.r22FlagsAccepted = 15
        XCTAssertEqual(DeviceCommandCenterStatusResolver.r22Label(value), "Accepted 15/15")
    }
}

@MainActor
final class DeviceConnectionUptimeTests: XCTestCase {
    func testConnectReconnectDisconnectTransitions() {
        let state = LiveState()
        state.markConnected(at: 100)
        XCTAssertEqual(state.connectedAt, 100)
        state.markConnected(at: 200)
        XCTAssertEqual(state.connectedAt, 100, "duplicate callbacks must not reset uptime")
        state.markDisconnected()
        XCTAssertNil(state.connectedAt)
        state.markConnected(at: 300)
        XCTAssertEqual(state.connectedAt, 300)
    }
}
