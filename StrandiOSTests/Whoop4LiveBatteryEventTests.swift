import XCTest
import WhoopProtocol
@testable import NOOP

/// Synthetic protocol-valid events exercise live admission, not hardware battery accuracy.
@MainActor
final class Whoop4LiveBatteryEventTests: XCTestCase {
    private let observed = Date(timeIntervalSince1970: 1_792_600_000)
    private let source = LiveHeartRateSource(
        deviceId: "battery-strap", peripheralID: UUID(), connectionGeneration: 7)

    private func connectedState() -> LiveState {
        let live = LiveState()
        live.activateHeartRateSource(source)
        live.connected = true
        live.bonded = true
        live.setBattery(80)
        return live
    }

    private func batteryEvent(rawSoc: UInt16 = 505, timestamp: UInt32? = nil,
                              payloadCount: Int = 27) -> [UInt8] {
        // WHOOP4 EVENT: event@6, timestamp@8, SoC@17, mV@21, charging@26.
        // frameFromPayload places this body at byte7. Keep the length configurable so a
        // valid CRC cannot disguise a truncated protected payload as a complete battery event.
        var payload = [UInt8](repeating: 0, count: payloadCount)
        let stamp = timestamp ?? UInt32(observed.timeIntervalSince1970)
        for index in 0..<4 where index + 1 < payload.count {
            payload[index + 1] = UInt8(truncatingIfNeeded: stamp >> (8 * index))
        }
        if payload.count > 11 {
            payload[10] = UInt8(truncatingIfNeeded: rawSoc)
            payload[11] = UInt8(truncatingIfNeeded: rawSoc >> 8)
        }
        if payload.count > 15 { payload[14] = 0xD8; payload[15] = 0x0E } // 3800mV
        if payload.count > 19 { payload[19] = 0 }
        return frameFromPayload(payload, type: 48, seq: 1, cmd: 3)
    }

    private func commandBattery(rawSoc: UInt16) -> [UInt8] {
        frameFromPayload([0, 0, UInt8(truncatingIfNeeded: rawSoc),
                          UInt8(truncatingIfNeeded: rawSoc >> 8)], type: 36, seq: 2, cmd: 26)
    }

    func testCurrentOwnedWhoop4EventUpdatesPercentageAndBanksSample() {
        let live = connectedState()
        let router = FrameRouter(state: live)

        router.handle(frame: batteryEvent(), observedAt: observed, source: source)

        XCTAssertEqual(live.batteryPct, 50.5)
        XCTAssertEqual(live.batterySamples.last?.soc, 50.5)
        XCTAssertEqual(live.charging, false)
    }

    func testZeroPercentIsARealBatteryReading() {
        let live = connectedState()
        FrameRouter(state: live).handle(
            frame: batteryEvent(rawSoc: 0), observedAt: observed, source: source)
        XCTAssertEqual(live.batteryPct, 0)
    }

    func testWhoop5EventDoesNotBecomeWhoop4BatteryAuthority() {
        let live = connectedState()
        let router = FrameRouter(state: live)
        router.family = .whoop5
        var payload = [UInt8](repeating: 0, count: 27)
        let stamp = UInt32(observed.timeIntervalSince1970)
        for index in 0..<4 { payload[index + 1] = UInt8(truncatingIfNeeded: stamp >> (8 * index)) }
        payload[10] = 0xF9; payload[11] = 1 // 50.5% in the shifted WHOOP5 layout

        router.handle(frame: puffinCommandFrame(cmd: 3, seq: 1, payload: payload, type: 48),
                      observedAt: observed, source: source)
        XCTAssertEqual(live.batteryPct, 80)
    }

