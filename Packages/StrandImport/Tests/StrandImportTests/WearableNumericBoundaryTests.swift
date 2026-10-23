import XCTest
@testable import StrandImport

final class WearableNumericBoundaryTests: XCTestCase {
    func testJSONBooleanScalarsStayAbsentWhileNumericZeroAndOneRemainNumbers() throws {
        let data = Data("{\"false\":false,\"true\":true,\"zero\":0,\"one\":1,\"decimal\":0.2}".utf8)
        let values = try XCTUnwrap(WearableJSON.object(data))
        for key in ["false", "true"] {
            XCTAssertNil(WearableJSON.dbl(values, key))
            XCTAssertNil(WearableJSON.int(values, key))
            XCTAssertNil(WearableJSON.posDbl(values, key))
            XCTAssertNil(WearableJSON.posInt(values, key))
        }
        XCTAssertEqual(WearableJSON.dbl(values, "zero"), 0)
        XCTAssertEqual(WearableJSON.int(values, "one"), 1)
        XCTAssertEqual(WearableJSON.dbl(values, "decimal"), 0.2)
    }

    func testOuraCSVNonfiniteFloatingMeasurementsAreAbsent() throws {
        for invalid in ["nan", "inf", "-inf"] {
            let csv = """
            day,steps,average_hrv,respiratory_rate,temperature_deviation,sleep_efficiency,total_sleep_duration,spo2_percentage,vo2_max,active_calories,total_calories,equivalent_walking_distance
            2026-06-01,8421,\(Array(repeating: invalid, count: 10).joined(separator: ","))
            """
            let parsed = WearableExportImporter.parse(brand: .oura, files: ["oura.csv": Data(csv.utf8)])
            let day = try XCTUnwrap(parsed.days.first)
            XCTAssertEqual(day.steps, 8421)
            XCTAssertNil(day.avgHrvMs)
            XCTAssertNil(day.respRateBpm)
            XCTAssertNil(day.skinTempDevC)
            XCTAssertNil(day.efficiencyPct)
            XCTAssertNil(day.totalSleepMin)
            XCTAssertNil(day.spo2Pct)
            XCTAssertNil(day.vo2max)
            XCTAssertNil(day.activeKcal)
            XCTAssertNil(day.totalKcal)
            XCTAssertNil(day.distanceM)
        }
    }

    func testCSVNumericHelperRejectsNonfiniteButPreservesFiniteNumbersAndTolerance() {
        for raw in ["nan", "inf", "-inf", "1e9999"] {
            XCTAssertNil(["value": raw].double("value"))
        }
        XCTAssertEqual(["value": "1e300"].double("value"), 1e300)
        XCTAssertEqual(["value": "-1e300"].double("value"), -1e300)
        XCTAssertEqual(["value": "0"].double("value"), 0)
        XCTAssertEqual(["value": "1,234"].double("value"), 1234)
        XCTAssertEqual(["value": "62 ms"].double("value"), 62)
    }

    func testOuraFiniteFloatingMagnitudesRemainSupported() throws {
        let csv = """
        day,steps,average_hrv,temperature_deviation
        2026-06-01,1e300,1e300,-1e300
        """
        let day = try XCTUnwrap(WearableExportImporter.parse(brand: .oura, files: ["oura.csv": Data(csv.utf8)]).days.first)
        XCTAssertNil(day.steps, "An unrepresentable integer stays absent")
        XCTAssertEqual(day.avgHrvMs, 1e300, "Finite floating semantics are unchanged")
        XCTAssertEqual(day.skinTempDevC, -1e300)
    }

    func testOuraCSVFiniteFloatingControlsAndObservedZeroTemperatureRemainValid() throws {
        let csv = """
        day,steps,average_hrv,respiratory_rate,temperature_deviation
        2026-06-01,8421,65,14.2,0
        2026-06-02,0,55,13.5,-0.2
        """
        let parsed = WearableExportImporter.parse(brand: .oura, files: ["oura.csv": Data(csv.utf8)])
        XCTAssertEqual(parsed.days.map(\.steps), [8421, 0])
        XCTAssertEqual(parsed.days.map(\.avgHrvMs), [65, 55])
        XCTAssertEqual(parsed.days.map(\.skinTempDevC), [0, -0.2])
    }
}
