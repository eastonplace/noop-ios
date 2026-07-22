import AppIntents
import XCTest
@testable import NOOP

#if os(iOS)
final class AppIntentRegistrationTests: XCTestCase {
    func testShortcutsProviderKeepsBothPhoneActions() {
        XCTAssertEqual(NOOPShortcuts.appShortcuts.count, 2)
        XCTAssertFalse(BuzzStrapIntent.openAppWhenRun)
        XCTAssertFalse(MarkMomentIntent.openAppWhenRun)
    }
}
#endif
