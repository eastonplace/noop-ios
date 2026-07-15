import XCTest
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore
@testable import Strand

/// T031's checked-in pre-adoption oracle. The fixed dates and compact values are a
/// deterministic projection of the standard Apple demo seed, so this catches engine
/// drift without depending on the simulator clock, locale, repository, or UI state.
final class DesignLabEngineFreezeTests: XCTestCase {
    func testStandardFixtureKeepsSleepStressTotalsAndTrendOutputsFrozen() throws {
        let days = Self.standardSleepDays

        // SleepModel consumes these resolved engine values. Keep the exact usable-day
        // ordering, composites, duration trend, need floor, and debt ledger frozen.
        let composites = days.compactMap { AnalyticsEngine.Rest.composite(daily: $0) }
        XCTAssertEqual(composites.count, 4)
        XCTAssertEqual(composites[0], 84.46, accuracy: 1e-12)
        XCTAssertEqual(composites[1], 87.88, accuracy: 1e-12)
        XCTAssertEqual(composites[2], 91.67, accuracy: 1e-12)
        XCTAssertEqual(composites[3], 77.72, accuracy: 1e-12)

        let durationTrend = days.compactMap { day -> TrendPoint? in
            guard let minutes = day.totalSleepMin, minutes > 0,
                  let date = Self.dayParser.date(from: day.day) else { return nil }
            return TrendPoint(date: date, value: minutes / 60.0)
        }
        XCTAssertEqual(durationTrend.map { Int($0.date.timeIntervalSince1970) },
                       [1_783_641_600, 1_783_814_400, 1_783_900_800, 1_783_987_200])
        XCTAssertEqual(durationTrend.map(\.value), [7.0, 7.5, 8.0, 6.5])

        let usableMinutes = days.compactMap(\.totalSleepMin)
        let typicalSleepMinutes = usableMinutes.reduce(0, +) / Double(usableMinutes.count)
        // SleepModel's existing personal-need floor is 7.5 h (450 min), intentionally
        // distinct from Rest.defaultNeedHours. Freeze that exact screen-model rule.
        let needMinutes = max(450, typicalSleepMinutes)
        XCTAssertEqual(typicalSleepMinutes, 435, accuracy: 1e-12)
        XCTAssertEqual(needMinutes, 450, accuracy: 1e-12)

        let debt = SleepDebt.ledger(
            series: days.map { ($0.day, $0.totalSleepMin) },
            needHours: needMinutes / 60
        )
        XCTAssertEqual(debt.needMin, 450, accuracy: 1e-12)
        XCTAssertEqual(debt.nights.map(\.deltaMin), [-30, 0, 30, -60])
        XCTAssertEqual(debt.balanceMin, -60, accuracy: 1e-12)
        XCTAssertEqual(debt.nightCount, 4)

        let daytime = DaytimeStress.analyze(hr: Self.standardStressHR, rr: [])
        XCTAssertEqual(daytime.hours.map(\.hour), [6, 7, 8, 9, 10, 11])
        XCTAssertEqual(daytime.hours.map(\.startTs),
                       [21_600, 25_200, 28_800, 32_400, 36_000, 39_600])
        let levels = try daytime.hours.map { try XCTUnwrap($0.level) }
        let expectedLevels = [
            1.405006669849105, 1.4809768942822985, 1.557044852321287,
            2.1868219618210487, 2.5747938217158985, 2.7747665734538862,
        ]
        XCTAssertEqual(levels.count, expectedLevels.count)
        for (actual, expected) in zip(levels, expectedLevels) {
            XCTAssertEqual(actual, expected, accuracy: 1e-9)
        }
        XCTAssertEqual(try XCTUnwrap(daytime.dayMean), 1.9965684622405873, accuracy: 1e-9)
        XCTAssertEqual(daytime.peak?.hour, 11)
        XCTAssertTrue(daytime.sustainedHigh)
        XCTAssertEqual(daytime.sustainedRun, 3)

        let totals = StressTotals(hours: daytime.hours)
        XCTAssertEqual(totals.calmHours, 0)
        XCTAssertEqual(totals.moderateHours, 3)
        XCTAssertEqual(totals.highHours, 3)
        XCTAssertEqual(totals.total, 6)
        XCTAssertEqual(totals.fraction(.low), 0, accuracy: 1e-12)
        XCTAssertEqual(totals.fraction(.medium), 0.5, accuracy: 1e-12)
        XCTAssertEqual(totals.fraction(.high), 0.5, accuracy: 1e-12)
    }

    private static let standardSleepDays: [DailyMetric] = [
        day("2026-07-10", total: 420, efficiency: 86, deep: 70, rem: 95, light: 255),
        day("2026-07-11", total: nil, efficiency: nil, deep: nil, rem: nil, light: nil),
        day("2026-07-12", total: 450, efficiency: 91, deep: 80, rem: 100, light: 270),
        day("2026-07-13", total: 480, efficiency: 94, deep: 90, rem: 110, light: 280),
        day("2026-07-14", total: 390, efficiency: 82, deep: 45, rem: 80, light: 265),
    ]

    private static func day(_ key: String, total: Double?, efficiency: Double?,
                            deep: Double?, rem: Double?, light: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: total, efficiency: efficiency,
                    deepMin: deep, remMin: rem, lightMin: light,
                    disturbances: nil, restingHr: nil, avgHrv: nil,
                    recovery: nil, strain: nil, exerciseCount: nil)
    }

    private static let standardStressHR: [HRSample] = {
        [58, 60, 62, 80, 96, 110].enumerated().flatMap { index, bpm in
            let hourStart = (index + 6) * DaytimeStress.bucketSeconds
            return (0..<DaytimeStress.minHourHRSamples).map {
                HRSample(ts: hourStart + $0, bpm: bpm)
            }
        }
    }()

    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
