import XCTest
@testable import StrandImport

final class ImportNumericSafetyTests: XCTestCase {
    func testIntegerConversionPreservesRoundingAndRejectsUnrepresentableValues() {
        XCTAssertEqual(ImportNumericSafety.integer(80.6, rounding: .toNearestOrAwayFromZero), 81)
        XCTAssertEqual(ImportNumericSafety.integer(80.6), 80)
        XCTAssertEqual(ImportNumericSafety.integer(-80.6), -80)
        XCTAssertEqual(ImportNumericSafety.integer(Double(Int.min)), Int.min)
        for value in [Double.nan, .infinity, -.infinity, Double(Int.max), 1e100, -1e100] {
            XCTAssertNil(ImportNumericSafety.integer(value))
        }
        XCTAssertNil(ImportNumericSafety.integer(nil))
    }

    func testWhoopCycleParsingRejectsUnrepresentableHeartRatesAndKeepsOtherValues() throws {
        let csv = """
        Cycle start time,Resting heart rate (bpm),Recovery score %,Average HR (bpm),Max HR (bpm)
        2026-10-20 08:00:00,1e100,78,80.6,1e100
        """
        let rows = WhoopExportImporter().parseCycles(CSVTable(data: Data(csv.utf8)))
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.restingHeartRate)
        XCTAssertNil(row.maxHeartRate)
        XCTAssertEqual(row.avgHeartRate, 80.6)
        XCTAssertEqual(row.recoveryScore, 78)
    }

    func testWhoopWorkoutParsingRejectsUnrepresentableHeartRates() throws {
        let csv = """
        Workout start time,Average HR (bpm),Max HR (bpm)
        2026-10-20 08:00:00,1e100,159.6
        """
        let rows = WhoopExportImporter().parseWorkouts(CSVTable(data: Data(csv.utf8)))
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.avgHeartRate)
        XCTAssertEqual(row.maxHeartRate, 159.6)
    }

    func testAppleInvalidReadingsDoNotPoisonValidDailyMeans() throws {
        for type in ["HeartRate", "RestingHeartRate", "WalkingHeartRateAverage"] {
            let samples = [Double.nan, .infinity, -.infinity, 1e100, 80.6].map { sample(type, value: $0) }
            let day = try XCTUnwrap(AppleHealthAggregator.daily(samples: samples).first)
            let value: Double?
            switch type {
            case "RestingHeartRate": value = day.restingHr
            case "WalkingHeartRateAverage": value = day.walkingHr
            default: value = day.avgHr; XCTAssertEqual(day.maxHr, 80.6)
            }
            XCTAssertEqual(value, 80.6)
        }
    }

    func testAppleStepTotalsRejectOverflowWithoutChangingValidSourceReduction() throws {
        let huge = Double(Int.max).nextDown
        let overflowing = try XCTUnwrap(AppleHealthAggregator.daily(samples: [
            sample("StepCount", value: huge), sample("StepCount", value: huge),
        ]).first)
        XCTAssertNil(overflowing.steps)

        let valid = try XCTUnwrap(AppleHealthAggregator.daily(samples: [
            sample("StepCount", value: .nan), sample("StepCount", value: 1e100),
            sample("StepCount", value: 1.5), sample("StepCount", value: 2.5),
        ]).first)
        XCTAssertEqual(valid.steps, 4)
    }

    private func sample(_ type: String, value: Double) -> HealthSample {
        let date = Date(timeIntervalSince1970: 1_792_454_400)
        return HealthSample(type: type, value: value, valueString: nil, unit: nil,
                            start: date, end: date, tzOffsetMin: 0, sourceName: "synthetic")
    }
}
