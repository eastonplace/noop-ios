import XCTest
@testable import StrandDesign

final class DesignLabAtomTests: XCTestCase {
    func testPaperToastUsesTwoPointFourSecondDefaultDwell() {
        XCTAssertEqual(PaperToastDwellState.defaultDwellNanoseconds, 2_400_000_000)
    }

    func testPaperToastPresentationRestartInvalidatesPriorDismissal() {
        var scheduler = PaperToastDwellState()
        let first = scheduler.present()
        let restarted = scheduler.present()

        XCTAssertFalse(scheduler.shouldDismiss(generation: first))
        XCTAssertTrue(scheduler.shouldDismiss(generation: restarted))
        XCTAssertGreaterThan(restarted, first)
    }

    func testPaperToastCancellationInvalidatesScheduledDismissal() {
        var scheduler = PaperToastDwellState()
        let scheduled = scheduler.present()

        scheduler.cancel()

        XCTAssertFalse(scheduler.shouldDismiss(generation: scheduled))
        XCTAssertNil(scheduler.activeGeneration)
    }

    func testPaperToastOwnerControlledModeHasNoAutomaticDwell() {
        XCTAssertNil(PaperToastDismissal.ownerControlled.dwellNanoseconds)
        XCTAssertEqual(
            PaperToastDismissal.automatic.dwellNanoseconds,
            PaperToastDwellState.defaultDwellNanoseconds
        )
    }

    func testProgressDotsAccessibilityLabelClampsToRealStep() {
        XCTAssertEqual(
            ProgressDots.accessibilityLabel(count: 4, current: 1),
            "Step 2 of 4"
        )
        XCTAssertEqual(
            ProgressDots.accessibilityLabel(count: 4, current: 99),
            "Step 4 of 4"
        )
        XCTAssertEqual(
            ProgressDots.accessibilityLabel(count: 0, current: 0),
            "No steps"
        )
    }

    func testValueTokenAccessibilityLabelComposition() {
        XCTAssertEqual(
            ValueToken.accessibilityLabel(label: "Heart rate", value: "152 bpm"),
            "Heart rate, 152 bpm"
        )
    }

    func testSegmentedPillSelectionCallbackPrecedesFeedback() {
        var events: [String] = []
        var selection = "Day"

        SegmentedPillSelection.perform(
            current: selection,
            next: "Week",
            isEnabled: true,
            setSelection: {
                selection = $0
                events.append("selection:\($0)")
            },
            feedback: { events.append("feedback") }
        )

        XCTAssertEqual(selection, "Week")
        XCTAssertEqual(events, ["selection:Week", "feedback"])
    }

    func testSegmentedPillDoesNotCallbackForRetapOrDisabledSegment() {
        var callbackCount = 0
        let record: (String) -> Void = { _ in callbackCount += 1 }
        let feedback = { callbackCount += 1 }

        SegmentedPillSelection.perform(
            current: "Day", next: "Day", isEnabled: true,
            setSelection: record, feedback: feedback
        )
        SegmentedPillSelection.perform(
            current: "Day", next: "Week", isEnabled: false,
            setSelection: record, feedback: feedback
        )

        XCTAssertEqual(callbackCount, 0)
    }

    func testHypnogramHighlightUsesContractOpacityWithoutChangingHoverRule() {
        XCTAssertEqual(
            Hypnogram.intervalOpacity(
                for: .deep,
                highlightedStage: .rem,
                isDimmedByHover: false
            ),
            0.18
        )
        XCTAssertEqual(
            Hypnogram.intervalOpacity(
                for: .rem,
                highlightedStage: .rem,
                isDimmedByHover: false
            ),
            1.0
        )
        XCTAssertEqual(
            Hypnogram.intervalOpacity(
                for: .rem,
                highlightedStage: .rem,
                isDimmedByHover: true
            ),
            0.45
        )
        XCTAssertEqual(
            Hypnogram.intervalOpacity(
                for: .deep,
                highlightedStage: nil,
                isDimmedByHover: true
            ),
            0.45
        )
    }

    func testHypnogramHighlightDoesNotChangeSmoothingAxisOrHoverInputs() {
        let intervals = [
            SleepInterval(stage: .light, start: 0, end: 600),
            SleepInterval(stage: .awake, start: 600, end: 630),
            SleepInterval(stage: .rem, start: 630, end: 1_230)
        ]
        let expected = Hypnogram.displaySmoothed(intervals, minDuration: 300)
        let start = Date(timeIntervalSince1970: 1_000)
        let highlighted = Hypnogram(
            intervals: intervals,
            showsHover: true,
            nightStart: start,
            showsTimeAxis: true,
            smoothingSeconds: 300,
            highlightedStage: .rem
        )

        XCTAssertEqual(highlighted.intervals.map(\.id), expected.map(\.id))
        XCTAssertTrue(highlighted.showsHover)
        XCTAssertEqual(highlighted.nightStart, start)
        XCTAssertTrue(highlighted.showsTimeAxis)
        XCTAssertEqual(highlighted.highlightedStage, .rem)
    }
}
