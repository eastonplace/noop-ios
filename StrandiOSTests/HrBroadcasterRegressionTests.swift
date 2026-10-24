import XCTest
@testable import NOOP

@MainActor
final class HrBroadcasterRegressionTests: XCTestCase {
    func testRepeatedBindLeavesOneSubscription() {
        let broadcaster = HrBroadcaster(log: { _ in })
        let live = LiveState()

        broadcaster.bind(to: live)
        for _ in 0..<10 {
            broadcaster.bind(to: live)
        }

        XCTAssertEqual(broadcaster.cancellables.count, 1)
    }

    func testRebindingReplacesPreviousSubscription() {
        let broadcaster = HrBroadcaster(log: { _ in })

        broadcaster.bind(to: LiveState())
        broadcaster.bind(to: LiveState())

        XCTAssertEqual(broadcaster.cancellables.count, 1)
    }

    func testSourceRetirementClearsTheValueReplayedToNewSubscribers() {
        let broadcaster = HrBroadcaster(log: { _ in })
        let live = LiveState()
        broadcaster.bind(to: live)
        broadcaster.start()
        live.heartRate = 94
        XCTAssertEqual(broadcaster.lastBpm, 94)

        live.clearBiometrics()

        XCTAssertNil(broadcaster.lastBpm, "A new subscriber must not receive the retired source's BPM")
        live.heartRate = 112
        XCTAssertEqual(broadcaster.lastBpm, 112, "Fresh readings still broadcast after source replacement")
        broadcaster.stop()
    }
}
