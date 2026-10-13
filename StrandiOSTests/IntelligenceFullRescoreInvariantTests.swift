import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import NOOP

/// Review findings on the N2 branch: a full-history rescore (the v3 migration's 30-day chunks) must not lose
/// stored values. Each fixture day is a regular strap night (23:00 to 06:00 at a resting heart rate, with an
/// hour of R-R for HRV and a skin-temperature reading every minute) followed by an awake day with an
/// evening hour of exercise. 30 s cadence keeps the 95-day fixture fast.
@MainActor
final class IntelligenceFullRescoreInvariantTests: XCTestCase {

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 2026-03-01T00:00:00Z: the fixture's first civil day.
    private let firstDayStart = 1_772_323_200

    private struct Harness {
        let store: WhoopStore
        let engine: IntelligenceEngine
        let computedId: String
        let reference: Date
        let dayKeys: [String]
    }

    private func dayKey(_ index: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(firstDayStart + index * 86_400)))
    }

    /// Nights for days `range` (0 = the first fixture day). The pass's "now" is 22:00 on the last day, so no
    /// reading is in the future.
    private func makeHarness(days: Int, strapDays: Range<Int>? = nil) async throws -> Harness {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let engine = IntelligenceEngine(repo: repository, profile: ProfileStore(), deviceId: Repository.whoopSource)
        for k in strapDays ?? 0..<days {
            let s = firstDayStart + k * 86_400
            var streams = Streams()
            let sleepRange = (s - 3_600)..<(s + 6 * 3_600)
            for ts in stride(from: sleepRange.lowerBound, to: sleepRange.upperBound, by: 30) {
                streams.hr.append(HRSample(ts: ts, bpm: 52 + k % 3))
                streams.gravity.append(GravitySample(ts: ts, x: 0, y: 0, z: 1))
                if ts % 60 == 0 { streams.skinTemp.append(SkinTempSample(ts: ts, raw: 3_450 + (k % 5) * 8)) }
            }
            var toggle = false
            let swing = 8 + (k % 4) * 3
            for ts in stride(from: s + 3_600, to: s + 2 * 3_600, by: 2) {
                toggle.toggle()
                streams.rr.append(RRInterval(ts: ts, rrMs: 1_150 + (toggle ? swing : -swing)))
            }
            for ts in stride(from: s + 6 * 3_600, to: s + 23 * 3_600, by: 30) {
                let exercising = ts >= s + 17 * 3_600 && ts < s + 18 * 3_600
                streams.hr.append(HRSample(ts: ts, bpm: exercising ? 135 + ts % 11 : 78 + ts % 9))
                let wobble = Double(ts % 11) * 0.2
                streams.gravity.append(GravitySample(ts: ts, x: wobble, y: 0.3 - wobble, z: 0.8))
                if ts % 60 == 0 { streams.skinTemp.append(SkinTempSample(ts: ts, raw: 3_300)) }
            }
            _ = try await store.insert(streams, deviceId: Repository.whoopSource)
        }
        let reference = Date(timeIntervalSince1970: TimeInterval(firstDayStart + (days - 1) * 86_400 + 22 * 3_600))
        return Harness(store: store, engine: engine, computedId: Repository.whoopSource + "-noop",
                       reference: reference, dayKeys: (0..<days).map(dayKey))
    }

    private func pass(_ harness: Harness, maxDays: Int, startOffset: Int = 0) async -> Bool {
        await harness.engine.analyzeRecent(
            maxDays: maxDays, startOffset: startOffset, force: true, refreshRepository: false,
            analysisReference: harness.reference, analysisCalendar: utcCalendar)
    }

    /// The v3 migration's shape: newest-first 30-day chunks over the whole history.
    private func chunkedRescore(_ harness: Harness, days: Int) async -> Bool {
        var ok = true
        for offset in stride(from: 0, to: days, by: IntelligenceEngine.effortRescoreChunkDays) {
            ok = await pass(harness, maxDays: IntelligenceEngine.effortRescoreChunkDays, startOffset: offset) && ok
        }
        return ok
    }

    private func stored(_ harness: Harness) async throws -> [String: DailyMetric] {
        let rows = try await harness.store.dailyMetrics(
            deviceId: harness.computedId, from: "0000-01-01", to: "9999-12-31")
        return Dictionary(rows.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func withRecalibrationEpochsRestored(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let keys = [Baselines.hrvBaselineEpochKey, Baselines.recoveryBaselineEpochKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        for key in keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        try await body()
    }

    // MARK: - F3 invariant (with F2 skin and F5 chunk edges)

    /// A full chunked rescore over 95 days with unchanged inputs turns no stored Charge, skin-temperature
    /// deviation, HRV or resting HR into nil (F3). Skin deviations come out identical (F2: the as-of skin
    /// baseline used to see only the chunk, so the oldest four days of every chunk were wiped), and so does
    /// Effort on the chunk edges (F5: the newest day of each chunk had no successor and was cut at midnight).
    func testFullChunkedRescoreKeepsEveryStoredValue() async throws {
        try await withRecalibrationEpochsRestored {
            let days = 95
            let harness = try await makeHarness(days: days)
            let single = await pass(harness, maxDays: days)
            XCTAssertTrue(single)
            let before = try await stored(harness)
            XCTAssertGreaterThan(before.values.compactMap(\.recovery).count, 80, "fixture must score Charge")
            XCTAssertGreaterThan(before.values.compactMap(\.skinTempDevC).count, 80, "fixture must score skin")

            let chunked = await chunkedRescore(harness, days: days)
            XCTAssertTrue(chunked)
            let after = try await stored(harness)

            for day in harness.dayKeys {
                let a = before[day], b = after[day]
                if a?.recovery != nil { XCTAssertNotNil(b?.recovery, "\(day) recovery") }
                if a?.skinTempDevC != nil { XCTAssertNotNil(b?.skinTempDevC, "\(day) skin") }
                if a?.avgHrv != nil { XCTAssertNotNil(b?.avgHrv, "\(day) hrv") }
                if a?.restingHr != nil { XCTAssertNotNil(b?.restingHr, "\(day) rhr") }
                XCTAssertEqual(b?.skinTempDevC, a?.skinTempDevC, "\(day) skin deviation unchanged")
                XCTAssertEqual(b?.recovery, a?.recovery, "\(day) Charge unchanged")
                XCTAssertEqual(b?.strain, a?.strain, "\(day) Effort unchanged")
            }
        }
    }

    // MARK: - Strap nights overlapping a wearable import (review round 3, findings 1, 7 and 9)

    /// A strap user who also imported an Oura export covering the same months, plus a steps-only Fitbit export.
    /// The fold never writes on a strap day, so those computed rows are the strap's own nights and stay in
    /// its baseline: stored Charge survives a chunked rescore and a one-day pass, and matches a run with no
    /// imports at all.
    func testStrapNightsOverlappingAWearableImportStayInTheStrapBaseline() async throws {
        try await withRecalibrationEpochsRestored {
            let days = 40
            let plain = try await makeHarness(days: days)
            let plainCompleted = await pass(plain, maxDays: days)
            XCTAssertTrue(plainCompleted)
            let expected = try await stored(plain)
            XCTAssertGreaterThan(expected.values.compactMap(\.recovery).count, 30, "fixture must score Charge")

            let harness = try await makeHarness(days: days)
            let ouraRows = (0..<days).map { k in
                DailyMetric(day: dayKey(k), totalSleepMin: 450, efficiency: 0.9, deepMin: 80, remMin: 100,
                            lightMin: 270, disturbances: nil, restingHr: 47, avgHrv: 130 + Double(k % 3),
                            recovery: nil, strain: nil, exerciseCount: nil, respRateBpm: 13)
            }
            _ = try await harness.store.upsertDailyMetrics(ouraRows, deviceId: "oura-import")
            let fitbitRows = (0..<days).map { k in
                DailyMetric(day: dayKey(k), totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                            lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                            strain: nil, exerciseCount: nil, steps: 9_000 + k)
            }
            _ = try await harness.store.upsertDailyMetrics(fitbitRows, deviceId: "fitbit-import")
            let single = await pass(harness, maxDays: days)
            XCTAssertTrue(single)
            let chunked = await chunkedRescore(harness, days: days)
            XCTAssertTrue(chunked)
            let afterChunks = try await stored(harness)
            for day in harness.dayKeys {
                XCTAssertEqual(afterChunks[day]?.recovery, expected[day]?.recovery, "\(day) Charge after the rescore")
                XCTAssertEqual(afterChunks[day]?.avgHrv, expected[day]?.avgHrv, "\(day) the strap's own HRV")
            }

            let oneDay = await pass(harness, maxDays: 1)
            XCTAssertTrue(oneDay)
            let today = harness.dayKeys[days - 1]
            let afterOneDay = try await stored(harness)
            XCTAssertNotNil(afterOneDay[today]?.recovery, "a one-day pass still sees the strap's history")
            XCTAssertEqual(afterOneDay[today]?.recovery, expected[today]?.recovery)
        }
    }

    // MARK: - F1

    /// Recalibrating on day 30 and then rescoring the whole history leaves every earlier day's Charge as it
    /// was. The as-of fold used to drop every night before the epoch, so pre-epoch days lost their baseline
    /// and their stored Charge was overwritten with nil.
    func testRecalibrationKeepsEveryPreEpochCharge() async throws {
        try await withRecalibrationEpochsRestored {
            let days = 40
            let harness = try await makeHarness(days: days)
            let single = await pass(harness, maxDays: days)
            XCTAssertTrue(single)
            let before = try await stored(harness)
            let epochIndex = 30
            Baselines.recalibrateRecoveryBaselines(
                now: TimeInterval(firstDayStart + epochIndex * 86_400 + 14 * 3_600), defaults: .standard)

            let chunked = await chunkedRescore(harness, days: days)
            XCTAssertTrue(chunked)
            let after = try await stored(harness)

            let preEpoch = harness.dayKeys.prefix(epochIndex + 1)   // the epoch's own day started before it
            XCTAssertGreaterThan(preEpoch.compactMap { before[$0]?.recovery }.count, 20)
            for day in preEpoch {
                XCTAssertEqual(after[day]?.recovery, before[day]?.recovery, "\(day) Charge kept")
            }
            // The day after the recalibration restarts the build-up.
            XCTAssertNil(after[harness.dayKeys[epochIndex + 1]]?.recovery)
        }
    }

    // MARK: - F7

    /// Oura rows the wearable fold re-homed under the computed id must not seed the strap's HRV baseline
    /// (#459): the first strap night after months of Oura imports is still calibrating.
    func testWearableImportHrvStaysOutOfTheStrapBaseline() async throws {
        try await withRecalibrationEpochsRestored {
            let days = 36
            let harness = try await makeHarness(days: days, strapDays: 30..<days)
            let ouraRows = (0..<30).map { k in
                DailyMetric(day: dayKey(k), totalSleepMin: 450, efficiency: 0.9, deepMin: 80, remMin: 100,
                            lightMin: 270, disturbances: nil, restingHr: 50, avgHrv: 130 + Double(k % 3),
                            recovery: nil, strain: nil, exerciseCount: nil)
            }
            _ = try await harness.store.upsertDailyMetrics(ouraRows, deviceId: "oura-import")
            // What earlier passes' wearable fold wrote under the computed id for those days.
            _ = try await harness.store.upsertDailyMetrics(
                ouraRows.map { $0.with(recovery: 60, skinTempDevC: nil) }, deviceId: harness.computedId)

            let completed = await pass(harness, maxDays: 6)
            XCTAssertTrue(completed)
            let after = try await stored(harness)
            XCTAssertNotNil(after[dayKey(30)]?.avgHrv, "the first strap night is scored")
            XCTAssertNil(after[dayKey(30)]?.recovery, "with no strap history its Charge is still calibrating")
        }
    }

    // MARK: - F8

    /// A watch-only user's Apple-scored days stay in the pass results, so Smart Alarm's green wake mode and
    /// the Charge forecast keep their history after a one-day pass.
    func testAppleScoredDaysStayInResults() async throws {
        try await withRecalibrationEpochsRestored {
            let store = try await WhoopStore.inMemory()
            let repository = Repository(deviceId: Repository.whoopSource)
            repository.setStoreForTesting(store)
            let engine = IntelligenceEngine(repo: repository, profile: ProfileStore(),
                                            deviceId: Repository.whoopSource)
            let rows = (0..<20).map { k in
                DailyMetric(day: dayKey(k), totalSleepMin: 420, efficiency: 0.9, deepMin: 80, remMin: 90,
                            lightMin: 250, disturbances: nil, restingHr: 55 + k % 3, avgHrv: 48 + Double(k % 5),
                            recovery: nil, strain: nil, exerciseCount: nil)
            }
            _ = try await store.upsertDailyMetrics(rows, deviceId: Repository.appleHealthSource)
            let reference = Date(timeIntervalSince1970: TimeInterval(firstDayStart + 19 * 86_400 + 12 * 3_600))
            let completed = await engine.analyzeRecent(
                maxDays: 1, startOffset: 0, force: true, refreshRepository: false,
                analysisReference: reference, analysisCalendar: utcCalendar)
            XCTAssertTrue(completed)
            let appleRecoveries = engine.results.filter { $0.source == .appleHealth }.compactMap(\.recovery)
            XCTAssertGreaterThanOrEqual(appleRecoveries.count, RecoveryForecaster.minBaselineNights)
        }
    }
}
