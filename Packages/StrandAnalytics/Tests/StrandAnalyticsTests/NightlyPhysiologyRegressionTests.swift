import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Adapted from upstream primary-night RHR (#2522) and the nightly clean-beat floor.
/// These exercise the production selectors shared by analysis and persisted-session repair.
final class NightlyPhysiologyRegressionTests: XCTestCase {
    func testPrimaryNightRHRDoesNotTakeLowerNapFloor() {
        let night = (start: 0, end: 8 * 3_600, restingHR: Optional(57))
        let nap = (start: 12 * 3_600, end: 14 * 3_600, restingHR: Optional(41))

        XCTAssertEqual(PrimaryNightRestingHR.floor([night, nap]), 57)
        XCTAssertEqual(PrimaryNightRestingHR.floor([nap, night]), 57)
    }

    func testPrimaryNightMissingHRDoesNotSubstituteNap() {
        let night = (start: 0, end: 8 * 3_600, restingHR: Optional<Int>.none)
        let nap = (start: 12 * 3_600, end: 14 * 3_600, restingHR: Optional(41))

        XCTAssertNil(PrimaryNightRestingHR.floor([night, nap]))
        XCTAssertNil(PrimaryNightRestingHR.floor([nap, night]))
    }

    func testPrimaryNightDurationTieKeepsFirstSession() {
        XCTAssertEqual(PrimaryNightRestingHR.floor([
            (start: 0, end: 3_600, restingHR: 55),
            (start: 7_200, end: 10_800, restingHR: 40)
        ]), 55)
    }

    func testPrimaryNightRejectsNonpositiveAndOverflowingSpans() {
        XCTAssertNil(PrimaryNightRestingHR.floor([]))
        XCTAssertEqual(PrimaryNightRestingHR.floor([
            (start: Int.min, end: Int.max, restingHR: 30),
            (start: 1, end: 1, restingHR: 31),
            (start: 2, end: 1, restingHR: 32),
            (start: 0, end: 3_600, restingHR: 55)
        ]), 55)
    }

    func testNightlyWindowNeedsTwentyCleanIntervals() throws {
        let start = 1_000
        let nineteen = (0..<19).map {
            RRInterval(ts: start + $0, rrMs: $0.isMultiple(of: 2) ? 900 : 1_000)
        }
        let twenty = nineteen + [RRInterval(ts: start + 19, rrMs: 1_000)]

        let thin = try XCTUnwrap(SleepStager.sessionHrvWindows(
            start: start, end: start + 300, rr: nineteen, stages: []).first)
        let sufficient = try XCTUnwrap(SleepStager.sessionHrvWindows(
            start: start, end: start + 300, rr: twenty, stages: []).first)

        XCTAssertEqual(thin.cleanBeats, 19)
        XCTAssertNil(thin.rmssd)
        XCTAssertNil(SleepStager.sessionAvgHRV(start: start, end: start + 300, rr: nineteen))
        XCTAssertEqual(sufficient.cleanBeats, HRVAnalyzer.minBeats)
        XCTAssertEqual(try XCTUnwrap(sufficient.rmssd), 100, accuracy: 0.000_001)
    }

    func testNightlyMinimumIsAppliedAfterCleaning() throws {
        let start = 1_000
        let raw = (0..<25).map {
            RRInterval(ts: start + $0, rrMs: $0 < 6 ? 100 : 1_000)
        }
        let window = try XCTUnwrap(SleepStager.sessionHrvWindows(
            start: start, end: start + 300, rr: raw, stages: []).first)

        XCTAssertGreaterThan(raw.count, HRVAnalyzer.minBeats)
        XCTAssertEqual(window.cleanBeats, 19)
        XCTAssertNil(window.rmssd)
    }

    func testSparseHighVarianceWindowDoesNotInflateNightlyMean() throws {
        let start = 1_000
        let full = (0..<300).map {
            RRInterval(ts: start + $0, rrMs: $0.isMultiple(of: 2) ? 900 : 1_000)
        }
        let sparse = (0..<10).map {
            RRInterval(ts: start + 300 + $0, rrMs: $0.isMultiple(of: 2) ? 900 : 1_300)
        }
        let windows = SleepStager.sessionHrvWindows(
            start: start, end: start + 600, rr: full + sparse, stages: [])

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(try XCTUnwrap(windows.first?.rmssd), 100, accuracy: 0.000_001)
        XCTAssertNil(windows.last?.rmssd)
        XCTAssertEqual(try XCTUnwrap(SleepStager.sessionAvgHRV(
            start: start, end: start + 600, rr: full + sparse)), 100, accuracy: 0.000_001)
    }

    func testEnoughCleanIntervalsStillCannotBridgeRemovedBeats() throws {
        let start = 1_000
        let rr = (0..<40).map {
            RRInterval(ts: start + $0, rrMs: $0.isMultiple(of: 2) ? 1_000 : 100)
        }
        let window = try XCTUnwrap(SleepStager.sessionHrvWindows(
            start: start, end: start + 300, rr: rr, stages: []).first)

        XCTAssertEqual(window.cleanBeats, HRVAnalyzer.minBeats)
        XCTAssertNil(window.rmssd, "a count floor must not splice the survivors across removed beats")
    }
}
