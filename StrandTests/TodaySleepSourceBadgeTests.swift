import XCTest
import StrandAnalytics
@testable import Strand

final class TodaySleepSourceBadgeTests: XCTestCase {
    private let day = "2026-07-20"

    func testWhoopBadgeUsesExactDisplayedPoint() {
        let point = SleepScorePoint(day: day, value: 84, source: .whoopImport, modelVersion: nil)

        XCTAssertEqual(
            TodayView.displayedSleepSourcePoint(
                day: day, value: 84, resolvedSource: "my-whoop", deviceId: "my-whoop",
                v2IsAuthoritative: false, noopV2: [], whoop: [point]),
            point)
    }

    func testWhoopBadgeRejectsDifferentDayOrValue() {
        let point = SleepScorePoint(day: "2026-07-19", value: 84, source: .whoopImport, modelVersion: nil)

        XCTAssertNil(TodayView.displayedSleepSourcePoint(
            day: day, value: 84, resolvedSource: "my-whoop", deviceId: "my-whoop",
            v2IsAuthoritative: false, noopV2: [], whoop: [point]))
        XCTAssertNil(TodayView.displayedSleepSourcePoint(
            day: "2026-07-19", value: 83, resolvedSource: "my-whoop", deviceId: "my-whoop",
            v2IsAuthoritative: false, noopV2: [], whoop: [point]))
    }

    func testShadowModeNeverLabelsComputedLegacyScoreAsV2() {
        let point = SleepScorePoint(
            day: day, value: 88, source: .noopMeasured,
            modelVersion: SleepPerformanceV2.modelVersion)

        XCTAssertNil(TodayView.displayedSleepSourcePoint(
            day: day, value: 88, resolvedSource: "my-whoop-noop", deviceId: "my-whoop",
            v2IsAuthoritative: false, noopV2: [point], whoop: []))
    }

    func testAuthoritativeV2BadgeUsesExactV2Point() {
        let point = SleepScorePoint(
            day: day, value: 88, source: .noopEdited,
            modelVersion: SleepPerformanceV2.modelVersion)

        XCTAssertEqual(
            TodayView.displayedSleepSourcePoint(
                day: day, value: 88, resolvedSource: "my-whoop-noop", deviceId: "my-whoop",
                v2IsAuthoritative: true, noopV2: [point], whoop: []),
            point)
    }

    func testMissingDisplayedValueOrProvenanceHasNoBadge() {
        let point = SleepScorePoint(day: day, value: 84, source: .whoopImport, modelVersion: nil)

        XCTAssertNil(TodayView.displayedSleepSourcePoint(
            day: day, value: nil, resolvedSource: "my-whoop", deviceId: "my-whoop",
            v2IsAuthoritative: false, noopV2: [], whoop: [point]))
        XCTAssertNil(TodayView.displayedSleepSourcePoint(
            day: day, value: 84, resolvedSource: nil, deviceId: "my-whoop",
            v2IsAuthoritative: false, noopV2: [], whoop: [point]))
    }
}
