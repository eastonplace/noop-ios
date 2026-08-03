import XCTest
import WhoopStore
@testable import NOOP

/// Focused UI policy coverage for the durable Today first-paint handoff.
final class TodayFirstPaintSemanticsTests: XCTestCase {
    private func metric(_ value: Double, day: String, algorithm: String = "test",
                        observedAt: Int? = nil, rawFrontierTs: Int? = nil) -> TodayHealthMetricValue {
        TodayHealthMetricValue(value: value, metricDay: day, sourceId: "my-whoop-noop",
                               observedAt: observedAt, rawFrontierTs: rawFrontierTs,
                               algorithmVersion: algorithm,
                               strainVersion: algorithm == "strain-v2" ? 2 : nil)
    }

    private func snapshot(day: String, recovery: TodayHealthMetricValue? = nil,
                          strain: TodayHealthMetricValue? = nil, sleep: TodayHealthMetricValue? = nil,
                          generatedAt: Int = 1, rawFrontierTs: Int? = nil) -> TodayHealthSnapshot {
        TodayHealthSnapshot(
            scopeId: "dashboard:test", deviceId: "my-whoop", displayDay: day,
            logicalDay: day, localDay: day, generatedAt: generatedAt, rawFrontierTs: rawFrontierTs,
            schemaVersion: 2,
            dailyMetric: DailyMetric(day: day, totalSleepMin: nil, efficiency: nil,
                                     deepMin: nil, remMin: nil, lightMin: nil,
                                     disturbances: nil, restingHr: nil, avgHrv: nil,
                                     recovery: recovery?.value, strain: strain?.value,
                                     exerciseCount: nil,
                                     strainVersion: strain?.strainVersion),
            recovery: recovery, strain: strain, sleepScore: sleep)
    }

    func testOldStrainIsNotAcceptedAfterTheLogicalDayChanges() {
        let oldDay = "2026-08-02"
        let snapshot = snapshot(day: oldDay,
                                strain: metric(64, day: oldDay, algorithm: "strain-v2"))

        XCTAssertNil(TodayView.firstPaintMetric(
            .strain, snapshot: snapshot, selectedDayOffset: 0,
            currentLogicalDay: "2026-08-03", currentLocalDay: "2026-08-03"))
        XCTAssertEqual(TodayView.firstPaintMetric(
            .strain, snapshot: snapshot, selectedDayOffset: 0,
            currentLogicalDay: oldDay, currentLocalDay: oldDay)?.value, 64)
    }

    func testRenderedScreenDoesNotReuseOldSnapshotDailyStrainAfterRejection() {
        let oldDay = "2026-08-02"
        let currentDay = "2026-08-03"
        let snapshot = snapshot(day: oldDay,
                                strain: metric(64, day: oldDay, algorithm: "strain-v2"))
        let rejectedMetric = TodayView.firstPaintMetric(
            .strain, snapshot: snapshot, selectedDayOffset: 0,
            currentLogicalDay: currentDay, currentLocalDay: currentDay)

        XCTAssertNil(rejectedMetric)
        XCTAssertNil(TodayView.renderedStrainValue(
            firstPaint: snapshot,
            strainMetric: rejectedMetric,
            fallback: snapshot.dailyMetric.strain
        ))
        XCTAssertEqual(TodayView.renderedStrainValue(
            firstPaint: nil, strainMetric: nil, fallback: 42
        ), 42)
    }

    func testSameDayOldFrontierIsStaleEvenWhenSnapshotWriteIsRecent() {
        let now = 2_000_000
        let currentDay = "2026-08-03"
        let staleFrontier = metric(64, day: currentDay, algorithm: "strain-v2",
                                   rawFrontierTs: now - (60 * 60 + 1))
        let recentSnapshot = snapshot(day: currentDay, strain: staleFrontier,
                                      generatedAt: now, rawFrontierTs: now)

        XCTAssertEqual(TodayView.firstPaintMetricFreshness(
            staleFrontier, snapshot: recentSnapshot,
            currentLogicalDay: currentDay, currentLocalDay: currentDay,
            nowTimestamp: now), .stale)
        XCTAssertEqual(TodayView.firstPaintMetricDetail(
            metricDay: currentDay, snapshotDisplayDay: currentDay,
            currentLogicalDay: currentDay, freshness: .stale),
                       "Stale · \(currentDay)")

        let generatedOnly = metric(64, day: currentDay, algorithm: "strain-v2")
        let oldSnapshot = snapshot(day: currentDay, strain: generatedOnly,
                                   generatedAt: now - (60 * 60 + 1))
        XCTAssertEqual(TodayView.firstPaintMetricFreshness(
            generatedOnly, snapshot: oldSnapshot,
            currentLogicalDay: currentDay, currentLocalDay: currentDay,
            nowTimestamp: now), .stale)
    }

