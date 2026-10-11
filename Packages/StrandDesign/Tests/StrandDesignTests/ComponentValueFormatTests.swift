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

    /// A label and the band that colours it must read the same number: 66.5 is "67" and green, 24.5 is "25" and Low
    /// (not Depleted), 33.5 is "34" and yellow. The formatter's own default rounds half to even and said "66".
    func testRecoveryLabelAndBandAgreeOnHalfPoints() {
        let cases: [(score: Double, label: String, band: RecoveryBand)] = [
            (66.5, "67", .high), (66.49, "66", .medium),
            (33.5, "34", .medium), (33.49, "33", .low),
            (24.5, "25", .low), (0.5, "1", .low), (99.5, "100", .high),
        ]
        for item in cases {
            XCTAssertEqual(ComponentValueFormat.rounded(item.score), item.label, "label of \(item.score)")
            XCTAssertEqual(RecoveryBands.band(for: item.score), item.band, "band of \(item.score)")
        }
        XCTAssertEqual(RecoveryBands.word(for: 24.5), String(localized: "Low", bundle: .module))
        XCTAssertEqual(RecoveryBands.word(for: 24.4), String(localized: "Depleted", bundle: .module))
    }

    /// The trend line changes colour at the raw cut points, and each side of an edge is its own band.
    func testRecoveryRawCutPointsSitWhereTheBandChanges() {
        XCTAssertEqual(RecoveryBands.rawCutPoints, [33.5, 66.5])
        let sides: [(RecoveryBand, RecoveryBand)] = [(.low, .medium), (.medium, .high)]
        for (cut, pair) in zip(RecoveryBands.rawCutPoints, sides) {
            XCTAssertEqual(RecoveryBands.band(for: cut - 0.01), pair.0)
            XCTAssertEqual(RecoveryBands.band(for: cut), pair.1)
        }
        XCTAssertNotEqual(RecoveryBands.color(of: .low), RecoveryBands.color(of: .medium))
        XCTAssertNotEqual(RecoveryBands.color(of: .medium), RecoveryBands.color(of: .high))
    }
}
