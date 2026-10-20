import SwiftUI
import XCTest
@testable import StrandDesign

final class PillSystemTokenTests: XCTestCase {
    func testPillStrokeIsWhiteAtAlpha1F() {
        let c = StrandPalette.pillStroke.rgbaComponents
        XCTAssertEqual(c.r, 1, accuracy: 0.01)
        XCTAssertEqual(c.g, 1, accuracy: 0.01)
        XCTAssertEqual(c.b, 1, accuracy: 0.01)
        XCTAssertEqual(c.a, Double(0x1F) / 255, accuracy: 0.01)
    }

    func testPillFillIsChipFillAndTagFillIsInset() {
        XCTAssertEqual(StrandPalette.pillFill, StrandPalette.chipFill)
        XCTAssertEqual(StrandPalette.tagFill, StrandPalette.inset)
        XCTAssertEqual(StrandPalette.onLightFill, StrandPalette.canvas)
    }

    func testPrimaryButtonIsSolidLightWithDarkLabel() {
        let primary = NoopButtonAppearance(.primary)
        XCTAssertEqual(primary.fill, StrandPalette.solidFill)
        XCTAssertEqual(primary.label, StrandPalette.onLightFill)
        XCTAssertNil(primary.border)
        let c = StrandPalette.solidFill.rgbaComponents
        XCTAssertEqual(c.r, 0xF2 / 255.0, accuracy: 0.01)
        XCTAssertEqual(c.g, 0xF4 / 255.0, accuracy: 0.01)
        XCTAssertEqual(c.b, 0xF5 / 255.0, accuracy: 0.01)
    }

    func testSecondaryButtonIsHairlineNotFilled() {
        let secondary = NoopButtonAppearance(.secondary)
        XCTAssertNil(secondary.fill)
        XCTAssertEqual(secondary.border, StrandPalette.hairlineStrong)
        XCTAssertEqual(secondary.label, StrandPalette.textPrimary)
    }

    func testChipUnselectedIsHairlineAndSelectedIsSolidLight() {
        let off = ChoiceChipAppearance.resolve(isSelected: false, tint: nil)
        XCTAssertEqual(off.fill, .clear)
        XCTAssertEqual(off.stroke, StrandPalette.hairlineStrong)
        XCTAssertEqual(off.label, StrandPalette.textSecondary)
        let on = ChoiceChipAppearance.resolve(isSelected: true, tint: nil)
        XCTAssertEqual(on.fill, StrandPalette.solidFill)
        XCTAssertEqual(on.label, StrandPalette.onLightFill)
        // A selected chip is never mint.
        XCTAssertNotEqual(on.fill, StrandPalette.ink)
    }

    func testChipOnMetricPageMatchesTheRangeControl() {
        let tint = StrandPalette.strainAccent
        let chip = ChoiceChipAppearance.resolve(isSelected: true, tint: tint)
        let range = SegmentedPillSelectionAppearance.resolve(tint: tint, style: .solid)
        XCTAssertEqual(chip.fill, range.fill)
        XCTAssertEqual(chip.label, range.label)
    }

    func testGreyTintFallsBackToTheNeutralSolidChip() {
        let chip = ChoiceChipAppearance.resolve(isSelected: true, tint: StrandPalette.textTertiary)
        XCTAssertEqual(chip.fill, StrandPalette.solidFill)
    }

    func testToneToDotColourMappingIsUnchanged() {
        XCTAssertEqual(StrandTone.neutral.color, StrandPalette.textSecondary)
        XCTAssertEqual(StrandTone.accent.color, StrandPalette.accent)
        XCTAssertEqual(StrandTone.positive.color, StrandPalette.statusPositive)
        XCTAssertEqual(StrandTone.warning.color, StrandPalette.statusWarning)
        XCTAssertEqual(StrandTone.critical.color, StrandPalette.statusCritical)
    }

    func testButtonAndChipGeometry() {
        XCTAssertEqual(NoopButtonMetrics.height, 50)
        XCTAssertEqual(NoopButtonMetrics.cornerRadius, 25)
        XCTAssertEqual(ChoiceChipMetrics.height, 34)
        XCTAssertEqual(ChoiceChipMetrics.hitTarget, 44)
        XCTAssertEqual(TagMetrics.cornerRadius, 6)
        XCTAssertEqual(TagMetrics.minHeight, 20)
        XCTAssertEqual(TagMetrics.tracking, 0.6)
    }
}
