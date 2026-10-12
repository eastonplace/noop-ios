import SwiftUI
import XCTest
@testable import StrandDesign

final class LiveNumeralsTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    // MARK: Two sizes

    func testThereAreTwoNumeralSizesAndTheFocusIsTheLarger() {
        XCTAssertEqual(LiveNumeralMetrics.focusPointSize, 160)
        XCTAssertEqual(LiveNumeralMetrics.secondaryPointSize, 76)
        XCTAssertGreaterThan(LiveNumeralMetrics.focusPointSize, LiveNumeralMetrics.secondaryPointSize)
    }

    func testDigitsAreShorterThanTheirPointSizeAndScaleWithIt() {
        let big = LiveNumeralMetrics.digitHeight(160), small = LiveNumeralMetrics.digitHeight(76)
        XCTAssertLessThan(big, 160)
        XCTAssertGreaterThan(big, small)
        XCTAssertEqual(big / small, 160.0 / 76.0, accuracy: 0.02)
    }

    func testAUnitIsNeverLargerThanItsNumeral() {
        // At every size, the unit's ceiling is a fraction of the figure it labels.
        XCTAssertLessThan(LiveNumeralMetrics.unitShareOfNumeral, 0.5)
        XCTAssertLessThan(LiveNumeralMetrics.secondaryUnitSize, LiveNumeralMetrics.secondaryPointSize * LiveNumeralMetrics.unitShareOfNumeral + 1)
    }

    // MARK: Page fit

    func testAPageThatFitsIsNotScaledAndKeepsItsNoticeBand() {
        let natural = LiveNumeralMetrics.stackHeight(rows: 3)
        let fit = LiveNumeralMetrics.fit(natural: natural, region: natural + LiveNumeralMetrics.noticeBand + 80)
        XCTAssertEqual(fit.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(fit.top, LiveNumeralMetrics.noticeBand + 80 * 0.4, accuracy: 1e-6)
        XCTAssertFalse(fit.scrolls)
    }

    func testAShortRegionScalesEveryFigureDownTogetherNeverUp() {
        let natural = LiveNumeralMetrics.stackHeight(rows: 3)
        let fit = LiveNumeralMetrics.fit(natural: natural, region: LiveNumeralMetrics.noticeBand + natural * 0.7)
        XCTAssertEqual(fit.scale, 0.7, accuracy: 1e-6)
        XCTAssertEqual(fit.top, LiveNumeralMetrics.noticeBand, accuracy: 1e-6)
        XCTAssertEqual(LiveNumeralMetrics.fit(natural: natural, region: 5000).scale, 1)
    }

    func testAnImpossiblyShortRegionStopsScalingAndScrolls() {
        let natural = LiveNumeralMetrics.stackHeight(rows: 3)
        let fit = LiveNumeralMetrics.fit(natural: natural, region: 100)
        XCTAssertEqual(fit.scale, LiveNumeralMetrics.minimumScale)
        XCTAssertTrue(fit.scrolls)
    }

    func testTheReferenceScreenFitsAtFullSize() {
        // 874 pt tall: below the header (to 104) and above the dots (636) there are 532 pt.
        let fit = LiveNumeralMetrics.fit(natural: LiveNumeralMetrics.stackHeight(rows: 3), region: 532)
        XCTAssertEqual(fit.scale, 1)
        XCTAssertFalse(fit.scrolls)
    }

    func testTheNoticeBandIsTakenOffTheTopAndCanBeTallerForWrappedPills() {
        let natural = LiveNumeralMetrics.stackHeight(rows: 3)
        let normal = LiveNumeralMetrics.fit(natural: natural, region: 600)
        let tall = LiveNumeralMetrics.fit(natural: natural, region: 600, band: 76)
        XCTAssertGreaterThanOrEqual(tall.top, 76)
        XCTAssertGreaterThanOrEqual(normal.top, LiveNumeralMetrics.noticeBand)
    }

    // MARK: A figure with no reading

    /// Apple Workout's "--": two hyphens in the numeral face, not the em or en dash a text row would use.
    func testAFigureWithNoReadingIsDrawnAsTwoHyphens() {
        XCTAssertEqual(LiveNumeral.missingText, "--")
        XCTAssertFalse(LiveNumeral.missingText.contains("\u{2013}"))
        XCTAssertFalse(LiveNumeral.missingText.contains("\u{2014}"))
        // Short enough to sit beside a unit block at the secondary size.
        XCTAssertLessThan(LiveNumeralMetrics.numeralWidth(LiveNumeral.missingText, pointSize: 76, tracking: -1.7),
                          LiveNumeralMetrics.numeralWidth("00:00", pointSize: 76, tracking: -1.7))
    }

    // MARK: Fitting a wide figure

    /// A figure wider than its line is scaled by an exact factor worked out from its width, so its digits stay on the baseline.
    func testAWiderFigureMeasuresWiderAndALargerSizeMeasuresLarger() {
        let short = LiveNumeralMetrics.numeralWidth("5.49", pointSize: 160, tracking: -6.4)
        let long = LiveNumeralMetrics.numeralWidth("105.49", pointSize: 160, tracking: -6.4)
        XCTAssertGreaterThan(long, short)
        XCTAssertGreaterThan(LiveNumeralMetrics.numeralWidth("5.49", pointSize: 160, tracking: -6.4),
                             LiveNumeralMetrics.numeralWidth("5.49", pointSize: 76, tracking: -3))
        XCTAssertGreaterThan(LiveNumeralMetrics.unitWidth("AVG", pointSize: 15), 0)
    }

    // MARK: Zone row

    func testTimeInZoneIsWholeMinutesWithTheirUnit() {
        XCTAssertEqual(LiveZoneRow.minutes(seconds: 0, locale: en).figure, "0")
        XCTAssertEqual(LiveZoneRow.minutes(seconds: 59, locale: en).figure, "<1")
        XCTAssertEqual(LiveZoneRow.minutes(seconds: 60, locale: en).figure, "1")
        XCTAssertEqual(LiveZoneRow.minutes(seconds: 1680, locale: en).figure, "28")
        XCTAssertEqual(LiveZoneRow.minutes(seconds: 3600 + 4 * 60, locale: en).figure, "1:04")
    }

    func testTheSpokenTimeNeverSaysZeroHours() {
        let spoken = LiveZoneRow.spoken(seconds: [0, 540, 1380], locale: en)
        XCTAssertFalse(spoken.contains("hour"), spoken)
        XCTAssertTrue(spoken.contains("9 minutes"), spoken)
        XCTAssertTrue(spoken.contains("23 minutes"), spoken)
        XCTAssertTrue(spoken.contains("Rest 0 minutes"), spoken)
    }

    func testAZoneUnderAMinuteIsSpokenAsLessThanAMinute() {
        XCTAssertEqual(LiveZoneRow.spokenDuration(seconds: 40, locale: en), "less than a minute")
    }

    func testAnHourAndMinutesAreSpokenAsBoth() {
        let text = LiveZoneRow.spokenDuration(seconds: 3600 + 4 * 60, locale: en)
        XCTAssertTrue(text.contains("1 hour"), text)
        XCTAssertTrue(text.contains("4 minutes"), text)
    }

    func testTheRangeNamesWhereEachZoneStarts() {
        let thresholds = HRZoneStyle.Thresholds(rest: 94.5, steady: 131.5)
        XCTAssertEqual(LiveZoneRow.range(0, thresholds: thresholds), "<95")
        XCTAssertEqual(LiveZoneRow.range(1, thresholds: thresholds), "95–131")
        XCTAssertEqual(LiveZoneRow.range(2, thresholds: thresholds), "132+")
    }

    // MARK: Circles

    func testTheZoneRowIsOneLinePerZoneAtTheAccessibilitySizes() {
        XCTAssertGreaterThan(LiveZoneRow.height(scale: 1, accessibilitySize: true), LiveZoneRow.height(scale: 1, accessibilitySize: false))
        XCTAssertEqual(LiveZoneRow.height(scale: 0.5, accessibilitySize: false), LiveZoneRow.height(scale: 1, accessibilitySize: false) / 2)
    }

    func testTheCirclesShrinkAtTheAccessibilitySizes() {
        XCTAssertEqual(LiveCircleMetrics.diameter(accessibilitySize: false), 76)
        XCTAssertLessThan(LiveCircleMetrics.diameter(accessibilitySize: true), 76)
        XCTAssertEqual(LiveCircleMetrics.startDiameter(accessibilitySize: false), 88)
        XCTAssertGreaterThanOrEqual(LiveCircleMetrics.diameter(accessibilitySize: true), 44, "still a touch target")
    }
}
