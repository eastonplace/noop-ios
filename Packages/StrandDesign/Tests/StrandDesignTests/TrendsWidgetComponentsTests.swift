import SwiftUI
import XCTest
@testable import StrandDesign

final class TrendsWidgetComponentsTests: XCTestCase {

    // MARK: Monotone curve

    /// Samples every cubic segment of `path` and returns (segment start y, segment end y, sampled y values).
    private func sampledSegments(_ path: Path) -> [(start: CGFloat, end: CGFloat, samples: [CGFloat])] {
        var segments: [(start: CGFloat, end: CGFloat, samples: [CGFloat])] = []
        var current = CGPoint.zero
        path.forEach { element in
            switch element {
            case .move(let to):
                current = to
            case .curve(let to, let c1, let c2):
                let samples = stride(from: 0.0, through: 1.0, by: 0.05).map { t -> CGFloat in
                    let u = CGFloat(t)
                    let a = (1 - u) * (1 - u) * (1 - u)
                    let b = 3 * (1 - u) * (1 - u) * u
                    let c = 3 * (1 - u) * u * u
                    let d = u * u * u
                    return a * current.y + b * c1.y + c * c2.y + d * to.y
                }
                segments.append((current.y, to.y, samples))
                current = to
            default:
                break
            }
        }
        return segments
    }

    func testMonotoneCurveNeverLeavesTheSpanOfTheTwoSamplesItJoins() {
        // A spiky daily series: the shape that makes a Catmull-Rom spline invent peaks and troughs.
        let ys: [CGFloat] = [40, 38, 90, 12, 14, 70, 69, 20, 22, 95, 30]
        let points = ys.enumerated().map { CGPoint(x: CGFloat($0.offset) * 10, y: $0.element) }
        var path = Path()
        TrendCurve.append(points, to: &path)

        let segments = sampledSegments(path)
        XCTAssertEqual(segments.count, ys.count - 1)
        for segment in segments {
            let low = min(segment.start, segment.end) - 0.0001
            let high = max(segment.start, segment.end) + 0.0001
            for sample in segment.samples {
                XCTAssertGreaterThanOrEqual(sample, low, "curve dipped below the samples it joins")
                XCTAssertLessThanOrEqual(sample, high, "curve rose above the samples it joins")
            }
        }
    }

    func testMonotoneCurveHandlesTwoPointsAndFlatRuns() {
        var two = Path()
        TrendCurve.append([CGPoint(x: 0, y: 5), CGPoint(x: 10, y: 5)], to: &two)
        for segment in sampledSegments(two) {
            XCTAssertTrue(segment.samples.allSatisfy { abs($0 - 5) < 0.0001 })
        }

        var empty = Path()
        TrendCurve.append([], to: &empty)
        XCTAssertTrue(empty.isEmpty)

        var single = Path()
        TrendCurve.append([CGPoint(x: 1, y: 1)], to: &single)
        XCTAssertTrue(sampledSegments(single).isEmpty)
    }

    func testRunsBreakOnlyOnLongGaps() {
        XCTAssertEqual(TrendCurve.runs(dayIndices: [], maxGapDays: 3), [])
        XCTAssertEqual(TrendCurve.runs(dayIndices: [0, 1, 2, 4, 7], maxGapDays: 3), [0..<5])
        XCTAssertEqual(TrendCurve.runs(dayIndices: [0, 1, 2, 9, 10], maxGapDays: 3), [0..<3, 3..<5])
        XCTAssertEqual(TrendCurve.runs(dayIndices: [3], maxGapDays: 3), [0..<1])
    }

    // MARK: Axis

    func testAxisNeverRunsPastWhatTheMetricCanBe() {
        let axis = TrendsAxis.make(values: [8, 40, 99], baseline: 39, bounds: 0...100)
        XCTAssertGreaterThanOrEqual(axis.lower, 0)
        XCTAssertLessThanOrEqual(axis.upper, 100)
        XCTAssertLessThan(axis.lower, 8.0 + 0.0001)
        XCTAssertGreaterThan(axis.upper, 98.9)
    }

    func testAxisSurvivesAFlatSeriesAndNonFiniteValues() {
        let flat = TrendsAxis.make(values: [50, 50, 50], baseline: 50, bounds: 0...100)
        XCTAssertGreaterThan(flat.upper, flat.lower)
        XCTAssertEqual(flat.unit(50), 0.5, accuracy: 0.05)

        let noisy = TrendsAxis.make(values: [.nan, .infinity, 3, 4], baseline: .nan, bounds: 0...100)
        XCTAssertTrue(noisy.lower.isFinite && noisy.upper.isFinite)
        XCTAssertGreaterThan(noisy.upper, noisy.lower)

        let empty = TrendsAxis.make(values: [], baseline: .nan, bounds: 0...100)
        XCTAssertTrue(empty.lower.isFinite && empty.upper.isFinite)
    }

    // MARK: Defaults

    func testNewComponentsRejectNonFiniteValuesInTheirDefaultFormat() {
        let now = Date()
        let hero = TrendsHeroChart(
            days: [], dateDomain: now...now, referenceDate: now, baseline: 0, typical: -1...1,
            tint: .neutral, unit: ""
        )
        let heat = TrendsCalendarHeat(days: [], tint: .neutral)
        let weekdays = TrendsWeekdayBars(values: [], tint: .neutral)
        for format in [hero.valueFormat, heat.valueFormat, weekdays.valueFormat] {
            XCTAssertEqual(format(.nan), "—")
            XCTAssertEqual(format(.infinity), "—")
            XCTAssertFalse(format(Double(Int.max)).isEmpty)
        }
    }
}