    func testCRCEnvelopeAndProtectedPayloadFailuresCannotReplaceLastKnownPercentage() {
        var payloadCRCFailure = batteryEvent()
        payloadCRCFailure[17] ^= 1
        var headerCRCFailure = batteryEvent()
        headerCRCFailure[3] ^= 1
        let cases: [(String, [UInt8])] = [
            ("payload CRC", payloadCRCFailure),
            ("header CRC", headerCRCFailure),
            ("trailing bytes", batteryEvent() + [0]),
            ("charging offset in CRC trailer", batteryEvent(payloadCount: 19)),
            ("SoC absent", batteryEvent(payloadCount: 8)),
            ("110 percent", batteryEvent(rawSoc: 1100)),
        ]
        for (name, frame) in cases {
            let live = connectedState()
            FrameRouter(state: live).handle(frame: frame, observedAt: observed, source: source)
            XCTAssertEqual(live.batteryPct, 80, name)
        }
    }

    func testOldFutureAndZeroEventTimestampsCannotRefreshPercentage() {
        let stamp = UInt32(observed.timeIntervalSince1970)
        for timestamp in [stamp - 46, stamp + 46, 0] {
            let live = connectedState()
            FrameRouter(state: live).handle(
                frame: batteryEvent(timestamp: timestamp), observedAt: observed, source: source)
            XCTAssertEqual(live.batteryPct, 80, "timestamp \(timestamp)")
        }
    }

    func testMissingOwnerOldConnectionAndInactiveLinkCannotRefreshPercentage() {
        let oldSource = LiveHeartRateSource(
            deviceId: source.deviceId, peripheralID: source.peripheralID, connectionGeneration: 6)
        let otherSource = LiveHeartRateSource(
            deviceId: "other-strap", peripheralID: UUID(), connectionGeneration: 7)
        for incoming in [nil, oldSource, otherSource] {
            let live = connectedState()
            FrameRouter(state: live).handle(
                frame: batteryEvent(), observedAt: observed, source: incoming)
            XCTAssertEqual(live.batteryPct, 80)
        }
        for (connected, bonded) in [(true, false), (false, true)] {
            let live = connectedState()
            live.connected = connected
            live.bonded = bonded
            FrameRouter(state: live).handle(
                frame: batteryEvent(), observedAt: observed, source: source)
            XCTAssertEqual(live.batteryPct, 80)
        }
    }

    func testEventCannotRegressNewerCommandReadingButLaterEventCanRefreshIt() {
        let live = connectedState()
        let router = FrameRouter(state: live)
        router.handle(frame: commandBattery(rawSoc: 900),
                      observedAt: observed.addingTimeInterval(10), source: source)
        XCTAssertEqual(live.batteryPct, 90)

        router.handle(frame: batteryEvent(timestamp: UInt32(observed.timeIntervalSince1970 + 5)),
                      observedAt: observed.addingTimeInterval(11), source: source)
        XCTAssertEqual(live.batteryPct, 90, "A replay arriving now is older than the command reading")

        router.handle(frame: batteryEvent(rawSoc: 510,
                                        timestamp: UInt32(observed.timeIntervalSince1970 + 12)),
                      observedAt: observed.addingTimeInterval(12), source: source)
        XCTAssertEqual(live.batteryPct, 51)
    }

    func testObservationOrderingIsScopedToTheCurrentConnectionOwner() {
        let live = connectedState()
        let router = FrameRouter(state: live)
        router.handle(frame: commandBattery(rawSoc: 900),
                      observedAt: observed.addingTimeInterval(30), source: source)
        let nextSource = LiveHeartRateSource(
            deviceId: source.deviceId, peripheralID: source.peripheralID, connectionGeneration: 8)
        live.activateHeartRateSource(nextSource)

        router.handle(frame: batteryEvent(), observedAt: observed, source: nextSource)

        XCTAssertEqual(live.batteryPct, 50.5, "The previous session's ordering cannot fence a new owner")
    }

    func testBatteryAndChargingAreCurrentBeforeEventRequestsSync() {
        let live = connectedState()
        let router = FrameRouter(state: live)
        var powerAtSync: (Double?, Bool?)?
        router.onSyncTrigger = { powerAtSync = (live.batteryPct, live.charging) }

        router.handle(frame: batteryEvent(), observedAt: observed, source: source)

        XCTAssertEqual(powerAtSync?.0, 50.5)
        XCTAssertEqual(powerAtSync?.1, false)
    }

