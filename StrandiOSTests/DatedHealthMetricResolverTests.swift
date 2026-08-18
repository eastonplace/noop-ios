import XCTest
@testable import NOOP
import WhoopStore

final class DatedHealthMetricResolverTests: XCTestCase {
    private func metric(day: String, skin: Double?) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: nil,
            efficiency: nil,
            deepMin: nil,
            remMin: nil,
            lightMin: nil,
            disturbances: nil,
            restingHr: nil,
            avgHrv: nil,
            recovery: nil,
            strain: nil,
            exerciseCount: nil,
            skinTempDevC: skin
        )
    }

    func testNewestRecentValueCarriesDayAgeAndSource() {
        let rows = [
            SourcedDailyMetric(metric: metric(day: "2026-08-10", skin: 0.2), source: .whoopImport),
            SourcedDailyMetric(metric: metric(day: "2026-08-15", skin: 0.4), source: .noopComputed)
        ]

        let value = DatedHealthMetricResolver.skinTemperature(
            rows: rows, targetDay: "2026-08-16", maximumAgeDays: 7
        )

        XCTAssertEqual(value?.day, "2026-08-15")
        XCTAssertEqual(value?.ageDays, 1)
        XCTAssertEqual(value?.value, 0.4)
        XCTAssertEqual(value?.source, .noopComputed)
        XCTAssertEqual(value?.freshness, .recent)
    }

    func testSkinTemperatureAgeLabelsShowOnlyCarriedValues() {
        XCTAssertNil(TodayView.skinTemperatureAgeLabel(ageDays: 0))
        XCTAssertEqual(TodayView.skinTemperatureAgeLabel(ageDays: 1), "1d ago")
        XCTAssertEqual(TodayView.skinTemperatureAgeLabel(ageDays: 2), "2d ago")
        XCTAssertEqual(TodayView.skinTemperatureAgeLabel(ageDays: 7), "7d ago")
    }

    func testFreshnessIncludesSevenLogicalDaysAndRejectsEight() {
        let sevenDaysOld = DatedHealthMetricResolver.skinTemperature(
            rows: [SourcedDailyMetric(metric: metric(day: "2026-08-09", skin: 0.4), source: .whoopImport)],
            targetDay: "2026-08-16",
            maximumAgeDays: 7
        )
        let eightDaysOld = DatedHealthMetricResolver.skinTemperature(
            rows: [SourcedDailyMetric(metric: metric(day: "2026-08-08", skin: 0.4), source: .whoopImport)],
            targetDay: "2026-08-16",
            maximumAgeDays: 7
        )

        XCTAssertEqual(sevenDaysOld?.ageDays, 7)
        XCTAssertEqual(sevenDaysOld?.freshness, .recent)
        XCTAssertNil(eightDaysOld)
    }

    func testPresentationUsesOneIdentityForCurrentAndHistory() {
        let rows = [
            SourcedDailyMetric(metric: metric(day: "2026-08-10", skin: 34.4), source: .whoopImport),
            SourcedDailyMetric(metric: metric(day: "2026-08-14", skin: 0.2), source: .whoopImport),
            SourcedDailyMetric(metric: metric(day: "2026-08-15", skin: 0.3), source: .whoopImport)
        ]

        let presentation = DatedHealthMetricResolver.skinTemperaturePresentation(
            rows: rows, targetDay: "2026-08-16"
        )

        XCTAssertEqual(presentation?.current.day, "2026-08-15")
        XCTAssertEqual(presentation?.current.ageDays, 1)
        XCTAssertEqual(presentation?.history, [0.2, 0.3])
    }

    func testSameDayWhoopImportWinsOverComputedAndAppleHealthIsExcluded() {
        let rows = [
            SourcedDailyMetric(metric: metric(day: "2026-08-16", skin: 0.8), source: .noopComputed),
            SourcedDailyMetric(metric: metric(day: "2026-08-16", skin: 0.3), source: .whoopImport),
            SourcedDailyMetric(metric: metric(day: "2026-08-16", skin: 34.5), source: .appleHealth)
        ]

        let value = DatedHealthMetricResolver.skinTemperature(
            rows: rows, targetDay: "2026-08-16", maximumAgeDays: 7
        )

        XCTAssertEqual(value?.value, 0.3)
        XCTAssertEqual(value?.source, .whoopImport)
        XCTAssertEqual(value?.freshness, .current)
    }

    func testFutureAndStaleRowsDoNotResolve() {
        let future = DatedHealthMetricResolver.skinTemperature(
            rows: [SourcedDailyMetric(metric: metric(day: "2026-08-17", skin: 0.5), source: .whoopImport)],
            targetDay: "2026-08-16",
            maximumAgeDays: 7
        )
        let stale = DatedHealthMetricResolver.skinTemperaturePresentation(
            rows: [SourcedDailyMetric(metric: metric(day: "2026-08-01", skin: 0.5), source: .whoopImport)],
            targetDay: "2026-08-16",
            maximumAgeDays: 7
        )

        XCTAssertNil(future)
        XCTAssertNil(stale)
    }

    func testHistoryDoesNotMixAbsoluteAndDeviationRepresentations() {
        let rows = [
            SourcedDailyMetric(metric: metric(day: "2026-08-10", skin: 34.4), source: .whoopImport),
            SourcedDailyMetric(metric: metric(day: "2026-08-11", skin: 0.2), source: .whoopImport),
            SourcedDailyMetric(metric: metric(day: "2026-08-12", skin: 0.3), source: .whoopImport)
        ]

        XCTAssertEqual(
            DatedHealthMetricResolver.skinTemperatureHistory(
                rows: rows, targetDay: "2026-08-12"
            ),
            [0.2, 0.3]
        )
    }
}
