import Combine
import XCTest
@testable import NOOP

@MainActor
final class LiveHeartRateReceiptTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_600_000)
    private let source = LiveHeartRateSource(deviceId: "whoop-a", peripheralID: UUID(), connectionGeneration: 4)

    private func receive(_ live: LiveState, bpm: Int = 100, second: Double,
                         transport: LiveHeartRateReceipt.Transport = .standard) {
        let observed = start.addingTimeInterval(second)
        live.receiveHeartRate(bpm: bpm, observedAt: observed, source: source, transport: transport, now: observed)
    }

    func testEqualBPMReceiptsKeepEveryObservedSecondWithoutRepublishingTheDisplay() {
        let live = LiveState()
        live.activateHeartRateSource(source)
        var receipts: [LiveHeartRateReceipt] = []
        var values: [Int?] = []
        let receiptSink = live.heartRateReceipts.sink { receipts.append($0) }
        let displaySink = live.$heartRate.dropFirst().sink { values.append($0) }

        for second in 0..<60 { receive(live, second: Double(second)) }

        XCTAssertEqual(receipts.count, 60)
        XCTAssertEqual(receipts.last?.observedAt, start.addingTimeInterval(59))
        XCTAssertEqual(values, [100])
        withExtendedLifetime((receiptSink, displaySink)) {}
    }

    func testRawAndStandardTransportDeliverOnlyOneSampleInTheSameSecond() {
        let live = LiveState()
        live.activateHeartRateSource(source)
        var receipts: [LiveHeartRateReceipt] = []
        let sink = live.heartRateReceipts.sink { receipts.append($0) }

        receive(live, second: 1.1, transport: .raw)
        receive(live, bpm: 101, second: 1.2, transport: .standard)
        receive(live, second: 2.1, transport: .standard)

        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts.map(\.transport), [.raw, .standard])
        withExtendedLifetime(sink) {}
    }

    func testStaleBackwardAndOtherSessionReceiptsCannotChangeFreshnessOrDisplay() {
        let live = LiveState()
        live.activateHeartRateSource(source)
        receive(live, second: 10)
        let last = live.latestHeartRateReceipt

        receive(live, bpm: 80, second: 9)
        live.receiveHeartRate(bpm: 80, observedAt: start.addingTimeInterval(11), source: source,
                             transport: .standard, now: start.addingTimeInterval(30))
        let other = LiveHeartRateSource(deviceId: source.deviceId, peripheralID: source.peripheralID,
                                        connectionGeneration: 3)
        live.receiveHeartRate(bpm: 80, observedAt: start.addingTimeInterval(12), source: other,
                             transport: .standard, now: start.addingTimeInterval(12))

        XCTAssertEqual(live.heartRate, 100)
        XCTAssertEqual(live.latestHeartRateReceipt, last)
    }

    func testSourceSwitchInvalidatesOldReceiptsIncludingQueuedSameDeviceSession() {
        let live = LiveState()
        live.activateHeartRateSource(source)
        receive(live, second: 10)
        let receipt = live.latestHeartRateReceipt!
        let next = LiveHeartRateSource(deviceId: "whoop-b", peripheralID: UUID(), connectionGeneration: 5)
        live.activateHeartRateSource(next)

        receive(live, second: 11)

        XCTAssertNil(live.latestHeartRateReceipt)
        XCTAssertFalse(live.isCurrentHeartRateReceipt(receipt))
        XCTAssertNil(live.heartRate)
    }

    func testRRCanResumeFreshHRWhenTheDirectStreamHasGoneSilent() {
        let live = LiveState()
        live.activateHeartRateSource(source)
        receive(live, second: 10)
        live.setRRIntervals([750], observedAt: start.addingTimeInterval(11), source: source)
        XCTAssertEqual(live.latestHeartRateReceipt?.bpm, 100, "fresh direct HR wins over the same packet's RR")

        live.setRRIntervals([750], observedAt: start.addingTimeInterval(16), source: source)

        XCTAssertEqual(live.latestHeartRateReceipt?.bpm, 80)
        XCTAssertEqual(live.latestHeartRateReceipt?.transport, .rrFallback)
        XCTAssertEqual(live.latestHeartRateReceipt?.observedAt, start.addingTimeInterval(16))
    }

    func testDisconnectClearsTheReceiptAndRejectsAQueuedOldSource() {
        let live = LiveState()
        live.activateHeartRateSource(source)
        receive(live, second: 10)

        live.clearBiometrics()
        receive(live, second: 11)

        XCTAssertNil(live.heartRate)
        XCTAssertNil(live.latestHeartRateReceipt)
    }
}

final class RealtimeHRLeaseOwnershipTests: XCTestCase {
    func testAConsumerCanReleaseOnlyItsOwnToken() {
        var leases = RealtimeHRLeaseSet()
        let live = leases.acquire(.visible)
        let workout = leases.acquire(.workout)
        let session = leases.acquire(.liveSession)

        XCTAssertTrue(leases.release(live))
        XCTAssertFalse(leases.release(live), "a repeated Live disappearance cannot release a recording")
        XCTAssertFalse(leases.release(RealtimeHRLeaseToken()))
        XCTAssertEqual(leases.demand(applicationIsActive: true), .init(visible: false, recording: true))
        XCTAssertTrue(leases.release(workout))
        XCTAssertTrue(leases.release(session))
        XCTAssertTrue(leases.isEmpty)
    }

    func testBackgroundReleasesVisibleDemandAndKeepsTheIndependentRecording() {
        var leases = RealtimeHRLeaseSet()
        _ = leases.acquire(.visible)
        let workout = leases.acquire(.workout)
        XCTAssertEqual(leases.demand(applicationIsActive: true), .init(visible: true, recording: true))
        XCTAssertEqual(leases.demand(applicationIsActive: false), .init(visible: false, recording: true))

        XCTAssertTrue(leases.release(workout))

        XCTAssertEqual(leases.demand(applicationIsActive: false), .init(visible: false, recording: false))
        XCTAssertEqual(leases.demand(applicationIsActive: true), .init(visible: true, recording: false))
    }
}
