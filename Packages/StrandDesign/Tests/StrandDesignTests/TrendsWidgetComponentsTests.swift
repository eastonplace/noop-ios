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

    // MARK: Isolated days, weekday names, units

    func testAnIsolatedDayOnALongRangeIsStillMarkedForADot() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000))
        // 120 days. Days 0...39 are recorded, then a long gap, day 70 stands alone, then another long gap and a
        // run from day 100: with more than 35 points the dots switch off, so the lone day needs its own rule.
        let recorded = Set(Array(0...39) + [70] + Array(100...119))
        let days = (0..<120).map { offset in
            CalendarMetricDay(
                date: calendar.date(byAdding: .day, value: offset, to: start)!,
                value: recorded.contains(offset) ? 60 + Double(offset % 7) : nil
            )
        }
        let hero = TrendsHeroChart(
            days: days, dateDomain: start...calendar.date(byAdding: .day, value: 119, to: start)!,
            referenceDate: start, calendar: calendar, baseline: 62, typical: 58...66, tint: .neutral, unit: "")

        XCTAssertGreaterThan(hero.points.count, 35)
        let lone = hero.points.firstIndex { calendar.dateComponents([.day], from: start, to: $0.date).day == 70 }
        XCTAssertNotNil(lone)
        XCTAssertEqual(hero.singletonIndices, Set([lone].compactMap { $0 }))
    }

    /// Day counts use the calendar the window is built in, but the labels are printed in the calendar the person reads dates
    /// in: on a Buddhist-calendar device a year-long axis says 2568 and 2569, the same era the rest of the page uses.
    func testTheAxisLabelsFollowTheDisplayCalendarWhileTheWindowKeepsItsOwn() {
        let gregorian = Calendar(identifier: .gregorian)
        let start = gregorian.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000))
        let end = gregorian.date(byAdding: .day, value: 400, to: start)!
        let days = (0...400).map { CalendarMetricDay(date: gregorian.date(byAdding: .day, value: $0, to: start)!, value: 60) }
        func chart(display: Calendar?) -> TrendsHeroChart {
            TrendsHeroChart(
                days: days, dateDomain: start...end, referenceDate: end, calendar: gregorian, displayCalendar: display,
                baseline: 60, typical: 55...65, tint: .neutral, unit: "", longRange: true)
        }
        let plain = chart(display: nil).tickLabels.map(\.label)
        let buddhist = chart(display: Calendar(identifier: .buddhist)).tickLabels.map(\.label)
        XCTAssertEqual(plain.count, buddhist.count)
        // The last label is "Today"-style wording from the window's own calendar; the others carry a year.
        XCTAssertTrue(plain.dropLast().contains { $0.contains("2025") || $0.contains("2026") }, "\(plain)")
        XCTAssertTrue(buddhist.dropLast().contains { $0.contains("2568") || $0.contains("2569") }, "\(buddhist)")
        XCTAssertFalse(buddhist.dropLast().contains { $0.contains("2025") || $0.contains("2026") }, "\(buddhist)")
    }

    /// The scrub caption and the day VoiceOver speaks are printed in the person's calendar as the axis is, on a short range as
    /// well as a year-long one; Today and Yesterday still count days in the window's own calendar.
    func testTheScrubCaptionAndSpokenDayFollowTheDisplayCalendarOnShortRanges() {
        let gregorian = Calendar(identifier: .gregorian)
        let end = gregorian.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000))
        let start = gregorian.date(byAdding: .day, value: -29, to: end)!
        let days = (0...29).map { CalendarMetricDay(date: gregorian.date(byAdding: .day, value: $0, to: start)!, value: 60) }
        func chart(display: Calendar?) -> TrendsHeroChart {
            TrendsHeroChart(
                days: days, dateDomain: start...end, referenceDate: end, calendar: gregorian, displayCalendar: display,
                baseline: 60, typical: 55...65, tint: .neutral, unit: "")
        }
        let earlier = gregorian.date(byAdding: .day, value: -12, to: end)!
        let yesterday = gregorian.date(byAdding: .day, value: -1, to: end)!
        let plain = chart(display: nil)
        let persian = chart(display: Calendar(identifier: .persian))

        XCTAssertEqual(plain.dayLabel(earlier), TrendCalendar.relativeLabel(for: earlier, relativeTo: end, calendar: gregorian))
        XCTAssertNotEqual(persian.dayLabel(earlier), plain.dayLabel(earlier), "Same day, a different calendar")
        XCTAssertEqual(
            persian.dayLabel(earlier),
            TrendsDateFormatters.shared.string(from: earlier, template: "EEE MMM d", calendar: Calendar(identifier: .persian)))
        XCTAssertEqual(persian.dayLabel(end), plain.dayLabel(end))
        XCTAssertEqual(persian.dayLabel(yesterday), plain.dayLabel(yesterday))
        // The last axis label reads the same way when the window does not end on the reference day.
        let behind = gregorian.date(byAdding: .day, value: 5, to: end)!
        XCTAssertNotEqual(
            TrendCalendar.relativeLabel(for: end, relativeTo: behind, calendar: gregorian, displayCalendar: Calendar(identifier: .persian)),
            TrendCalendar.relativeLabel(for: end, relativeTo: behind, calendar: gregorian))
    }

    /// A weekly series has a reading every seven days, past the default three-day gap limit, so by default every
    /// reading stands alone with no line between them. A caller that knows the cadence passes a limit to match and
    /// gets one connected line with no stranded dots.
    func testAWeeklySeriesDrawsOneConnectedLineWhenTheGapLimitMatchesItsCadence() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000))
        // The chart takes one entry per calendar day, with no value on the days nothing was recorded.
        let days = (0..<70).map { offset in
            CalendarMetricDay(
                date: calendar.date(byAdding: .day, value: offset, to: start)!,
                value: offset % 7 == 0 ? 70 + Double(offset % 5) : nil)
        }
        func chart(maxGapDays: Int?) -> TrendsHeroChart {
            let domain = start...calendar.date(byAdding: .day, value: 69, to: start)!
            if let maxGapDays {
                return TrendsHeroChart(
                    days: days, dateDomain: domain, referenceDate: start, calendar: calendar, baseline: 72,
                    typical: 68...76, tint: .neutral, unit: "kg", maxGapDays: maxGapDays)
            }
            return TrendsHeroChart(
                days: days, dateDomain: domain, referenceDate: start, calendar: calendar, baseline: 72,
                typical: 68...76, tint: .neutral, unit: "kg")
        }
        XCTAssertEqual(chart(maxGapDays: nil).singletonIndices.count, 10)
        XCTAssertEqual(chart(maxGapDays: 21).singletonIndices, [])
        // One missing week (a 14-day hole) is still bridged at a 21-day limit; three missing weeks are not.
        XCTAssertEqual(TrendCurve.runs(dayIndices: [0, 7, 21, 28], maxGapDays: 21).count, 1)
        XCTAssertEqual(TrendCurve.runs(dayIndices: [0, 7, 42, 49], maxGapDays: 21).count, 2)
    }

    func testTheDefaultPillToneFollowsTheSignOfTheMove() {
        func tone(_ value: Double, _ direction: TrendPanelChart.Direction) -> StrandTone {
            TrendsHeroChart.deltaTone(
                value: value, baseline: 60, typical: 55...65, direction: direction, neutralInsideTypical: false)
        }
        XCTAssertEqual(tone(62, .higherIsBetter), .positive)
        XCTAssertEqual(tone(58, .higherIsBetter), .critical)
        XCTAssertEqual(tone(58, .lowerIsBetter), .positive)
        XCTAssertEqual(tone(62, .lowerIsBetter), .critical)
        XCTAssertEqual(tone(62, .contextual), .neutral)
    }

    /// Inside the typical band a move off the average is ordinary and reads neutral; outside it the colour follows the
    /// side the value fell on and the metric's polarity (a low resting heart rate is good, a low HRV is not).
    func testAPillInsideTheTypicalBandIsNeutralAndOutsideItFollowsPolarity() {
        func tone(_ value: Double, _ direction: TrendPanelChart.Direction) -> StrandTone {
            TrendsHeroChart.deltaTone(
                value: value, baseline: 60, typical: 55...65, direction: direction, neutralInsideTypical: true)
        }
        for direction in [TrendPanelChart.Direction.higherIsBetter, .lowerIsBetter, .contextual] {
            XCTAssertEqual(tone(55, direction), .neutral)
            XCTAssertEqual(tone(58, direction), .neutral)
            XCTAssertEqual(tone(65, direction), .neutral)
        }
        XCTAssertEqual(tone(70, .higherIsBetter), .positive)
        XCTAssertEqual(tone(50, .higherIsBetter), .critical)
        XCTAssertEqual(tone(70, .lowerIsBetter), .critical)
        XCTAssertEqual(tone(50, .lowerIsBetter), .positive)
        XCTAssertEqual(tone(70, .contextual), .neutral)
        XCTAssertEqual(tone(50, .contextual), .neutral)
    }

    func testWeekdayNamesFollowTheLocaleAndStartOnMonday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        let short = TrendsWeekdayNames.veryShort(calendar: calendar)
        let full = TrendsWeekdayNames.full(calendar: calendar)
        XCTAssertEqual(short.count, 7)
        XCTAssertEqual(full.count, 7)
        // Symbols run Sunday first; the grid runs Monday first, so Sunday ends the list.
        XCTAssertEqual(full.first, calendar.standaloneWeekdaySymbols[1])
        XCTAssertEqual(full.last, calendar.standaloneWeekdaySymbols[0])
        XCTAssertEqual(short.first, calendar.veryShortStandaloneWeekdaySymbols[1])
    }

    func testUnitSuffixIsSpacedForWordsAndLocaleAwareForPercent() {
        XCTAssertEqual(TrendsUnitSuffix.text(for: ""), "")
        XCTAssertEqual(TrendsUnitSuffix.text(for: "bpm"), " bpm")
        XCTAssertTrue(TrendsUnitSuffix.text(for: "%").hasSuffix("%"))
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

    // MARK: Training load value axis

    /// The page's own case: a six-week load that runs from about 6.6 to 13.4 gets the mockup's 6, 8, 10, 12, 14.
    func testLoadAxisDrawsFourOrFiveRoundGridlinesAcrossTheWholeRange() {
        let axis = TrendsLoadChart.valueAxis(low: 6.6, high: 13.4)
        XCTAssertEqual(axis.ticks, [6, 8, 10, 12, 14])
        XCTAssertEqual(axis.step, 2)
    }

    /// A narrow range was the bug: 9.4 to 13 drew only 10 and 12. It now draws every whole number across it.
    func testLoadAxisNeverLeavesTwoGridlinesOnANarrowRange() {
        let axis = TrendsLoadChart.valueAxis(low: 9.4, high: 13)
        XCTAssertEqual(axis.ticks, [9, 10, 11, 12, 13])
    }

    func testLoadAxisKeepsEveryValueInsideTheLabelledRange() {
        let cases: [(Double, Double)] = [(0, 0), (10, 10), (10, 10.2), (3.04, 3.06), (0.2, 4.1), (9.6, 11.6), (10.15, 11.9),
                                         (6, 14), (0, 21), (1.1, 20.9), (7.999999999, 12.000000001), (0.0, 0.3)]
        for (low, high) in cases {
            let axis = TrendsLoadChart.valueAxis(low: low, high: high)
            XCTAssertTrue((4...5).contains(axis.ticks.count), "\(low)...\(high): \(axis.ticks)")
            XCTAssertLessThanOrEqual(axis.ticks.first!, low + 1e-9, "\(low)...\(high): the lowest value is above the first gridline")
            XCTAssertGreaterThanOrEqual(axis.ticks.last!, high - 1e-9, "\(low)...\(high): the highest value is below the last gridline")
            XCTAssertLessThan(axis.lower, axis.ticks.first!, "the outer labels sit inside the plot")
            XCTAssertGreaterThan(axis.upper, axis.ticks.last!)
            XCTAssertEqual(axis.ticks, axis.ticks.sorted())
            for pair in zip(axis.ticks, axis.ticks.dropFirst()) {
                XCTAssertEqual(pair.1 - pair.0, axis.step, accuracy: 1e-6, "even steps")
            }
        }
    }

    func testLoadAxisNeverGoesBelowZeroForAPlainLoad() {
        XCTAssertEqual(TrendsLoadChart.valueAxis(low: 0, high: 0).ticks.first, 0)
        XCTAssertGreaterThanOrEqual(TrendsLoadChart.valueAxis(low: 0.05, high: 0.3).ticks.first!, 0)
    }
}
