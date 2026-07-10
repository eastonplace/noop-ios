import XCTest
import SwiftUI
@testable import StrandDesign

final class StrandDesignTests: XCTestCase {

    func testVersion() {
        XCTAssertEqual(StrandDesign.version, "0.1.0")
    }

    func testPaperProportionContract() {
        XCTAssertEqual(NoopMetrics.trioRingDiameter, 64)
        XCTAssertEqual(NoopMetrics.trioRingLineWidth, 5)
        XCTAssertEqual(NoopMetrics.trioRingNumeralSize, 30)
        XCTAssertEqual(NoopMetrics.heroRingDiameter, 96)
        XCTAssertEqual(NoopMetrics.heroRingLineWidth, 7)
        XCTAssertEqual(NoopMetrics.heroRingNumeralSize, 44)
        XCTAssertEqual(NoopMetrics.liveRunTimerSize, 64)
        XCTAssertEqual(NoopMetrics.healthTileIconSize, 16)
        XCTAssertEqual(NoopMetrics.healthTileLabelSize, 13)
        XCTAssertEqual(NoopMetrics.healthTileValueSize, 20)
        XCTAssertEqual(NoopMetrics.stressTimelineHeight, 8)
        XCTAssertEqual(NoopMetrics.chartLineWidth, 2)
        XCTAssertGreaterThanOrEqual(NoopMetrics.iconCircleDiameter, 32)
        XCTAssertLessThanOrEqual(NoopMetrics.iconCircleDiameter, 36)
    }

    func testHexParsing() {
        let c = Color(hex: "#0B0D12").rgbaComponents
        XCTAssertEqual(c.r, 0x0B / 255.0, accuracy: 0.01)
        XCTAssertEqual(c.g, 0x0D / 255.0, accuracy: 0.01)
        XCTAssertEqual(c.b, 0x12 / 255.0, accuracy: 0.01)
        XCTAssertEqual(c.a, 1.0, accuracy: 0.001)
    }

    func testRecoveryGradientStops() {
        XCTAssertEqual(StrandPalette.recoveryStops.count, 5)
        XCTAssertEqual(StrandPalette.recoveryStops.first?.location, 0.0)
        XCTAssertEqual(StrandPalette.recoveryStops.last?.location, 1.0)
    }

    func testRecoveryColorEndpoints() {
        // Score 0 should equal the indigo start; 100 the mint end.
        let low = StrandPalette.recoveryColor(0).rgbaComponents
        let indigo = StrandPalette.recovery000.rgbaComponents
        XCTAssertEqual(low.r, indigo.r, accuracy: 0.02)
        XCTAssertEqual(low.g, indigo.g, accuracy: 0.02)
        XCTAssertEqual(low.b, indigo.b, accuracy: 0.02)

        let high = StrandPalette.recoveryColor(100).rgbaComponents
        let mint = StrandPalette.recovery100.rgbaComponents
        XCTAssertEqual(high.r, mint.r, accuracy: 0.02)
        XCTAssertEqual(high.g, mint.g, accuracy: 0.02)
        XCTAssertEqual(high.b, mint.b, accuracy: 0.02)
    }

    func testRecoveryColorClamps() {
        // Out of range clamps to endpoints rather than crashing.
        let below = StrandPalette.recoveryColor(-50).rgbaComponents
        let zero = StrandPalette.recoveryColor(0).rgbaComponents
        XCTAssertEqual(below.r, zero.r, accuracy: 0.001)
        let above = StrandPalette.recoveryColor(150).rgbaComponents
        let hundred = StrandPalette.recoveryColor(100).rgbaComponents
        XCTAssertEqual(above.b, hundred.b, accuracy: 0.001)
    }

