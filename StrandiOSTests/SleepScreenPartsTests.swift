import XCTest
import CoreGraphics
import StrandDesign
@testable import NOOP

/// The pure rules behind the Sleep tab's presentation: the balance strip's scale, the "on typical"
/// flag, the shares of the night, the score bands, the stage timeline and the spoken durations.
final class SleepScreenPartsTests: XCTestCase {
    // MARK: Balance strip scale

    func testBalanceGeometryGivesSurplusAndDebtOneScale() {
        let layout = SleepBalanceBars.Geometry(minutes: [40, -20], height: 62)
        XCTAssertEqual(layout.perMinute, 1, accuracy: 0.0001)
        XCTAssertEqual(layout.mid, 41, accuracy: 0.0001)
        XCTAssertEqual(layout.barHeight(for: 40), 39, accuracy: 0.0001)
        XCTAssertEqual(layout.barHeight(for: -20), 19, accuracy: 0.0001)
        // A tiny night is still drawn.
        XCTAssertEqual(layout.barHeight(for: 1), 3, accuracy: 0.0001)
    }

    func testBalanceGeometryPutsTheCentreLineAtTheEdgeWhenOnlyOneSideHasBars() {
        let debtOnly = SleepBalanceBars.Geometry(minutes: [-30, -90], height: 62)
        XCTAssertEqual(debtOnly.mid, 6, accuracy: 0.0001, "no empty half above a fortnight of debt")
        XCTAssertEqual(debtOnly.barHeight(for: -90), 62 - 6 - 2, accuracy: 0.0001)

        let surplusOnly = SleepBalanceBars.Geometry(minutes: [30, 60], height: 62)
        XCTAssertEqual(surplusOnly.mid, 56, accuracy: 0.0001, "no empty half below a fortnight of surplus")
        XCTAssertEqual(surplusOnly.barHeight(for: 60), 54, accuracy: 0.0001)
    }

    func testBalanceGeometryHandlesNoNights() {
        let layout = SleepBalanceBars.Geometry(minutes: [], height: 62)
        XCTAssertEqual(layout.mid, 6, accuracy: 0.0001)
        XCTAssertTrue(layout.perMinute.isFinite)
    }

    // MARK: "On typical"

    func testIsOnTypicalIsWithinHalfAMinute() {
        func presentation(_ minutes: Double, typical: Double?) -> SleepStageRowPresentation {
            SleepStageRowPresentation(stage: .deep, minutes: minutes, total: 400, typical: typical)
        }
        XCTAssertTrue(presentation(90, typical: 90).isOnTypical)
        XCTAssertTrue(presentation(90.4, typical: 90).isOnTypical)
        XCTAssertFalse(presentation(90.5, typical: 90).isOnTypical)
        XCTAssertFalse(presentation(91, typical: 90).isOnTypical)
        XCTAssertFalse(presentation(89, typical: 90).isOnTypical)
        XCTAssertFalse(presentation(90, typical: nil).isOnTypical)
        XCTAssertFalse(presentation(90, typical: 0).isOnTypical)
    }

    func testShortDeltaIsSignedAndAbsentWithoutATypical() {
        func delta(_ minutes: Double, typical: Double?) -> String? {
            SleepStageRowPresentation(stage: .rem, minutes: minutes, total: 400, typical: typical).shortDelta
        }
        XCTAssertEqual(delta(97, typical: 90), "+7m")
        XCTAssertEqual(delta(78, typical: 90), "−12m")
        XCTAssertNil(delta(90, typical: nil))
    }

    // MARK: Shares of the night

    func testStageSharesAlwaysAddUpToOneHundred() {
        for minutes in [[301.0, 280, 100, 19], [1, 1, 1], [33, 33, 34], [200, 100, 50, 50], [7, 0, 0, 3]] {
            let shares = SleepStageShares.percents(minutes: minutes)
            XCTAssertEqual(shares.reduce(0, +), 100, "\(minutes) -> \(shares)")
            XCTAssertEqual(shares.count, minutes.count)
        }
    }

    func testStageSharesGiveALeftoverPointOnlyToAStageThatHasMinutes() {
        XCTAssertEqual(SleepStageShares.percents(minutes: [1, 1, 1]), [34, 33, 33])
        XCTAssertEqual(SleepStageShares.percents(minutes: [7, 0, 0, 3]), [70, 0, 0, 30])
    }

    func testStageSharesAreZeroWithoutAnyMinutes() {
        XCTAssertEqual(SleepStageShares.percents(minutes: [0, 0, 0, 0]), [0, 0, 0, 0])
        XCTAssertEqual(SleepStageShares.percents(minutes: []), [])
    }

