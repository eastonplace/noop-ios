import XCTest
import WhoopProtocol
@testable import NOOP

@MainActor
final class RebootResponseLogTests: XCTestCase {
    func testWhoop4RebootResponseKeepsItsLegacyResultLayout() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.family = .whoop4
        let frame = frameFromPayload(
            [0xA7, 0x00], type: 36, seq: 0x42, cmd: WhoopCommand.rebootStrap.rawValue)

        router.handle(frame: frame)
        live.publishPendingLog()

        XCTAssertEqual(live.log.last, "reboot: strap acked result=0x00 (accepted)")
    }

    func testWhoop5RebootResponseLogsTheResultInsteadOfThePacketType() {
        for type: UInt8 in [36, 38] {
            let live = LiveState()
            let router = FrameRouter(state: live)
            router.family = .whoop5
            let frame = puffinCommandFrame(
                cmd: WhoopCommand.rebootStrap.rawValue,
                seq: 0x42, payload: [0xA7, 0x01], type: type)

            router.handle(frame: frame)
            live.publishPendingLog()

            XCTAssertEqual(
                live.log.last,
                "reboot: strap acked result=0x01 (command-specific response; physical reboot unconfirmed)",
                "the response result is byte 12, not the 5/MG packet type at byte 8")
        }
    }

    func testWhoop5RebootResponsePreservesAnUnknownResultWithoutInventingAVerdict() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.family = .whoop5
        let frame = puffinCommandFrame(
            cmd: WhoopCommand.rebootStrap.rawValue,
            seq: 0x42, payload: [0xA7, 0x7F], type: 36)

        router.handle(frame: frame)
        live.publishPendingLog()

        XCTAssertEqual(
            live.log.last,
            "reboot: strap acked result=0x7f (command-specific response; physical reboot unconfirmed)")
    }
}