    func testRecoveryStateWords() {
        XCTAssertEqual(StrandPalette.recoveryState(10), "DEPLETED")
        XCTAssertEqual(StrandPalette.recoveryState(40), "LOW")
        XCTAssertEqual(StrandPalette.recoveryState(60), "MODERATE")
        XCTAssertEqual(StrandPalette.recoveryState(80), "PRIMED")
        XCTAssertEqual(StrandPalette.recoveryState(95), "PEAK")
    }

    func testStrainColorScaleAndEndpoints() {
        // Effort samples the 0...100 ramp; endpoints match ember/magenta.
        let ember = StrandPalette.strainColor(0).rgbaComponents
        let start = StrandPalette.strain000.rgbaComponents
        XCTAssertEqual(ember.r, start.r, accuracy: 0.02)
        let magenta = StrandPalette.strainColor(100).rgbaComponents
        let end = StrandPalette.strain100.rgbaComponents
        XCTAssertEqual(magenta.b, end.b, accuracy: 0.02)
    }

    func testStrainScaleCanonicalConversionsAndClamping() {
        XCTAssertEqual(StrainScale.formatted(67), "14.1")
        XCTAssertEqual(StrainScale.displayValue(fromStored: 100), 21, accuracy: 0.0001)
        XCTAssertEqual(StrainScale.displayValue(fromStored: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(StrainScale.displayValue(fromStored: -1), 0, accuracy: 0.0001)
        XCTAssertEqual(StrainScale.displayValue(fromStored: 101), 21, accuracy: 0.0001)
    }

    func testStrainScaleRoundTripsWithoutChangingStorage() {
        for stored in stride(from: 0.0, through: 100.0, by: 0.5) {
            let display = StrainScale.displayValue(fromStored: stored)
            XCTAssertEqual(StrainScale.storedValue(fromDisplay: display), stored, accuracy: 0.0001)
        }
    }

    func testWorkoutBadgeFixtureUsesCanonicalStrainFormatter() {
        XCTAssertEqual(StrainScale.badgeText(fromStored: 67), "14.1")
        XCTAssertEqual(StrainScale.badgeText(fromStored: 0), "0.0")
        XCTAssertEqual(StrainScale.badgeText(fromStored: nil), "–")
    }

    func testStrainBandBoundariesUseDisplayScale() {
        XCTAssertEqual(StrainScale.band(0), .light)
        XCTAssertEqual(StrainScale.band(9.9), .light)
        XCTAssertEqual(StrainScale.band(10), .moderate)
        XCTAssertEqual(StrainScale.band(13.9), .moderate)
        XCTAssertEqual(StrainScale.band(14), .high)
        XCTAssertEqual(StrainScale.band(17.9), .high)
        XCTAssertEqual(StrainScale.band(18), .allOut)
        XCTAssertEqual(StrainScale.band(21), .allOut)
    }

    func testFactorBandsPersonalVitalBoundaries() {
        XCTAssertEqual(FactorBands.hrv(deviationRatio: 0.050_001, zScore: 0.5), .good)
        XCTAssertEqual(FactorBands.hrv(deviationRatio: 0.05, zScore: 0.5), .steady)
        XCTAssertEqual(FactorBands.hrv(deviationRatio: -0.05, zScore: -0.5), .steady)
        XCTAssertEqual(FactorBands.hrv(deviationRatio: -0.050_001, zScore: -2), .fair)
        XCTAssertEqual(FactorBands.hrv(deviationRatio: -0.050_001, zScore: -2.001), .low)

        XCTAssertEqual(FactorBands.restingHR(deviationRatio: -0.050_001, zScore: -0.5), .good)
        XCTAssertEqual(FactorBands.restingHR(deviationRatio: -0.05, zScore: -0.5), .steady)
        XCTAssertEqual(FactorBands.restingHR(deviationRatio: 0.05, zScore: 0.5), .steady)
        XCTAssertEqual(FactorBands.restingHR(deviationRatio: 0.050_001, zScore: 2), .fair)
        XCTAssertEqual(FactorBands.restingHR(deviationRatio: 0.050_001, zScore: 2.001), .high)
        XCTAssertNil(FactorBands.hrv(deviationRatio: nil, zScore: nil))
    }

    func testFactorBandsSleepAndNormalWindowBoundaries() {
        XCTAssertEqual(FactorBands.sleepPerformance(percent: 85), .good)
        XCTAssertEqual(FactorBands.sleepPerformance(percent: 84.999), .fair)
        XCTAssertEqual(FactorBands.sleepPerformance(percent: 70), .fair)
        XCTAssertEqual(FactorBands.sleepPerformance(percent: 69.999), .low)

        XCTAssertEqual(FactorBands.respiratoryRate(zScore: -1), .good)
        XCTAssertEqual(FactorBands.respiratoryRate(zScore: 1), .good)
        XCTAssertEqual(FactorBands.respiratoryRate(zScore: 1.001), .fair)
        XCTAssertEqual(FactorBands.respiratoryRate(zScore: -1.001), .fair)
        XCTAssertEqual(FactorBands.respiratoryRate(zScore: 2), .high)
        XCTAssertEqual(FactorBands.respiratoryRate(zScore: -2), .low)

        XCTAssertEqual(FactorBands.skinTemperature(deviationC: 0.3, typicalBandC: 0.3), .good)
        XCTAssertEqual(FactorBands.skinTemperature(deviationC: -0.3, typicalBandC: 0.3), .good)
        XCTAssertEqual(FactorBands.skinTemperature(deviationC: 0.301, typicalBandC: 0.3), .fair)
        XCTAssertEqual(FactorBands.skinTemperature(deviationC: -0.301, typicalBandC: 0.3), .fair)
        XCTAssertEqual(FactorBands.skinTemperature(deviationC: 1, typicalBandC: 0.3), .high)
        XCTAssertEqual(FactorBands.skinTemperature(deviationC: -1, typicalBandC: 0.3), .low)
    }

    func testFactorBandsHeartRateZoneBoundaries() {
        XCTAssertEqual(FactorBands.heartRate(bpm: 169.999, maxHR: 200), .moderate)
        XCTAssertEqual(FactorBands.heartRate(bpm: 170, maxHR: 200), .high)
        XCTAssertEqual(FactorBands.heartRate(bpm: 140, maxHR: 200), .moderate)
        XCTAssertEqual(FactorBands.heartRate(bpm: 139.999, maxHR: 200), .light)
        XCTAssertNil(FactorBands.heartRate(bpm: nil, maxHR: 200))
        XCTAssertNil(FactorBands.heartRate(bpm: 150, maxHR: nil))
    }

    func testRecoveryBandBoundariesAndColors() {
        XCTAssertEqual(RecoveryBands.band(for: 33), .low)
        XCTAssertEqual(RecoveryBands.band(for: 34), .medium)
        XCTAssertEqual(RecoveryBands.band(for: 66), .medium)
        XCTAssertEqual(RecoveryBands.band(for: 67), .high)

        assertColor(RecoveryBands.color(for: 33), equals: StrandPalette.recoveryLow)
        assertColor(RecoveryBands.color(for: 34), equals: StrandPalette.recoveryMed)
        assertColor(RecoveryBands.color(for: 66), equals: StrandPalette.recoveryMed)
        assertColor(RecoveryBands.color(for: 67), equals: StrandPalette.recoveryHigh)
    }

    private func assertColor(_ actual: Color, equals expected: Color,
                             file: StaticString = #filePath, line: UInt = #line) {
        let actualComponents = actual.rgbaComponents
        let expectedComponents = expected.rgbaComponents
        XCTAssertEqual(actualComponents.r, expectedComponents.r, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualComponents.g, expectedComponents.g, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualComponents.b, expectedComponents.b, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualComponents.a, expectedComponents.a, accuracy: 0.001, file: file, line: line)
    }

    func testHRZoneColor() {
        XCTAssertEqual(StrandPalette.hrZoneColor(1).rgbaComponents.b,
                       StrandPalette.zone1.rgbaComponents.b, accuracy: 0.001)
        XCTAssertEqual(StrandPalette.hrZoneColor(5).rgbaComponents.r,
                       StrandPalette.zone5.rgbaComponents.r, accuracy: 0.001)
        // Clamps out-of-range.
        XCTAssertEqual(StrandPalette.hrZoneColor(99).rgbaComponents.r,
                       StrandPalette.zone5.rgbaComponents.r, accuracy: 0.001)
    }

    func testSleepStageColorMapping() {
        XCTAssertEqual(StrandPalette.sleepStageColor(.rem).rgbaComponents.g,
                       StrandPalette.sleepREM.rgbaComponents.g, accuracy: 0.001)
        XCTAssertEqual(StrandPalette.sleepStageColor(.awake).rgbaComponents.r,
                       StrandPalette.sleepAwake.rgbaComponents.r, accuracy: 0.001)
    }

    func testSleepStageBandRankOrdering() {
        XCTAssertEqual(SleepStage.awake.bandRank, 0)
        XCTAssertEqual(SleepStage.deep.bandRank, 3)
        XCTAssertLessThan(SleepStage.awake.bandRank, SleepStage.deep.bandRank)
    }

    func testSampleMidpointInterpolatesBetweenStops() {
        // Halfway between two black/white stops is mid-grey.
        let stops: [Gradient.Stop] = [
            .init(color: Color(hex: "#000000"), location: 0),
            .init(color: Color(hex: "#FFFFFF"), location: 1),
        ]
        let mid = StrandPalette.sample(stops: stops, at: 0.5).rgbaComponents
        XCTAssertEqual(mid.r, 0.5, accuracy: 0.03)
        XCTAssertEqual(mid.g, 0.5, accuracy: 0.03)
        XCTAssertEqual(mid.b, 0.5, accuracy: 0.03)
    }

    func testSleepIntervalDuration() {
        let i = SleepInterval(stage: .deep, start: 100, end: 460)
        XCTAssertEqual(i.duration, 360, accuracy: 0.001)
    }

    // MARK: - Chart hover toolkit

    func testNearestIndexEvenlySpaced() {
        // 5 samples across width 100 → stride 25. Cursor near each step.
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 0, count: 5, width: 100), 0)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 26, count: 5, width: 100), 1)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 60, count: 5, width: 100), 2)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 100, count: 5, width: 100), 4)
        // Out of range clamps to the ends.
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: -50, count: 5, width: 100), 0)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 999, count: 5, width: 100), 4)
    }

    func testNearestIndexEdgeCases() {
        XCTAssertNil(ChartHoverMath.nearestIndex(toX: 10, count: 0, width: 100))
        // Single sample always resolves to index 0.
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 80, count: 1, width: 100), 0)
    }

    func testNearestIndexArbitraryXs() {
        let xs: [CGFloat] = [0, 30, 90, 200]
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 5, xs: xs), 0)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 35, xs: xs), 1)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 100, xs: xs), 2)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 195, xs: xs), 3)
        XCTAssertNil(ChartHoverMath.nearestIndex(toX: 10, xs: []))
    }

    func testTooltipPlacementStaysInBounds() {
        let container = CGSize(width: 200, height: 120)
        let size = CGSize(width: 80, height: 36)
        // Anchor in the top-left corner: tooltip must clamp fully inside.
        let topLeft = ChartTooltipPlacement.position(anchor: CGPoint(x: 0, y: 0),
                                                     tooltipSize: size, in: container)
        XCTAssertGreaterThanOrEqual(topLeft.x - size.width / 2, -0.001)
        XCTAssertGreaterThanOrEqual(topLeft.y - size.height / 2, -0.001)
        XCTAssertLessThanOrEqual(topLeft.x + size.width / 2, container.width + 0.001)
        XCTAssertLessThanOrEqual(topLeft.y + size.height / 2, container.height + 0.001)

        // Anchor in the bottom-right corner: still inside.
        let bottomRight = ChartTooltipPlacement.position(anchor: CGPoint(x: 200, y: 120),
                                                         tooltipSize: size, in: container)
        XCTAssertLessThanOrEqual(bottomRight.x + size.width / 2, container.width + 0.001)
        XCTAssertLessThanOrEqual(bottomRight.y + size.height / 2, container.height + 0.001)
    }

    func testTooltipPlacementFlipsBelowWhenNoRoomAbove() {
        let container = CGSize(width: 300, height: 200)
        let size = CGSize(width: 60, height: 40)
        // Anchor near the top: with gap 12 there's no room above, so it drops below.
        let pos = ChartTooltipPlacement.position(anchor: CGPoint(x: 150, y: 5),
                                                 tooltipSize: size, in: container, gap: 12)
        XCTAssertGreaterThan(pos.y, 5)
    }

    func testTrendChartDefaultDateStringNonEmpty() {
        let s = TrendChart.defaultDateString(Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertFalse(s.isEmpty)
    }

    func testSparklineDefaultValueString() {
        XCTAssertEqual(Sparkline.defaultValueString(64), "64")
        XCTAssertEqual(Sparkline.defaultValueString(64.5), "64.5")
    }

    // MARK: - TrendChart Y domain (#974 top-headroom fix)

    /// With no explicit yDomain the axis falls back to the gradient's valueRange.
    func testTrendChartResolvedDomainDefaultsToValueRange() {
        let pts = [
            TrendPoint(date: Date(timeIntervalSince1970: 0), value: 10),
            TrendPoint(date: Date(timeIntervalSince1970: 86_400), value: 40),
        ]
        let chart = TrendChart(points: pts, valueRange: 0...100)
        XCTAssertEqual(chart.resolvedYDomain.lowerBound, 0, accuracy: 0.0001)
        XCTAssertEqual(chart.resolvedYDomain.upperBound, 100, accuracy: 0.0001)
    }

    /// An explicit yDomain (a data-fitted axis with top headroom) overrides valueRange, and its
    /// top sits ABOVE the highest reading so a peak curve + the top axis label clear the plot clip.
    func testTrendChartExplicitYDomainProvidesTopHeadroom() {
        let peak = 2.4
        let pts = [
            TrendPoint(date: Date(timeIntervalSince1970: 0), value: 0.5),
            TrendPoint(date: Date(timeIntervalSince1970: 86_400), value: peak),
        ]
        // Mirrors StressView's fitted axis: round the peak up, add headroom, floor at 1.
        let yTop = max(1, peak.rounded(.up) + 0.3)
        let chart = TrendChart(points: pts, valueRange: 0...3, yDomain: 0...yTop)
        XCTAssertEqual(chart.resolvedYDomain.lowerBound, 0, accuracy: 0.0001)
        // 2.4 → ceil 3 → +0.3 = 3.3, comfortably above the peak.
        XCTAssertGreaterThan(chart.resolvedYDomain.upperBound, peak)
        XCTAssertEqual(chart.resolvedYDomain.upperBound, 3.3, accuracy: 0.0001)
    }

    /// A flat, all-calm history (max 0) must not collapse to a zero-height axis: the floor holds it at 1.
    func testTrendChartFittedDomainFloorsAtOne() {
        let peak = 0.0
        let yTop = max(1, peak.rounded(.up) + 0.3)
        let pts = [
            TrendPoint(date: Date(timeIntervalSince1970: 0), value: 0),
            TrendPoint(date: Date(timeIntervalSince1970: 86_400), value: 0),
        ]
        let chart = TrendChart(points: pts, valueRange: 0...3, yDomain: 0...yTop)
        XCTAssertEqual(chart.resolvedYDomain.upperBound, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(chart.resolvedYDomain.upperBound, chart.resolvedYDomain.lowerBound)
    }
}
