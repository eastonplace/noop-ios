import XCTest
@testable import Strand

final class DeviceCommandCenterStatusTests: XCTestCase {
    private func input() -> DeviceCommandCenterInput {
        .init(isWhoop: true, supportsR22: true, connected: true, encryptedBond: true,
              bluetoothUnavailableMessage: nil, reconnectGuide: nil, pairingHint: nil,
              rtcWarning: nil, lastSyncError: nil, strapNeedsReboot: false, batteryPct: 60,
              historySyncExperimental: false, standardHRMode: nil, backfilling: false,
              syncChunksThisSession: 0, lastSyncedAt: 900, deepDataEnabled: false,
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
        var value = input(); value.backfilling = true; value.syncChunksThisSession = 12
        let label = DeviceCommandCenterStatusResolver.syncLabel(value)
        XCTAssertEqual(label, "Syncing · 12 chunks received")
        XCTAssertFalse(label.contains("%"))
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
