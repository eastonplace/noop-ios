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

    func testExtremaSamplerSortsAndDropsNonFiniteValues() {
        let points = [
            TrendPoint(date: Date(timeIntervalSince1970: 3), value: 30),
            TrendPoint(date: Date(timeIntervalSince1970: 1), value: .nan),
            TrendPoint(date: Date(timeIntervalSince1970: 2), value: 20),
            TrendPoint(date: Date(timeIntervalSince1970: 4), value: .infinity),
        ]

        let sampled = TrendPointExtremaSampler.sample(points, maximumCount: 30)

        XCTAssertEqual(sampled.map(\.value), [20, 30])
        XCTAssertEqual(sampled.map(\.date), sampled.map(\.date).sorted())
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
            revision: 42,
            anchorDay: "2026-07-22",
            timeZoneIdentifier: "America/New_York",
            canonicalDays: [day],
            sleepPerfByDay: [day.day: 84],
            stressByDay: [day.day: 1.2],
            appleDays: []
        )

        XCTAssertEqual(loaded.revision, 42)
        XCTAssertEqual(loaded.anchorDay, day.day)
        XCTAssertEqual(loaded.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(loaded.canonicalDays.map(\.day), [day.day])
        XCTAssertEqual(loaded.canonicalByDay[day.day], day)
        XCTAssertEqual(loaded.sleepPerfByDay[day.day], 84)
        XCTAssertEqual(loaded.stressByDay[day.day], 1.2)
        XCTAssertTrue(loaded.appleDays.isEmpty)
        XCTAssertTrue(loaded.appleByDay.isEmpty)
    }

    func testFourThousandDaySnapshotKeepsRenderInputsBounded() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 22
        )))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let days = (0..<4_000).compactMap { offset -> DailyMetric? in
            guard let date = calendar.date(byAdding: .day, value: offset - 3_999, to: anchor)
            else { return nil }
            return DailyMetric(
                day: formatter.string(from: date),
                totalSleepMin: 420,
                efficiency: 0.9,
                deepMin: 90,
                remMin: 110,
                lightMin: 200,
                disturbances: 6,
                restingHr: 52,
                avgHrv: 64,
                recovery: Double(offset % 100),
                strain: 9,
                exerciseCount: 1
            )
        }
        let loaded = TrendsLoadedData(
            revision: 7,
            anchorDay: "2026-07-22",
            timeZoneIdentifier: "UTC",
            canonicalDays: days,
            sleepPerfByDay: [:],
            stressByDay: [:],
            appleDays: []
        )
        let key = TrendsScreenSnapshotKey(
            revision: 7,
            anchorDay: "2026-07-22",
            timeZoneIdentifier: "UTC",
            metric: ProductionTrendMetric.recovery.rawValue,
            range: TrendRange.half.rawValue,
            weekOffset: 0
        )

        let snapshot = try XCTUnwrap(TrendsScreenSnapshot.build(
            key: key,
            data: loaded,
            metric: .recovery,
            range: .half,
            weekOffset: 0,
            referenceDate: anchor,
            calendar: calendar,
            effortDisplayFactor: 1
        ))

        XCTAssertEqual(snapshot.selectedCalendarDays.count, 180)
        XCTAssertEqual(snapshot.selectedPoints.count, 180)
        XCTAssertEqual(snapshot.currentSeries.recovery.count, 180)
        XCTAssertEqual(snapshot.previousSeries.recovery.count, 180)
        XCTAssertEqual(snapshot.heatDays.count, 35)
        XCTAssertEqual(snapshot.minimumWeekOffset, -520)
    }
}
