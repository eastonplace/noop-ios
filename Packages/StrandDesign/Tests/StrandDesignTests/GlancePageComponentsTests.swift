import SwiftUI
import XCTest
@testable import StrandDesign

final class GlancePageComponentsTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    // MARK: Page dots

    func testPagesStopAtTheEndsInsteadOfWrapping() {
        XCTAssertEqual(PageDots.moved(0, by: -1, count: 3), 0)
        XCTAssertEqual(PageDots.moved(0, by: 1, count: 3), 1)
        XCTAssertEqual(PageDots.moved(2, by: 1, count: 3), 2)
        XCTAssertEqual(PageDots.moved(1, by: -1, count: 3), 0)
        XCTAssertEqual(PageDots.moved(5, by: 1, count: 0), 0)
    }

    func testTheSpokenPageIsOneBasedAndNamed() {
        XCTAssertEqual(PageDots.spoken(page: 1, count: 3, title: "Heart"), "Page 2 of 3, Heart")
    }

    // MARK: Time in zone

    func testAWorkoutWithNoTimeYetDrawsThreeEqualSegments() {
        XCTAssertEqual(ZoneMinutesBar.weights(seconds: [0, 0, 0]), [1, 1, 1])
        XCTAssertEqual(ZoneMinutesBar.weights(seconds: []), [1, 1, 1])
    }

    func testSegmentsAreAsWideAsTheTimeSpentInThem() {
        let weights = ZoneMinutesBar.weights(seconds: [120, 540, 1380])
        XCTAssertEqual(weights[0], 120.0 / 2040, accuracy: 1e-9)
        XCTAssertEqual(weights[1], 540.0 / 2040, accuracy: 1e-9)
        XCTAssertEqual(weights[2], 1380.0 / 2040, accuracy: 1e-9)
    }

    func testAZoneWithAlmostNoTimeKeepsAVisibleSegment() {
        let weights = ZoneMinutesBar.weights(seconds: [5, 0, 3600])
        XCTAssertGreaterThanOrEqual(weights[0], ZoneMinutesBar.minimumShare)
        XCTAssertGreaterThanOrEqual(weights[1], ZoneMinutesBar.minimumShare)
    }

    func testTimeInZoneIsWholeMinutesRoundedDown() {
        XCTAssertEqual(ZoneMinutesBar.durationText(seconds: 0, locale: en), "0m")
        XCTAssertEqual(ZoneMinutesBar.durationText(seconds: 59, locale: en), "<1m")
        XCTAssertEqual(ZoneMinutesBar.durationText(seconds: 60, locale: en), "1m")
        XCTAssertEqual(ZoneMinutesBar.durationText(seconds: 599, locale: en), "9m")
        XCTAssertEqual(ZoneMinutesBar.durationText(seconds: 3600 + 4 * 60 + 30, locale: en), "1h 4m")
    }

    // MARK: Wash

    func testTheWashIsAWhisper() {
        XCTAssertEqual(ZoneWashBackground.peakOpacity, 0.14, accuracy: 1e-9)
    }

    // MARK: Page numeral

    func testAPageNumeralIsBetweenTheSecondaryAndTheFocusSizes() {
        XCTAssertEqual(GlanceMetricLayout.pagePointSize, 96)
        XCTAssertGreaterThan(GlanceMetricLayout.pagePointSize, GlanceMetricLayout.secondaryPointSize)
        XCTAssertLessThan(GlanceMetricLayout.pagePointSize, GlanceMetricLayout.focusPointSize(characterCount: 4))
    }
}