    // MARK: Score bands

    func testScoreBandUsesTheScoreAsTheDialShowsIt() {
        XCTAssertEqual(SleepScoreBand(score: 0), .poor)
        XCTAssertEqual(SleepScoreBand(score: 49.4), .poor)
        XCTAssertEqual(SleepScoreBand(score: 49.6), .fair, "49.6 shows as 50, which is Fair")
        XCTAssertEqual(SleepScoreBand(score: 69.4), .fair)
        XCTAssertEqual(SleepScoreBand(score: 69.5), .good)
        XCTAssertEqual(SleepScoreBand(score: 84.6), .optimal)
        XCTAssertEqual(SleepScoreBand(score: 100), .optimal)
    }

    // MARK: Need breakdown

    func testNeedBreakdownShowsOnlyWhenV2IsComputed() {
        XCTAssertFalse(SleepNeedBreakdownVisibility.isVisible(mode: .off))
        XCTAssertTrue(SleepNeedBreakdownVisibility.isVisible(mode: .shadow))
        XCTAssertTrue(SleepNeedBreakdownVisibility.isVisible(mode: .on))
    }

    func testSelectedNightSleepNeedUsesOnlyItsOwnTotalAndProvenance() throws {
        let onDevice = ["2026-10-20": 480.0]
        let imported = ["2026-10-20": 450.0, "2026-10-21": 510.0]
        func target(_ day: String) -> SleepNeedFallbackPresentation? {
            SleepNeedFallbackPresentation.resolve(wakeDay: day,
                onDevice: { onDevice[$0] }, imported: { imported[$0] })
        }
        let local = try XCTUnwrap(target("2026-10-20"))
        XCTAssertEqual(local.wakeDay, "2026-10-20")
        XCTAssertEqual(local.minutes, 480)
        XCTAssertEqual(local.source, .onDevice)
        let whoop = try XCTUnwrap(target("2026-10-21"))
        XCTAssertEqual(whoop.wakeDay, "2026-10-21")
        XCTAssertEqual(whoop.minutes, 510)
        XCTAssertEqual(whoop.source, .whoop)
        XCTAssertNil(target("2026-10-19"), "A different night's target must not carry into this night")
    }

    func testSleepNeedFallbackRequiresAValidRecordedTotal() throws {
        for invalid in [Double.nan, .infinity, -1, 0] {
            let imported = try XCTUnwrap(SleepNeedFallbackPresentation.resolve(wakeDay: "2026-10-21",
                onDevice: { _ in invalid }, imported: { _ in 450 }))
            XCTAssertEqual(imported.source, .whoop)
            XCTAssertEqual(imported.minutes, 450)
            XCTAssertNil(SleepNeedFallbackPresentation.resolve(wakeDay: "2026-10-21",
                onDevice: { _ in invalid }, imported: { _ in invalid }))
        }
    }

    func testSleepNeedFallbackRemainsUntilAnExactDayVisibleV2BreakdownExists() {
        let day = "2026-10-21"
        XCTAssertTrue(SleepNeedFallbackPresentation.shouldShow(mode: .off, breakdownDay: day, wakeDay: day))
        for mode in [SleepPerformanceV2Prefs.Mode.shadow, .on] {
            XCTAssertTrue(SleepNeedFallbackPresentation.shouldShow(mode: mode, breakdownDay: nil, wakeDay: day))
            XCTAssertTrue(SleepNeedFallbackPresentation.shouldShow(mode: mode, breakdownDay: "2026-10-20", wakeDay: day))
            XCTAssertFalse(SleepNeedFallbackPresentation.shouldShow(mode: mode, breakdownDay: day, wakeDay: day))
        }
    }

    func testNeedChipFlowBoundsOversizedChipsAndPreservesTheirWrappedHeight() {
        let idealSizes = [CGSize(width: 480, height: 24), CGSize(width: 90, height: 24)]
        var measuredWidths: [CGFloat?] = []
        let geometry = SleepChipFlow.Geometry(width: 240, spacing: 8, count: idealSizes.count) { index, proposedWidth in
            measuredWidths.append(proposedWidth)
            let ideal = idealSizes[index]
            let width = min(ideal.width, proposedWidth ?? ideal.width)
            return CGSize(width: width, height: ideal.height * ceil(ideal.width / width))
        }
        XCTAssertEqual(geometry.size, CGSize(width: 240, height: 80))
        XCTAssertEqual(geometry.items.map(\.origin), [CGPoint.zero, CGPoint(x: 0, y: 56)])
        XCTAssertEqual(geometry.items.map(\.proposedWidth), [240, 90])
        XCTAssertEqual(measuredWidths.compactMap { $0 }, [240, 90])
        for item in geometry.items {
            XCTAssertLessThanOrEqual(item.origin.x + item.proposedWidth, 240)
        }
    }

