import AppIntents
import XCTest
@testable import NOOP

#if os(iOS)
final class AppIntentRegistrationTests: XCTestCase {
    func testShortcutsProviderKeepsAllPhoneActionsAndForegroundDeliveryContract() {
        XCTAssertEqual(NOOPShortcuts.appShortcuts.count, 10)
        // Buzz needs the app's existing BLE owner, so the intent opens NOOP and the lifecycle drains
        // the App Group queue. Mark Moment can remain background-safe because it only queues a timestamp.
        XCTAssertTrue(BuzzStrapIntent.openAppWhenRun)
        XCTAssertTrue(SyncStrapIntent.openAppWhenRun)
        XCTAssertFalse(MarkMomentIntent.openAppWhenRun)
    }

    func testGPSRouteExportRequiresAuthenticationOnTheLocalDevice() {
        // The file includes timestamped precise locations. Siri/Shortcuts must authenticate
        // before perform can read the saved route, including when NOOP remains backgrounded.
        XCTAssertEqual(ExportWorkoutRouteIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
        XCTAssertFalse(ExportWorkoutRouteIntent.openAppWhenRun)
    }
}
#endif
