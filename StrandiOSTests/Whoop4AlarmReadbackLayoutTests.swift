import XCTest
import WhoopProtocol
@testable import NOOP

final class Whoop4AlarmReadbackLayoutTests: XCTestCase {
    private func response(_ payload: [UInt8]) -> [UInt8] {
        frameFromPayload([0x16, 0x01] + payload, type: 36, seq: 0xC7, cmd: 67)
    }

    func testCapturedFirmware4117ReadbackUsesEpochAfterRevisionAndState() {
        let frame: [UInt8] = [0xaa, 0x14, 0x00, 0x03, 0x24, 0xc7, 0x43, 0x16,
            0x01, 0x01, 0x01, 0x88, 0x60, 0xd9, 0x6a, 0x00, 0x00, 0x04,
            0x00, 0x20, 0x9d, 0x4b, 0x2e, 0x0a]
        XCTAssertTrue(parseFrame(frame, family: .whoop4).crcOK == true)
        XCTAssertEqual(FrameRouter.armedAlarmEpoch(in: frame), 1_792_630_920)
        XCTAssertFalse(FrameRouter.readbackReportsNoAlarm(in: frame))
    }

    func testCapturedFirmware4117NoAlarmRemainsDistinctFromArmed() {
        let frame = response([1, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0x20])
        XCTAssertNil(FrameRouter.armedAlarmEpoch(in: frame))
        XCTAssertTrue(FrameRouter.readbackReportsNoAlarm(in: frame))
    }

    func testUnknownStateCannotReinterpretMisalignedPlausibleEpoch() {
        let frame = response([1, 2, 0x88, 0x60, 0xd9, 0x6a, 0, 0, 4, 0, 0x20])
        XCTAssertNil(FrameRouter.armedAlarmEpoch(in: frame))
        XCTAssertFalse(FrameRouter.readbackReportsNoAlarm(in: frame))
    }

    func testInactiveStateWithNonzeroEpochCannotConfirmAnAlarm() {
        let frame = response([1, 0, 0x88, 0x60, 0xd9, 0x6a, 0, 0, 4, 0, 0x20])
        XCTAssertNil(FrameRouter.armedAlarmEpoch(in: frame))
        XCTAssertFalse(FrameRouter.readbackReportsNoAlarm(in: frame))
    }

    func testUnknownElevenByteRevisionCannotFallBackToLegacyFields() {
        let plausibleMisaligned = response([2, 1, 0x88, 0x60, 0xd9, 0x6a, 0, 0, 4, 0, 0x20])
        XCTAssertNil(FrameRouter.armedAlarmEpoch(in: plausibleMisaligned))
        XCTAssertFalse(FrameRouter.readbackReportsNoAlarm(in: plausibleMisaligned))
        let zeroMisaligned = response([0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0x20])
        XCTAssertNil(FrameRouter.armedAlarmEpoch(in: zeroMisaligned))
        XCTAssertFalse(FrameRouter.readbackReportsNoAlarm(in: zeroMisaligned))
    }

    func testLegacySetMirrorAndBareEpochRemainSupported() {
        XCTAssertEqual(FrameRouter.armedAlarmEpoch(in: response(
            [1, 0x88, 0x60, 0xd9, 0x6a, 0, 0, 0, 0])), 1_792_630_920)
        XCTAssertEqual(FrameRouter.armedAlarmEpoch(in: response(
            [0x88, 0x60, 0xd9, 0x6a])), 1_792_630_920)
    }

    func testTruncatedCapturedLayoutCannotReadOutsideEnvelope() {
        var frame = response([1, 1, 0x88, 0x60, 0xd9, 0x6a, 0, 0, 4, 0, 0x20])
        frame.removeLast(8)
        XCTAssertNil(FrameRouter.armedAlarmEpoch(in: frame))
        XCTAssertFalse(FrameRouter.readbackReportsNoAlarm(in: frame))
    }
}
