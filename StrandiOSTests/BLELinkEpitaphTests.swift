import XCTest
@testable import NOOP

final class BLELinkEpitaphTests: XCTestCase {
    func testFailedConnectAttemptEmitsNothing() {
        var state = BLELinkEpitaphState()

        XCTAssertNil(
            state.disconnected(
                nowUptimeNanoseconds: 2_000_000_000,
                realtimeArmed: false,
                ended: "failed connect"))
    }

    func testConnectedLinkEmitsOnceAndCountsInboundNotifications() throws {
        var state = BLELinkEpitaphState()
        state.connected(nowUptimeNanoseconds: 1_000_000_000)
        state.received(byteCount: 12, commandChannel: false)
        state.received(byteCount: 7, commandChannel: true)

        let line = try XCTUnwrap(
            state.disconnected(
                nowUptimeNanoseconds: 3_500_000_000,
                realtimeArmed: true,
                ended: "intentional"))
        XCTAssertEqual(
            line,
            "Link epitaph: up 2500ms, inbound 2 frames / 19 bytes (cmd-channel 1), "
                + "realtime armed=yes, ended=intentional")

        XCTAssertNil(
            state.disconnected(
                nowUptimeNanoseconds: 4_000_000_000,
                realtimeArmed: false,
                ended: "duplicate"),
            "a repeated disconnect callback must not emit a second epitaph")
    }

    func testNextConnectionStartsFromZero() throws {
        var state = BLELinkEpitaphState()
        state.connected(nowUptimeNanoseconds: 1_000_000_000)
        state.received(byteCount: 100, commandChannel: true)
        _ = state.disconnected(
            nowUptimeNanoseconds: 2_000_000_000,
            realtimeArmed: true,
            ended: "first")

        state.connected(nowUptimeNanoseconds: 5_000_000_000)
        let second = try XCTUnwrap(
            state.disconnected(
                nowUptimeNanoseconds: 5_500_000_000,
                realtimeArmed: false,
                ended: "second"))
        XCTAssertEqual(
            second,
            "Link epitaph: up 500ms, inbound 0 frames / 0 bytes (cmd-channel 0), "
                + "realtime armed=no, ended=second - the strap sent NOTHING on this link")
    }
}
