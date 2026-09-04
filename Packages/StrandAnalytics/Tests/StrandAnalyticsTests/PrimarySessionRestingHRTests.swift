import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class PrimarySessionRestingHRTests: XCTestCase {
    func testLongestSessionWinsAndInvalidSamplesAreExcluded() {
        let nap = PrimarySessionRestingHR.Session(durationSec: 2_000, bpm: Array(repeating: 45, count: 40))
        let night = PrimarySessionRestingHR.Session(
            durationSec: 28_800,
            bpm: Array(repeating: 61, count: 30) + [0, 221]
        )
        let result = PrimarySessionRestingHR.measure(sessions: [nap, night])
        XCTAssertEqual(result?.meanHR, 61)
        XCTAssertEqual(result?.coverage.validSamples, 30)
        XCTAssertEqual(result?.coverage.durationSec, 28_800)
    }

    func testCoverageGateAndStableTie() {
        XCTAssertNil(PrimarySessionRestingHR.meanHR(sessions: [
            .init(durationSec: 3_600, bpm: Array(repeating: 60, count: 29))
        ]))
        let first = PrimarySessionRestingHR.Session(durationSec: 3_600, bpm: Array(repeating: 50, count: 30))
        let second = PrimarySessionRestingHR.Session(durationSec: 3_600, bpm: Array(repeating: 70, count: 30))
        XCTAssertEqual(PrimarySessionRestingHR.meanHR(sessions: [first, second]), 50)
    }

    func testEngineWrapperWindowsHeartRateOnlyOnceToPrimarySession() {
        let night = SleepSession(start: 1_000, end: 5_000, efficiency: 0.9,
                                 stages: [], restingHR: nil, avgHRV: nil)
        let nap = SleepSession(start: 6_000, end: 7_000, efficiency: 0.9,
                               stages: [], restingHR: nil, avgHRV: nil)
        var hr = (0..<40).map { HRSample(ts: 1_000 + $0 * 60, bpm: 58) }
        hr += (0..<40).map { HRSample(ts: 6_000 + $0 * 20, bpm: 45) }
        let result = AnalyticsEngine.primarySessionRestingHRWithCoverage(sessions: [nap, night], hr: hr)
        XCTAssertEqual(result?.meanHR, 58)
        XCTAssertEqual(result?.coverage.validSamples, 40)
        XCTAssertEqual(result?.coverage.durationSec, 4_000)
    }

    func testEngineWrapperRejectsOverflowingSessionDuration() {
        let corrupt = SleepSession(start: Int.min, end: Int.max, efficiency: 0.9,
                                   stages: [], restingHR: nil, avgHRV: nil)
        XCTAssertNil(AnalyticsEngine.primarySessionRestingHRWithCoverage(
            sessions: [corrupt], hr: []
        ))
    }
}
