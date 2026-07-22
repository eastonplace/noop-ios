import XCTest
import StrandDesign
import StrandAnalytics
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
            goodDirection: .higher
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
            goodDirection: .neutral
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
            goodDirection: .higher
        )

        XCTAssertEqual(presentation.spark.count, 30)
        XCTAssertEqual(presentation.spark.first?.value, 0)
        XCTAssertEqual(presentation.spark.last?.value, 179)
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

    @MainActor
    func testAlarmCoordinatorCoalescesRapidEnabledEditsToNewestSnapshot() async throws {
        let coordinator = SmartAlarmCommandReconcileCoordinator(debounceNanoseconds: 5_000_000)
        let first = SmartAlarmCommandSnapshot(
            enabled: true, modeRawValue: "exact", minutes: 420, weekdays: [2, 3]
        )
        let newest = SmartAlarmCommandSnapshot(
            enabled: true, modeRawValue: "exact", minutes: 435, weekdays: [2, 3, 4]
        )
        var applied: [SmartAlarmCommandSnapshot] = []

        coordinator.schedule(first) { applied.append(first) }
        coordinator.schedule(newest) { applied.append(newest) }
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(applied, [newest])
    }

    @MainActor
    func testAlarmCoordinatorAppliesDisableImmediatelyAndCancelsPendingEdit() async throws {
        let coordinator = SmartAlarmCommandReconcileCoordinator(debounceNanoseconds: 50_000_000)
        let pending = SmartAlarmCommandSnapshot(
            enabled: true, modeRawValue: "exact", minutes: 420, weekdays: [2]
        )
        let disabled = SmartAlarmCommandSnapshot(
            enabled: false, modeRawValue: "exact", minutes: 420, weekdays: [2]
        )
        var applied: [SmartAlarmCommandSnapshot] = []

        coordinator.schedule(pending) { applied.append(pending) }
        coordinator.schedule(disabled) { applied.append(disabled) }
        XCTAssertEqual(applied, [disabled])
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(applied, [disabled])
    }

    @MainActor
    func testAlarmCoordinatorSuppressesDuplicateAppliedSnapshot() async throws {
        let coordinator = SmartAlarmCommandReconcileCoordinator(debounceNanoseconds: 1_000_000)
        let snapshot = SmartAlarmCommandSnapshot(
            enabled: true, modeRawValue: "exact", minutes: 420, weekdays: [2]
        )
        var applyCount = 0

        coordinator.schedule(snapshot) { applyCount += 1 }
        try await Task.sleep(nanoseconds: 10_000_000)
        coordinator.schedule(snapshot) { applyCount += 1 }
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(applyCount, 1)
    }
}
