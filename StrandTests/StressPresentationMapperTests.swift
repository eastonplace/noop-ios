import XCTest
import StrandAnalytics
@testable import Strand

final class StressPresentationMapperTests: XCTestCase {
    func testBandThresholdsStayOnTheSharedZeroToThreeScale() {
        XCTAssertEqual(StressPresentationMapper.band(for: 0), .low)
        XCTAssertEqual(StressPresentationMapper.band(for: 0.999), .low)
        XCTAssertEqual(StressPresentationMapper.band(for: 1), .medium)
        XCTAssertEqual(StressPresentationMapper.band(for: 1.999), .medium)
        XCTAssertEqual(StressPresentationMapper.band(for: 2), .high)
        XCTAssertEqual(StressPresentationMapper.band(for: 3), .high)
    }

    func testPeakAnnotationUsesExplicitResultPeakInsteadOfRecomputingHoursMaximum() {
        let explicitPeak = point(hour: 14, level: 2.4)
        let visuallyHigherDifferentHour = point(hour: 15, level: 2.9)
        let result = DaytimeStress.Result(
            hours: [explicitPeak, visuallyHigherDifferentHour],
            sustainedHigh: false,
            sustainedRun: 0,
            dayMean: 2.65,
            peak: explicitPeak
        )

        let annotation = StressPresentationMapper.peakAnnotation(
            peak: result.peak,
            hourLabel: { "H\($0)" }
        )

        XCTAssertEqual(annotation, "PEAK 2.4 · H14")
        XCTAssertFalse(annotation?.contains("2.9") == true)
        XCTAssertFalse(annotation?.contains("H15") == true)
    }

    func testPeakAnnotationIsAbsentWhenEngineHasNoScoredPeak() {
        XCTAssertNil(StressPresentationMapper.peakAnnotation(peak: nil, hourLabel: { "H\($0)" }))
        XCTAssertNil(StressPresentationMapper.peakAnnotation(
            peak: point(hour: 8, level: nil),
            hourLabel: { "H\($0)" }
        ))
    }

    func testStressTotalsFractionsUseOnlyScoredHours() {
        let totals = StressTotals(hours: [
            point(hour: 6, level: 0.4),
            point(hour: 7, level: 0.9),
            point(hour: 8, level: 1.0),
            point(hour: 9, level: 1.8),
            point(hour: 10, level: 2.0),
            point(hour: 11, level: nil),
        ])

        XCTAssertEqual(totals.total, 5)
        XCTAssertEqual(totals.calmHours, 2)
        XCTAssertEqual(totals.moderateHours, 2)
        XCTAssertEqual(totals.highHours, 1)
        XCTAssertEqual(totals.fraction(.low), 0.4, accuracy: 1e-12)
        XCTAssertEqual(totals.fraction(.medium), 0.4, accuracy: 1e-12)
        XCTAssertEqual(totals.fraction(.high), 0.2, accuracy: 1e-12)
    }

    func testStressTotalsZeroStateKeepsEveryRailEmpty() {
        let totals = StressTotals(hours: [
            point(hour: 6, level: nil),
            point(hour: 7, level: nil),
        ])

        XCTAssertEqual(totals.total, 0)
        XCTAssertEqual(totals.fraction(.low), 0)
        XCTAssertEqual(totals.fraction(.medium), 0)
        XCTAssertEqual(totals.fraction(.high), 0)
    }

    private func point(hour: Int, level: Double?) -> DaytimeStress.HourPoint {
        DaytimeStress.HourPoint(
            hour: hour,
            startTs: hour * DaytimeStress.bucketSeconds,
            level: level,
            meanHR: level == nil ? nil : 64,
            rmssd: level == nil ? nil : 42
        )
    }
}
