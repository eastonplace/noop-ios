import XCTest
import StrandDesign
@testable import NOOP

final class AppHeaderChromeStateTests: XCTestCase {
    func testConnectedIdleState() {
        XCTAssertEqual(AppHeaderChromeMapper.state(connected: true, backfilling: false,
                                                    error: nil, transient: .idle),
                       AppHeaderChromeState(strap: .live, sync: .idle))
    }

    func testOfflineState() {
        XCTAssertEqual(AppHeaderChromeMapper.state(connected: false, backfilling: false,
                                                    error: nil, transient: .idle).strap, .offline)
    }

    func testBackfillDoesNotReplaceConnectionStatus() {
        XCTAssertEqual(AppHeaderChromeMapper.state(connected: true, backfilling: true,
                                                    error: "old", transient: .done),
                       AppHeaderChromeState(strap: .live, sync: .syncing))
    }

    func testErrorOverridesTransientCompletion() {
        XCTAssertEqual(AppHeaderChromeMapper.state(connected: true, backfilling: false,
                                                    error: "Bluetooth unavailable", transient: .done).sync,
                       .error)
    }

    func testCompletionIsExposedWhenHealthy() {
        XCTAssertEqual(AppHeaderChromeMapper.state(connected: true, backfilling: false,
                                                    error: nil, transient: .done).sync, .done)
    }
}
