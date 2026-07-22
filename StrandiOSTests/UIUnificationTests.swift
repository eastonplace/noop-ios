import XCTest
import StrandDesign
import StrandAnalytics
import WhoopStore
@testable import NOOP

final class UIUnificationTests: XCTestCase {
    func testTrendSummaryComparesEqualLengthPeriodMeans() throws {
        let current = [10.0, 20.0, 30.0].enumerated().map { index, value in
            TrendPoint(date: Date(timeIntervalSince1970: Double(index)), value: value)
        }
        let previous = [4.0, 8.0, 12.0].enumerated().map { index, value in
            TrendPoint(date: Date(timeIntervalSince1970: Double(index - 3)), value: value)
        }

        let presentation = TrendSummaryPresentation(
            series: current,
            previousSeries: previous,
            goodDirection: .higher,
            expectedCount: 3
        )

        XCTAssertEqual(presentation.latest, 30)
        XCTAssertEqual(try XCTUnwrap(presentation.delta), 12, accuracy: 0.0001)
        XCTAssertEqual(presentation.deltaTone, .positive)
        XCTAssertEqual(presentation.source.map(\.value), current.map(\.value))
    }

    func testTrendSummaryTreatsStrainMovementAsNeutral() throws {
        let presentation = TrendSummaryPresentation(
            series: [TrendPoint(date: .now, value: 14)],
            previousSeries: [TrendPoint(date: .distantPast, value: 8)],
            goodDirection: .neutral,
            expectedCount: 1
        )

        XCTAssertEqual(try XCTUnwrap(presentation.delta), 6, accuracy: 0.0001)
        XCTAssertEqual(presentation.deltaTone, .neutral)
    }

    func testLongRangeSparkKeepsEndpointsAndCapsDensity() {
        let points = (0..<180).map { index in
            TrendPoint(date: Date(timeIntervalSince1970: Double(index)), value: Double(index))
        }
        let presentation = TrendSummaryPresentation(
            series: points,
            previousSeries: [],
            goodDirection: .higher,
            expectedCount: 180
        )

        XCTAssertEqual(presentation.spark.count, 30)
        XCTAssertEqual(presentation.spark.first?.value, 0)
        XCTAssertEqual(presentation.spark.last?.value, 179)
    }

    func testWeeklyDigestUsesCanonicalSleepAuthority() throws {
        let day = DailyMetric(
            day: "2026-07-20", totalSleepMin: 300, efficiency: 0.7,
            deepMin: 40, remMin: 50, lightMin: 210, disturbances: 10,
            restingHr: 60, avgHrv: 40, recovery: 70, strain: 8,
            exerciseCount: 0
        )
        let digest = WeeklyDigestSource.digest(
            from: [day], anchorDay: day.day, sleepByDay: [day.day: 85]
        )
        let sleep = try XCTUnwrap(digest.summary(.rest))
        XCTAssertEqual(sleep.thisWeek.mean, 85, accuracy: 0.0001)
    }

    func testSparseTrendComparisonStaysNeutral() {
        let point = TrendPoint(date: .now, value: 80)
        let presentation = TrendSummaryPresentation(
            series: [point], previousSeries: [TrendPoint(date: .distantPast, value: 60)],
            goodDirection: .higher, expectedCount: 90
        )
        XCTAssertFalse(presentation.comparisonIsReliable)
        XCTAssertEqual(presentation.deltaTone, .neutral)
        XCTAssertEqual(presentation.currentCount, 1)
        XCTAssertEqual(presentation.previousCount, 1)
    }

    @MainActor
    func testSharedAlarmModesKeepUnavailableGreenModeVisible() throws {
        let insufficient = SleepAlarmEditorSupport.wakeModes(
            recoveryHistoryCount: max(0, RecoveryForecaster.minBaselineNights - 1)
        )
        let available = SleepAlarmEditorSupport.wakeModes(
            recoveryHistoryCount: RecoveryForecaster.minBaselineNights
        )

        XCTAssertEqual(insufficient.count, 3)
        XCTAssertEqual(available.count, 3)
        XCTAssertEqual(insufficient.map(\.id), available.map(\.id))

        let greenID = SmartAlarmEvaluator.Mode.inTheGreen.rawValue
        let unavailableGreen = try XCTUnwrap(insufficient.first { $0.id == greenID })
        let availableGreen = try XCTUnwrap(available.first { $0.id == greenID })
        XCTAssertFalse(unavailableGreen.isAvailable)
        XCTAssertTrue(availableGreen.isAvailable)
    }

