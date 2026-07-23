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

    func testSnapshotHandoffRejectsRapidMetricChanges() {
        let old = key(metric: "Recovery")
        let current = key(metric: "HRV")

        XCTAssertFalse(TrendsSnapshotHandoff.accepts(snapshotKey: old, currentKey: current))
        XCTAssertTrue(TrendsSnapshotHandoff.accepts(snapshotKey: current, currentKey: current))
    }

    func testSnapshotHandoffRejectsRapidRangeChanges() {
        let ranges = ["W", "M", "3M", "6M"]
        for oldRange in ranges {
            for currentRange in ranges where currentRange != oldRange {
                XCTAssertFalse(TrendsSnapshotHandoff.accepts(
                    snapshotKey: key(range: oldRange),
                    currentKey: key(range: currentRange)
                ))
            }
        }
    }

    func testSnapshotHandoffRejectsRapidWeeklyReviewNavigation() {
        XCTAssertFalse(TrendsSnapshotHandoff.accepts(
            snapshotKey: key(weekOffset: -3),
            currentKey: key(weekOffset: -1)
        ))
        XCTAssertTrue(TrendsSnapshotHandoff.accepts(
            snapshotKey: key(weekOffset: -1),
            currentKey: key(weekOffset: -1)
        ))
    }

    func testSnapshotHandoffRejectsRepositoryRevisionWhileBuildIsSuspended() {
        XCTAssertFalse(TrendsSnapshotHandoff.accepts(
            snapshotKey: key(revision: 41),
            currentKey: key(revision: 42)
        ))
    }

    func testOldCompletionCannotReplaceNewerSnapshotKey() {
        let oldCompletion = key(revision: 7, metric: "Recovery", range: "M", weekOffset: 0)
        let newerSelection = key(revision: 8, metric: "HRV", range: "6M", weekOffset: -2)
        var renderedKey: TrendsScreenSnapshotKey?

        if TrendsSnapshotHandoff.accepts(snapshotKey: newerSelection, currentKey: newerSelection) {
            renderedKey = newerSelection
        }
        if TrendsSnapshotHandoff.accepts(snapshotKey: oldCompletion, currentKey: newerSelection) {
            renderedKey = oldCompletion
        }

        XCTAssertEqual(renderedKey, newerSelection)
    }

    func testSnapshotHandoffRejectsNilDuringFirstOrReplacementBuild() {
        XCTAssertFalse(TrendsSnapshotHandoff.accepts(
            snapshotKey: nil,
            currentKey: key()
        ))
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

    func testTrendSummaryDropsNonFiniteValuesAndSortsLatestChronologically() throws {
        let presentation = TrendSummaryPresentation(
            series: [
                TrendPoint(date: Date(timeIntervalSince1970: 3), value: 30),
                TrendPoint(date: Date(timeIntervalSince1970: 1), value: .nan),
                TrendPoint(date: Date(timeIntervalSince1970: 2), value: 20),
                TrendPoint(date: Date(timeIntervalSince1970: 4), value: .infinity),
            ],
            previousSeries: [
                TrendPoint(date: Date(timeIntervalSince1970: 2), value: 18),
                TrendPoint(date: Date(timeIntervalSince1970: 1), value: -.infinity),
                TrendPoint(date: Date(timeIntervalSince1970: 3), value: 22),
            ],
            goodDirection: .higher,
            expectedCount: 2
        )

        XCTAssertEqual(presentation.source.map(\.value), [20, 30])
        XCTAssertEqual(presentation.currentCount, 2)
        XCTAssertEqual(presentation.previousCount, 2)
        XCTAssertEqual(presentation.latest, 30)
        XCTAssertEqual(try XCTUnwrap(presentation.delta), 5, accuracy: 0.0001)
    }

    func testSnapshotDropsNonFiniteMetricValuesBeforeBuildingRanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 22
        )))
        let day = DailyMetric(
            day: "2026-07-22",
            totalSleepMin: 420,
            efficiency: 0.9,
            deepMin: 90,
            remMin: 110,
            lightMin: 200,
            disturbances: 6,
            restingHr: 52,
            avgHrv: .infinity,
            recovery: .nan,
            strain: 9,
            exerciseCount: 1
        )
        let loaded = TrendsLoadedData(
            revision: 9,
            anchorDay: day.day,
            timeZoneIdentifier: "UTC",
            canonicalDays: [day],
            sleepPerfByDay: [day.day: .infinity],
            stressByDay: [day.day: .nan],
            appleDays: []
        )
        let snapshot = try XCTUnwrap(TrendsScreenSnapshot.build(
            key: key(revision: 9),
            data: loaded,
            metric: .recovery,
            range: .week,
            weekOffset: 0,
            referenceDate: anchor,
            calendar: calendar,
            effortDisplayFactor: .nan
        ))

        XCTAssertTrue(snapshot.selectedPoints.isEmpty)
        XCTAssertTrue(snapshot.currentSeries.recovery.isEmpty)
        XCTAssertTrue(snapshot.currentSeries.hrv.isEmpty)
        XCTAssertTrue(snapshot.baseline.isFinite)
        XCTAssertTrue(snapshot.typical.lowerBound.isFinite)
        XCTAssertTrue(snapshot.typical.upperBound.isFinite)
    }

    func testMetricFormatterFailsClosedForNonFiniteValues() {
        XCTAssertEqual(ProductionTrendMetric.recovery.format(.nan), "—")
        XCTAssertEqual(ProductionTrendMetric.sleepDuration.format(.infinity), "—")
        XCTAssertEqual(ProductionTrendMetric.hrv.formatWithUnit(-.infinity), "—")
    }

    private func key(
        revision: Int = 7,
        metric: String = "Recovery",
        range: String = "M",
        weekOffset: Int = 0
    ) -> TrendsScreenSnapshotKey {
        TrendsScreenSnapshotKey(
            revision: revision,
            anchorDay: "2026-07-22",
            timeZoneIdentifier: "America/New_York",
            metric: metric,
            range: range,
            weekOffset: weekOffset
        )
    }
}
