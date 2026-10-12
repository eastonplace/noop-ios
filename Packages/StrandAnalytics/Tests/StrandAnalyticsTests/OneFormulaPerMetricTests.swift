import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// N2-2: one formula per metric. Heart-rate plausibility (AN-03), the resting-HR kernel (AN-06) and the
/// gap-aware RMSSD (AN-10) are each applied once, on the path production calls.
final class OneFormulaPerMetricTests: XCTestCase {

    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
    private let dayStart = 1_781_481_600   // 2026-06-15T00:00:00Z
    private let day = "2026-06-15"

    // MARK: - AN-03: 0-bpm off-wrist rows

    /// A strap lying still off-wrist for the afternoon streams 0 bpm. Those rows used to confirm sleep
    /// (median 0 ≤ baseline), pass the nap guard and set a 0 resting HR, pegging Charge. Worn, moving HR
    /// surrounds the stretch, as on a real day.
    func testStillOffWristZeroBpmStretchIsNotSleepAndSetsNoRestingHR() {
        let wornMorning = (dayStart + 7 * 3_600)..<(dayStart + 12 * 3_600)
        let offWrist = (dayStart + 12 * 3_600)..<(dayStart + 18 * 3_600)
        let wornEvening = (dayStart + 18 * 3_600)..<(dayStart + 22 * 3_600)
        var hr: [HRSample] = []
        var gravity: [GravitySample] = []
        for range in [wornMorning, wornEvening] {
            for ts in range {
                hr.append(HRSample(ts: ts, bpm: 70 + ts % 15))
                let wobble = Double(ts % 7) * 0.15
                gravity.append(GravitySample(ts: ts, x: wobble, y: 0.2 - wobble, z: 0.9))
            }
        }
        for ts in offWrist {
            hr.append(HRSample(ts: ts, bpm: 0))
            gravity.append(GravitySample(ts: ts, x: 0, y: 0, z: 1))
        }
        hr.sort { $0.ts < $1.ts }
        gravity.sort { $0.ts < $1.ts }

        let result = AnalyticsEngine.analyzeDay(day: day, hr: hr, gravity: gravity, dayHr: hr,
                                                dayGravity: gravity, profile: profile)
        XCTAssertFalse(result.sleepSessions.contains { offWrist.contains($0.start) || offWrist.contains($0.end - 1) },
                       "a still 0-bpm stretch is off-wrist, not sleep")
        XCTAssertNil(result.daily.restingHr, "no session, no resting HR, and never 0")
        XCTAssertFalse(result.workouts.contains { $0.start >= offWrist.lowerBound && $0.end <= offWrist.upperBound })

        // detectSleep on its own (the public entry) drops the zeros too.
        let detected = SleepStager.detectSleep(hr: hr, gravity: gravity)
        XCTAssertFalse(detected.contains { $0.restingHR == 0 })
    }

    /// A real night with a short 0-bpm dropout keeps its true resting HR.
    func testZeroBpmDropoutInsideARealNightCannotSetRestingHR() throws {
        let start = dayStart - 2 * 3_600
        let end = dayStart + 5 * 3_600
        var hr = (start..<end).map { HRSample(ts: $0, bpm: 52) }
        for index in 3_600..<(3_600 + 600) { hr[index] = HRSample(ts: hr[index].ts, bpm: 0) }
        let gravity = (start..<end).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        var toggle = false
        let rr: [RRInterval] = stride(from: start, to: end, by: 2).map { ts in
            toggle.toggle()
            return RRInterval(ts: ts, rrMs: toggle ? 1_205 : 1_195)
        }
        let result = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, gravity: gravity, profile: profile)
        XCTAssertEqual(result.sleepSessions.count, 1)
        XCTAssertEqual(result.daily.restingHr, 52)
    }

    func testValidityRangeIsTheOneSharedDefinition() {
        XCTAssertFalse(HRValidity.isPlausible(0))
        XCTAssertFalse(HRValidity.isPlausible(29))
        XCTAssertTrue(HRValidity.isPlausible(30))
        XCTAssertTrue(HRValidity.isPlausible(240))
        XCTAssertFalse(HRValidity.isPlausible(241))
        XCTAssertEqual(PrimarySessionRestingHR.defaultValidBpm, HRValidity.bpmRange)
        XCTAssertEqual(SleepHeartRateContrast.validMinBpm, 30)
        XCTAssertEqual(SleepHeartRateContrast.validMaxBpm, 240)
    }

    // MARK: - AN-06: the single resting-HR kernel

    /// Production (`sessionRestingHR`) and the public kernel are the same function, on sorted and unsorted
    /// input alike, including the partial trailing bin and an end-boundary sample.
    func testSessionRestingHRIsTheKernel() {
        let start = 10_000
        var hr: [HRSample] = []
        for i in 0..<700 { hr.append(HRSample(ts: start + i, bpm: 50 + (i / 100) * 3)) }
        hr.append(HRSample(ts: start + 900, bpm: 41))   // exactly at `end` on a bin boundary
        for end in [start + 900, start + 750, start + 600, start + 1] {
            XCTAssertEqual(SleepStager.sessionRestingHR(start: start, end: end, hr: hr),
                           RecoveryScorer.restingHR(hr, start: start, end: end), "end=\(end)")
            XCTAssertEqual(RecoveryScorer.restingHR(hr.reversed(), start: start, end: end),
                           RecoveryScorer.restingHR(hr, start: start, end: end), "order-independent, end=\(end)")
        }
        // The lone 41 bpm end-boundary sample is in no bin, so it can't win the floor: the lowest bin is the
        // first 5 minutes (100 s each at 50, 53 and 56 bpm).
        XCTAssertEqual(RecoveryScorer.restingHR(hr, start: start, end: start + 900), 53)
    }

    // MARK: - AN-10: gap-aware RMSSD everywhere

    private func rrWithSplice() -> [Double] {
        // Steady beats with one out-of-range beat (2,600 ms) followed by a 15% short beat. Plain cleaning
        // splices the beats either side of the dropped one into a large fake difference.
        var values: [Double] = []
        for i in 0..<40 { values.append(i % 2 == 0 ? 900 : 910) }
        values.insert(2_600, at: 20)
        values[21] = 780
        return values
    }

    func testRollingRmssdSkipsDifferencesAcrossDroppedBeats() throws {
        let values = rrWithSplice()
        let rr = values.enumerated().map { RRInterval(ts: 1_000 + $0.offset, rrMs: Int($0.element)) }
        let points = HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 600)
        let last = try XCTUnwrap(points.last)
        let cleaned = HRVAnalyzer.cleanRRGapAware(values)
        let expected = try XCTUnwrap(HRVAnalyzer.rmssdGapAware(cleaned.nn, cleaned.contiguous))
        XCTAssertEqual(last.rmssd, expected, accuracy: 1e-9)
        let spliced = try XCTUnwrap(HRVAnalyzer.rmssdRaw(HRVAnalyzer.cleanRR(values)))
        XCTAssertLessThan(last.rmssd, spliced, "the spliced difference no longer inflates the timeline")
        // And it equals the nightly analyzer on the same beats.
        XCTAssertEqual(last.rmssd, try XCTUnwrap(HRVAnalyzer.analyze(rawRR: values).rmssd), accuracy: 1e-9)
    }
}
