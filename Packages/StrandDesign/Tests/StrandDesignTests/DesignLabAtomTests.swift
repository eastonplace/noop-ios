import SwiftUI
import XCTest
@testable import StrandDesign

final class DesignLabAtomTests: XCTestCase {
    func testHoldGateRequiresOneUninterruptedHoldAndCompletesOnce() {
        var gate = HoldToConfirmContract()

        XCTAssertTrue(gate.begin())
        gate.cancel()
        XCTAssertFalse(gate.complete())

        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.complete())
        XCTAssertFalse(gate.complete())
        XCTAssertFalse(gate.begin())
    }

    func testHoldGateKeepsLabTimingAndClampsUnsafeDurations() {
        XCTAssertEqual(HoldToConfirmContract.defaultHoldSeconds, 1.2)
        XCTAssertEqual(HoldToConfirmContract.normalized(seconds: 1.2), 1.2)
        XCTAssertEqual(HoldToConfirmContract.normalized(seconds: 0), 0.1)
    }

    func testHoldStylePresetsKeepTheDestructiveLookAndGiveTheWorkoutEndItsOwn() {
        let destructive = HoldToConfirmStyle.destructive
        XCTAssertEqual(destructive.height, 44, "the bar every destructive gate has always had")
        XCTAssertEqual(destructive.shape, .rounded(13))
        XCTAssertEqual(destructive.icon, "trash")
        XCTAssertEqual(destructive.completedIcon, "checkmark")

        let end = HoldToConfirmStyle.glanceEnd
        XCTAssertEqual(end.height, GlanceActionButtonStyle.minimumHeight, "as tall as the workout screen's other big button")
        XCTAssertEqual(end.shape, .capsule)
        XCTAssertEqual(end.icon, "stop.fill")
        XCTAssertNotEqual(end, destructive)
    }

    func testTheHoldIsTheSameForEveryStyle() {
        // The styles change the look only: the hold is the one contract.
        XCTAssertEqual(HoldToConfirmContract.defaultHoldSeconds, 1.2)
    }

    func testAHeldGateRearmsOnlyWhenTheButtonIsRebuilt() {
        // `confirmed` is sticky by design (a confirmed gate cannot fire twice); the workout screen rebuilds the button
        // (`.id(finishAttemptID)`) when End can be asked for again, which is a fresh contract.
        var gate = HoldToConfirmContract()
        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.complete())
        XCTAssertFalse(gate.begin(), "sticky until rebuilt")
        gate = HoldToConfirmContract()
        XCTAssertTrue(gate.begin(), "a rebuilt button holds again")
    }

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

    func testFlatSegmentThumbFollowsTheTintAndTheSelectionStyle() {
        let tint = Color.orange
        let tinted = SegmentedPillSelectionAppearance.resolve(tint: tint, style: .solid)
        XCTAssertEqual(tinted.fill, tint.opacity(0.18))
        XCTAssertEqual(tinted.label, tint.lightened(by: SegmentedPillSelectionAppearance.tintedLabelLightening))
        // With a tint the two styles draw the same thumb.
        XCTAssertEqual(SegmentedPillSelectionAppearance.resolve(tint: tint, style: .quiet), tinted)

        let quiet = SegmentedPillSelectionAppearance.resolve(tint: nil, style: .quiet)
        XCTAssertEqual(quiet.fill, StrandPalette.ink.opacity(0.12))
        XCTAssertEqual(quiet.label, StrandPalette.textPrimary)
        let solid = SegmentedPillSelectionAppearance.resolve(tint: nil, style: .solid)
        XCTAssertEqual(solid.fill, StrandPalette.ink.opacity(0.22))
        XCTAssertEqual(solid.label, StrandPalette.textPrimary)
    }

    /// WCAG relative luminance and contrast of sRGB colours, for the label-on-thumb check below.
    private func luminance(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    func testTintedSelectedLabelReachesTextContrastOnTheThumb() {
        let tints: [(String, Color)] = [
            ("hrv purple", StrandPalette.metricPurple), ("recovery red", Color(hex: "#FF0026")),
            ("strain", StrandPalette.strainAccent), ("sleep", StrandPalette.sleepAccent),
            ("recovery data", StrandPalette.recoveryData),
        ]
        for (name, tint) in tints {
            let appearance = SegmentedPillSelectionAppearance.resolve(tint: tint, style: .solid)
            let label = luminance(appearance.label.rgbaComponents)
            let thumb = tint.rgbaComponents
            for background in [StrandPalette.canvas, StrandPalette.card] {
                let bg = background.rgbaComponents
                // The thumb is the tint at 0.18 over the surface it sits on.
                let blended = (r: bg.r + (thumb.r - bg.r) * 0.18, g: bg.g + (thumb.g - bg.g) * 0.18,
                               b: bg.b + (thumb.b - bg.b) * 0.18, a: 1.0)
                XCTAssertGreaterThanOrEqual(contrast(label, luminance(blended)), 4.5, name)
            }
        }
    }

    func testGreyTintsFallBackToTheNeutralLook() {
        let neutral = SegmentedPillSelectionAppearance.resolve(tint: nil, style: .solid)
        XCTAssertEqual(SegmentedPillSelectionAppearance.resolve(tint: StrandPalette.textTertiary, style: .solid), neutral)
        XCTAssertEqual(SegmentedPillSelectionAppearance.resolve(tint: StrandPalette.textSecondary, style: .solid), neutral)
        XCTAssertNil(DomainTint.neutral.rangeControlAccent)
    }

    func testRecoveryRangeTintIsStableAcrossScoreBands() {
        XCTAssertEqual(DomainTint.recovery(score: 12).rangeControlAccent, StrandPalette.recoveryData)
        XCTAssertEqual(DomainTint.recovery(score: 95).rangeControlAccent, StrandPalette.recoveryData)
        XCTAssertEqual(DomainTint.recovery(score: nil).rangeControlAccent, StrandPalette.recoveryData)
        XCTAssertEqual(DomainTint.strain.rangeControlAccent, StrandPalette.strainAccent)
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
