import XCTest
@testable import NOOP

/// The shell closes the Settings sheet before it presents anything else, because SwiftUI drops a sheet presented while
/// another is still on screen.
final class ShellSettingsGateTests: XCTestCase {
    func testNothingWaitsWhenSettingsIsNotUp() {
        XCTAssertNil(ShellSettingsGate.delay(settingsIsUp: false))
    }

    func testARequestWaitsOutTheDismissalWhenSettingsIsUp() throws {
        let delay = try XCTUnwrap(ShellSettingsGate.delay(settingsIsUp: true))
        XCTAssertEqual(delay, ShellSettingsGate.dismissalDelay)
        // Long enough for a sheet dismissal (the Lift and Settings hand-offs wait 0.4 and 0.45).
        XCTAssertGreaterThanOrEqual(delay, 0.4)
    }
}
