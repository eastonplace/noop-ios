import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// AN-05: Effort's physiological day runs sleep-to-sleep. Day D's cycle is [main onset(D), cycle start(D+1)),
/// where the pass supplies the end. Load after midnight but before the next onset belongs to D, and an hour of
/// load is never counted in both D and D+1.
final class AnalyticsEngineCycleBoundsTests: XCTestCase {

    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

    // 2 s cadence keeps the stager fast.
    private struct Streams {
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        var gravity: [GravitySample] = []
        mutating func still(_ range: Range<Int>) {
            var toggle = false
            for ts in stride(from: range.lowerBound, to: range.upperBound, by: 2) {
                hr.append(HRSample(ts: ts, bpm: 50))
                gravity.append(GravitySample(ts: ts, x: 0, y: 0, z: 1))
                toggle.toggle()
                rr.append(RRInterval(ts: ts, rrMs: toggle ? 1_205 : 1_195))
            }
        }
        mutating func moving(_ range: Range<Int>, bpm: Int) {
            for ts in stride(from: range.lowerBound, to: range.upperBound, by: 2) {
                hr.append(HRSample(ts: ts, bpm: bpm + ts % 9))
                let wobble = Double(ts % 11) * 0.2
                gravity.append(GravitySample(ts: ts, x: wobble, y: 0.3 - wobble, z: 0.8))
            }
        }
        /// The rows in `[lo, hi]`, as the store's inclusive range read returns them.
        func window(_ lo: Int, _ hi: Int) -> Streams {
            Streams(hr: hr.filter { $0.ts >= lo && $0.ts <= hi }.sorted { $0.ts < $1.ts },
                    rr: rr.filter { $0.ts >= lo && $0.ts <= hi }.sorted { $0.ts < $1.ts },
                    gravity: gravity.filter { $0.ts >= lo && $0.ts <= hi }.sorted { $0.ts < $1.ts })
        }
    }

    private func interval(_ day: String) throws -> Range<Int> {
        try XCTUnwrap(AnalyticsEngine.civilDayInterval(day: day, timeZone: XCTUnwrap(TimeZone(identifier: "UTC"))))
    }

    /// `analyzeDay` over the pass's read window for `day`: `[dayStart − 30 h, nextStart]`.
    private func score(_ day: String, _ streams: Streams, cycleEnd: AnalyticsEngine.CycleEnd? = nil) throws
        -> AnalyticsEngine.DayResult {
        let bounds = try interval(day)
        let w = streams.window(bounds.lowerBound - 30 * 3_600, bounds.upperBound)
        return AnalyticsEngine.analyzeDay(day: day, hr: w.hr, rr: w.rr, gravity: w.gravity, profile: profile,
                                          tzOffsetSeconds: 0, dayInterval: bounds, cycleEnd: cycleEnd)
    }

    /// The boundary the pass hands D once D+1 is scored: D+1's cycle start plus the readings past D's window.
    private func cycleEnd(for day: String, next: AnalyticsEngine.DayResult, nextDay: String,
                          _ streams: Streams) throws -> AnalyticsEngine.CycleEnd {
        let readEnd = try interval(day).upperBound
        let end = AnalyticsEngine.CycleEnd.next(cycleStart: next.cycleStart, nextDayInterval: try interval(nextDay))
        return AnalyticsEngine.CycleEnd(end: end, tailHr: streams.hr.filter { $0.ts > readEnd && $0.ts < end })
    }

