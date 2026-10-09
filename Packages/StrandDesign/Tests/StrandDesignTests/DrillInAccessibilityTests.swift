import SwiftUI
import XCTest
@testable import StrandDesign

/// What the drill-in controls hand to touch and to VoiceOver: hours in the clock the app was set to, a finger-sized
/// range pill, and band hours that read singular for one.
@MainActor
final class DrillInAccessibilityTests: XCTestCase {
    func testHourLabelsFollowTheLocaleTheAppHandsDown() {
        let twelve = StressDayRibbon.hourLabel(18, locale: Locale(identifier: "en_US@hours=h12"))
        let twentyFour = StressDayRibbon.hourLabel(18, locale: Locale(identifier: "en_US@hours=h23"))
        XCTAssertTrue(twelve.contains("PM"), twelve)
        XCTAssertEqual(twentyFour, "18")
        // Past the end of a day wraps, so the axis can label its last tick as midnight.
        XCTAssertEqual(StressDayRibbon.hourLabel(24, locale: Locale(identifier: "en_US@hours=h23")),
                       StressDayRibbon.hourLabel(0, locale: Locale(identifier: "en_US@hours=h23")))
    }

    func testAPillSegmentIsFortyFourPointsTallToAFinger() {
        let touch = SegmentTouchShape().path(in: CGRect(x: 0, y: 0, width: 50, height: 32)).boundingRect
        XCTAssertEqual(touch.height, 44, accuracy: 0.001)
        // Its own width, so neighbouring segments never fight over a touch.
        XCTAssertEqual(touch.width, 50, accuracy: 0.001)
        XCTAssertEqual(touch.minY, -6, accuracy: 0.001)
    }

    func testBandHoursAreSpokenAsDurationsSoOneHourIsSingular() {
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertEqual(plain(StressModuleCard.spokenHours(1)), "1 hour")
        XCTAssertEqual(plain(StressModuleCard.spokenHours(3)), "3 hours")
        XCTAssertEqual(plain(StressModuleCard.spokenHours(0)), "0 hours")
    }
}