    func testGlobalSnapshotFrontierCannotFreshenRecoveryWithoutMetricEvidence() {
        let now = 2_000_000
        let currentDay = "2026-08-03"
        let oldRecovery = metric(78, day: currentDay, observedAt: now - (60 * 60 + 1))
        let recentOtherMetricFrontier = snapshot(
            day: currentDay,
            recovery: oldRecovery,
            generatedAt: now,
            rawFrontierTs: now
        )

        XCTAssertEqual(TodayView.firstPaintMetricFreshness(
            oldRecovery, snapshot: recentOtherMetricFrontier,
            currentLogicalDay: currentDay, currentLocalDay: currentDay,
            nowTimestamp: now), .stale)

        let noMetricEvidence = metric(78, day: currentDay)
        let globallyRecentOnly = snapshot(
            day: currentDay,
            recovery: noMetricEvidence,
            generatedAt: now,
            rawFrontierTs: now
        )
        XCTAssertEqual(TodayView.firstPaintMetricFreshness(
            noMetricEvidence, snapshot: globallyRecentOnly,
            currentLogicalDay: currentDay, currentLocalDay: currentDay,
            nowTimestamp: now), .stale)
    }

    func testFreshnessDeadlineTracksMetricEvidenceNotGlobalSnapshotFrontier() {
        let now = 2_000_000
        let currentDay = "2026-08-03"
        let recovery = metric(78, day: currentDay, observedAt: now - 120)
        let handoff = snapshot(day: currentDay, recovery: recovery, rawFrontierTs: now)

        XCTAssertEqual(TodayView.nextFirstPaintFreshnessDeadline(
            snapshot: handoff,
            selectedDayOffset: 0,
            currentLogicalDay: currentDay,
            currentLocalDay: currentDay,
            nowTimestamp: now
        ), now + 60 * 60 - 119)
    }

    func testMultiDayCarryIsStaleAgainstCurrentLogicalDay() {
        let now = 2_000_000
        let oldDay = "2026-07-31"
        let currentDay = "2026-08-03"
        let carried = metric(78, day: oldDay, rawFrontierTs: now)
        let snapshot = snapshot(day: currentDay, recovery: carried, generatedAt: now)

        XCTAssertEqual(TodayView.firstPaintMetricFreshness(
            carried, snapshot: snapshot,
            currentLogicalDay: currentDay, currentLocalDay: currentDay,
            nowTimestamp: now), .stale)
        XCTAssertEqual(TodayView.firstPaintMetricDetail(
            metricDay: oldDay, snapshotDisplayDay: currentDay,
            currentLogicalDay: currentDay, freshness: .stale),
                       "Stale · \(oldDay)")
    }

    func testPriorNightRecoveryAndSleepAreLabeledAgainstCurrentLogicalDay() {
        let oldDay = "2026-08-02"
        let currentDay = "2026-08-03"
        let snapshot = snapshot(
            day: currentDay,
            recovery: metric(78, day: oldDay),
            sleep: metric(86, day: oldDay))

        XCTAssertEqual(TodayView.firstPaintMetric(
            .recovery, snapshot: snapshot, selectedDayOffset: 0,
            currentLogicalDay: currentDay, currentLocalDay: currentDay)?.value, 78)
        XCTAssertEqual(TodayView.firstPaintMetric(
            .sleepScore, snapshot: snapshot, selectedDayOffset: 0,
            currentLogicalDay: currentDay, currentLocalDay: currentDay)?.value, 86)
        XCTAssertEqual(TodayView.firstPaintMetricDetail(
            metricDay: oldDay, snapshotDisplayDay: currentDay, currentLogicalDay: currentDay),
                       "Last scored · \(oldDay)")
    }

    func testFutureMetricIsNeverAcceptedAndLegacyDayIsNotSilent() {
        let currentDay = "2026-08-03"
        let future = snapshot(day: "2026-08-04",
                              recovery: metric(78, day: "2026-08-04"))
        XCTAssertNil(TodayView.firstPaintMetric(
            .recovery, snapshot: future, selectedDayOffset: 0,
            currentLogicalDay: currentDay, currentLocalDay: currentDay))
        XCTAssertEqual(TodayView.firstPaintMetricDetail(
            metricDay: nil, snapshotDisplayDay: "2026-08-02", currentLogicalDay: currentDay),
                       "Last scored · 2026-08-02")
    }
}