    func testNeedChipFlowRemeasuresNativePixelOverflowWithoutLosingWrappedHeight() {
        let overflow: CGFloat = 240.33333333333331 - 240
        var measuredWidths: [CGFloat] = []
        let geometry = SleepChipFlow.Geometry(width: 240, spacing: 8, count: 1) { _, proposedWidth in
            guard let proposedWidth else { return CGSize(width: 480, height: 24) }
            measuredWidths.append(proposedWidth)
            return CGSize(width: proposedWidth + overflow, height: proposedWidth < 240 ? 832 : 800)
        }
        XCTAssertLessThanOrEqual(geometry.size.width, 240)
        XCTAssertEqual(geometry.size.height, 832, "Use the adjusted measurement's wrapped height")
        XCTAssertEqual(measuredWidths, [240, 239.66666666666669])
        XCTAssertEqual(geometry.items.first?.proposedWidth, 239.66666666666669,
                       "Placement must use the final measured proposal")
    }

    // MARK: Stage timeline

    @MainActor
    func testTimelineClipsOverlapsAndKeepsGaps() {
        let timeline = SleepStageTimeline([
            SleepInterval(stage: .light, start: 300, end: 1200),   // overlaps the deep fragment before it
            SleepInterval(stage: .deep, start: 0, end: 600),
            SleepInterval(stage: .rem, start: 5000, end: 5600),    // a separate fragment after a long gap
        ])
        XCTAssertEqual(timeline.origin, 0)
        XCTAssertEqual(timeline.span, 5600)
        XCTAssertEqual(timeline.intervals.count, 3)
        for (previous, next) in zip(timeline.intervals, timeline.intervals.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.start, previous.end, "no overlaps")
        }
        XCTAssertTrue(timeline.joins(timeline.intervals[0], timeline.intervals[1]))
        XCTAssertFalse(timeline.joins(timeline.intervals[1], timeline.intervals[2]), "no riser across a gap")
        // The overlapped time is counted once.
        XCTAssertEqual(timeline.stageMinutes[.deep] ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(timeline.stageMinutes[.light] ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(timeline.stageMinutes[.rem] ?? 0, 10, accuracy: 0.001)
    }

    @MainActor
    func testTimelineSmoothsEachRunWithoutBridgingAGap() {
        let timeline = SleepStageTimeline([
            SleepInterval(stage: .light, start: 0, end: 1800),
            SleepInterval(stage: .deep, start: 1800, end: 2400),
            SleepInterval(stage: .awake, start: 2400, end: 2460),  // a minute: absorbed into a neighbour
            SleepInterval(stage: .deep, start: 2460, end: 3000),
            SleepInterval(stage: .rem, start: 9000, end: 9060),    // a minute on its own after a gap: kept
        ], minimumSegment: 300)
        XCTAssertFalse(timeline.intervals.contains { $0.stage == .awake })
        XCTAssertEqual(timeline.intervals.last?.stage, .rem)
        XCTAssertEqual(timeline.intervals.last?.start, 9000)
        XCTAssertEqual(timeline.intervals.last?.end, 9060)
    }

    @MainActor
    func testEmptyTimelineIsEmpty() {
        XCTAssertTrue(SleepStageTimeline([]).isEmpty)
    }

    // MARK: Spoken durations

    func testSpokenDurationRejectsInvalidAndOverflowingSeconds() {
        for value in [Double.nan, .infinity, -.infinity, 1e100, Double(Int.max)] {
            XCTAssertEqual(SleepSpokenDuration.text(minutes: value), String(localized: "Duration unavailable"))
        }
    }

    func testSpokenDurationIsWordsInTheUsersLanguage() {
        let en = Locale(identifier: "en_US")
        let long = SleepSpokenDuration.text(minutes: 125, locale: en)
        XCTAssertTrue(long.contains("2 hours"), long)
        XCTAssertTrue(long.contains("5 minutes"), long)
        XCTAssertTrue(SleepSpokenDuration.text(minutes: 45, locale: en).contains("45 minutes"))
        XCTAssertTrue(SleepSpokenDuration.text(minutes: 60, locale: en).contains("1 hour"))
        XCTAssertTrue(SleepSpokenDuration.text(minutes: 0, locale: en).contains("0 minutes"))
        XCTAssertTrue(SleepSpokenDuration.text(minutes: 125, locale: Locale(identifier: "es_ES")).contains("horas"))
    }
}
