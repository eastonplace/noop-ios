import XCTest
@testable import StrandAnalytics
import WhoopStore

final class AnalyticsNumericSafetyTests: XCTestCase {
    func testReadinessStatisticsIgnoreNonFiniteObservations() throws {
        XCTAssertEqual(try XCTUnwrap(ReadinessEngine.mean([2, .nan, .infinity, 4, 6])), 4)
        XCTAssertEqual(try XCTUnwrap(ReadinessEngine.sampleSD([2, .nan, 4, 6])), 2, accuracy: 1e-12)
        XCTAssertNil(ReadinessEngine.mean([.nan, .infinity]))
        XCTAssertNil(ReadinessEngine.sampleSD([2, .nan]))
    }

    func testTrainingLoadPrimingCannotOverflowForAcceptedFiniteLoads() throws {
        let load = Double.greatestFiniteMagnitude
        let result = TrainingLoadEngine.evaluateDense(Array(repeating: load, count: 14))
        XCTAssertTrue(result.isAvailable)
        XCTAssertEqual(try XCTUnwrap(result.ctl), load)
        XCTAssertEqual(try XCTUnwrap(result.atl), load)
        XCTAssertEqual(try XCTUnwrap(result.tsb), 0)
        XCTAssertTrue(result.points.allSatisfy {
            $0.chronicLoad.isFinite && $0.acuteLoad.isFinite && $0.balance.isFinite
        })
    }

    func testReadinessOmitsNonFiniteCurrentHRVWithoutFormattingIt() {
        let rows = (1...15).map { day in
            metric(day: day, hrv: day == 15 ? .infinity : Double(58 + day % 3))
        }
        let result = ReadinessEngine.evaluate(days: rows)
        XCTAssertFalse(result.signals.contains { $0.key == "hrv" })
    }

    func testReadinessFormatsLargeFiniteHRVWithoutIntegerTrap() {
        let rows = (1...15).map { day in
            metric(day: day, hrv: day == 15 ? Double(Int.max) : Double(58 + day % 3))
        }
        let result = ReadinessEngine.evaluate(days: rows)
        XCTAssertNotNil(result.signals.first { $0.key == "hrv" })
    }

    private func metric(day: Int, hrv: Double) -> DailyMetric {
        DailyMetric(day: String(format: "2026-10-%02d", day), totalSleepMin: nil, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                    avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil)
    }
}
