import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class SleepWindowRecoveryTests: XCTestCase {
    private func stillGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1) }
    }

    private func activeGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { index in
            GravitySample(ts: start + index, x: index.isMultiple(of: 2) ? 0 : 0.4, y: 0, z: 1)
        }
    }

    private func hr(start: Int, durationS: Int, bpm: Int) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    func testBoundedRecoveryCanRecoverHighHRNightRejectedByAutomaticDetector() {
        let sleepStart = 1_749_520_800 // 2026-06-10 02:00 UTC
        let awakeStart = sleepStart - 4 * 3_600
        let sleepDuration = 90 * 60
        let awakeDuration = 4 * 3_600

        let allGravity = activeGravity(start: awakeStart, durationS: awakeDuration)
            + stillGravity(start: sleepStart, durationS: sleepDuration)
        let allHR = hr(start: awakeStart, durationS: awakeDuration, bpm: 55)
            + hr(start: sleepStart, durationS: sleepDuration, bpm: 120)

        XCTAssertTrue(
            SleepStager.detectSleep(hr: allHR, gravity: allGravity).isEmpty,
            "the automatic detector should reject the still block because its HR never dipped")

        let recovered = SleepWindowRecovery.analyze(
            start: sleepStart,
            end: sleepStart + sleepDuration,
            hr: allHR,
            gravity: allGravity)

        XCTAssertEqual(recovered.outcome, .complete)
        XCTAssertTrue(recovered.canPersistSession)
        XCTAssertFalse(recovered.stages.isEmpty)
        XCTAssertEqual(recovered.restingHR, 120)
        XCTAssertGreaterThan(recovered.confidence, 0.5)
    }

    func testShortLowSleepNightCanBeRecoveredWhenUserConstrainsWindow() {
        let start = 1_749_520_800
        let duration = 45 * 60
        let recovered = SleepWindowRecovery.analyze(
            start: start,
            end: start + duration,
            hr: hr(start: start, durationS: duration, bpm: 62),
            gravity: stillGravity(start: start, durationS: duration))

        XCTAssertEqual(recovered.outcome, .complete)
        XCTAssertGreaterThanOrEqual(recovered.efficiency ?? 0, 0.5)
        XCTAssertEqual(recovered.requestedEnd - recovered.requestedStart, duration)
    }

    func testSparseMotionPreservesRealVitalsWithoutInventingStages() {
        let start = 1_749_520_800
        let duration = 6 * 3_600
        let recovered = SleepWindowRecovery.analyze(
            start: start,
            end: start + duration,
            hr: hr(start: start, durationS: duration, bpm: 51),
            gravity: [])

        XCTAssertEqual(recovered.outcome, .partial)
        XCTAssertEqual(recovered.reason, .sparseMotion)
        XCTAssertTrue(recovered.canPersistSession)
        XCTAssertFalse(recovered.hasDefensibleStages)
        XCTAssertNil(recovered.efficiency)
        XCTAssertEqual(recovered.restingHR, 51)
    }

    func testNoPhysiologyDoesNotCreateSession() {
        let start = 1_749_520_800
        let recovered = SleepWindowRecovery.analyze(
            start: start,
            end: start + 8 * 3_600)

        XCTAssertEqual(recovered.outcome, .insufficientData)
        XCTAssertEqual(recovered.reason, .noPhysiology)
        XCTAssertFalse(recovered.canPersistSession)
        XCTAssertEqual(recovered.confidence, 0)
    }

    func testInvalidAndImplausiblyLongWindowsAreRejected() {
        let start = 1_749_520_800
        let inverted = SleepWindowRecovery.analyze(start: start, end: start - 60)
        let tooShort = SleepWindowRecovery.analyze(start: start, end: start + 20 * 60)
        let tooLong = SleepWindowRecovery.analyze(start: start, end: start + 17 * 3_600)

        for result in [inverted, tooShort, tooLong] {
            XCTAssertEqual(result.outcome, .invalidWindow)
            XCTAssertEqual(result.reason, .invalidDuration)
            XCTAssertFalse(result.canPersistSession)
        }
    }

    func testDSTSpringForwardWindowUsesAbsoluteElapsedTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 1, minute: 30)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 3, minute: 30)))
        let startTs = Int(start.timeIntervalSince1970)
        let endTs = Int(end.timeIntervalSince1970)

        XCTAssertEqual(endTs - startTs, 60 * 60)
        let recovered = SleepWindowRecovery.analyze(
            start: startTs,
            end: endTs,
            hr: hr(start: startTs, durationS: endTs - startTs, bpm: 55),
            gravity: stillGravity(start: startTs, durationS: endTs - startTs))

        XCTAssertEqual(recovered.outcome, .complete)
        XCTAssertEqual(recovered.requestedEnd - recovered.requestedStart, 60 * 60)
    }
}
