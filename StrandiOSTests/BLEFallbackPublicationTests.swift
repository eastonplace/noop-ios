import Combine
import XCTest
@testable import NOOP

@MainActor
final class BLEFallbackPublicationTests: XCTestCase {
    func testRepeatedFallbackReceiptsPublishAndLogOnlyTheModeTransition() {
        let state = LiveState()
        let manager = BLEManager(state: state, collector: nil)
        manager.connect(model: .whoop5mg)
        var publishedModes: [String?] = []
        let observation = state.$standardHRMode.dropFirst().sink { publishedModes.append($0) }

        for _ in 0..<3_600 { manager.updateWhoop5StandardHRFallback() }
        state.publishPendingLog()

        XCTAssertEqual(publishedModes.count, 1)
        XCTAssertEqual(state.log.filter { $0.contains("standard HR is live while") }.count, 1)

        manager.pauseAutoReconnectForWhoop5SecureFailureForTesting()
        for _ in 0..<3_600 { manager.updateWhoop5StandardHRFallback() }
        state.publishPendingLog()

        XCTAssertEqual(publishedModes.count, 2, "a change to paused recovery still publishes once")
        XCTAssertEqual(state.log.filter { $0.contains("standard HR is live while") }.count, 2)
        XCTAssertTrue(state.standardHRMode?.contains("paused") == true)
        withExtendedLifetime(observation) {}
        manager.disconnect()
    }

    func testWhoop4DoesNotAcquireTheWhoop5FallbackMode() {
        let state = LiveState()
        let manager = BLEManager(state: state, collector: nil)
        manager.connect(model: .whoop4)

        manager.updateWhoop5StandardHRFallback()

        XCTAssertNil(state.standardHRMode)
        manager.disconnect()
    }
}
