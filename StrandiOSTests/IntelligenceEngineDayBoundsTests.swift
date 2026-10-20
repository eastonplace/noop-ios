import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import NOOP

/// AN-02 wiring: IntelligenceEngine hands each civil day its own `[start, nextStart)` interval and offset,
/// so a daylight-saving day keeps its real length and an edit near midnight stays on its own day. Also
/// carries the fixed-offset midnight helpers ported from StrandTests/LocalDayMidnightTests (#277), which no
/// target compiled (ORG-1).
@MainActor
final class IntelligenceEngineDayBoundsTests: XCTestCase {

    private var newYorkCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    // MARK: - The civil interval reaches analyzeDay (AN-02)

    /// US fall-back day (25 h). Steps taken between local 00:00 and 01:00, still on daylight time, used to
    /// fall outside the pass-wide standard-time bucket and vanish from the stored row.
    func testFallBackDayFirstHourStepsReachTheStoredDailyRow() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let profile = ProfileStore()
        let previousScale = profile.stepTicksPerStep
        profile.stepTicksPerStep = 1.0
        defer { profile.stepTicksPerStep = previousScale }
        let engine = IntelligenceEngine(repo: repository, profile: profile, deviceId: Repository.whoopSource)

        let day = try XCTUnwrap(AnalyticsEngine.civilDayInterval(
            day: "2026-11-01", timeZone: newYorkCalendar.timeZone))
        XCTAssertEqual(day.upperBound - day.lowerBound, 25 * 3_600)
        // Enough HR rows to pass the 200-row scoring gate, and step ticks only in the first local hour.
        let hr = stride(from: day.lowerBound - 3_600, to: day.upperBound, by: 60)
            .map { HRSample(ts: $0, bpm: 70) }
        var counter = 100
        let steps: [StepSample] = stride(from: day.lowerBound, to: day.lowerBound + 3_600, by: 60).map { ts in
            counter += 7
            return StepSample(ts: ts, counter: counter)
        }
        _ = try await store.insert(Streams(hr: hr, steps: steps), deviceId: Repository.whoopSource)

        let reference = try XCTUnwrap(newYorkCalendar.date(
            from: DateComponents(year: 2026, month: 11, day: 2, hour: 12)))
        let completed = await engine.analyzeRecent(
            maxDays: 2, startOffset: 0, force: true, refreshRepository: false,
            analysisReference: reference, analysisCalendar: newYorkCalendar)
        XCTAssertTrue(completed)

        let stored = try await store.dailyMetrics(
            deviceId: Repository.whoopSource + "-noop", from: "2026-11-01", to: "2026-11-01")
        XCTAssertEqual(stored.first?.steps, 59 * 7)
    }

    /// An edited night ending at 00:30 daylight time on the fall-back day belongs to that day.
    func testEditEndingInFallBackFirstHourBelongsToThatDay() throws {
        let tz = newYorkCalendar.timeZone
        let fallBack = try XCTUnwrap(AnalyticsEngine.civilDayInterval(day: "2026-11-01", timeZone: tz))
        let dayBefore = try XCTUnwrap(AnalyticsEngine.civilDayInterval(day: "2026-10-31", timeZone: tz))
        let end = fallBack.lowerBound + 30 * 60
        let row = CachedSleepSession(startTs: end - 6 * 3_600, endTs: end, efficiency: 0.9,
                                     restingHr: 52, avgHrv: 60, stagesJSON: nil, userEdited: true)

        XCTAssertEqual(IntelligenceEngine.editedRowsForDay([row], dayWindow: fallBack), [row])
        XCTAssertTrue(IntelligenceEngine.editedRowsForDay([row], dayWindow: dayBefore).isEmpty)
        XCTAssertTrue(IntelligenceEngine.editedRowsForDay([row], dayWindow: nil).isEmpty)
    }

    /// The scan version keys both the day-scan cache and the idle-tick watermark, so scans cached under an
    /// older scoring semantics (fixed-offset days before AN-02, the midnight-cut Effort before AN-05, the
    /// unfilled calorie total before D3b) are never replayed.
    func testCacheSignatureCarriesTheCivilDayScanVersion() {
        XCTAssertEqual(IntelligenceEngine.analyzeScanVersion, "cache-v5")
        let signature = IntelligenceEngine.analyzeRecentCacheConfigSignature(
            profile: UserProfile(), baselines: AnalyticsEngine.ProfileBaselines(), maxHROverride: nil,
            timeZoneIdentifier: "America/New_York", timeZoneOffsetSeconds: -18_000,
            sleepNeedHours: 8, sleepConsistency: nil, habitualMidsleepSec: nil,
            useSleepStagerV2: false, useMotionAwareWake: false, deepHrvWindow: false,
            sleepTraceActive: false, hrvTraceActive: false, stepsTraceActive: false)
        XCTAssertTrue(signature.hasPrefix("\(IntelligenceEngine.analyzeScanVersion)|"))
    }

    // MARK: - Fixed-offset midnight helpers (ported from StrandTests/LocalDayMidnightTests, #277)

    func testMidnightLocalFloorsToLocalMidnightWestOfUTC() throws {
        // UTC-4: local 21:00 on 2021-06-15 == 01:00 UTC 2021-06-16 == 1623805200. Local midnight is
        // 2021-06-15 00:00 local == 04:00 UTC == 1623729600.
        let offset = -4 * 3600
        let tsUtc = 1_623_805_200
        let midnight = try XCTUnwrap(IntelligenceEngine.midnightLocal(tsUtc, offsetSec: offset))
        XCTAssertEqual(midnight, 1_623_729_600)
        XCTAssertEqual(AnalyticsEngine.dayString(midnight, offsetSec: offset), "2021-06-15")
    }

    func testMidnightLocalOffsetZeroEqualsMidnightUtc() throws {
        for ts in [1_609_459_200, 1_609_459_200 + 45_000, 0, 86_399, -1, -86_401] {
            XCTAssertEqual(try XCTUnwrap(IntelligenceEngine.midnightLocal(ts, offsetSec: 0)),
                           try XCTUnwrap(IntelligenceEngine.midnightUtc(ts)),
                           "midnightLocal(offset=0) must equal midnightUtc for ts=\(ts)")
        }
    }

    func testMidnightLocalNegativeOffsetSignCorrect() throws {
        let offset = -5 * 3600
        for ts in [1_623_805_200, 1_600_000_000, 100] {
            let mid = try XCTUnwrap(IntelligenceEngine.midnightLocal(ts, offsetSec: offset))
            let mod = ((mid + offset) % 86_400 + 86_400) % 86_400
            XCTAssertEqual(mod, 0, "must land on a local-day boundary")
            XCTAssertLessThanOrEqual(mid, ts, "midnight floor must not exceed ts")
            XCTAssertLessThan(ts - mid, 86_400, "floor must be within the same local day")
        }
    }
}
