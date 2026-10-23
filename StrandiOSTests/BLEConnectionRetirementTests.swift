import CoreBluetooth
import NoopPhase34Core
import WhoopProtocol
import WhoopStore
import XCTest
@testable import NOOP

@MainActor
final class BLEConnectionRetirementTests: XCTestCase {
    @MainActor
    private final class StoreProbe: StoreWriting {
        struct Write {
            let deviceId: String
            let hr: [HRSample]
            let rr: [RRInterval]
        }

        var writes: [Write] = []
        var didWrite: (() -> Void)?

        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            writes.append(Write(deviceId: deviceId, hr: streams.hr, rr: streams.rr))
            didWrite?()
            return (streams.hr.count, streams.rr.count, streams.events.count,
                    streams.battery.count, streams.spo2.count, streams.skinTemp.count,
                    streams.resp.count, streams.gravity.count)
        }

        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
    }

    func testRadioLossRetiresThePublishedConnectionWithoutADisconnectCallback() {
        for radioState in [CBManagerState.poweredOff, .resetting, .unauthorized, .unsupported] {
            let state = LiveState()
            let manager = BLEManager(state: state, collector: nil)
            state.markConnected()
            state.bonded = true
            state.encryptedBond = true
            state.streamingLiveHR = true
            state.heartRate = 91
            state.backfilling = true

            manager.handleBluetoothUnavailable(radioState)

            XCTAssertFalse(state.connected, "radio state \(radioState) ends the old connection")
            XCTAssertFalse(state.encryptedBond)
            XCTAssertFalse(state.streamingLiveHR)
            XCTAssertNil(state.heartRate)
            XCTAssertFalse(state.backfilling)
            XCTAssertFalse(manager.historicalSyncBackgroundSnapshot().syncActive)
            XCTAssertFalse(manager.requestSync(.manual), "no history command may use the retired link")
            manager.disconnect()
        }
    }

    func testRadioLossCancelsReconnectAndHeldHelloWithoutResettingRetryIntent() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        manager.connect(model: .whoop5mg)
        let session = Whoop5SecureSessionID(peripheralID: UUID(), connectGeneration: 1, attemptEpoch: 1)
        let deadline = Date().addingTimeInterval(30)
        manager.armReconnectForTesting(after: 20, secureRecovery: true)
        manager.holdWhoop5ClientHelloForTesting(session, until: deadline)
        manager.pauseAutoReconnectForBackgroundCapForTesting()

        manager.handleBluetoothUnavailable(.poweredOff)

        XCTAssertFalse(manager.reconnectArmedForTesting)
        XCTAssertNil(manager.whoop5HeldClientHelloForTesting)
        XCTAssertFalse(manager.whoop5HoldTimerArmedForTesting)
        XCTAssertFalse(manager.whoop5HoldBackgroundTaskActiveForTesting)
        XCTAssertEqual(manager.whoop5HandshakeHoldForTesting, deadline,
                       "a radio interruption must not shorten the secure retry delay")
        XCTAssertTrue(manager.autoReconnectPausedForBackgroundCapForTesting)
        manager.connectFromSystem(model: .whoop4)
        XCTAssertTrue(manager.isWhoop5, "radio power-on must still respect the retry cap")
        manager.disconnect()
    }

    func testRadioLossDoesNotUndoExplicitDisconnectOrSecurePause() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        manager.connect(model: .whoop5mg)
        manager.disconnect()
        manager.handleBluetoothUnavailable(.resetting)
        manager.connectFromSystem(model: .whoop4)
        XCTAssertTrue(manager.isWhoop5)

        manager.connect(model: .whoop5mg)
        manager.pauseAutoReconnectForWhoop5SecureFailureForTesting()
        manager.handleBluetoothUnavailable(.poweredOff)
        manager.connectFromSystem(model: .whoop4)
        XCTAssertTrue(manager.isWhoop5, "the secure failure pause belongs to the retry series")
        manager.disconnect()
    }

    func testRadioLossPreservesAReplacementProviderAndItsFreshReceipt() {
        let state = LiveState()
        let manager = BLEManager(state: state, collector: nil)
        state.markConnected()
        manager.handleBluetoothUnavailable(.poweredOff)
        XCTAssertFalse(state.connected)

        let source = LiveHeartRateSource(
            deviceId: "replacement", peripheralID: UUID(), connectionGeneration: 1,
            providerSessionID: UUID())
        let now = Date()
        state.activateHeartRateProviderSource(source, at: now.timeIntervalSince1970)
        state.receiveHeartRate(bpm: 120, observedAt: now, source: source, transport: .standard, now: now)

        // A second callback from the retired WHOOP central must not clear the new provider.
        manager.handleBluetoothUnavailable(.resetting)

        XCTAssertTrue(state.connected)
        XCTAssertEqual(state.currentHeartRateSource, source)
        XCTAssertEqual(state.latestHeartRateReceipt?.bpm, 120)
        XCTAssertEqual(state.heartRate, 120)
        manager.disconnect()
    }

    func testRadioLossFlushesAlreadyReceivedSamplesUnderTheirOriginalOwner() async {
        await assertBufferedSamplesArePreserved { $0.handleBluetoothUnavailable(.poweredOff) }
    }

    func testForgetFlushesAlreadyReceivedSamplesWithoutWaitingForADisconnectCallback() async {
        await assertBufferedSamplesArePreserved { $0.forgetDevice(nil, isActiveDevice: true) }
    }

    private func assertBufferedSamplesArePreserved(_ retire: (BLEManager) -> Void) async {
        let store = StoreProbe()
        let collector = Collector(store: store, deviceId: "strap-a")
        collector.ingestStandardHR(hr: 80, rr: [750], at: 1_792_600_001)
        let state = LiveState()
        let manager = BLEManager(state: state, deviceId: "strap-a", collector: collector)
        state.markConnected()
        let persisted = expectation(description: "received samples survive link retirement")
        store.didWrite = { persisted.fulfill() }

        retire(manager)
        manager.setActiveDeviceId("strap-b")
        await fulfillment(of: [persisted], timeout: 2)

        XCTAssertEqual(store.writes.map(\.deviceId), ["strap-a"])
        XCTAssertEqual(store.writes.flatMap { $0.hr.map(\.bpm) }, [80])
        XCTAssertEqual(store.writes.flatMap { $0.rr.map(\.rrMs) }, [750])
        XCTAssertFalse(state.connected)
        manager.disconnect()
    }
}
