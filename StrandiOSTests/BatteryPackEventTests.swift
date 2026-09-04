import XCTest
@testable import NOOP

@MainActor
final class BatteryPackEventTests: XCTestCase {
    func testPackEdgesUpdateChargingWithoutChangingBatteryLevelSemantics() {
        XCTAssertEqual(
            FrameRouter.liveChargingState(event: "BATTERY_PACK_CONNECTED(21)", batteryCharging: nil),
            true
        )
        XCTAssertEqual(
            FrameRouter.liveChargingState(event: "BATTERY_PACK_REMOVED(22)", batteryCharging: nil),
            false
        )
        XCTAssertEqual(
            FrameRouter.liveChargingState(event: "BATTERY_LEVEL(7)", batteryCharging: 1),
            true
        )
        XCTAssertEqual(
            FrameRouter.liveChargingState(event: "BATTERY_LEVEL(7)", batteryCharging: 0),
            false
        )
        XCTAssertEqual(
            FrameRouter.liveChargingState(event: "CHARGING_ON(7)", batteryCharging: nil),
            true
        )
        XCTAssertEqual(
            FrameRouter.liveChargingState(event: "CHARGING_OFF(8)", batteryCharging: nil),
            false
        )
        XCTAssertNil(FrameRouter.liveChargingState(event: "WRIST_ON(3)", batteryCharging: nil))
    }

    func testRouterAppliesPackEdgesToLiveChargingState() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.applyLiveChargingState(event: "BATTERY_PACK_CONNECTED(21)", batteryCharging: nil)
        XCTAssertEqual(live.charging, true)
        router.applyLiveChargingState(event: "BATTERY_PACK_REMOVED(22)", batteryCharging: nil)
        XCTAssertEqual(live.charging, false)
    }
}
