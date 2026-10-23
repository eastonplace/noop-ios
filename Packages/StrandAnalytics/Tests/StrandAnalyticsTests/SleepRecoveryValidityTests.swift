import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class SleepRecoveryValidityTests: XCTestCase {
    private func stillGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1) }
    }

    private func hr(start: Int, durationS: Int, bpm: Int) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    func testOffWristHeartRateCannotAuthorizeRecoveredSleep() {
        let start = 1_749_520_800
        let duration = 90 * 60
        let recovered = SleepWindowRecovery.analyze(
            start: start,
            end: start + duration,
            hr: hr(start: start, durationS: duration, bpm: 0),
            gravity: stillGravity(start: start, durationS: duration))

        XCTAssertEqual(recovered.outcome, .insufficientData)
        XCTAssertEqual(recovered.reason, .noPhysiology)
        XCTAssertFalse(recovered.canPersistSession,
                       "a motionless off-wrist strap is not evidence of a recovered night")
        XCTAssertTrue(recovered.stages.isEmpty)
        XCTAssertNil(recovered.restingHR)
        XCTAssertEqual(recovered.evidence.hrSamples, 0)
        XCTAssertEqual(recovered.evidence.hrCoverage, 0)
        XCTAssertEqual(recovered.confidence, 0)
    }

    func testMixedInvalidHeartRateDoesNotChangeRecoveredVitalsOrCoverage() {
        let start = 1_749_520_800
        let duration = 30 * 60
        let valid = stride(from: 0, to: duration, by: 2).map {
            HRSample(ts: start + $0, bpm: 60)
        }
        let invalid = stride(from: 1, to: duration, by: 2).map {
            HRSample(ts: start + $0, bpm: 0)
        }
        let recovered = SleepWindowRecovery.analyze(
            start: start,
            end: start + duration,
            hr: Array((valid + invalid).reversed()),
            gravity: stillGravity(start: start, durationS: duration))

        XCTAssertEqual(recovered.outcome, .complete)
        XCTAssertEqual(recovered.restingHR, 60)
        XCTAssertEqual(recovered.evidence.hrSamples, valid.count)
        XCTAssertEqual(recovered.evidence.hrCoverage, 1)
    }

    func testInvalidRRAloneCannotAuthorizeRecoveredSleep() {
        let start = 1_749_520_800
        let duration = 30 * 60
        let invalid = (0..<duration).map {
            RRInterval(ts: start + $0, rrMs: [0, 299, 2_001][$0 % 3])
        }
        let recovered = SleepWindowRecovery.analyze(
            start: start,
            end: start + duration,
            rr: invalid,
            gravity: stillGravity(start: start, durationS: duration))

        XCTAssertEqual(recovered.outcome, .insufficientData)
        XCTAssertEqual(recovered.reason, .noPhysiology)
        XCTAssertFalse(recovered.canPersistSession)
        XCTAssertNil(recovered.avgHRV)
        XCTAssertEqual(recovered.evidence.rrSamples, 0)
        XCTAssertEqual(recovered.evidence.rrCoverage, 0)
    }

    func testValidRROnlyRecoverySurvivesInvalidHeartRate() {
        let start = 1_749_520_800
        let duration = 30 * 60
        let rr = (0..<duration).map {
            RRInterval(ts: start + $0, rrMs: $0.isMultiple(of: 2) ? 800 : 820)
        }
        let recovered = SleepWindowRecovery.analyze(
            start: start,
            end: start + duration,
            hr: hr(start: start, durationS: duration, bpm: 0),
            rr: Array(rr.reversed()))

        XCTAssertEqual(recovered.outcome, .partial)
        XCTAssertTrue(recovered.canPersistSession)
        XCTAssertNil(recovered.restingHR)
        XCTAssertEqual(recovered.avgHRV ?? -1, 20, accuracy: 1e-9)
        XCTAssertEqual(recovered.evidence.hrSamples, 0)
        XCTAssertEqual(recovered.evidence.rrSamples, rr.count)
    }

}
