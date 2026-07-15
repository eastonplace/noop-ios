import XCTest
import StrandDesign
@testable import Strand

final class SleepPresentationMapperTests: XCTestCase {
    func testStageRowMapsResolvedTotalsToFractionPercentAndExistingDurationFormat() {
        let row = SleepStageRowPresentation(
            stage: .rem,
            minutes: 104,
            total: 431
        )

        XCTAssertEqual(row.fraction, 104.0 / 431.0, accuracy: 1e-12)
        XCTAssertEqual(row.percent, 24)
        XCTAssertEqual(row.duration, "1h 44m")
        XCTAssertNil(row.delta)
        XCTAssertNil(row.deltaTone)
    }

    func testStageRowClampsInvalidFractionsWithoutFabricatingDuration() {
        let noTotal = SleepStageRowPresentation(stage: .deep, minutes: 45, total: 0)
        let overTotal = SleepStageRowPresentation(stage: .light, minutes: 90, total: 60)
        let negative = SleepStageRowPresentation(stage: .awake, minutes: -10, total: 60)

        XCTAssertEqual(noTotal.fraction, 0)
        XCTAssertEqual(noTotal.percent, 0)
        XCTAssertEqual(noTotal.duration, "45m")
        XCTAssertEqual(overTotal.fraction, 1)
        XCTAssertEqual(overTotal.percent, 100)
        XCTAssertEqual(negative.fraction, 0)
        XCTAssertEqual(negative.duration, "0m")
    }

    func testStageDeltaToneMatchesExplicitLabDirectionOnly() {
        let moreDeep = SleepStageRowPresentation(
            stage: .deep,
            minutes: 101,
            total: 431,
            typical: 92
        )
        let lessDeep = SleepStageRowPresentation(
            stage: .deep,
            minutes: 80,
            total: 431,
            typical: 92
        )
        let moreAwake = SleepStageRowPresentation(
            stage: .awake,
            minutes: 40,
            total: 431,
            typical: 31
        )
        let lessAwake = SleepStageRowPresentation(
            stage: .awake,
            minutes: 24,
            total: 431,
            typical: 31
        )

        XCTAssertEqual(moreDeep.delta, "+9m vs typ")
        XCTAssertEqual(moreDeep.deltaTone, .positive)
        XCTAssertEqual(lessDeep.delta, "−12m vs typ")
        XCTAssertEqual(lessDeep.deltaTone, .warning)
        XCTAssertEqual(moreAwake.delta, "+9m vs typ")
        XCTAssertEqual(moreAwake.deltaTone, .warning)
        XCTAssertEqual(lessAwake.delta, "−7m vs typ")
        XCTAssertEqual(lessAwake.deltaTone, .positive)
    }

    func testMissingTypicalKeepsDeltaNeutralAndAbsent() {
        let missing = SleepStageRowPresentation(
            stage: .rem,
            minutes: 100,
            total: 420,
            typical: nil
        )
        let zero = SleepStageRowPresentation(
            stage: .rem,
            minutes: 100,
            total: 420,
            typical: 0
        )

        XCTAssertNil(missing.delta)
        XCTAssertNil(missing.deltaTone)
        XCTAssertNil(zero.delta)
        XCTAssertNil(zero.deltaTone)
    }

    func testStageLessWindowUsesRecordedCoverageInsteadOfZeroStageTotal() {
        let window = SleepWindowPresentation(
            hasStageData: false,
            asleepMinutes: 0,
            stagedInBedMinutes: 0,
            sessionStartTs: 82_800,
            sessionEndTs: 111_600
        )

        XCTAssertEqual(window.asleepDuration, "—")
        XCTAssertEqual(window.inBedDuration, "8h 0m")
    }

    func testStagedWindowKeepsExistingStageTotalSemantics() {
        let window = SleepWindowPresentation(
            hasStageData: true,
            asleepMinutes: 407,
            stagedInBedMinutes: 431,
            sessionStartTs: 82_800,
            sessionEndTs: 111_600
        )

        XCTAssertEqual(window.asleepDuration, "6h 47m")
        XCTAssertEqual(window.inBedDuration, "7h 11m")
    }
}
