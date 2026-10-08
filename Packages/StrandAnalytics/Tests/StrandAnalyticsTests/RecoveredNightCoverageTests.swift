import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

final class RecoveredNightCoverageTests: XCTestCase {
    private let start = 1_790_000_000

    func testShortRRFragmentCannotRepresentTenHourRecoveredNight() {
        let rr = (0..<300).map { RRInterval(ts: start + $0, rrMs: $0.isMultiple(of: 2) ? 800 : 900) }
        let result = SleepWindowRecovery.analyze(start: start, end: start + 36_000,
            hr: (0..<36_000).map { HRSample(ts: start + $0, bpm: 60) }, rr: rr)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertNil(result.avgHRV, "A short fragment is not a nightly baseline measurement")
        XCTAssertEqual(result.restingHR, 60)
    }

    func testDenseRRStillSupportsVitalsWhenMotionIsMissing() {
        let rr = (0..<3600).map { RRInterval(ts: start + $0, rrMs: $0.isMultiple(of: 2) ? 800 : 850) }
        let result = SleepWindowRecovery.analyze(start: start, end: start + 3600,
            hr: (0..<3600).map { HRSample(ts: start + $0, bpm: 60) }, rr: rr)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.avgHRV ?? -1, 50, accuracy: 0.001)
    }

    func testRejectedBeatsDoNotQualifyNightlyCoverage() {
        let rr = stride(from: 0, to: 3600, by: 300).flatMap { offset in
            [RRInterval(ts: start + offset, rrMs: 800),
             RRInterval(ts: start + offset + 1, rrMs: 900),
             RRInterval(ts: start + offset + 2, rrMs: 10)]
        }
        let result = SleepWindowRecovery.analyze(start: start, end: start + 3600,
            hr: [HRSample(ts: start, bpm: 60)], rr: rr)
        XCTAssertNil(result.avgHRV)
    }

    func testMissingRecomputedHRVDoesNotResurrectPreviousOverride() {
        let result = SleepWindowRecovery.analyze(start: start, end: start + 3600,
            hr: (0..<3600).map { HRSample(ts: start + $0, bpm: 60) })
        let existing = DailyMetric(day: "2026-09-27", totalSleepMin: nil, efficiency: nil,
            deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
            restingHr: 56, avgHrv: 99, recovery: 99, strain: 1, exerciseCount: 0)
        let score = ManualSleepDailyScorer.score(day: "2026-09-27", analysis: result,
            existing: existing, priorHistory: [])
        XCTAssertNil(score.daily.avgHrv)
        XCTAssertNil(score.daily.recovery)
        XCTAssertEqual(score.daily.strain, 1)
    }
}
