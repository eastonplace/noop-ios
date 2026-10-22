import Combine
import XCTest
@testable import NOOP

@MainActor
final class ProviderHeartRateReceiptTests: XCTestCase {
    func testAllRetainedProviderKindsDeliverEqualBPMWithObservedTimeWithoutDisplayChurn() {
        for deviceId in ["standard-strap", "oura-ring", "huami-band", "ftms-machine"] {
            let live = LiveState()
            let owner = LiveHeartRateProviderSession(live: live, deviceId: deviceId)
            let characteristic = NSObject()
            let source = owner.begin(peripheralID: UUID())
            owner.bind(characteristic)
            var receipts: [LiveHeartRateReceipt] = []
            var display: [Int?] = []
            let a = live.heartRateReceipts.sink { receipts.append($0) }
            let b = live.$heartRate.dropFirst().sink { display.append($0) }
            let start = Date(timeIntervalSince1970: 1_792_600_000)

            for second in 0..<60 {
                let observed = start.addingTimeInterval(Double(second))
                XCTAssertTrue(owner.receive(bpm: 100, observedAt: observed, source: source, now: observed))
            }

            XCTAssertEqual(receipts.count, 60, deviceId)
            XCTAssertEqual(receipts.last?.observedAt, start.addingTimeInterval(59))
            XCTAssertEqual(receipts.last?.source.deviceId, deviceId)
            XCTAssertEqual(display, [100])
            XCTAssertTrue(live.hasActiveHeartRateConnection)
            withExtendedLifetime((a, b)) {}
        }
    }

    func testColdGenericConnectionUsesOwnedSessionWithoutClaimingWhoopBond() {
        let live = LiveState()
        XCTAssertFalse(live.hasActiveHeartRateConnection)
        let owner = LiveHeartRateProviderSession(live: live, deviceId: "strap")
        let source = owner.begin(peripheralID: UUID())
        XCTAssertTrue(live.hasActiveHeartRateConnection)
        XCTAssertFalse(live.bonded)
        XCTAssertNil(live.latestHeartRateReceipt)

        let now = Date()
        XCTAssertTrue(owner.receive(bpm: 100, observedAt: now, source: source))
        XCTAssertTrue(live.hasActiveHeartRateConnection)
        XCTAssertFalse(live.bonded)

        XCTAssertTrue(owner.end())
        XCTAssertFalse(live.hasActiveHeartRateConnection)
        XCTAssertNil(live.heartRate)
    }

    func testWhoopConnectionStillRequiresBondProof() {
        let live = LiveState()
        live.activateHeartRateSource(.init(deviceId: "whoop", peripheralID: UUID(), connectionGeneration: 1))
        live.connected = true
        XCTAssertFalse(live.hasActiveHeartRateConnection)
        live.bonded = true
        XCTAssertTrue(live.hasActiveHeartRateConnection)
    }

    func testOldProviderStopCannotClearNewProviderOnTheSamePhysicalUUID() {
        let live = LiveState()
        let physical = UUID()
        let old = LiveHeartRateProviderSession(live: live, deviceId: "strap")
        let oldSource = old.begin(peripheralID: physical)
        let new = LiveHeartRateProviderSession(live: live, deviceId: "strap")
        let newSource = new.begin(peripheralID: physical)
        XCTAssertNotEqual(oldSource, newSource, "a recreated provider must have a distinct session")
        let now = Date()
        XCTAssertTrue(new.receive(bpm: 120, observedAt: now, source: newSource))

        XCTAssertFalse(old.end())

        XCTAssertEqual(live.currentHeartRateSource, newSource)
        XCTAssertEqual(live.heartRate, 120)
        XCTAssertTrue(live.hasActiveHeartRateConnection)
    }

    func testOldSessionCallbackAndCharacteristicCannotAcquireNewOwnership() {
        let live = LiveState()
        let owner = LiveHeartRateProviderSession(live: live, deviceId: "strap")
        let physical = UUID()
        let oldCharacteristic = NSObject()
        let old = owner.begin(peripheralID: physical)
        owner.bind(oldCharacteristic)
        XCTAssertEqual(owner.source(for: oldCharacteristic, peripheralID: physical), old)
        owner.end()
        let current = owner.begin(peripheralID: physical)
        let currentCharacteristic = NSObject()
        owner.bind(currentCharacteristic)
        let now = Date()

        XCTAssertNil(owner.source(for: oldCharacteristic, peripheralID: physical))
        XCTAssertNil(owner.source(for: currentCharacteristic, peripheralID: UUID()))
        XCTAssertFalse(owner.receive(bpm: 80, observedAt: now, source: old))
        XCTAssertTrue(owner.receive(bpm: 120, observedAt: now, source: current))
        XCTAssertEqual(live.heartRate, 120)
    }

