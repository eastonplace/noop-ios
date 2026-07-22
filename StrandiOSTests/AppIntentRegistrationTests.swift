import AppIntents
import XCTest
@testable import NOOP

#if os(iOS)
final class AppIntentRegistrationTests: XCTestCase {
    func testShortcutsProviderKeepsBothPhoneActionsAndForegroundDeliveryContract() {
        XCTAssertEqual(NOOPShortcuts.appShortcuts.count, 2)
        // Buzz needs the app's existing BLE owner, so the intent opens NOOP and the lifecycle drains
        // the App Group queue. Mark Moment can remain background-safe because it only queues a timestamp.
        XCTAssertTrue(BuzzStrapIntent.openAppWhenRun)
        XCTAssertFalse(MarkMomentIntent.openAppWhenRun)
    }
}
#endif
