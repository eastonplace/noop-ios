import Foundation
import XCTest
import NoopPhase34Core
import WhoopStore
@testable import NOOP

/// Root-cause fixes for the Home Screen widgets that went stale while Recovery and Sleep stayed fresh
/// (HRV, Resting HR, Steps, Stress). Each section is the regression test of one fix.
@MainActor
final class WidgetStalenessTests: XCTestCase {
    // MARK: - M4: HRV is the nightly RMSSD Today shows (daily_metrics.avgHrv)

    private func night(_ day: String, hrv: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: hrv,
                    recovery: nil, strain: nil, exerciseCount: nil)
    }

    /// The strap pipeline writes HRV to `daily_metrics.avgHrv` and never to the `hrv` metric series, which only
    /// file importers fill. The widget read the series, so it froze on an old import (or showed a dash).
    func testHRVEnrichmentReadsTheDailyAvgHrvTodayShows() async throws {
        let store = try await WhoopStore.inMemory()
        let anchor = try CivilDay(key: "2026-08-08")
        // Today's strap night, computed under the strap's "-noop" namespace.
        try await store.upsertDailyMetrics([night("2026-08-08", hrv: 58)], deviceId: "strap-noop")
        // An old file import sits in the metric series, twenty days back.
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-07-19", key: "hrv", value: 44),
        ], deviceId: "strap")
        // Apple's HRV is SDNN, a different quantity (DL-11); it is not a source of the namespace.
        try await store.upsertDailyMetrics([night("2026-08-08", hrv: 33)], deviceId: "apple-health")

        let series = try await WidgetSnapshot.verifiedHRVSeries(
            store: store, sourceIds: ["strap", "strap-noop"], anchorDay: anchor)

        XCTAssertEqual(series.map(\.day), ["2026-08-08"])
        XCTAssertEqual(WidgetSnapshot.widgetHRVProjection(from: series).current, 58)
    }

    func testHRVEnrichmentIsEmptyWhenNoDailyHrvExists() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-08-07", key: "hrv", value: 44),
        ], deviceId: "strap")
        let series = try await WidgetSnapshot.verifiedHRVSeries(
            store: store, sourceIds: ["strap", "strap-noop"], anchorDay: CivilDay(key: "2026-08-08"))
        XCTAssertTrue(series.isEmpty)
        XCTAssertNil(WidgetSnapshot.widgetHRVProjection(from: series).current)
    }

    /// Imported WHOOP beats the strap's computed night field by field, exactly as `Repository.mergeDaily`
    /// resolves Today's row; a night the import lacks is filled from the computed row.
    func testHRVEnrichmentFollowsTheTodayMergePrecedencePerDay() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDailyMetrics([
            night("2026-08-07", hrv: 70), night("2026-08-08", hrv: nil),
        ], deviceId: "strap")
        try await store.upsertDailyMetrics([
            night("2026-08-07", hrv: 41), night("2026-08-08", hrv: 62),
        ], deviceId: "strap-noop")

        let series = try await WidgetSnapshot.verifiedHRVSeries(
            store: store, sourceIds: ["strap", "strap-noop"], anchorDay: CivilDay(key: "2026-08-08"))

        XCTAssertEqual(series.map(\.day), ["2026-08-07", "2026-08-08"])
        XCTAssertEqual(series.map(\.value), [70, 62])
    }

    /// Until tonight's sleep is scored the anchor day has no HRV. Today carries the last night for two days
    /// and then relabels it; the widget has no label, so it uses the same window as a hard limit.
    func testHRVScalarCarriesThePriorNightOnlyInsideTodaysWindow() throws {
        let anchor = try CivilDay(key: "2026-08-08")
        func current(_ days: [(String, Double)]) -> Int? {
            WidgetSnapshot.widgetHRVProjection(
                from: days.map { (day: $0.0, value: $0.1) }, anchorDay: anchor).current
        }
        XCTAssertEqual(current([("2026-08-07", 61), ("2026-08-08", 64)]), 64,
                       "today's own night wins")
        XCTAssertEqual(current([("2026-08-07", 61)]), 61, "last night stands in until today is scored")
        XCTAssertEqual(current([("2026-08-06", 60)]), 60, "two nights back is still inside Today's window")
        XCTAssertNil(current([("2026-08-05", 60)]), "three nights back is a stale value, never today's")
        XCTAssertNil(current([("2026-07-19", 44)]))
        // The sparkline keeps the history either way.
        let spark = WidgetSnapshot.widgetHRVProjection(
            from: [(day: "2026-07-19", value: 44), (day: "2026-08-07", value: 61)], anchorDay: anchor).sparkline
        XCTAssertEqual(spark, [44, 61])
    }

    func testCarryWindowMatchesTodaysFreshnessCap() {
        XCTAssertEqual(CarriedVitalWindow.maximumAgeDays, TodayView.carryFreshnessDays)
        XCTAssertTrue(CarriedVitalWindow.permits(day: "2026-08-08", anchorDay: "2026-08-08"))
        XCTAssertTrue(CarriedVitalWindow.permits(day: "2026-08-06", anchorDay: "2026-08-08"))
        XCTAssertFalse(CarriedVitalWindow.permits(day: "2026-08-05", anchorDay: "2026-08-08"))
        XCTAssertFalse(CarriedVitalWindow.permits(day: "2026-08-09", anchorDay: "2026-08-08"), "never a future day")
        XCTAssertFalse(CarriedVitalWindow.permits(day: "not-a-day", anchorDay: "2026-08-08"))
        // Across a month and a year boundary.
        XCTAssertTrue(CarriedVitalWindow.permits(day: "2025-12-31", anchorDay: "2026-01-02"))
        XCTAssertFalse(CarriedVitalWindow.permits(day: "2025-12-30", anchorDay: "2026-01-02"))
    }
}