    func testDiscoveryOnlyOrSecondaryProviderCannotStealPrimaryOwnership() {
        let live = LiveState()
        let primary = LiveHeartRateProviderSession(live: live, deviceId: "primary")
        let primarySource = primary.begin(peripheralID: UUID())
        let secondary = LiveHeartRateProviderSession(live: live, deviceId: "secondary-ftms")
        let now = Date()
        XCTAssertTrue(primary.receive(bpm: 120, observedAt: now, source: primarySource))

        secondary.bind(NSObject())
        XCTAssertNil(secondary.source)
        XCTAssertFalse(secondary.end())

        XCTAssertEqual(live.currentHeartRateSource, primarySource)
        XCTAssertEqual(live.heartRate, 120)
    }

    func testProviderCallbacksRejectBackwardAndStaleObservations() {
        let live = LiveState()
        let owner = LiveHeartRateProviderSession(live: live, deviceId: "strap")
        let source = owner.begin(peripheralID: UUID())
        let now = Date()
        XCTAssertTrue(owner.receive(bpm: 120, observedAt: now, source: source))

        XCTAssertFalse(owner.receive(bpm: 80, observedAt: now.addingTimeInterval(-1), source: source))
        XCTAssertFalse(owner.receive(bpm: 80, observedAt: now.addingTimeInterval(1), source: source,
                                     now: now.addingTimeInterval(20)))

        XCTAssertEqual(live.latestHeartRateReceipt?.observedAt, now)
        XCTAssertEqual(live.heartRate, 120)
    }

    func testLateWhoopDisconnectCannotClearGenericSessionOnTheSamePhysicalUUID() {
        let live = LiveState()
        let physical = UUID()
        let whoop = LiveHeartRateSource(deviceId: "same-logical-row", peripheralID: physical, connectionGeneration: 1)
        live.activateHeartRateSource(whoop)
        let generic = LiveHeartRateProviderSession(live: live, deviceId: whoop.deviceId)
        let current = generic.begin(peripheralID: physical)
        let now = Date()
        XCTAssertTrue(generic.receive(bpm: 120, observedAt: now, source: current))

        XCTAssertFalse(live.disconnectHeartRateSource(ifOwnedBy: whoop))

        XCTAssertEqual(live.currentHeartRateSource, current)
        XCTAssertEqual(live.latestHeartRateReceipt?.source, current)
        XCTAssertEqual(live.heartRate, 120)
        XCTAssertTrue(live.hasActiveHeartRateConnection)
        XCTAssertTrue(live.streamingLiveHR)
    }

    func testMatchingWhoopDisconnectStillClearsItsOwnBiometricsAndConnection() {
        let live = LiveState()
        let source = LiveHeartRateSource(deviceId: "whoop", peripheralID: UUID(), connectionGeneration: 1)
        live.activateHeartRateSource(source)
        live.connected = true
        live.bonded = true
        live.streamingLiveHR = true
        let now = Date()
        live.receiveHeartRate(bpm: 100, observedAt: now, source: source, transport: .standard)

        XCTAssertTrue(live.disconnectHeartRateSource(ifOwnedBy: source))

        XCTAssertNil(live.heartRate)
        XCTAssertNil(live.latestHeartRateReceipt)
        XCTAssertFalse(live.connected)
        XCTAssertFalse(live.streamingLiveHR)
    }

    #if targetEnvironment(simulator)
    func testAdoptingGenericSessionReleasesWhoopDemandWithoutLosingTheViewsLease() {
        let model = AppModel(startRuntimeTasks: false)
        let lease = model.acquireRealtimeHR(for: .visible)
        XCTAssertTrue(model.live.liveFeedActive)
        let owner = LiveHeartRateProviderSession(live: model.live, deviceId: "existing-generic")

        owner.begin(peripheralID: UUID())

        XCTAssertFalse(model.live.liveFeedActive, "generic visibility must not arm the unrelated WHOOP")
        model.releaseRealtimeHR(lease)
        XCTAssertTrue(model.live.hasActiveHeartRateConnection)
        owner.end()
    }

    func testNewVisibleAndRecordingLeasesForGenericSourceDoNotArmWhoop() {
        let model = AppModel(startRuntimeTasks: false)
        let owner = LiveHeartRateProviderSession(live: model.live, deviceId: "existing-generic")
        owner.begin(peripheralID: UUID())

        let view = model.acquireRealtimeHR(for: .visible)
        let recording = model.acquireRealtimeHR(for: .workout)
        model.rearmRealtimeIfWanted()

        XCTAssertFalse(model.live.liveFeedActive)
        model.releaseRealtimeHR(view)
        model.releaseRealtimeHR(recording)
        owner.end()
    }
    #endif
}
