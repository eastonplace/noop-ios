import XCTest
@testable import StrandAnalytics

final class ComparePearsonParityTests: XCTestCase {
    func testCompareUsesEnginePearsonOnDayAlignedRows() throws {
        let a = [
            (day: "2026-07-17", value: 1.0),
            (day: "2026-07-18", value: 2.0),
            (day: "2026-07-19", value: 3.0),
            (day: "2026-07-20", value: 99.0),
        ]
        let b = [
            (day: "2026-07-17", value: 6.0),
            (day: "2026-07-18", value: 4.0),
            (day: "2026-07-19", value: 2.0),
            (day: "2026-07-16", value: -100.0),
        ]

        let aligned = CorrelationEngine.alignByDay(a, b)
        let result = try XCTUnwrap(CorrelationEngine.pearson(aligned))

        XCTAssertEqual(result.n, 3)
        XCTAssertEqual(result.r, -1, accuracy: 1e-12)
        XCTAssertEqual(result.slope, -2, accuracy: 1e-12)
    }
}
