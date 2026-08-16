
import XCTest
@testable import NOOP

final class WidgetPublicationIssue44Tests: XCTestCase {
    func testHRVEnrichmentPublishesScalarAndBoundedSparkline() {
        let series: [(day: String, value: Double)] = [
            ("2026-08-12", 62.2),
            ("2026-08-13", .nan),
            ("2026-08-14", 64.8),
            ("2026-08-15", 900),
            ("2026-08-16", 67.2),
        ]

        let projection = WidgetSnapshot.widgetHRVProjection(from: series)

        XCTAssertEqual(projection.current, 67)
        XCTAssertEqual(projection.sparkline, [62, 65, 67])
    }

    func testMissingHRVDoesNotEraseOtherHeadlineValues() {
        var snapshot = WidgetSnapshot(
            recovery: 81,
            bpm: nil,
            batteryPct: nil,
            bonded: true,
            updated: Date(),
            effort: 9.4,
            hrv: nil
        )
        let projection = WidgetSnapshot.widgetHRVProjection(from: [])
        snapshot.hrv = projection.current
        snapshot.hrvSparkline = projection.sparkline

        XCTAssertEqual(snapshot.recovery, 81)
        XCTAssertEqual(snapshot.strain, 9.4)
        XCTAssertNil(snapshot.hrv)
    }
}
