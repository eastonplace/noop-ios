import XCTest
@testable import WhoopProtocol

/// BLE-4: Continuous HRV capture holds only the lightweight HR toggle; the heavy R10/R11 raw burst stays
/// scoped to a visible Live screen, and the frames it produces are not buffered when nothing persists them.
final class RealtimeArmPolicyTests: XCTestCase {

    /// The finding's regression: a keep-alive tick with continuous capture on and no Live screen must not
    /// re-send R10/R11 [1]. It still holds the HR toggle armed.
    func testContinuousCaptureAloneArmsToggleButNeverTheRawBurst() {
        let tick = RealtimeArmPolicy(screenWantsRealtime: false, continuousCaptureWantsNow: true,
                                     standardHRFallback: false)
        XCTAssertTrue(tick.wantsHrToggle)
        XCTAssertFalse(tick.wantsRawBurst)
    }

    func testLiveScreenArmsBothUnlessTheMarginalRadioFallbackTripped() {
        let live = RealtimeArmPolicy(screenWantsRealtime: true, continuousCaptureWantsNow: false,
                                     standardHRFallback: false)
        XCTAssertTrue(live.wantsHrToggle)
        XCTAssertTrue(live.wantsRawBurst)

        let fallback = RealtimeArmPolicy(screenWantsRealtime: true, continuousCaptureWantsNow: true,
                                         standardHRFallback: true)
        XCTAssertTrue(fallback.wantsHrToggle)
        XCTAssertFalse(fallback.wantsRawBurst, "#80: never re-arm the burst the radio could not sustain")
    }

    func testNothingWantedArmsNothing() {
        let idle = RealtimeArmPolicy(screenWantsRealtime: false, continuousCaptureWantsNow: false,
                                     standardHRFallback: false)
        XCTAssertFalse(idle.wantsHrToggle)
        XCTAssertFalse(idle.wantsRawBurst)
    }

    /// Type 43 (REALTIME_RAW_DATA) decodes to no rows, so it is dropped unless raw capture is on.
    func testType43IsDroppedUnlessRawCaptureIsActive() {
        let typeName = loadSchema().typeName(43)
        XCTAssertEqual(typeName, "REALTIME_RAW_DATA")
        XCTAssertFalse(LiveFrameRetention.shouldBuffer(typeName: typeName, rawCaptureActive: false))
        XCTAssertTrue(LiveFrameRetention.shouldBuffer(typeName: typeName, rawCaptureActive: true))
    }

    /// Every type `extractStreams` decodes is always kept, so the decoded output is unchanged.
    func testDecodedLiveTypesAreAlwaysBuffered() {
        for name in ["REALTIME_DATA", "EVENT", "COMMAND_RESPONSE"] {
            XCTAssertTrue(LiveFrameRetention.shouldBuffer(typeName: name, rawCaptureActive: false), name)
        }
        XCTAssertFalse(LiveFrameRetention.shouldBuffer(typeName: "INVALID/FRAGMENT", rawCaptureActive: false))
    }

    /// The retained set really is everything `extractStreams` reads: a dropped frame type adds no rows.
    func testDroppedTypesContributeNoDecodedRows() {
        let raw43 = frameFromPayload([UInt8](repeating: 0x3C, count: 1917), type: 43, seq: 1, cmd: 0)
        let parsed = parseFrame(raw43)
        XCTAssertFalse(LiveFrameRetention.shouldBuffer(typeName: parsed.typeName, rawCaptureActive: false))
        XCTAssertTrue(extractStreams([parsed], deviceClockRef: 0, wallClockRef: 0).isEmpty)
    }

    func testRealtimeHrEchoEventsDoNotTriggerSync() {
        XCTAssertFalse(StrapEventSyncPolicy.shouldTriggerSync(eventName: "BLE_REALTIME_HR_ON(43)"))
        XCTAssertFalse(StrapEventSyncPolicy.shouldTriggerSync(eventName: "BLE_REALTIME_HR_OFF(44)"))
        XCTAssertTrue(StrapEventSyncPolicy.shouldTriggerSync(eventName: "WRIST_ON(9)"))
        XCTAssertTrue(StrapEventSyncPolicy.shouldTriggerSync(eventName: "BATTERY_LEVEL(3)"))
    }
}