    /// A late night out: a hard hour at 00:30-01:30 and sleep from 02:00. That hour is D's, not D+1's, and
    /// not lost between them (the old cycle stopped at the read window's midnight).
    func testActivityAfterMidnightBeforeTheNextOnsetCountsTowardTheDay() throws {
        let d = try interval("2026-06-15")
        func fixture(lateBpm: Int) -> Streams {
            var s = Streams()
            s.moving((d.lowerBound - 6 * 3_600)..<(d.lowerBound - 3_600), bpm: 80)
            s.still((d.lowerBound - 3_600)..<(d.lowerBound + 7 * 3_600))                     // night of D
            s.moving((d.lowerBound + 7 * 3_600)..<(d.upperBound + 1_800), bpm: 80)
            s.moving((d.upperBound + 1_800)..<(d.upperBound + 5_400), bpm: lateBpm)           // 00:30-01:30
            s.moving((d.upperBound + 5_400)..<(d.upperBound + 7_200), bpm: 80)
            s.still((d.upperBound + 7_200)..<(d.upperBound + 9 * 3_600))                      // night of D+1
            s.moving((d.upperBound + 9 * 3_600)..<(d.upperBound + 12 * 3_600), bpm: 80)
            return s
        }
        let hard = fixture(lateBpm: 165), easy = fixture(lateBpm: 80)

        let nextHard = try score("2026-06-16", hard), nextEasy = try score("2026-06-16", easy)
        let nextStart = try XCTUnwrap(nextHard.cycleStart)
        XCTAssertEqual(nextEasy.cycleStart, nextStart)
        XCTAssertGreaterThanOrEqual(nextStart, d.upperBound + 7_200 - 600, "D+1's cycle starts at its 02:00 onset")

        let dayHard = try score("2026-06-15", hard, cycleEnd: cycleEnd(for: "2026-06-15", next: nextHard,
                                                                         nextDay: "2026-06-16", hard))
        let dayEasy = try score("2026-06-15", easy, cycleEnd: cycleEnd(for: "2026-06-15", next: nextEasy,
                                                                         nextDay: "2026-06-16", easy))
        let dayHardAtMidnight = try score("2026-06-15", hard, cycleEnd: .init(end: d.upperBound))
        XCTAssertGreaterThan(try XCTUnwrap(dayHard.strain), try XCTUnwrap(dayEasy.strain) + 1,
                             "the post-midnight hour counts toward D")
        XCTAssertGreaterThan(try XCTUnwrap(dayHard.strain), try XCTUnwrap(dayHardAtMidnight.strain) + 1,
                             "stopping at midnight loses it")
        XCTAssertEqual(try XCTUnwrap(nextHard.strain), try XCTUnwrap(nextEasy.strain), accuracy: 1e-9,
                       "and D+1, whose cycle starts at 02:00, does not count it")
    }

    /// An early bedtime (22:00 on D): D's cycle ends there and D+1's starts there, so the 22:00-24:00 span
    /// is D+1's only, and an evening hour before 22:00 is D's only.
    func testConsecutiveCyclesMeetAtTheNextOnsetAndNeverOverlap() throws {
        let d = try interval("2026-06-15")
        func fixture(eveningBpm: Int, lateBpm: Int) -> Streams {
            var s = Streams()
            s.moving((d.lowerBound - 6 * 3_600)..<(d.lowerBound - 3_600), bpm: 80)
            s.still((d.lowerBound - 3_600)..<(d.lowerBound + 7 * 3_600))
            s.moving((d.lowerBound + 7 * 3_600)..<(d.lowerBound + 19 * 3_600), bpm: 80)
            s.moving((d.lowerBound + 19 * 3_600)..<(d.lowerBound + 20 * 3_600), bpm: eveningBpm)  // 19-20 h
            s.moving((d.lowerBound + 20 * 3_600)..<(d.lowerBound + 22 * 3_600), bpm: 80)
            s.still((d.lowerBound + 22 * 3_600)..<(d.upperBound + 6 * 3_600))                     // 22:00 → 06:00
            s.moving((d.upperBound + 6 * 3_600)..<(d.upperBound + 10 * 3_600), bpm: lateBpm)
            return s
        }
        let base = fixture(eveningBpm: 80, lateBpm: 80)
        let next = try score("2026-06-16", base)
        let nextStart = try XCTUnwrap(next.cycleStart)
        XCTAssertLessThan(nextStart, d.upperBound, "D+1's main night starts before D's midnight")
        let end = try cycleEnd(for: "2026-06-15", next: next, nextDay: "2026-06-16", base)
        XCTAssertEqual(end.end, nextStart)
        XCTAssertTrue(end.tailHr.isEmpty, "the boundary is inside D's read window")
        let day = try score("2026-06-15", base, cycleEnd: end)
        XCTAssertLessThan(try XCTUnwrap(day.cycleStart), nextStart)

        // An evening workout before 22:00 moves D only.
        let evening = fixture(eveningBpm: 165, lateBpm: 80)
        let nextEvening = try score("2026-06-16", evening)
        XCTAssertEqual(nextEvening.cycleStart, nextStart)
        XCTAssertEqual(try XCTUnwrap(nextEvening.strain), try XCTUnwrap(next.strain), accuracy: 1e-9)
        let dayEvening = try score("2026-06-15", evening, cycleEnd: .init(end: nextStart))
        XCTAssertGreaterThan(try XCTUnwrap(dayEvening.strain), try XCTUnwrap(day.strain) + 1)

        // Readings at or after D+1's onset never reach D: D's score ignores them entirely.
        var noisy = base
        noisy.hr = noisy.hr.map { $0.ts >= nextStart && $0.ts <= d.upperBound ? HRSample(ts: $0.ts, bpm: 170) : $0 }
        let dayNoisy = try score("2026-06-15", noisy, cycleEnd: .init(end: nextStart))
        XCTAssertEqual(try XCTUnwrap(dayNoisy.strain), try XCTUnwrap(day.strain), accuracy: 1e-9)
    }

