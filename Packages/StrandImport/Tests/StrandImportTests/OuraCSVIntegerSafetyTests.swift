import XCTest
@testable import StrandImport

final class OuraCSVIntegerSafetyTests: XCTestCase {
    private func parse(_ values: String) -> WearableDailyRow? {
        let csv = """
        date,steps,average_resting_heart_rate,readiness_score,sleep_score,temperature_deviation
        2026-06-01,\(values),0.2
        """
        return WearableExportImporter.parse(brand: .oura, files: ["oura.csv": Data(csv.utf8)]).days.first
    }

    func testOutOfRangeAndNonfiniteCSVIntegerFieldsAreDroppedWithoutTrapping() throws {
        for invalid in ["1e300", "inf", "nan", "-inf", "-1"] {
            let row = try XCTUnwrap(parse(Array(repeating: invalid, count: 4).joined(separator: ",")))
            XCTAssertNil(row.steps)
            XCTAssertNil(row.restingHr)
            XCTAssertNil(row.readinessScore)
            XCTAssertNil(row.sleepScore)
            XCTAssertEqual(row.skinTempDevC, 0.2, "A malformed integer must not discard valid sibling measurements")
        }
    }

    func testValidCountsAndScoresKeepExistingSentinelRules() throws {
        let row = try XCTUnwrap(parse("8421,48,81,84"))
        XCTAssertEqual(row.steps, 8421)
        XCTAssertEqual(row.restingHr, 48)
        XCTAssertEqual(row.readinessScore, 81)
        XCTAssertEqual(row.sleepScore, 84)
        let zero = try XCTUnwrap(parse("0,0,0,0"))
        XCTAssertEqual(zero.steps, 0)
        XCTAssertNil(zero.restingHr)
        XCTAssertNil(zero.readinessScore)
        XCTAssertNil(zero.sleepScore)
    }

    func testBareCategoryScoresRejectUnrepresentableCSVValues() throws {
        for (signals, value) in [("temperature_deviation", "0.2"), ("contributors", "{}") ] {
            let csv = """
            day,score,\(signals)
            2026-06-01,1e300,\(value)
            """
            let row = try XCTUnwrap(WearableExportImporter.parse(
                brand: .oura, files: ["oura.csv": Data(csv.utf8)]).days.first)
            XCTAssertNil(row.readinessScore)
            XCTAssertNil(row.sleepScore)
        }
    }

    func testLargeRepresentableCSVCountsAndNegativeFractionsDoNotTrap() throws {
        let large = try XCTUnwrap(parse("9000000000000000000,48,81,84"))
        XCTAssertEqual(large.steps, 9_000_000_000_000_000_000)
        let negative = try XCTUnwrap(parse("-0.5,48,81,84"))
        XCTAssertNil(negative.steps)
    }
}
