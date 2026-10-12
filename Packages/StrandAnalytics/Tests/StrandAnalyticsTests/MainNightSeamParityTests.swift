import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// AN-12: `analyzeDay` and the sleep-edit seam (`dailyAggregateHonoringEdits`) pick the main night with ONE
/// selector over the SAME `[onset, end]` spans. The seam used to rank on decoded asleep minutes while
/// `analyzeDay` ranked on clock span, so editing any block could switch a day's main night. Each fixture
/// runs through both entry points and asserts they agree.
final class MainNightSeamParityTests: XCTestCase {

    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

    // MARK: - Fixture builders (2 s cadence keeps the stager fast)

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
        mutating func awake(_ range: Range<Int>) {
            for ts in stride(from: range.lowerBound, to: range.upperBound, by: 2) {
                hr.append(HRSample(ts: ts, bpm: 80 + ts % 9))
                let wobble = Double(ts % 11) * 0.2
                gravity.append(GravitySample(ts: ts, x: wobble, y: 0.3 - wobble, z: 0.8))
            }
        }
        func sorted() -> Streams {
            Streams(hr: hr.sorted { $0.ts < $1.ts }, rr: rr.sorted { $0.ts < $1.ts },
                    gravity: gravity.sorted { $0.ts < $1.ts })
        }
    }

    private func interval(_ day: String, _ id: String) throws -> (Range<Int>, Int) {
        let tz = try XCTUnwrap(TimeZone(identifier: id))
        let range = try XCTUnwrap(AnalyticsEngine.civilDayInterval(day: day, timeZone: tz))
        return (range, AnalyticsEngine.civilDayClockOffset(range, timeZone: tz))
    }

    /// The seam's view of a scored day: the stored rows exactly as IntelligenceEngine hands them over
    /// (detected onset/end + stages), with no edit, through the same selector and offset.
    private func seam(_ result: AnalyticsEngine.DayResult, offset: Int,
                      habitual: Int? = nil) -> (DailySleepLike?, [Int]) {
        let rows = result.cachedSleep
        let blocks = rows.map { (startTs: $0.startTs, stagesJSON: $0.stagesJSON) }
        let onsets = Dictionary(rows.map { ($0.startTs, $0.effectiveStartTs) }, uniquingKeysWith: { a, _ in a })
        let ends = Dictionary(rows.map { ($0.startTs, $0.endTs) }, uniquingKeysWith: { a, _ in a })
        let aggregate = SleepStageTotals.dailyAggregateHonoringEdits(
            detected: blocks, edited: [:], onsetByStart: onsets, endByStart: ends,
            offsetSec: offset, habitualMidsleepSec: habitual)
        let group = SleepStageTotals.mainNightGroupIndices(
            SleepStageTotals.seamNightBlocks(blocks, onsetByStart: onsets, endByStart: ends),
            offsetSec: offset, habitualMidsleepSec: habitual) ?? []
        return (aggregate.map { DailySleepLike(total: $0.sleep.totalSleepMin, efficiency: $0.sleep.efficiency) },
                group.map { rows[$0].startTs })
    }

    private struct DailySleepLike { let total: Double; let efficiency: Double }

    /// The engine's pick for the same day: the identical selector call `analyzeDay` makes.
    private func enginePick(_ result: AnalyticsEngine.DayResult, offset: Int, habitual: Int? = nil) -> [Int] {
        let sessions = result.sleepSessions
        let group = SleepStageTotals.mainNightGroupIndices(
            sessions.map { SleepStageTotals.NightBlock(start: $0.start, end: $0.end) },
            offsetSec: offset, habitualMidsleepSec: habitual) ?? []
        return group.map { sessions[$0].start }
    }

    private func assertParity(_ result: AnalyticsEngine.DayResult, offset: Int, habitual: Int? = nil,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let (aggregate, seamGroup) = seam(result, offset: offset, habitual: habitual)
        XCTAssertFalse(seamGroup.isEmpty, file: file, line: line)
        XCTAssertEqual(seamGroup, enginePick(result, offset: offset, habitual: habitual),
                       "the seam and analyzeDay pick the same main-night group", file: file, line: line)
        let seamTotal = try XCTUnwrap(aggregate?.total, file: file, line: line)
        let engineTotal = try XCTUnwrap(result.daily.totalSleepMin, file: file, line: line)
        XCTAssertEqual(seamTotal, engineTotal, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(aggregate?.efficiency), try XCTUnwrap(result.daily.efficiency),
                       accuracy: 0.01, file: file, line: line)
    }

    // MARK: - Fixtures through analyzeDay AND the seam

    /// A daytime sleep longer than a short overnight: both entry points resolve the same block.
    func testNapLongerThanTheNight() throws {
        let (day, offset) = try interval("2026-06-15", "UTC")
        var streams = Streams()
        streams.awake((day.lowerBound - 4 * 3_600)..<(day.lowerBound + 3_600))
        streams.still((day.lowerBound + 3_600)..<(day.lowerBound + 4 * 3_600))          // 3 h night
        streams.awake((day.lowerBound + 4 * 3_600)..<(day.lowerBound + 12 * 3_600))
        streams.still((day.lowerBound + 12 * 3_600)..<(day.lowerBound + 16 * 3_600 + 1_800)) // 4.5 h nap
        streams.awake((day.lowerBound + 16 * 3_600 + 1_800)..<(day.lowerBound + 20 * 3_600))
        let s = streams.sorted()
        let result = AnalyticsEngine.analyzeDay(day: "2026-06-15", hr: s.hr, rr: s.rr, gravity: s.gravity,
                                                profile: profile, tzOffsetSeconds: offset, dayInterval: day)
        XCTAssertGreaterThanOrEqual(result.sleepSessions.count, 2, "fixture must detect the night and the nap")
        try assertParity(result, offset: offset)
    }

    /// One night split by a 40-minute wake: both bridge it into the same two-fragment group.
    func testSplitNight() throws {
        let (day, offset) = try interval("2026-06-16", "UTC")
        var streams = Streams()
        streams.awake((day.lowerBound - 6 * 3_600)..<(day.lowerBound - 2 * 3_600))
        streams.still((day.lowerBound - 2 * 3_600)..<(day.lowerBound + 2 * 3_600))
        streams.awake((day.lowerBound + 2 * 3_600)..<(day.lowerBound + 2 * 3_600 + 2_400))
        streams.still((day.lowerBound + 2 * 3_600 + 2_400)..<(day.lowerBound + 6 * 3_600))
        streams.awake((day.lowerBound + 6 * 3_600)..<(day.lowerBound + 8 * 3_600))
        let s = streams.sorted()
        let result = AnalyticsEngine.analyzeDay(day: "2026-06-16", hr: s.hr, rr: s.rr, gravity: s.gravity,
                                                profile: profile, tzOffsetSeconds: offset, dayInterval: day)
        try assertParity(result, offset: offset)
        if result.sleepSessions.count >= 2 {
            XCTAssertEqual(seam(result, offset: offset).1.count, 2, "the 40-min wake is bridged on both paths")
        }
    }

    /// A night across the US fall-back change, plus an afternoon nap, scored with the day's own interval
    /// and offset (N2-1a). The seam receives the same offset, so both pick the same block.
    func testDSTNight() throws {
        let (day, offset) = try interval("2026-11-01", "America/New_York")
        var streams = Streams()
        streams.awake((day.lowerBound - 5 * 3_600)..<(day.lowerBound - 3_600))
        streams.still((day.lowerBound - 3_600)..<(day.lowerBound + 7 * 3_600))            // 23:00 EDT → 06:00 EST
        streams.awake((day.lowerBound + 7 * 3_600)..<(day.lowerBound + 14 * 3_600))
        streams.still((day.lowerBound + 14 * 3_600)..<(day.lowerBound + 15 * 3_600 + 1_800))
        streams.awake((day.lowerBound + 15 * 3_600 + 1_800)..<(day.lowerBound + 18 * 3_600))
        let s = streams.sorted()
        let result = AnalyticsEngine.analyzeDay(day: "2026-11-01", hr: s.hr, rr: s.rr, gravity: s.gravity,
                                                profile: profile, tzOffsetSeconds: offset, dayInterval: day)
        try assertParity(result, offset: offset)
        try assertParity(result, offset: offset, habitual: 3 * 3_600)
    }

    // MARK: - In bed long, asleep short (#525 class), at the shared selector

    /// A 9 h block with only 3 h asleep against a 5 h nap that is all sleep. `analyzeDay` ranks clock
    /// spans, and the seam now does too, so an edit can't flip the day to the nap. The old stages-scored
    /// seam ranked asleep minutes (180 + 90 bonus vs 300) and picked the nap.
    func testInBedLongAsleepShortPicksTheSameBlockOnBothPaths() throws {
        let (day, offset) = try interval("2026-06-17", "UTC")
        let night = (start: day.lowerBound - 3 * 3_600, end: day.lowerBound + 6 * 3_600)
        let nap = (start: day.lowerBound + 13 * 3_600, end: day.lowerBound + 18 * 3_600)
        let nightStages = #"{"awake":360,"light":120,"deep":30,"rem":30}"#   // 540 in bed, 180 asleep
        let napStages = #"{"awake":0,"light":200,"deep":50,"rem":50}"#       // 300 in bed, 300 asleep
        let rows = [
            CachedSleepSession(startTs: night.start, endTs: night.end, efficiency: 1.0 / 3.0,
                               restingHr: 50, avgHrv: 40, stagesJSON: nightStages),
            CachedSleepSession(startTs: nap.start, endTs: nap.end, efficiency: 1,
                               restingHr: 52, avgHrv: 42, stagesJSON: napStages),
        ]
        let engine = SleepStageTotals.mainNightGroupIndices(
            rows.map { SleepStageTotals.NightBlock(start: $0.startTs, end: $0.endTs) }, offsetSec: offset)
        let blocks = rows.map { (startTs: $0.startTs, stagesJSON: $0.stagesJSON) }
        let onsets = Dictionary(uniqueKeysWithValues: rows.map { ($0.startTs, $0.startTs) })
        let ends = Dictionary(uniqueKeysWithValues: rows.map { ($0.startTs, $0.endTs) })
        let seamGroup = SleepStageTotals.mainNightGroupIndices(
            SleepStageTotals.seamNightBlocks(blocks, onsetByStart: onsets, endByStart: ends), offsetSec: offset)
        XCTAssertEqual(engine, [0])
        XCTAssertEqual(seamGroup, engine)
        // A no-op "edit" of the night (same stages) keeps the night as the day total.
        let edited = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: blocks, edited: [night.start: nightStages], onsetByStart: onsets, endByStart: ends,
            offsetSec: offset))
        XCTAssertEqual(edited.sleep.totalSleepMin, 180, accuracy: 0.001)
    }
}
