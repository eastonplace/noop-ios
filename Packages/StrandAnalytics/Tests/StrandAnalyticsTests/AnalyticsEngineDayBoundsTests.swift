import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Locks the analyzeDay hot-path optimization (#996): the integer UTC-bounds membership check that replaced
/// the per-sample `dayString(ts, offsetSec:) == day` DateFormatter must be BYTE-IDENTICAL to it. If the two
/// ever diverge, samples get attributed to the wrong calendar day (wrong step / calorie / Effort totals), so
/// this sweeps timestamps densely across BOTH midnight edges at a range of fixed offsets — including the
/// FRACTIONAL ones (+5:30 Kolkata, +5:45 Kathmandu, −9:30 Marquesas, −3:30 Newfoundland) the whole-hour
/// Kotlin sweep leaves uncovered — and asserts the two agree at every point. Mirrors the Android
/// `AnalyticsEngineDayBoundsTest` (same anchor, same prime step, superset of its offsets) so the
/// cross-platform golden vectors stay in lockstep.
final class AnalyticsEngineDayBoundsTests: XCTestCase {

    // MARK: - Membership equivalence sweep

    func testIntegerBoundsMatchDayStringAcrossMidnightAndOffsets() {
        let anchor = 1_700_000_000  // 2023-11-14T22:13:20Z
        // UTC, the whole-hour extremes NOOP actually threads (±12/13/14 h are the real-world edges),
        // AND the fractional offsets the lane's timezone table carries (#996 review swept these too).
        let offsets = [0,
                       -4 * 3600, 5 * 3600, 13 * 3600, -12 * 3600, 14 * 3600,
                       5 * 3600 + 1800,   // +5:30 Kolkata
                       5 * 3600 + 2700,   // +5:45 Kathmandu
                       -(9 * 3600 + 1800), // −9:30 Marquesas
                       -(3 * 3600 + 1800)] // −3:30 Newfoundland
        for off in offsets {
            let day = AnalyticsEngine.dayString(anchor, offsetSec: off)
            let start = AnalyticsEngine.dayStartUtcSeconds(day)
            // ±28 h around the anchor at a prime step, so both midnight edges of `day` are crossed densely
            // and never in phase with the day grid.
            var ts = anchor - 100_800
            while ts < anchor + 100_800 {
                let viaFormatter = AnalyticsEngine.dayString(ts, offsetSec: off) == day
                let viaBounds = (ts + off) >= start && (ts + off) < start + 86_400
                XCTAssertEqual(viaFormatter, viaBounds, "ts=\(ts) off=\(off)")
                ts += 97
            }
        }
    }

    func testExactMidnightEdgesAtFractionalOffset() {
        // The two boundary seconds are where an off-by-one would hide: the local-midnight second is IN
        // the day, the next local-midnight second is OUT. +5:30 so a whole-hour bug can't pass by luck.
        let off = 5 * 3600 + 1800
        let day = "2021-06-15"
        let start = AnalyticsEngine.dayStartUtcSeconds(day)   // 2021-06-15T00:00:00Z = 1623715200
        XCTAssertEqual(start, 1_623_715_200)
        let localMidnightUtcTs = start - off                  // wall-clock 00:00 +05:30 as a UTC instant
        for (probe, expected) in [(localMidnightUtcTs, true),          // first second of the local day
                                  (localMidnightUtcTs - 1, false),     // last second of the day before
                                  (localMidnightUtcTs + 86_399, true), // last second of the local day
                                  (localMidnightUtcTs + 86_400, false)] {  // first second of the next
            XCTAssertEqual(AnalyticsEngine.dayString(probe, offsetSec: off) == day, expected, "probe=\(probe)")
            XCTAssertEqual((probe + off) >= start && (probe + off) < start + 86_400, expected, "probe=\(probe)")
        }
    }

    // MARK: - dayStartUtcSeconds

    func testDayStartUtcSecondsIsUtcMidnight() {
        XCTAssertEqual(AnalyticsEngine.dayStartUtcSeconds("1970-01-01"), 0)
        // 1_700_000_000 is 2023-11-14T22:13:20Z, so that day's UTC midnight is 80_000 s earlier.
        XCTAssertEqual(AnalyticsEngine.dayStartUtcSeconds("2023-11-14"), 1_699_920_000)
        XCTAssertEqual(AnalyticsEngine.dayStartUtcSeconds("2021-06-15"), 1_623_715_200)
    }

    func testDayStartUtcSecondsRoundTripsThroughDayString() {
        // dayString(dayStartUtcSeconds(day)) == day for a spread of days (incl. a leap-year Feb 29).
        for day in ["1970-01-01", "2021-06-15", "2023-11-14", "2024-02-29", "2026-12-31"] {
            XCTAssertEqual(AnalyticsEngine.dayString(AnalyticsEngine.dayStartUtcSeconds(day)), day)
        }
    }

    func testMalformedDayFallsBackToEmptyEpochWindowNotATrap() {
        // Nil-tolerant failure mode (#996 review): a malformed `day` degrades to 0 — an empty 1970 window
        // no real sample matches — on BOTH platforms (Kotlin runCatching → 0), never a crash. Unreachable
        // in practice (`day` always comes from dayString), locked so the parity can't silently drift.
        XCTAssertEqual(AnalyticsEngine.dayStartUtcSeconds("not-a-day"), 0)
        XCTAssertEqual(AnalyticsEngine.dayStartUtcSeconds(""), 0)
    }

    func testExtremeRawTimelineRowsFailClosedBeforeDayScoring() {
        let day = "2021-06-15"
        let start = AnalyticsEngine.dayStartUtcSeconds(day) + 3_600
        let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
        let cleanHr = (0..<12).map { HRSample(ts: start + $0 * 30, bpm: 90) }
        let cleanSteps = [
            StepSample(ts: start, counter: 100),
            StepSample(ts: start + 60, counter: 108),
            StepSample(ts: start + 120, counter: 116)
        ]
        let baseline = AnalyticsEngine.analyzeDay(
            day: day, dayHr: cleanHr, daySteps: cleanSteps, profile: profile)

        let hostile = AnalyticsEngine.analyzeDay(
            day: day,
            hr: [HRSample(ts: .min, bpm: 60), HRSample(ts: .max, bpm: 60)],
            rr: [RRInterval(ts: .min, rrMs: 1_000), RRInterval(ts: .max, rrMs: 1_000)],
            resp: [RespSample(ts: .min, raw: 10), RespSample(ts: .max, raw: 10)],
            gravity: [
                GravitySample(ts: .min, x: 0, y: 0, z: 1),
                GravitySample(ts: .max, x: 0, y: 0, z: 1)
            ],
            steps: [StepSample(ts: .min, counter: 1), StepSample(ts: .max, counter: 2)],
            dayHr: [HRSample(ts: .min, bpm: 60)] + cleanHr + [HRSample(ts: .max, bpm: 60)],
            daySteps: [StepSample(ts: .min, counter: 1)] + cleanSteps + [StepSample(ts: .max, counter: 2)],
            dayGravity: [
                GravitySample(ts: .min, x: 0, y: 0, z: 1),
                GravitySample(ts: .max, x: 0, y: 0, z: 1)
            ],
            skinTemp: [SkinTempSample(ts: .min, raw: 1), SkinTempSample(ts: .max, raw: 1)],
            spo2: [SpO2Sample(ts: .min, red: 1, ir: 1), SpO2Sample(ts: .max, red: 1, ir: 1)],
            profile: profile,
            wristOff: [(start: .min, end: .max)],
            bandSleepState: [(ts: .min, state: 1), (ts: .max, state: 1)])

        XCTAssertEqual(hostile.daily, baseline.daily)
        XCTAssertEqual(hostile.workouts, baseline.workouts)
        XCTAssertEqual(AnalyticsEngine.dayString(.max, offsetSec: 1), "")
        XCTAssertEqual(AnalyticsEngine.dayString(.min, offsetSec: -1), "")
    }

    // MARK: - Byte-identity pin: same inputs → same DailyMetric numbers

    /// The optimization's whole contract: analyzeDay over FULL streams (which the tsInDay bounds check must
    /// trim to the day) produces the IDENTICAL DailyMetric as analyzeDay over streams PRE-trimmed with the
    /// old formatter compare. Runs at a fractional offset with spill samples planted on both sides of the
    /// local day, so any membership divergence changes the step/kcal/Effort numbers and fails Equatable.
    func testAnalyzeDayByteIdenticalToFormatterPrefilteredStreams() {
        for off in [5 * 3600 + 1800, -(9 * 3600 + 1800)] {   // +5:30 and −9:30
            let day = "2021-06-15"
            let localMid = AnalyticsEngine.dayStartUtcSeconds(day) - off
            // Full calendar-day HR every 10 s with ±2 h spill into the neighbour days; varying bpm so a
            // wrongly-included/excluded sample shifts the calorie/Effort sums, not just the count.
            let dayHr = stride(from: localMid - 7_200, to: localMid + 86_400 + 7_200, by: 10)
                .map { HRSample(ts: $0, bpm: 60 + ($0 / 10) % 40) }
            // Cumulative @57 counter every minute (+7/min) with the same spill; the spill deltas must be
            // excluded from the day total by BOTH filters identically.
            var counter = 100
            let daySteps: [StepSample] = stride(from: localMid - 7_200,
                                                to: localMid + 86_400 + 7_200, by: 60).map { ts in
                counter += 7
                return StepSample(ts: ts, counter: counter & 0xFFFF)
            }
            let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

            let full = AnalyticsEngine.analyzeDay(day: day, dayHr: dayHr, daySteps: daySteps,
                                                  profile: profile, tzOffsetSeconds: off)
            // The OLD path, byte for byte: pre-trim each stream with the formatter compare.
            let preHr = dayHr.filter { AnalyticsEngine.dayString($0.ts, offsetSec: off) == day }
            let preSteps = daySteps.filter { AnalyticsEngine.dayString($0.ts, offsetSec: off) == day }
            XCTAssertLessThan(preHr.count, dayHr.count, "fixture must actually spill outside the day")
            let pre = AnalyticsEngine.analyzeDay(day: day, dayHr: preHr, daySteps: preSteps,
                                                 profile: profile, tzOffsetSeconds: off)

            XCTAssertEqual(full.daily, pre.daily, "off=\(off)")
            XCTAssertNotNil(full.daily.steps)          // the pin is vacuous if the day computed nothing
            XCTAssertNotNil(full.daily.activeKcalEst)
        }
    }
}

/// AN-02: `analyzeDay` buckets by the real civil day `[start, nextStart)` and that day's own wall-clock
/// offset. The old engine used ONE offset for the whole pass and a fixed 86,400 s day, so after each DST
/// change every re-scored day on the other side lost an hour of steps and calories, the transition day
/// read as 24 h, and a session ending near midnight moved to the neighbouring day. The fixtures cover the
/// EU/UK change (2026-10-25), the US change (2026-11-01), US spring-forward (2026-03-08) and a southern
/// hemisphere zone, so a hemisphere or direction bug can't pass by luck.
final class AnalyticsEngineDSTDayBoundsTests: XCTestCase {

    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

    private func zone(_ id: String) throws -> TimeZone { try XCTUnwrap(TimeZone(identifier: id)) }

    private func interval(_ day: String, _ id: String) throws -> Range<Int> {
        try XCTUnwrap(AnalyticsEngine.civilDayInterval(day: day, timeZone: zone(id)), "\(day) \(id)")
    }

    /// Cumulative step counter every 60 s over `[from, to)`, +7 ticks per minute.
    private func steps(from: Int, to: Int) -> [StepSample] {
        var counter = 100
        return stride(from: from, to: to, by: 60).map { ts in
            counter += 7
            return StepSample(ts: ts, counter: counter & 0xFFFF)
        }
    }

    /// HR every 10 s over `[from, to)` with a varying bpm, so a wrongly in/excluded sample moves kcal.
    private func heartRate(from: Int, to: Int) -> [HRSample] {
        stride(from: from, to: to, by: 10).map { HRSample(ts: $0, bpm: 60 + ($0 / 10) % 40) }
    }

    /// A still, low-HR block `[start, end)` the stager detects as one sleep session.
    private func stillNight(start: Int, end: Int) -> (hr: [HRSample], rr: [RRInterval], gravity: [GravitySample]) {
        var toggle = false
        let rr: [RRInterval] = stride(from: start, to: end, by: 2).map { ts in
            toggle.toggle()
            return RRInterval(ts: ts, rrMs: toggle ? 1205 : 1195)
        }
        return ((start..<end).map { HRSample(ts: $0, bpm: 50) }, rr,
                (start..<end).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) })
    }

    // MARK: - Civil intervals and offsets

    func testCivilDayIntervalHasRealLengthAcrossTransitions() throws {
        let cases: [(String, String, Int)] = [
            ("2026-11-01", "America/New_York", 25),   // US fall-back
            ("2026-11-01", "America/Los_Angeles", 25),
            ("2026-03-08", "America/New_York", 23),   // US spring-forward
            ("2026-10-25", "Europe/London", 25),      // EU/UK fall-back
            ("2026-10-25", "Europe/Berlin", 25),
            ("2026-03-29", "Europe/London", 23),      // EU/UK spring-forward
            ("2026-10-04", "Australia/Sydney", 23),   // southern spring-forward
            ("2026-04-05", "Australia/Sydney", 25),   // southern fall-back
            ("2026-10-31", "America/New_York", 24),   // the ordinary day before
            ("2026-10-24", "Europe/London", 24),
            ("2026-06-15", "Asia/Kolkata", 24),       // no DST, fractional offset
        ]
        for (day, id, hours) in cases {
            let range = try interval(day, id)
            XCTAssertEqual(range.upperBound - range.lowerBound, hours * 3_600, "\(day) \(id)")
            XCTAssertEqual(AnalyticsEngine.dayString(range.lowerBound,
                                                     offsetSec: try zone(id).secondsFromGMT(
                                                        for: Date(timeIntervalSince1970: TimeInterval(range.lowerBound)))),
                           day, "the interval starts at local midnight of \(day) \(id)")
        }
        // Consecutive civil days tile time with no gap or overlap through the change.
        XCTAssertEqual(try interval("2026-10-31", "America/New_York").upperBound,
                       try interval("2026-11-01", "America/New_York").lowerBound)
        XCTAssertEqual(try interval("2026-11-01", "America/New_York").upperBound,
                       try interval("2026-11-02", "America/New_York").lowerBound)
    }

    func testCivilDayIntervalRejectsMalformedKeys() throws {
        let utc = try zone("UTC")
        for bad in ["", "not-a-day", "2026-02-30", "2026-13-01", "2026-1-01", "20261101"] {
            XCTAssertNil(AnalyticsEngine.civilDayInterval(day: bad, timeZone: utc), bad)
        }
    }

    func testCivilDayClockOffsetIsThatDaysOwnOffset() throws {
        let cases: [(String, String, Int)] = [
            ("2026-10-31", "America/New_York", -4 * 3_600),
            ("2026-11-01", "America/New_York", -5 * 3_600),   // after the 02:00 switch
            ("2026-11-02", "America/New_York", -5 * 3_600),
            ("2026-03-08", "America/New_York", -4 * 3_600),
            ("2026-10-24", "Europe/London", 3_600),
            ("2026-10-25", "Europe/London", 0),
            ("2026-10-04", "Australia/Sydney", 11 * 3_600),
            ("2026-06-15", "Asia/Kolkata", 5 * 3_600 + 1_800),
        ]
        for (day, id, offset) in cases {
            XCTAssertEqual(AnalyticsEngine.civilDayClockOffset(try interval(day, id), timeZone: try zone(id)),
                           offset, "\(day) \(id)")
        }
    }

    // MARK: - Fall-back day keeps its first local hour

    func testFallBackDayCountsStepsFromMidnightToOneAM() throws {
        for (day, id) in [("2026-11-01", "America/New_York"), ("2026-10-25", "Europe/London")] {
            let civil = try interval(day, id)
            let offset = AnalyticsEngine.civilDayClockOffset(civil, timeZone: try zone(id))
            // Steps only between local 00:00 and 01:00 (still on the pre-change offset).
            let firstHour = steps(from: civil.lowerBound, to: civil.lowerBound + 3_600)
            let fixed = AnalyticsEngine.analyzeDay(day: day, daySteps: firstHour, profile: profile,
                                                   tzOffsetSeconds: offset, dayInterval: civil)
            XCTAssertEqual(fixed.daily.steps, 59 * 7, "\(day) \(id): 60 samples → 59 deltas of 7")

            // The bug this replaces: a pass-wide offset taken after the change drops the whole hour.
            let legacy = AnalyticsEngine.analyzeDay(day: day, daySteps: firstHour, profile: profile,
                                                    tzOffsetSeconds: offset)
            XCTAssertNil(legacy.daily.steps, "\(day) \(id): the fixed-offset bucket loses 00:00-01:00")
        }
    }

    func testTransitionDaysUseTheirRealLengthForCaloriesAndSteps() throws {
        for (day, id, hours) in [("2026-11-01", "America/New_York", 25),
                                 ("2026-10-25", "Europe/London", 25),
                                 ("2026-03-08", "America/New_York", 23),
                                 ("2026-10-04", "Australia/Sydney", 23)] {
            let civil = try interval(day, id)
            let offset = AnalyticsEngine.civilDayClockOffset(civil, timeZone: try zone(id))
            // Streams spill two hours into both neighbouring days.
            let hr = heartRate(from: civil.lowerBound - 7_200, to: civil.upperBound + 7_200)
            let counter = steps(from: civil.lowerBound - 7_200, to: civil.upperBound + 7_200)
            let result = AnalyticsEngine.analyzeDay(day: day, dayHr: hr, daySteps: counter, profile: profile,
                                                    tzOffsetSeconds: offset, dayInterval: civil)

            let inDayHr = hr.filter { civil.contains($0.ts) }
            XCTAssertEqual(inDayHr.count, hours * 360, "\(day) \(id): \(hours) h of 10 s samples")
            // D3b: the samples' own energy plus resting BMR for every second of the 23/25 h day they don't cover.
            let restingPerSecond = Calories.restingKcalPerS(Calories.resolveCoeffs(profile.sex),
                                                            weightKg: profile.weightKg,
                                                            heightCm: profile.heightCm, age: profile.age)
            let expectedKcal = Calories.estimateDayCalories(inDayHr, profile: profile,
                                                            hrmax: StrainScorer.tanakaHRmax(age: 30),
                                                            restingHR: nil)
                + restingPerSecond * Double(hours * 3_600 - inDayHr.count)
            XCTAssertEqual(try XCTUnwrap(result.daily.activeKcalEst), expectedKcal, accuracy: 1e-9, "\(day) \(id)")
            XCTAssertEqual(result.daily.steps, (hours * 60 - 1) * 7, "\(day) \(id)")
        }
    }

    // MARK: - Session attribution near midnight

    func testSessionEndingInFallBackFirstHourBelongsToThatDay() throws {
        let day = "2026-11-01"
        let id = "America/New_York"
        let civil = try interval(day, id)
        let offset = AnalyticsEngine.civilDayClockOffset(civil, timeZone: try zone(id))
        // A still block that ends 40 min into Nov 1 (00:40 EDT), before the 02:00 switch.
        let night = stillNight(start: civil.lowerBound + 2_400 - 4 * 3_600, end: civil.lowerBound + 2_400)
        let fixed = AnalyticsEngine.analyzeDay(day: day, hr: night.hr, rr: night.rr, gravity: night.gravity,
                                               profile: profile, tzOffsetSeconds: offset, dayInterval: civil)
        XCTAssertEqual(fixed.sleepSessions.count, 1)
        let end = try XCTUnwrap(fixed.sleepSessions.first?.end)
        XCTAssertTrue(civil.contains(end) && end < civil.lowerBound + 3_600)
        XCTAssertNotNil(fixed.daily.totalSleepMin)

        // The previous day must not also claim it.
        let previousCivil = try interval("2026-10-31", id)
        let previous = AnalyticsEngine.analyzeDay(
            day: "2026-10-31", hr: night.hr, rr: night.rr, gravity: night.gravity, profile: profile,
            tzOffsetSeconds: AnalyticsEngine.civilDayClockOffset(previousCivil, timeZone: try zone(id)),
            dayInterval: previousCivil)
        XCTAssertTrue(previous.sleepSessions.isEmpty)

        // The bug: with the post-change offset and a fixed 24 h bucket the night lands on Oct 31.
        let legacy = AnalyticsEngine.analyzeDay(day: day, hr: night.hr, rr: night.rr, gravity: night.gravity,
                                                profile: profile, tzOffsetSeconds: offset)
        XCTAssertTrue(legacy.sleepSessions.isEmpty)
    }

    // MARK: - Re-scoring after the change is stable

    /// A day scored before the change and re-scored after it (when the device offset at "now" differs)
    /// must give identical results: the day's own interval and offset don't depend on when it is scored.
    func testPreChangeDayRescoredAfterChangeIsIdentical() throws {
        for (day, id) in [("2026-10-23", "Europe/London"), ("2026-11-03", "America/New_York")] {
            let tz = try zone(id)
            let civil = try interval(day, id)
            let dayOffset = AnalyticsEngine.civilDayClockOffset(civil, timeZone: tz)
            let night = stillNight(start: civil.lowerBound - 2 * 3_600, end: civil.lowerBound + 2 * 3_600)
            // Day streams cover exactly the civil day. The first hour is inside the detected night,
            // so sparse minute-counter changes there are now correctly sleep-filtered. Include a short
            // sustained walk (2 ticks/s) so a bucket losing that hour still loses retained movement.
            let hr = heartRate(from: civil.lowerBound, to: civil.upperBound)
            let minuteCounter = steps(from: civil.lowerBound, to: civil.upperBound)
            let firstCounter = try XCTUnwrap(minuteCounter.first)
            let walkStart = civil.lowerBound + 30
            let walk = (0..<10).map {
                StepSample(ts: walkStart + $0, counter: firstCounter.counter + ($0 + 1) * 2)
            }
            let counter = (minuteCounter.map { sample in
                StepSample(ts: sample.ts, counter: (sample.counter + (sample.ts >= walkStart ? 20 : 0)) & 0xFFFF)
            } + walk).sorted { $0.ts < $1.ts }
            func score(dayInterval: Range<Int>?, offset: Int) -> AnalyticsEngine.DayResult {
                AnalyticsEngine.analyzeDay(day: day, hr: night.hr, rr: night.rr, gravity: night.gravity,
                                           dayHr: hr, daySteps: counter, profile: profile,
                                           tzOffsetSeconds: offset, dayInterval: dayInterval)
            }
            // Before the change the old engine's pass-wide offset WAS this day's offset; that is the
            // correct historical result.
            let scoredBefore = score(dayInterval: nil, offset: dayOffset)
            let rescoredAfter = score(dayInterval: civil, offset: dayOffset)
            XCTAssertEqual(rescoredAfter.daily, scoredBefore.daily, "\(day) \(id)")
            XCTAssertEqual(rescoredAfter.sleepSessions, scoredBefore.sleepSessions, "\(day) \(id)")
            XCTAssertNotNil(rescoredAfter.daily.steps)
            XCTAssertNotNil(rescoredAfter.daily.totalSleepMin)
            XCTAssertEqual(SleepAwareStepCounter.stepsInWindow(
                [firstCounter] + walk, sleepSessions: scoredBefore.sleepSessions), 20,
                "\(day) \(id): the boundary-hour walk must survive sleep filtering")

            // The old engine re-scored it under the other side's offset and lost an hour.
            let otherSideOffset = dayOffset + (tz.isDaylightSavingTime(
                for: Date(timeIntervalSince1970: TimeInterval(civil.lowerBound))) ? -3_600 : 3_600)
            let oldRescore = score(dayInterval: nil, offset: otherSideOffset)
            XCTAssertNotEqual(oldRescore.daily.steps, scoredBefore.daily.steps, "\(day) \(id)")
        }
    }

    // MARK: - Ordinary days are byte-identical

    /// Golden pin: on a day with no transition, the civil interval equals the old fixed-offset bucket, so
    /// every output is byte-identical to the pre-fix engine (incl. fractional and southern-hemisphere zones).
    func testOrdinaryDaysAreByteIdenticalToTheFixedOffsetEngine() throws {
        for (day, id) in [("2026-06-15", "America/New_York"), ("2026-06-01", "Australia/Sydney"),
                          ("2026-02-02", "Asia/Kathmandu"), ("2026-05-05", "UTC")] {
            let tz = try zone(id)
            let civil = try interval(day, id)
            let offset = AnalyticsEngine.civilDayClockOffset(civil, timeZone: tz)
            XCTAssertEqual(civil, AnalyticsEngine.fixedOffsetDayInterval(day, offsetSec: offset), "\(day) \(id)")
            let night = stillNight(start: civil.lowerBound - 2 * 3_600, end: civil.lowerBound + 2 * 3_600)
            let hr = heartRate(from: civil.lowerBound - 7_200, to: civil.upperBound + 7_200)
            let counter = steps(from: civil.lowerBound - 7_200, to: civil.upperBound + 7_200)
            let civilResult = AnalyticsEngine.analyzeDay(
                day: day, hr: night.hr, rr: night.rr, gravity: night.gravity, dayHr: hr, daySteps: counter,
                profile: profile, tzOffsetSeconds: offset, dayInterval: civil)
            let fixedResult = AnalyticsEngine.analyzeDay(
                day: day, hr: night.hr, rr: night.rr, gravity: night.gravity, dayHr: hr, daySteps: counter,
                profile: profile, tzOffsetSeconds: offset)
            XCTAssertEqual(civilResult.daily, fixedResult.daily, "\(day) \(id)")
            XCTAssertEqual(civilResult.sleepSessions, fixedResult.sleepSessions, "\(day) \(id)")
            XCTAssertEqual(civilResult.cachedSleep, fixedResult.cachedSleep, "\(day) \(id)")
            XCTAssertEqual(civilResult.workouts, fixedResult.workouts, "\(day) \(id)")
            XCTAssertNotNil(civilResult.daily.steps)
            XCTAssertNotNil(civilResult.daily.totalSleepMin)
        }
    }

    // MARK: - Habitual midsleep across the change

    /// Nights with a fixed local 03:00 midpoint on both sides of the US change are learned as 03:00 when
    /// each block carries its own offset; one shared offset reads half of them an hour off.
    func testHabitualMidsleepUsesEachNightsOwnOffset() throws {
        let tz = try zone("America/New_York")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let blocks: [SleepStageTotals.HistoryBlock] = try (0..<20).map { index in
            let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 22 + index,
                                                                         hour: 3)))
            let mid = Int(day.timeIntervalSince1970)
            let offset = tz.secondsFromGMT(for: day)
            return SleepStageTotals.HistoryBlock(start: mid - 4 * 3_600, end: mid + 4 * 3_600,
                                                 dayKey: AnalyticsEngine.dayString(mid, offsetSec: offset),
                                                 clockOffsetSec: offset)
        }
        XCTAssertEqual(SleepStageTotals.habitualMidsleepSec(blocks, offsetSec: 0), 3 * 3_600)

        let sharedOffset = blocks.map {
            SleepStageTotals.HistoryBlock(start: $0.start, end: $0.end, dayKey: $0.dayKey)
        }
        XCTAssertNotEqual(SleepStageTotals.habitualMidsleepSec(sharedOffset, offsetSec: -5 * 3_600), 3 * 3_600)
    }

    // MARK: - Steps trace agrees with the bucket

    func testStepsRawCounterTraceUsesTheCivilInterval() throws {
        let day = "2026-11-01"
        let civil = try interval(day, "America/New_York")
        let firstHour = steps(from: civil.lowerBound, to: civil.lowerBound + 3_600)
        let lines = StepsEstimateEngine.rawCounterTrace(daySteps: firstHour, dayKey: day,
                                                        tzOffsetSeconds: -5 * 3_600, dayInterval: civil,
                                                        ticksPerStep: 1.0)
        XCTAssertTrue(lines.contains { $0.contains("counterSamples=60") }, lines.joined(separator: "\n"))
    }
}
