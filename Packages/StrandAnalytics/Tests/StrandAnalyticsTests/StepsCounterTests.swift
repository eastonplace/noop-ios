import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Unit tests for the shared windowed step kernel `StepsCounter.stepsInWindow` (#398). The same
/// wrap-aware positive-delta math the daily total uses (see StepsDailyTests), but exercised directly and
/// order-independently so a manual-workout window can reuse it. Returns the RAW motion-tick total (before
/// the caller's `stepTicksPerStep` calibration). Mirrors the Android StepsCounterTest vectors value-for-value.
final class StepsCounterTests: XCTestCase {

    private func step(_ ts: Int, _ counter: Int) -> StepSample { StepSample(ts: ts, counter: counter) }

    func testSumsPositiveConsecutiveDeltas() {
        // counters 100 -> 150 -> 220 => deltas 50 + 70 = 120
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100), step(60, 150), step(120, 220)]), 120)
    }

    func testSortsUnorderedInput() {
        // Same three samples shuffled — the kernel sorts by ts, so the result is identical (120).
        XCTAssertEqual(StepsCounter.stepsInWindow([step(120, 220), step(0, 100), step(60, 150)]), 120)
    }

    func testHandlesU16Wraparound() {
        // 65500 -> 20 wraps: (20 - 65500) & 0xFFFF = 56, a small real increment; then 20 -> 80 => 60.
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 65_500), step(60, 20), step(120, 80)]), 116)
    }

    func testFewerThanTwoSamplesIsNil() {
        XCTAssertNil(StepsCounter.stepsInWindow([]))
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 100)]))
    }

    func testNoForwardMovementIsNil() {
        // Flat counter across the window => no positive delta => nil (not 0).
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 500), step(60, 500), step(120, 500)]))
    }

    func testDropsBigGapDeltaAsBoundary() {
        // A jump >= 512 (sync-gap / reboot boundary) is dropped; the real 40 + 30 survive.
        // 100 -> 140 (=40) -> 5000 (=4860, dropped) -> 5030 (=30) => 70.
        XCTAssertEqual(StepsCounter.stepsInWindow(
            [step(0, 100), step(60, 140), step(120, 5_000), step(180, 5_030)]), 70)
    }

    func testMaxStepDeltaBoundaryIsExclusive() {
        // Exactly maxStepDelta (512) is dropped; 511 counts.
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 0), step(60, 512)]), nil)   // 512 dropped => no movement
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 0), step(128, 511)]), 511) // plausible rate, below reset bound
    }

    func testClassifiedWindowsOnlyCountWalkingAndRunning() {
        let rows = [
            StepSample(ts: 0, counter: 100, activityClass: 0),
            StepSample(ts: 1, counter: 102, activityClass: 0),
            StepSample(ts: 2, counter: 104, activityClass: 1),
            StepSample(ts: 3, counter: 107, activityClass: 2),
            StepSample(ts: 4, counter: 110, activityClass: 9),
            StepSample(ts: 5, counter: 112, activityClass: nil),
        ]
        XCTAssertEqual(StepsCounter.stepsInWindow(rows), 5)
    }

    func testEntirelyUnclassifiedHistoryRetainsCounterEstimate() {
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100), step(1, 102), step(2, 104)]), 4)
    }

    func testRejectsImplausibleRateButKeepsFollowingPlausibleMovement() {
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100), step(1, 130), step(2, 132)]), 2)
    }

    func testExactDuplicateRecordsDoNotChangeTheCount() {
        XCTAssertEqual(StepsCounter.stepsInWindow([
            step(0, 100), step(1, 102), step(1, 102), step(2, 104)
        ]), 4)
    }

    func testConflictingSameSecondCountersBreakContinuity() {
        let rows = [step(0, 100), step(1, 101), step(1, 103), step(2, 105), step(3, 107)]
        XCTAssertEqual(StepsCounter.stepsInWindow(rows), 2)
        XCTAssertEqual(StepsCounter.stepsInWindow(Array(rows.reversed())), 2)
    }

    func testInvalidCounterDoesNotBridgeTwoIndependentRuns() {
        XCTAssertEqual(StepsCounter.stepsInWindow([
            step(0, 100), step(1, -1), step(2, 104), step(3, 106)
        ]), 2)
    }

    func testRateBoundaryAndCounterWrap() {
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 65_534), step(1, 2)]), 4)
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 65_534), step(1, 3)]))
    }
}
