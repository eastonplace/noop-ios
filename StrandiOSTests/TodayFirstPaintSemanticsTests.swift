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

    func testCancelledOrSupersededDayLoadCannotPublishItsState() {
        let currentDay = "2026-08-03"
        let currentKey = "2026-08-03|2026-08-03|2026-08-03|0"

        XCTAssertTrue(TodayView.shouldCommitDayScopedLoad(
            loadSeq: 42, currentSeq: 42,
            loadDayKey: currentDay, currentDayKey: currentDay,
            loadRestScoreKey: currentKey, currentRestScoreKey: currentKey,
            isCancelled: false
        ))
        XCTAssertFalse(TodayView.shouldCommitDayScopedLoad(
            loadSeq: 42, currentSeq: 43,
            loadDayKey: currentDay, currentDayKey: currentDay,
            loadRestScoreKey: currentKey, currentRestScoreKey: currentKey,
            isCancelled: false
        ))
        XCTAssertFalse(TodayView.shouldCommitDayScopedLoad(
            loadSeq: 42, currentSeq: 42,
            loadDayKey: "2026-08-02", currentDayKey: currentDay,
            loadRestScoreKey: "2026-08-02|2026-08-03|2026-08-02|1",
            currentRestScoreKey: currentKey,
            isCancelled: false
        ))
        XCTAssertFalse(TodayView.shouldCommitDayScopedLoad(
            loadSeq: 42, currentSeq: 42,
            loadDayKey: currentDay, currentDayKey: currentDay,
            loadRestScoreKey: currentKey, currentRestScoreKey: currentKey,
            isCancelled: true
        ))
    }

    func testSameDayOldFrontierIsStaleEvenWhenSnapshotWriteIsRecent() {
        let now = 2_000_000
        let currentDay = "2026-08-03"
        let staleFrontier = metric(64, day: currentDay, algorithm: "strain-v2",
                                   rawFrontierTs: now - (60 * 60 + 1))
        let recentSnapshot = snapshot(day: currentDay, strain: staleFrontier,
                                      generatedAt: now, rawFrontierTs: now)

        XCTAssertEqual(TodayView.firstPaintMetricFreshness(
            .strain, value: staleFrontier, snapshot: recentSnapshot,
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
            .strain, value: generatedOnly, snapshot: oldSnapshot,
            currentLogicalDay: currentDay, currentLocalDay: currentDay,
            nowTimestamp: now), .stale)
    }

    func testGlobalSnapshotFrontierCannotFreshenStrainWithoutMetricEvidence() {
        let now = 2_000_000
        let currentDay = "2026-08-03"
        let oldStrain = metric(8, day: currentDay, algorithm: "strain-v2",
                               observedAt: now - (60 * 60 + 1))
        let recentOtherMetricFrontier = snapshot(
            day: currentDay,
            strain: oldStrain,
            generatedAt: now,
            rawFrontierTs: now
        )

        XCTAssertEqual(TodayView.firstPaintMetricFreshness(
            .strain, value: oldStrain, snapshot: recentOtherMetricFrontier,
            currentLogicalDay: currentDay, currentLocalDay: currentDay,
            nowTimestamp: now), .stale)

        let noMetricEvidence = metric(8, day: currentDay, algorithm: "strain-v2")
        let globallyRecentOnly = snapshot(
            day: currentDay,
            strain: noMetricEvidence,
            generatedAt: now,
            rawFrontierTs: now
        )
        XCTAssertEqual(TodayView.firstPaintMetricFreshness(
            .strain, value: noMetricEvidence, snapshot: globallyRecentOnly,
            currentLogicalDay: currentDay, currentLocalDay: currentDay,
            nowTimestamp: now), .stale)
    }

    func testSameDayRecoveryAndSleepRemainFreshAfterOvernightEvidenceAges() {
        let now = 2_000_000
        let currentDay = "2026-08-03"
        let overnight = now - 10 * 60 * 60
        let recovery = metric(78, day: currentDay, observedAt: overnight)
        let sleep = metric(86, day: currentDay, observedAt: overnight)
        let handoff = snapshot(day: currentDay, recovery: recovery, sleep: sleep,
                               generatedAt: now, rawFrontierTs: now)

        XCTAssertEqual(TodayView.firstPaintMetricFreshness(
            .recovery, value: recovery, snapshot: handoff,
            currentLogicalDay: currentDay, currentLocalDay: currentDay,
            nowTimestamp: now), .fresh)
        XCTAssertEqual(TodayView.firstPaintMetricFreshness(
            .sleepScore, value: sleep, snapshot: handoff,
            currentLogicalDay: currentDay, currentLocalDay: currentDay,
            nowTimestamp: now), .fresh)
        XCTAssertNil(TodayView.firstPaintMetricDetail(
            metricDay: currentDay, snapshotDisplayDay: currentDay,
            currentLogicalDay: currentDay, freshness: .fresh))
    }

    func testFreshnessDeadlineTracksMetricEvidenceNotGlobalSnapshotFrontier() {
        let now = 2_000_000
        let currentDay = "2026-08-03"
        let strain = metric(8, day: currentDay, algorithm: "strain-v2", observedAt: now - 120)
        let handoff = snapshot(day: currentDay, strain: strain, rawFrontierTs: now)

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
            .recovery, value: carried, snapshot: snapshot,
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

    func testDetailPassesTheDayKeyThroughTheDisplayLabelWithoutChangingWhenItAppears() {
        let currentDay = "2026-10-08"
        XCTAssertEqual(TodayView.firstPaintMetricDetail(
            metricDay: currentDay, snapshotDisplayDay: currentDay, currentLogicalDay: currentDay,
            freshness: .stale, dayLabel: { _ in "Oct 8" }),
                       "Stale · Oct 8")
        XCTAssertEqual(TodayView.firstPaintMetricDetail(
            metricDay: "2026-10-07", snapshotDisplayDay: currentDay, currentLogicalDay: currentDay,
            dayLabel: { _ in "Oct 7" }),
                       "Last scored · Oct 7")
        XCTAssertNil(TodayView.firstPaintMetricDetail(
            metricDay: currentDay, snapshotDisplayDay: currentDay, currentLogicalDay: currentDay,
            freshness: .fresh, dayLabel: { _ in "Oct 8" }))
    }
}
