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

    func testTheStressCardsHoursFollowTheLocaleToo() {
        let twelve = StressModuleCard.hourLabel(18, locale: Locale(identifier: "en_US@hours=h12"))
        let twentyFour = StressModuleCard.hourLabel(18, locale: Locale(identifier: "en_US@hours=h23"))
        XCTAssertTrue(twelve.contains("PM"), twelve)
        XCTAssertEqual(twentyFour, "18")
        XCTAssertFalse(StressModuleCard.hourLabel(6, locale: Locale(identifier: "en_US@hours=h23")).contains("AM"))
        XCTAssertEqual(StressModuleCard.hourLabel(24, locale: Locale(identifier: "en_US@hours=h23")),
                       StressModuleCard.hourLabel(0, locale: Locale(identifier: "en_US@hours=h23")))
    }

    /// The spoken summary is one sentence built from whole formats: the numbers and the peak hour follow the app's
    /// locale (a German 24-hour phone says "14 Uhr" and "2,4", never "2 PM" and "2.4").
    func testTheSpokenStressSummaryFollowsTheAppsLocale() {
        let peak = (hour: 14, level: 2.4)
        let counts = [10, 3, 1]
        let american = StressModuleCard.spokenSummary(
            subject: "Today's stress", value: 1.5, word: "Moderate", why: "", peak: peak, bandCounts: counts,
            locale: Locale(identifier: "en_US@hours=h12"))
        XCTAssertTrue(american.hasPrefix("Today's stress 1.5, Moderate"), american)
        XCTAssertTrue(american.contains("Peak 2.4 at "), american)
        XCTAssertTrue(american.contains("PM"), american)

        let german = StressModuleCard.spokenSummary(
            subject: "Today's stress", value: 1.5, word: "Moderate", why: "", peak: peak, bandCounts: counts,
            locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(german.contains("1,5"), german)
        XCTAssertTrue(german.contains("2,4"), german)
        XCTAssertFalse(german.contains("PM"), german)
        XCTAssertFalse(german.contains("AM"), german)
    }

    func testTheSpokenStressSummaryHasNoClausesWhenThereIsNothingToSay() {
        let none = StressModuleCard.spokenSummary(
            subject: "Today's stress", value: nil, word: "Calibrating", why: "First nights build your baseline.",
            peak: nil, bandCounts: [0, 0, 0], locale: Locale(identifier: "en_US"))
        XCTAssertEqual(none, "Today's stress, Calibrating. First nights build your baseline.")
        let valueOnly = StressModuleCard.spokenSummary(
            subject: "Today's stress", value: 0.8, word: "Low", why: "", peak: nil, bandCounts: [0, 0, 0],
            locale: Locale(identifier: "en_US"))
        XCTAssertEqual(valueOnly, "Today's stress 0.8, Low")
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
