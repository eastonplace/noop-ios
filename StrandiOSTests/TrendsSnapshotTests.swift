import XCTest
import StrandDesign
import WhoopStore
@testable import NOOP

final class TrendsSnapshotTests: XCTestCase {
    func testExtremaSamplerKeepsEndpointsSpikeAndTrough() {
        var points = (0..<1_000).map { index in
            TrendPoint(
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                value: 60
            )
        }
        points[250] = TrendPoint(
            date: Date(timeIntervalSince1970: 250),
            value: 5
        )
        points[750] = TrendPoint(
            date: Date(timeIntervalSince1970: 750),
            value: 99
        )

        let sampled = TrendPointExtremaSampler.sample(points, maximumCount: 30)

        XCTAssertLessThanOrEqual(sampled.count, 30)
        XCTAssertEqual(sampled.first?.date, points.first?.date)
        XCTAssertEqual(sampled.last?.date, points.last?.date)
        XCTAssertTrue(sampled.contains { $0.value == 5 })
        XCTAssertTrue(sampled.contains { $0.value == 99 })
        XCTAssertEqual(sampled.map(\.date), sampled.map(\.date).sorted())
    }

    func testExtremaSamplerLeavesShortSeriesUntouched() {
        let points = (0..<8).map { index in
            TrendPoint(
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                value: Double(index)
            )
        }
        XCTAssertEqual(
            TrendPointExtremaSampler.sample(points, maximumCount: 30).map(\.value),
            points.map(\.value)
        )
    }

    func testLoadedDataKeepsOneCanonicalRevisionAndAuxiliaryMaps() {
        let day = DailyMetric(
            day: "2026-07-22",
            totalSleepMin: 420,
            efficiency: 0.9,
            deepMin: 90,
            remMin: 110,
            lightMin: 200,
            disturbances: 6,
            restingHr: 52,
            avgHrv: 64,
            recovery: 78,
            strain: 9,
            exerciseCount: 1
        )
        let loaded = TrendsLoadedData(
            canonicalDays: [day],
            sleepPerfByDay: [day.day: 84],
            stressByDay: [day.day: 1.2],
            appleDays: []
        )

        XCTAssertEqual(loaded.canonicalDays.map(\.day), [day.day])
        XCTAssertEqual(loaded.sleepPerfByDay[day.day], 84)
        XCTAssertEqual(loaded.stressByDay[day.day], 1.2)
        XCTAssertTrue(loaded.appleDays.isEmpty)
        XCTAssertTrue(loaded.appleByDay.isEmpty)
    }
}
