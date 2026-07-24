import SwiftUI
import XCTest
@testable import StrandDesign

final class ComponentValueFormatTests: XCTestCase {
    func testPublicChartDefaultsRejectNonFiniteValuesWithoutIntegerConversion() {
        let timeline = HRTimelineChart(
            points: [],
            day: 0...1,
            timeLabel: { _ in "" }
        )
        let now = Date()
        let panel = TrendPanelChart(
            days: [],
            dateDomain: now...now,
            referenceDate: now,
            baseline: 0,
            typical: -1...1,
            tint: .blue,
            unit: "",
            range: .week
        )
        let heat = TrendMonthHeat(days: [], tint: .blue)
        let weekdays = TrendWeekdayBars(values: [], tint: .blue)
        let overview = OverviewHRChart(points: [])

        for format in [timeline.valueFormat, panel.valueFormat, heat.valueFormat, weekdays.valueFormat, overview.valueFormat] {
            XCTAssertEqual(format(.nan), "—")
            XCTAssertEqual(format(.infinity), "—")
            XCTAssertFalse(format(Double(Int.max)).isEmpty)
        }
    }
}