    /// The public cycle start is the selector `analyzeDay` uses.
    func testCycleStartIsTheMainNightOnset() throws {
        let d = try interval("2026-06-15")
        var s = Streams()
        s.moving((d.lowerBound - 6 * 3_600)..<(d.lowerBound - 3_600), bpm: 80)
        s.still((d.lowerBound - 3_600)..<(d.lowerBound + 7 * 3_600))
        s.moving((d.lowerBound + 7 * 3_600)..<(d.lowerBound + 13 * 3_600), bpm: 80)
        s.still((d.lowerBound + 13 * 3_600)..<(d.lowerBound + 14 * 3_600 + 1_800))            // a nap
        s.moving((d.lowerBound + 14 * 3_600 + 1_800)..<(d.lowerBound + 18 * 3_600), bpm: 80)
        let result = try score("2026-06-15", s)
        let blocks = result.sleepSessions.map { SleepStageTotals.NightBlock(start: $0.start, end: $0.end) }
        XCTAssertEqual(result.cycleStart, AnalyticsEngine.cycleStart(blocks, offsetSec: 0))
        XCTAssertEqual(result.cycleStart, result.sleepSessions.map(\.start).min(), "the night, not the nap")
        XCTAssertNil(AnalyticsEngine.cycleStart([], offsetSec: 0))
        XCTAssertEqual(AnalyticsEngine.CycleEnd.next(cycleStart: nil, nextDayInterval: d), d.lowerBound)
    }

    /// No sleep: the cycle is the civil day (up to the next cycle start), read through the validated,
    /// chronological stream, so unsorted input scores exactly as `StrainScorerV2.strain` does.
    func testNoSleepFallbackScoresTheSortedValidCivilDay() throws {
        let d = try interval("2026-06-15")
        var hr: [HRSample] = []
        for ts in stride(from: d.lowerBound + 8 * 3_600, to: d.lowerBound + 20 * 3_600, by: 5) {
            hr.append(HRSample(ts: ts, bpm: ts % 3_600 < 1_200 ? 160 : 85))
        }
        let unsorted = hr.reversed() + [HRSample(ts: d.lowerBound + 9 * 3_600, bpm: 0)]
        let result = AnalyticsEngine.analyzeDay(day: "2026-06-15", hr: Array(unsorted), profile: profile,
                                                dayInterval: d)
        XCTAssertNil(result.cycleStart)
        let expected = StrainScorerV2.strain(
            hr, maxHR: StrainScorer.tanakaHRmax(age: 30), restingHR: StrainScorer.defaultRestingHR,
            mode: .physiologicalDay(.init(validWornSleepMinutes: nil, steps: nil, activeEnergyKcal: nil,
                                          hasWearCoverage: true)))
        XCTAssertEqual(try XCTUnwrap(result.strain), try XCTUnwrap(expected), accuracy: 1e-9)
    }
}
