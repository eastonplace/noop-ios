import SwiftUI
import UIKit
import XCTest
@testable import NOOP
import StrandDesign
import StrandAnalytics

/// The cached time formatter keeps up with the device.
@MainActor
final class AppClockTimeZoneTests: XCTestCase {
    /// The cached time formatter follows the device's zone after travel instead of keeping the one it was made in.
    func testTheClockFormatterTracksTheDevicesTimeZone() {
        XCTAssertEqual(AppClock.hourMinuteFormatter().timeZone, TimeZone.autoupdatingCurrent)
    }
}
