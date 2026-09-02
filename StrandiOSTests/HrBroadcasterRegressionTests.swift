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
}