    func testAlarmSnapshotNormalizesMinutesAndWeekdays() {
        let snapshot = SmartAlarmCommandSnapshot(
            enabled: true,
            modeRawValue: "exact",
            minutes: -1,
            weekdays: [-4, 1, 7, 9]
        )

        XCTAssertEqual(snapshot.minutes, 1_439)
        XCTAssertEqual(snapshot.weekdays, [1, 7])
    }

    func testAlarmReconcileStateDebouncesEnabledEdits() {
        var state = SmartAlarmCommandReconcileState()
        let first = SmartAlarmCommandSnapshot(
            enabled: true, modeRawValue: "exact", minutes: 420, weekdays: [2, 3]
        )
        XCTAssertEqual(state.decision(for: first), .debounce)
        state.markApplied(first)
        XCTAssertEqual(state.decision(for: first), .ignore)
    }

    func testAlarmReconcileStateAppliesDisableImmediately() {
        let state = SmartAlarmCommandReconcileState()
        let disabled = SmartAlarmCommandSnapshot(
            enabled: false, modeRawValue: "exact", minutes: 420, weekdays: [2]
        )
        XCTAssertEqual(state.decision(for: disabled), .applyImmediately)
    }

    func testAlarmGenerationRejectsSupersededAsyncWork() {
        var generation = SmartAlarmRuntimeGeneration()
        let enabled = SmartAlarmRuntimeSnapshot(
            enabled: true, mode: .sleepGoal, minutes: 420, weekdays: [2]
        )
        let firstToken = generation.advance()
        XCTAssertTrue(generation.accepts(firstToken, request: enabled, current: enabled))

        let disabled = SmartAlarmRuntimeSnapshot(
            enabled: false, mode: .sleepGoal, minutes: 420, weekdays: [2]
        )
        let secondToken = generation.advance()
        XCTAssertFalse(generation.accepts(firstToken, request: enabled, current: disabled))
        XCTAssertTrue(generation.accepts(secondToken, request: disabled, current: disabled))
    }

    func testBackgroundRequestRoundTripsExactEndpointAndConfiguration() throws {
        let snapshot = SmartAlarmRuntimeSnapshot(
            enabled: true,
            mode: .inTheGreen,
            minutes: 6 * 60 + 45,
            weekdays: [2, 4, 6]
        )
        let endpoint = Date(timeIntervalSince1970: 1_800_000_000)
        let request = SmartAlarmBackgroundRequest(endpoint: endpoint, snapshot: snapshot)
        let decoded = try JSONDecoder().decode(
            SmartAlarmBackgroundRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.endpoint, endpoint)
        XCTAssertEqual(decoded.snapshot, snapshot)
    }

    func testFollowingBackgroundOccurrenceStartsAfterConsumedEndpoint() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 27, hour: 7
        )))
        let nextMonday = try XCTUnwrap(SmartAlarmSchedule.nextDate(
            minutes: 7 * 60,
            weekdays: [2],
            after: monday.addingTimeInterval(1),
            calendar: calendar
        ))
        XCTAssertEqual(
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: monday),
                to: calendar.startOfDay(for: nextMonday)
            ).day,
            7
        )
    }

    func testWakeNudgeCannotCrossRecurringOccurrenceMidnight() {
        let monday0002 = 1_440 + 2
        XCTAssertNil(SleepAlarmEditorSupport.sameOccurrenceMinute(
            current: monday0002, proposed: monday0002 - 5
        ))
        XCTAssertEqual(SleepAlarmEditorSupport.sameOccurrenceMinute(
            current: monday0002 + 10, proposed: monday0002 + 5
        ), monday0002 + 5)

        let sunday2358 = 1_438
        XCTAssertNil(SleepAlarmEditorSupport.sameOccurrenceMinute(
            current: sunday2358, proposed: sunday2358 + 5
        ))
    }
}