    func testInvalidCommandBatteryCannotPoisonEventOrdering() {
        var invalidHeader = commandBattery(rawSoc: 900)
        invalidHeader[3] ^= 1
        var invalidPayload = commandBattery(rawSoc: 900)
        invalidPayload[9] ^= 1
        let cases = [
            invalidHeader, invalidPayload, commandBattery(rawSoc: 1100),
            frameFromPayload([0, 0, 0xF4], type: 36, seq: 2, cmd: 26),
        ]
        for frame in cases {
            let live = connectedState()
            let router = FrameRouter(state: live)
            router.handle(frame: frame, observedAt: observed.addingTimeInterval(30), source: source)
            XCTAssertEqual(live.batteryPct, 80)

            router.handle(frame: batteryEvent(), observedAt: observed, source: source)

            XCTAssertEqual(live.batteryPct, 50.5, "An invalid response cannot advance the observation watermark")
        }
    }

    func testRetiredCommandOwnerCannotPoisonCurrentEventOrdering() {
        let live = connectedState()
        let router = FrameRouter(state: live)
        let oldSource = LiveHeartRateSource(
            deviceId: source.deviceId, peripheralID: source.peripheralID, connectionGeneration: 6)
        router.handle(frame: commandBattery(rawSoc: 900),
                      observedAt: observed.addingTimeInterval(30), source: oldSource)
        XCTAssertEqual(live.batteryPct, 80)

        router.handle(frame: batteryEvent(), observedAt: observed, source: source)

        XCTAssertEqual(live.batteryPct, 50.5)
    }

    func testLegacyCommandCallerUsesCurrentSourceForObservationOrdering() {
        let live = connectedState()
        let router = FrameRouter(state: live)
        router.handle(frame: commandBattery(rawSoc: 900), observedAt: observed.addingTimeInterval(10))

        router.handle(frame: batteryEvent(), observedAt: observed.addingTimeInterval(11), source: source)

        XCTAssertEqual(live.batteryPct, 90)
    }

    func testOffloadBatteryDispatchUpdatesOnlyFreshBatteryState() {
        let live = connectedState()
        let router = FrameRouter(state: live)
        router.onSyncTrigger = { XCTFail("The offload escape path must not trigger another sync") }

        router.dispatchLiveBatteryIfFresh(frame: batteryEvent(), observedAt: observed, source: source)

        XCTAssertEqual(live.batteryPct, 50.5)
        XCTAssertEqual(live.charging, false)
        XCTAssertNil(live.lastEvent)
        XCTAssertNil(live.lastFrameType)

        router.dispatchLiveBatteryIfFresh(
            frame: batteryEvent(rawSoc: 300,
                                timestamp: UInt32(observed.timeIntervalSince1970 - 46)),
            observedAt: observed.addingTimeInterval(1), source: source)
        XCTAssertEqual(live.batteryPct, 50.5, "Old history cannot replace the live reading")
    }

    func testOffloadBatteryDispatchRetainsOwnerFamilyAndIntegrityGates() {
        let oldSource = LiveHeartRateSource(
            deviceId: source.deviceId, peripheralID: source.peripheralID, connectionGeneration: 6)
        var corrupt = batteryEvent()
        corrupt[17] ^= 1
        for (family, incoming, frame) in [
            (DeviceFamily.whoop5, source, batteryEvent()),
            (.whoop4, oldSource, batteryEvent()),
            (.whoop4, source, corrupt),
        ] {
            let live = connectedState()
            let router = FrameRouter(state: live)
            router.family = family

            router.dispatchLiveBatteryIfFresh(frame: frame, observedAt: observed, source: incoming)

            XCTAssertEqual(live.batteryPct, 80)
        }
    }
}
