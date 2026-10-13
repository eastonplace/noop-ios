import XCTest
import NoopPhase34Core
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

    private let secondWhoop4Id = "whoop4-second-strap"
    private let earlierStrapId = "earlier-strap"

    private func dayKey(_ index: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(firstDayStart + index * 86_400)))
    }

    /// Nights for days `strapDays` (0 = the first fixture day). The pass's "now" is 22:00 on the last day, so no
    /// reading is in the future. A day in `lateNights` stays up past midnight instead: awake from 23:00, an hour
    /// of exercise from 00:00, asleep at 01:30. `whoop4` pairs the strap as a WHOOP 4.0, whose skin register
    /// is converted with an anchor each pass learns from its own window; its nightly raws drift up 2 units a
    /// night, so passes over different windows learn different anchors. `whoop4SwapDay` instead swaps to a
    /// second WHOOP 4.0 on that day: neither strap drifts, and the second one's register reads 30 units
    /// (1.5 °C) higher for the same skin. `whoop4SameIdSwapDay` reads the same way, but the replacement keeps
    /// the registry id: the strap starts on peripheral "strap-A", and the test adopts the replacement's.
    /// `earlierStrapUntil` records the days before it on an earlier strap, the active one, with the seeded strap
    /// paired beside it.
    private func makeHarness(days: Int, strapDays: Range<Int>? = nil, lateNights: Set<Int> = [],
                             whoop4: Bool = false, whoop4SwapDay: Int? = nil,
                             whoop4SameIdSwapDay: Int? = nil,
                             earlierStrapUntil: Int? = nil) async throws -> Harness {
        let store = try await WhoopStore.inMemory()
        if earlierStrapUntil != nil {
            let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
            try registry.add(PairedDevice(
                id: earlierStrapId, brand: "WHOOP", model: "WHOOP", sourceKind: .liveBLE,
                capabilities: [.hr, .hrv, .skinTemp, .sleep], status: .paired, addedAt: 0, lastSeenAt: 0))
            try registry.setActive(earlierStrapId)
        }
        let whoop4 = whoop4 || whoop4SwapDay != nil || whoop4SameIdSwapDay != nil
        if whoop4 {
            let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
            try registry.add(PairedDevice(
                id: Repository.whoopSource, brand: "WHOOP", model: "WHOOP 4.0", sourceKind: .liveBLE,
                capabilities: [.hr, .hrv, .skinTemp, .sleep], status: .active, addedAt: 0, lastSeenAt: 0))
            try registry.setActive(Repository.whoopSource)
            if whoop4SameIdSwapDay != nil {
                try registry.setPeripheralId(Repository.whoopSource, peripheralId: "strap-A")
            }
            if whoop4SwapDay != nil {
                try registry.add(PairedDevice(
                    id: secondWhoop4Id, brand: "WHOOP", model: "WHOOP 4.0", sourceKind: .liveBLE,
                    capabilities: [.hr, .hrv, .skinTemp, .sleep], status: .active, addedAt: 0, lastSeenAt: 0))
                try registry.setActive(secondWhoop4Id)
            }
        }
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let engine = IntelligenceEngine(repo: repository, profile: ProfileStore(), deviceId: Repository.whoopSource)
        for k in strapDays ?? 0..<days {
            let s = firstDayStart + k * 86_400
            var streams = Streams()
            let late = lateNights.contains(k)
            let onset = late ? s + 5_400 : s - 3_600
            if late {
                for ts in stride(from: s - 3_600, to: onset, by: 30) {
                    let exercising = ts >= s && ts < s + 3_600
                    streams.hr.append(HRSample(ts: ts, bpm: exercising ? 135 + ts % 11 : 78 + ts % 9))
                    let wobble = Double(ts % 11) * 0.2
                    streams.gravity.append(GravitySample(ts: ts, x: wobble, y: 0.3 - wobble, z: 0.8))
                    if !whoop4, ts % 60 == 0 { streams.skinTemp.append(SkinTempSample(ts: ts, raw: 3_300)) }
                }
            }
            for ts in stride(from: onset, to: s + 6 * 3_600, by: 30) {
                streams.hr.append(HRSample(ts: ts, bpm: 52 + k % 3))
                streams.gravity.append(GravitySample(ts: ts, x: 0, y: 0, z: 1))
                if ts % 60 == 0 {
                    let raw: Int
                    if let swap = whoop4SwapDay ?? whoop4SameIdSwapDay {
                        raw = (k >= swap ? 1_330 : 1_300) + (ts / 60) % 3
                    } else {
                        raw = whoop4 ? 1_300 + 2 * k + (ts / 60) % 3 : 3_450 + (k % 5) * 8
                    }
                    streams.skinTemp.append(SkinTempSample(ts: ts, raw: raw))
                }
            }
            var toggle = false
            let swing = 8 + (k % 4) * 3
            let rrStart = late ? s + 9_000 : s + 3_600
            for ts in stride(from: rrStart, to: rrStart + 3_600, by: 2) {
                toggle.toggle()
                streams.rr.append(RRInterval(ts: ts, rrMs: 1_150 + (toggle ? swing : -swing)))
            }
            for ts in stride(from: s + 6 * 3_600, to: s + 23 * 3_600, by: 30) {
                let exercising = ts >= s + 17 * 3_600 && ts < s + 18 * 3_600
                streams.hr.append(HRSample(ts: ts, bpm: exercising ? 135 + ts % 11 : 78 + ts % 9))
                let wobble = Double(ts % 11) * 0.2
                streams.gravity.append(GravitySample(ts: ts, x: wobble, y: 0.3 - wobble, z: 0.8))
                if !whoop4, ts % 60 == 0 { streams.skinTemp.append(SkinTempSample(ts: ts, raw: 3_300)) }
            }
            let strap = whoop4SwapDay.map { k >= $0 ? secondWhoop4Id : Repository.whoopSource }
                ?? earlierStrapUntil.map { k < $0 ? earlierStrapId : Repository.whoopSource }
            _ = try await store.insert(streams, deviceId: strap ?? Repository.whoopSource)
        }
        let reference = Date(timeIntervalSince1970: TimeInterval(firstDayStart + (days - 1) * 86_400 + 22 * 3_600))
        return Harness(store: store, engine: engine, computedId: Repository.whoopSource + "-noop",
                       reference: reference, dayKeys: (0..<days).map(dayKey))
    }

    private func pass(_ harness: Harness, maxDays: Int, startOffset: Int = 0, at reference: Date? = nil,
                      sourceContext: ExactWorkSourceContext? = nil,
                      keepUnproducedHistory: Bool = false) async -> Bool {
        await harness.engine.analyzeRecent(
            maxDays: maxDays, startOffset: startOffset, force: true, refreshRepository: false,
            analysisReference: reference ?? harness.reference, analysisCalendar: utcCalendar,
            sourceContext: sourceContext, keepUnproducedHistory: keepUnproducedHistory)
    }

    /// An exact historical pass's source context for `deviceId`'s committed work on `day`.
    private func exactSource(_ deviceId: String, day: String, createdAt: Date) throws -> ExactWorkSourceContext {
        ExactWorkSourceContext(work: try HistoricalAnalysisWork(
            scope: HistoricalAnalysisScope(
                databaseInstanceId: "rescore-invariant-db", sourceId: deviceId, deviceId: deviceId,
                deviceLineageId: "\(deviceId)-lineage", cursorEpoch: 0, trimScope: "historical"),
            firstReceiptGeneration: 1, lastReceiptGeneration: 1, affectedDays: [try CivilDay(key: day)],
            recordedTimeZoneIdentifier: "GMT", createdAt: createdAt))
    }

    /// The v3 migration's shape: newest-first 30-day chunks over the whole history. `keepUnproducedHistory` is
    /// the migration's own safety net; the invariant tests leave it off, so every day they check was produced.
    private func chunkedRescore(_ harness: Harness, days: Int, keepUnproducedHistory: Bool = false) async -> Bool {
        var ok = true
        for offset in stride(from: 0, to: days, by: IntelligenceEngine.effortRescoreChunkDays) {
            ok = await pass(harness, maxDays: IntelligenceEngine.effortRescoreChunkDays, startOffset: offset,
                            keepUnproducedHistory: keepUnproducedHistory) && ok
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
    /// The night after each chunk's newest day is a late one with exercise from midnight to 01:00, so a cycle
    /// cut at midnight loses that hour and Effort differs (review round 3, finding 11).
    func testFullChunkedRescoreKeepsEveryStoredValue() async throws {
        try await withRecalibrationEpochsRestored {
            let days = 95
            let chunk = IntelligenceEngine.effortRescoreChunkDays
            let chunkEdges = Array(stride(from: days - 1 - chunk, through: 0, by: -chunk))
            let harness = try await makeHarness(days: days, lateNights: Set(chunkEdges.map { $0 + 1 }))
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
            for edge in chunkEdges {
                XCTAssertNotNil(before[harness.dayKeys[edge]]?.strain, "chunk edge \(edge) must score Effort")
            }
        }
    }

    // MARK: - Upgrade path (review round 3, findings 7 and 12)

    /// An upgraded device has stored rows and no persisted nightly skin means. The v3 chunks run newest first,
    /// so no chunk's skin history reaches before its own window: every completed day keeps its stored
    /// deviation instead of being rewritten against a chunk-local baseline, and no stored field turns nil.
    func testUpgradeRescoreKeepsStoredSkinDeviationsWithoutPersistedMeans() async throws {
        try await withRecalibrationEpochsRestored {
            let days = 40
            let harness = try await makeHarness(days: days)
            let single = await pass(harness, maxDays: days)
            XCTAssertTrue(single)
            // Rows "from before the upgrade": scored by older code (a different deviation), no nightly means.
            let scored = try await stored(harness)
            let preUpgrade = harness.dayKeys.compactMap { scored[$0] }.map { row in
                row.with(recovery: row.recovery, skinTempDevC: row.skinTempDevC.map { $0 + 0.07 })
            }
            _ = try await harness.store.upsertDailyMetrics(preUpgrade, deviceId: harness.computedId)
            _ = try await harness.store.deleteMetricSeriesGlobally(keys: ["skin_temp_night_mean_c"])
            let before = try await stored(harness)
            XCTAssertGreaterThan(before.values.compactMap(\.skinTempDevC).count, 30, "fixture must store skin")

            let chunked = await chunkedRescore(harness, days: days)
            XCTAssertTrue(chunked)
            let after = try await stored(harness)

            let today = harness.dayKeys[days - 1]
            for day in harness.dayKeys {
                let a = before[day], b = after[day]
                if a?.recovery != nil { XCTAssertNotNil(b?.recovery, "\(day) recovery") }
                if a?.skinTempDevC != nil { XCTAssertNotNil(b?.skinTempDevC, "\(day) skin") }
                if a?.avgHrv != nil { XCTAssertNotNil(b?.avgHrv, "\(day) hrv") }
                if a?.restingHr != nil { XCTAssertNotNil(b?.restingHr, "\(day) rhr") }
                if day != today { XCTAssertEqual(b?.skinTempDevC, a?.skinTempDevC, "\(day) stored deviation kept") }
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

    // MARK: - WHOOP 4.0 skin anchor (review round 3, findings 2 and 10)

    /// A WHOOP 4.0's skin register is converted with an anchor each pass learns from its own window. A 30-day
    /// pass and a later one-day pass learn different anchors over the same raw data, yet today's deviation
    /// is the same: the persisted history is converted with the current pass's anchor, so the offset cancels.
    func testWhoop4SkinDeviationDoesNotDependOnThePassAnchor() async throws {
        try await withRecalibrationEpochsRestored {
            let days = 30
            let harness = try await makeHarness(days: days, whoop4: true)
            let wide = await pass(harness, maxDays: days)
            XCTAssertTrue(wide)
            let today = harness.dayKeys[days - 1]
            let first = try await stored(harness)
            let deviation = try XCTUnwrap(first[today]?.skinTempDevC, "a usable WHOOP 4.0 skin baseline")

            let narrow = await pass(harness, maxDays: 1)
            XCTAssertTrue(narrow)
            let second = try await stored(harness)
            XCTAssertEqual(try XCTUnwrap(second[today]?.skinTempDevC), deviation, accuracy: 0.011)
        }
    }

    /// Review round 4 (1): swapping to a second WHOOP 4.0 whose register reads 1.5 °C higher for the same skin
    /// does not read as a fever. A one-day pass after the swap converts the first strap's stored nights with
    /// that strap's own anchor, so today's deviation matches the 30-day pass, which converted each strap's
    /// fresh nights with its own anchor. One anchor for every stored night put the first strap's nights
    /// 1.5 °C low, and today's deviation jumped up by the share of them in the baseline.
    func testWhoop4StrapSwapKeepsSkinDeviationsContinuous() async throws {
        try await withRecalibrationEpochsRestored {
            let days = 30
            let harness = try await makeHarness(days: days, whoop4SwapDay: 20)
            let wide = await pass(harness, maxDays: days)
            XCTAssertTrue(wide)
            let first = try await stored(harness)
            for k in 18..<days {
                let deviation = try XCTUnwrap(first[dayKey(k)]?.skinTempDevC, "day \(k) has a skin deviation")
                XCTAssertEqual(deviation, 0, accuracy: 0.3, "day \(k): the swap is continuous")
            }

            let narrow = await pass(harness, maxDays: 1)
            XCTAssertTrue(narrow)
            let second = try await stored(harness)
            let today = harness.dayKeys[days - 1]
            XCTAssertEqual(try XCTUnwrap(second[today]?.skinTempDevC),
                           try XCTUnwrap(first[today]?.skinTempDevC), accuracy: 0.011)
        }
    }

    /// Review round 5 (4): a replacement WHOOP 4.0 that takes over the same registry id (it adopts a new BLE
    /// peripheral) does not read as a fever either. The first strap's stored nights keep their own identity and
    /// anchor, so the passes after the swap stay continuous, and a rescore over the swap keeps the first strap's
    /// nights under its identity. Keyed by registry id, its nights were converted with the replacement's anchor.
    func testSameIdWhoop4ReplacementKeepsSkinDeviationsContinuous() async throws {
        try await withRecalibrationEpochsRestored {
            let days = 30
            let harness = try await makeHarness(days: days, whoop4SameIdSwapDay: 20)
            let beforeSwap = Date(timeIntervalSince1970: TimeInterval(firstDayStart + 19 * 86_400 + 22 * 3_600))
            let first = await pass(harness, maxDays: 20, at: beforeSwap)
            XCTAssertTrue(first)
            let strapA = IntelligenceEngine.nightlySkinWhoop4RawKeyPrefix
                + IntelligenceEngine.whoop4SkinIdentity(owner: Repository.whoopSource, peripheralId: "strap-A")
            let strapB = IntelligenceEngine.nightlySkinWhoop4RawKeyPrefix
                + IntelligenceEngine.whoop4SkinIdentity(owner: Repository.whoopSource, peripheralId: "strap-B")
            let storedA = try await harness.store.metricSeries(
                deviceId: harness.computedId, key: strapA, from: dayKey(0), to: dayKey(19))
            XCTAssertEqual(storedA.count, 20, "the first strap's nights are stored under its identity")

            let registry = DeviceRegistryStore(dbQueue: harness.store.registryWriter)
            try registry.setPeripheralId(Repository.whoopSource, peripheralId: "strap-B")
            let afterSwap = await pass(harness, maxDays: 10)
            XCTAssertTrue(afterSwap)
            let second = try await stored(harness)
            for k in 20..<days {
                let deviation = try XCTUnwrap(second[dayKey(k)]?.skinTempDevC, "day \(k) has a skin deviation")
                XCTAssertEqual(deviation, 0, accuracy: 0.3, "day \(k): the replacement is continuous")
            }

            let rescore = await pass(harness, maxDays: 15)
            XCTAssertTrue(rescore)
            let third = try await stored(harness)
            for k in 15..<days {
                let deviation = try XCTUnwrap(third[dayKey(k)]?.skinTempDevC, "day \(k) has a skin deviation")
                XCTAssertEqual(deviation, 0, accuracy: 0.3, "day \(k): the rescore is continuous")
            }
            let keptA = try await harness.store.metricSeries(
                deviceId: harness.computedId, key: strapA, from: dayKey(15), to: dayKey(19))
            XCTAssertEqual(keptA.map(\.day), (15..<20).map(dayKey), "rescored nights keep the first strap's identity")
            let movedToB = try await harness.store.metricSeries(
                deviceId: harness.computedId, key: strapB, from: dayKey(15), to: dayKey(19))
            XCTAssertTrue(movedToB.isEmpty)
        }
    }

    /// Review round 6: a completed day belongs to the live strap with the most heart rate in that day, among the
    /// straps that reach the raw loop's 200-row gate, and the active strap wins only a tie. The second strap's
    /// first evening (23:00 on day 19) no longer takes day 19 from the first strap, whose own night and day it
    /// was; today still goes to the active strap by priority, and a single-strap install is unchanged.
    func testACompletedDayBelongsToTheStrapThatCoveredIt() async throws {
        try await withRecalibrationEpochsRestored {
            let harness = try await makeHarness(days: 30, whoop4SwapDay: 20)
            let lastFirstStrapDay = try await resolvedOwner(harness, day: 19, completed: true)
            XCTAssertEqual(lastFirstStrapDay, Repository.whoopSource, "day 19 is the first strap's")
            let firstSecondStrapDay = try await resolvedOwner(harness, day: 20, completed: true)
            XCTAssertEqual(firstSecondStrapDay, secondWhoop4Id)
            let firstStrapOnly = try await resolvedOwner(harness, day: 10, completed: true)
            XCTAssertEqual(firstStrapOnly, Repository.whoopSource, "a day only one strap covered is unchanged")
            let dayNineteenAsToday = try await resolvedOwner(harness, day: 19, completed: false)
            XCTAssertEqual(dayNineteenAsToday, secondWhoop4Id, "today keeps the active strap's priority")

            // A tie goes to the active strap.
            let start = firstDayStart + 25 * 86_400
            let secondStrapRows = try await harness.store.hrFingerprint(
                deviceId: secondWhoop4Id, from: start, to: start + 86_399).count
            var streams = Streams()
            streams.hr = (0..<secondStrapRows).map { HRSample(ts: start + $0, bpm: 60) }
            _ = try await harness.store.insert(streams, deviceId: Repository.whoopSource)
            let tie = try await resolvedOwner(harness, day: 25, completed: true)
            XCTAssertEqual(tie, secondWhoop4Id)

            let single = try await makeHarness(days: 3, whoop4: true)
            let singleOwner = try await resolvedOwner(single, day: 1, completed: true)
            XCTAssertEqual(singleOwner, Repository.whoopSource, "a single-strap install is unchanged")
        }
    }

    /// The owner `resolveDayOwner` gives fixture day `k`, with the scan loop's read window.
    private func resolvedOwner(_ harness: Harness, day k: Int, completed: Bool) async throws -> String {
        let registry = DeviceRegistryStore(dbQueue: harness.store.registryWriter)
        let start = firstDayStart + k * 86_400
        let window = IntelligenceEngine.CivilDayWindow(day: dayKey(k), start: start, nextStart: start + 86_400)
        let devices = try registry.all()
        let activeId = try registry.activeDeviceId() ?? Repository.whoopSource
        return await IntelligenceEngine.resolveDayOwner(
            day: dayKey(k), from: start - 30 * 3_600, to: start + 86_400, store: harness.store,
            devices: devices, activeId: activeId, registry: registry, fallbackDeviceId: Repository.whoopSource,
            completedDay: completed ? window : nil)
    }

    // MARK: - The v3 rescore keeps every stored completed day (review round 7, 1)

    /// An earlier strap, archived since, still owns the completed days it recorded, so the migration's full-history
    /// rescore scores them from its rows. Their stored Charge is overwritten first, so only a rescore from the
    /// earlier strap's readings brings it back. Archived straps used to be left out of the owner: those days
    /// resolved to the live strap's empty window and the reconcile deleted them.
    func testAFullHistoryRescoreScoresAnArchivedStrapsDays() async throws {
        try await withRecalibrationEpochsRestored {
            let days = 30
            let harness = try await makeHarness(days: days, earlierStrapUntil: 20)
            let first = await pass(harness, maxDays: days)
            XCTAssertTrue(first)
            let before = try await stored(harness)
            XCTAssertGreaterThan((0..<20).compactMap { before[dayKey($0)]?.recovery }.count, 10,
                                 "the earlier strap's days score Charge")

            let registry = DeviceRegistryStore(dbQueue: harness.store.registryWriter)
            try registry.setActive(Repository.whoopSource)
            try registry.archive(earlierStrapId)
            _ = try await harness.store.upsertDailyMetrics(
                (0..<20).compactMap { before[dayKey($0)]?.with(recovery: 1, skinTempDevC: nil) },
                deviceId: harness.computedId)

            let rescored = await chunkedRescore(harness, days: days, keepUnproducedHistory: true)
            XCTAssertTrue(rescored)
            let after = try await stored(harness)
            for k in 0..<days {
                let day = dayKey(k)
                XCTAssertNotNil(after[day], "day \(k) keeps its row")
                XCTAssertEqual(after[day]?.recovery, before[day]?.recovery, "day \(k) Charge from its own strap")
                XCTAssertEqual(after[day]?.restingHr, before[day]?.restingHr, "day \(k)")
                XCTAssertEqual(after[day]?.avgHrv, before[day]?.avgHrv, "day \(k)")
                XCTAssertEqual(after[day]?.strain, before[day]?.strain, "day \(k)")
            }
            let archivedDay = try await resolvedOwner(harness, day: 10, completed: true)
            XCTAssertEqual(archivedDay, earlierStrapId)
            let today = try await resolvedOwner(harness, day: days - 1, completed: false)
            XCTAssertEqual(today, Repository.whoopSource, "today's priority still leaves archived straps out")
        }
    }

    /// A migration chunk that can't produce a stored completed day (no readings left for it) leaves the day's row,
    /// its metric rows and its detected workout exactly as they were. An ordinary pass keeps the full
    /// replacement and still drops them.
    func testAMigrationChunkKeepsADayItCannotProduce() async throws {
        try await withRecalibrationEpochsRestored {
            let days = 30
            let harness = try await makeHarness(days: days, strapDays: 5..<days)
            let keptDays = [1, 2].map(dayKey)
            let rows = keptDays.map { day in
                DailyMetric(day: day, totalSleepMin: 440, efficiency: 0.91, deepMin: 85, remMin: 95,
                            lightMin: 260, disturbances: 3, restingHr: 51, avgHrv: 70,
                            recovery: 64, strain: 11.5, exerciseCount: 1)
            }
            _ = try await harness.store.upsertDailyMetrics(rows, deviceId: harness.computedId)
            let keys = [IntelligenceEngine.computedRowSourceMetricKey, IntelligenceEngine.strapWornSecondsMetricKey,
                        IntelligenceEngine.calorieFillEndMetricKey, IntelligenceEngine.nightlySkinMetricKey]
                + IntelligenceEngine.chargeBreakdownKeys
            let points = keptDays.flatMap { day in
                keys.enumerated().map { MetricPoint(day: day, key: $0.element, value: Double($0.offset) + 0.5) }
            }
            _ = try await harness.store.upsertMetricSeries(points, deviceId: harness.computedId)
            let workoutStart = firstDayStart + 2 * 86_400 + 17 * 3_600
            let workout = WorkoutRow(startTs: workoutStart, endTs: workoutStart + 3_600, sport: "running",
                                     source: harness.computedId, durationS: 3_600, energyKcal: 520, avgHr: 138,
                                     maxHr: 161, strain: 10.2, distanceM: nil, zonesJSON: nil, notes: nil,
                                     strainVersion: 2)
            _ = try await harness.store.upsertWorkouts([workout], deviceId: harness.computedId)

            let migration = await pass(harness, maxDays: days, keepUnproducedHistory: true)
            XCTAssertTrue(migration)
            let after = try await stored(harness)
            XCTAssertNotNil(after[dayKey(10)], "the strap days are scored")
            for row in rows {
                XCTAssertEqual(after[row.day], row, "\(row.day) keeps its row")
            }
            for key in keys {
                let kept = try await harness.store.metricSeries(
                    deviceId: harness.computedId, key: key, from: keptDays[0], to: keptDays[1])
                XCTAssertEqual(kept, points.filter { $0.key == key }, key)
            }
            let workouts = try await harness.store.workouts(
                deviceId: harness.computedId, from: workoutStart, to: workoutStart, limit: 10)
            XCTAssertEqual(workouts, [workout])

            let ordinary = await pass(harness, maxDays: days)
            XCTAssertTrue(ordinary)
            let afterOrdinary = try await stored(harness)
            XCTAssertNil(afterOrdinary[keptDays[0]], "an ordinary pass keeps the full replacement")
        }
    }

    /// Finding 6: after Recalibrate, the wearable fold has no Charge for the first nights after the epoch and
    /// produces no row for them. The migration's rescore keeps those days' stored rows; an ordinary pass over the
    /// same window still replaces them.
    func testAMigrationChunkKeepsFoldDaysAfterARecalibration() async throws {
        try await withRecalibrationEpochsRestored {
            let days = 30
            let harness = try await makeHarness(days: days, strapDays: 24..<days)
            let ouraRows = (0..<24).map { k in
                DailyMetric(day: dayKey(k), totalSleepMin: 450, efficiency: 0.9, deepMin: 80, remMin: 100,
                            lightMin: 270, disturbances: nil, restingHr: 50 + k % 2, avgHrv: 130 + Double(k % 3),
                            recovery: nil, strain: nil, exerciseCount: nil)
            }
            _ = try await harness.store.upsertDailyMetrics(ouraRows, deviceId: "oura-import")
            let first = await pass(harness, maxDays: days)
            XCTAssertTrue(first)
            let before = try await stored(harness)
            let epochIndex = 10
            let afterEpoch = (epochIndex + 1)..<(epochIndex + 8)
            for k in afterEpoch {
                XCTAssertNotNil(before[dayKey(k)]?.recovery, "fold day \(k) has a Charge before the recalibration")
            }
            Baselines.recalibrateRecoveryBaselines(
                now: TimeInterval(firstDayStart + epochIndex * 86_400 + 14 * 3_600), defaults: .standard)

            let migration = await pass(harness, maxDays: days, keepUnproducedHistory: true)
            XCTAssertTrue(migration)
            let after = try await stored(harness)
            for k in 0..<days where before[dayKey(k)] != nil {
                XCTAssertNotNil(after[dayKey(k)], "day \(k) keeps a row")
            }

            // The same window without the safety net shows which days the fold could not produce.
            let ordinary = await pass(harness, maxDays: days)
            XCTAssertTrue(ordinary)
            let afterOrdinary = try await stored(harness)
            let unproduced = (0..<days).filter { before[dayKey($0)] != nil && afterOrdinary[dayKey($0)] == nil }
            XCTAssertFalse(unproduced.isEmpty, "the fold has no row for the nights after the epoch")
            XCTAssertTrue(unproduced.allSatisfy { afterEpoch.contains($0) }, "\(unproduced)")
            for k in unproduced {
                XCTAssertEqual(after[dayKey(k)], before[dayKey(k)], "fold day \(k) kept its stored row")
            }
        }
    }

    // MARK: - Stored Charge breakdown (review round 3 findings 8 and 15, round 4 finding 3)

    /// Each fold stores the breakdown of the Charge it wrote: the drivers it built against exactly that Charge.
    /// Strap days with Oura-era history, the wearable fold's Oura days and an Apple-only user's days all read
    /// back a breakdown whose score is the stored Charge, with the HRV the fold scored. The drivers are each
    /// a marginal against a neutral term (the ChargeDrivers contract), so they don't add up arithmetically;
    /// the score they were built against is the stored one.
    func testStoredChargeBreakdownIsTheOneEachFoldScoredWith() async throws {
        try await withRecalibrationEpochsRestored {
            let days = 36
            let harness = try await makeHarness(days: days, strapDays: 30..<days)
            let ouraRows = (0..<30).map { k in
                DailyMetric(day: dayKey(k), totalSleepMin: 450, efficiency: 0.9, deepMin: 80, remMin: 100,
                            lightMin: 270, disturbances: nil, restingHr: 50, avgHrv: 130 + Double(k % 3),
                            recovery: nil, strain: nil, exerciseCount: nil)
            }
            _ = try await harness.store.upsertDailyMetrics(ouraRows, deviceId: "oura-import")
            let completed = await pass(harness, maxDays: days)
            XCTAssertTrue(completed)
            let after = try await stored(harness)
            var foldDays = 0
            var strapDays = 0
            for k in 0..<days {
                guard let row = after[dayKey(k)], let recovery = row.recovery else { continue }
                let loaded = await harness.engine.storedChargeBreakdown(day: dayKey(k))
                let breakdown = try XCTUnwrap(loaded, "day \(k) has a breakdown")
                XCTAssertEqual(breakdown.score, recovery, "day \(k): the breakdown explains the stored Charge")
                XCTAssertEqual(breakdown.drivers.first { $0.term == .hrv }?.value, row.avgHrv, "day \(k)")
                if k < 30 { foldDays += 1 } else { strapDays += 1 }
            }
            XCTAssertGreaterThan(foldDays, 15, "the fold scores the Oura days")
            XCTAssertGreaterThan(strapDays, 0, "the strap scores Charge after four nights")
            let calibrating = await harness.engine.storedChargeBreakdown(day: dayKey(30))
            XCTAssertNil(calibrating, "a calibrating strap night has no breakdown")

            // Apple-only: a one-day pass stores the breakdown of every Apple Watch Charge, the older days too.
            let store = try await WhoopStore.inMemory()
            let repository = Repository(deviceId: Repository.whoopSource)
            repository.setStoreForTesting(store)
            let engine = IntelligenceEngine(repo: repository, profile: ProfileStore(),
                                            deviceId: Repository.whoopSource)
            let appleRows = (0..<20).map { k in
                DailyMetric(day: dayKey(k), totalSleepMin: 420, efficiency: 0.9, deepMin: 80, remMin: 90,
                            lightMin: 250, disturbances: nil, restingHr: 55 + k % 3, avgHrv: 48 + Double(k % 5),
                            recovery: nil, strain: nil, exerciseCount: nil)
            }
            _ = try await store.upsertDailyMetrics(appleRows, deviceId: Repository.appleHealthSource)
            let reference = Date(timeIntervalSince1970: TimeInterval(firstDayStart + 19 * 86_400 + 12 * 3_600))
            let appleCompleted = await engine.analyzeRecent(
                maxDays: 1, startOffset: 0, force: true, refreshRepository: false,
                analysisReference: reference, analysisCalendar: utcCalendar)
            XCTAssertTrue(appleCompleted)
            var appleDays = 0
            for row in try await store.dailyMetrics(
                deviceId: Repository.appleHealthSource, from: "0000-01-01", to: "9999-12-31") {
                guard let recovery = row.recovery else { continue }
                let loaded = await engine.storedChargeBreakdown(day: row.day)
                let breakdown = try XCTUnwrap(loaded, "\(row.day) has a breakdown")
                XCTAssertEqual(breakdown.score, recovery, row.day)
                XCTAssertEqual(breakdown.drivers.first { $0.term == .hrv }?.value, row.avgHrv, row.day)
                appleDays += 1
            }
            XCTAssertGreaterThanOrEqual(appleDays, 10)
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

    /// Review round 4 (4): computed rows the wearable fold wrote stay out of the strap baseline after the import
    /// is re-imported with different values. The fold marks the rows it writes; a row from before the marker
    /// is a fold copy when no strap recorded heart rate that night, and that classification is persisted.
    /// Matching a row to its import by exact vitals let every fold copy into the strap baseline once a
    /// re-import changed the import's values.
    func testFoldRowsStayOutOfTheStrapBaselineAfterAReimportChangesTheirValues() async throws {
        try await withRecalibrationEpochsRestored {
            let days = 36
            let harness = try await makeHarness(days: days, strapDays: 30..<days)
            let ouraDays = (0..<30).map { dayKey($0) }
            func ouraRows(hrvShift: Double) -> [DailyMetric] {
                (0..<30).map { k in
                    DailyMetric(day: ouraDays[k], totalSleepMin: 450, efficiency: 0.9, deepMin: 80, remMin: 100,
                                lightMin: 270, disturbances: nil, restingHr: 50,
                                avgHrv: 130 + Double(k % 3) + hrvShift,
                                recovery: nil, strain: nil, exerciseCount: nil)
                }
            }
            _ = try await harness.store.upsertDailyMetrics(ouraRows(hrvShift: 0), deviceId: "oura-import")
            // Days 0-15: copies an earlier build's fold wrote under the computed id, with no marker.
            _ = try await harness.store.upsertDailyMetrics(
                ouraRows(hrvShift: 0).prefix(16).map { $0.with(recovery: 60, skinTempDevC: nil) },
                deviceId: harness.computedId)
            // Days 16-35: the fold writes the Oura days and the strap scores days 30-35.
            let first = await pass(harness, maxDays: 20)
            XCTAssertTrue(first)

            _ = try await harness.store.upsertDailyMetrics(ouraRows(hrvShift: 7), deviceId: "oura-import")
            let second = await pass(harness, maxDays: 6)
            XCTAssertTrue(second)
            let after = try await stored(harness)
            XCTAssertNotNil(after[dayKey(30)]?.avgHrv, "the first strap night is scored")
            XCTAssertNil(after[dayKey(30)]?.recovery, "with no strap history its Charge is still calibrating")

            let markers = try await harness.store.metricSeries(
                deviceId: harness.computedId, key: IntelligenceEngine.computedRowSourceMetricKey,
                from: "0000-01-01", to: "9999-12-31")
            let markerByDay = Dictionary(markers.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
            for k in 0..<16 {
                XCTAssertEqual(markerByDay[dayKey(k)], IntelligenceEngine.wearableFoldRowSource, "legacy day \(k)")
            }
            for k in 16..<30 where after[dayKey(k)] != nil {
                XCTAssertEqual(markerByDay[dayKey(k)], IntelligenceEngine.wearableFoldRowSource, "fold day \(k)")
            }
            XCTAssertNotNil(after[dayKey(29)], "the fold wrote the Oura days in its window")
            for k in 30..<days {
                XCTAssertEqual(markerByDay[dayKey(k)], IntelligenceEngine.strapRowSource, "strap day \(k)")
            }
        }
    }

    /// Review round 5 (5): a legacy unmarked row is classified by the raw loop's own test: the day's resolved
    /// owner has the loop's 200 heart-rate rows over the loop's window. Heart rate from another live device,
    /// which the loop did not read for that day, no longer makes a fold copy a strap night.
    func testLegacyRowProvenanceUsesTheRawLoopsOwnerAndGate() async throws {
        try await withRecalibrationEpochsRestored {
            try await checkLegacyProvenance(exactSourceDeviceId: nil)
        }
    }

    /// Review round 6 (1): an exact pass for another device's work classifies the legacy rows the way a
    /// production pass does. The classification covers the whole history and is stored for good, so the exact
    /// pass's source device is not the owner of every day.
    func testAnExactPassClassifiesLegacyRowsLikeAProductionPass() async throws {
        try await withRecalibrationEpochsRestored {
            try await checkLegacyProvenance(exactSourceDeviceId: "chest-strap")
        }
    }

    /// The legacy provenance fixture: unmarked fold copies on days 10, 14 and 18, with 150 owner rows, 250 owner
    /// rows, and 150 owner rows plus 300 a second live device recorded the evening before (inside the loop's
    /// read window, outside the day, so the day stays the owner's under the round 6 resolver). One pass (an
    /// exact pass when `exactSourceDeviceId` is set) classifies them.
    private func checkLegacyProvenance(exactSourceDeviceId: String?) async throws {
        let days = 21
        let harness = try await makeHarness(days: days, strapDays: 20..<days)
        let registry = DeviceRegistryStore(dbQueue: harness.store.registryWriter)
        try registry.add(PairedDevice(
            id: Repository.whoopSource, brand: "WHOOP", model: "WHOOP 5.0", sourceKind: .liveBLE,
            capabilities: [.hr, .hrv, .skinTemp, .sleep], status: .active, addedAt: 0, lastSeenAt: 0))
        try registry.add(PairedDevice(
            id: "chest-strap", brand: "Polar", model: "H10", sourceKind: .liveBLE,
            capabilities: [.hr], status: .active, addedAt: 0, lastSeenAt: 0))
        try registry.setActive(Repository.whoopSource)
        // Each case is four days from the next, outside the others' read windows. The second device's rows run
        // from 18:30 to 23:30 the evening before day 18.
        let heartRate: [(day: Int, rows: Int, deviceId: String, offset: Int)] = [
            (10, 150, Repository.whoopSource, 3_600), (14, 250, Repository.whoopSource, 3_600),
            (18, 150, Repository.whoopSource, 3_600), (18, 300, "chest-strap", -19_800),
        ]
        for night in heartRate {
            var streams = Streams()
            let start = firstDayStart + night.day * 86_400 + night.offset
            streams.hr = (0..<night.rows).map { HRSample(ts: start + $0 * 60, bpm: 55) }
            _ = try await harness.store.insert(streams, deviceId: night.deviceId)
        }
        let ouraRows = [10, 14, 18].map { k in
            DailyMetric(day: dayKey(k), totalSleepMin: 450, efficiency: 0.9, deepMin: 80, remMin: 100,
                        lightMin: 270, disturbances: nil, restingHr: 50, avgHrv: 130,
                        recovery: nil, strain: nil, exerciseCount: nil)
        }
        _ = try await harness.store.upsertDailyMetrics(ouraRows, deviceId: "oura-import")
        // Copies an earlier build wrote under the computed id, with no marker.
        _ = try await harness.store.upsertDailyMetrics(
            ouraRows.map { $0.with(recovery: 60, skinTempDevC: nil) }, deviceId: harness.computedId)

        let sourceContext = try exactSourceDeviceId.map {
            try exactSource($0, day: dayKey(days - 1), createdAt: harness.reference)
        }
        let completed = await pass(harness, maxDays: 1, sourceContext: sourceContext)
        XCTAssertTrue(completed)
        let markers = try await harness.store.metricSeries(
            deviceId: harness.computedId, key: IntelligenceEngine.computedRowSourceMetricKey,
            from: dayKey(0), to: dayKey(19))
        let markerByDay = Dictionary(markers.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(markerByDay[dayKey(10)], IntelligenceEngine.wearableFoldRowSource,
                       "150 rows: the loop never scored the day")
        XCTAssertEqual(markerByDay[dayKey(14)], IntelligenceEngine.strapRowSource, "the loop's 200 rows")
        XCTAssertEqual(markerByDay[dayKey(18)], IntelligenceEngine.wearableFoldRowSource,
                       "another device's heart rate is not the owner's")
    }

    // MARK: - Yesterday's calorie fill (review round 4, finding 2)

    /// A production pass scores today only. The first one after midnight also finishes yesterday's calorie
    /// total when the last pass of yesterday filled it only up to that pass's moment, and stores it as filled
    /// through midnight, so later passes leave it alone. Yesterday's total used to stay at 15:30's value.
    func testYesterdaysCalorieTotalIsFinishedOnTheFirstPassOfTheNextDay() async throws {
        try await withRecalibrationEpochsRestored {
            let harness = try await makeHarness(days: 4)
            let yesterday = harness.dayKeys[2]
            let yesterdayStart = firstDayStart + 2 * 86_400
            let afternoon = Date(timeIntervalSince1970: TimeInterval(yesterdayStart + 15 * 3_600 + 1_800))
            let partialPass = await pass(harness, maxDays: 1, at: afternoon)
            XCTAssertTrue(partialPass)
            let afterAfternoon = try await stored(harness)
            let partial = try XCTUnwrap(afterAfternoon[yesterday]?.activeKcalEst)

            let afterMidnight = Date(timeIntervalSince1970: TimeInterval(yesterdayStart + 86_400 + 600))
            let firstOfDay = await pass(harness, maxDays: 1, at: afterMidnight)
            XCTAssertTrue(firstOfDay)
            let afterFirstOfDay = try await stored(harness)
            let finished = try XCTUnwrap(afterFirstOfDay[yesterday]?.activeKcalEst)
            XCTAssertGreaterThan(finished, partial)
            let fillEnd = try await harness.store.metricSeries(
                deviceId: harness.computedId, key: IntelligenceEngine.calorieFillEndMetricKey,
                from: yesterday, to: yesterday)
            XCTAssertEqual(fillEnd.first?.value, Double(yesterdayStart + 86_400), "filled through midnight")

            let twoDays = await pass(harness, maxDays: 2, at: afterMidnight)
            XCTAssertTrue(twoDays)
            let afterTwoDays = try await stored(harness)
            XCTAssertEqual(finished, try XCTUnwrap(afterTwoDays[yesterday]?.activeKcalEst),
                           accuracy: 0.5, "the same total a two-day pass gives")
        }
    }

    /// Review round 5 (2): after a day with no pass, the next pass reaches back two days to finish the total of
    /// the last day it scored part of the way.
    func testACalorieTotalBeforeADayWithoutAPassIsFinishedOnTheNextPass() async throws {
        try await withRecalibrationEpochsRestored {
            let harness = try await makeHarness(days: 4)
            let day = harness.dayKeys[1]
            let dayStart = firstDayStart + 86_400
            let afternoon = Date(timeIntervalSince1970: TimeInterval(dayStart + 15 * 3_600 + 1_800))
            let partialPass = await pass(harness, maxDays: 1, at: afternoon)
            XCTAssertTrue(partialPass)
            let afterAfternoon = try await stored(harness)
            let partial = try XCTUnwrap(afterAfternoon[day]?.activeKcalEst)

            let twoMidnightsLater = Date(timeIntervalSince1970: TimeInterval(dayStart + 2 * 86_400 + 600))
            let nextPass = await pass(harness, maxDays: 1, at: twoMidnightsLater)
            XCTAssertTrue(nextPass)
            let afterNextPass = try await stored(harness)
            let finished = try XCTUnwrap(afterNextPass[day]?.activeKcalEst)
            XCTAssertGreaterThan(finished, partial)
            let fillEnd = try await harness.store.metricSeries(
                deviceId: harness.computedId, key: IntelligenceEngine.calorieFillEndMetricKey, from: day, to: day)
            XCTAssertEqual(fillEnd.first?.value, Double(dayStart + 86_400), "filled through midnight")

            let threeDays = await pass(harness, maxDays: 3, at: twoMidnightsLater)
            XCTAssertTrue(threeDays)
            let afterThreeDays = try await stored(harness)
            XCTAssertEqual(finished, try XCTUnwrap(afterThreeDays[day]?.activeKcalEst),
                           accuracy: 0.5, "the same total a three-day pass gives")
        }
    }

    /// Review round 6 (2): a newer day an exact pass finished doesn't hide an older unfinished one. The first
    /// production pass of the day checks every day in reach and widens to the oldest unfinished one.
    func testAnExactPassFinishingYesterdayDoesNotHideAnUnfinishedDayBefore() async throws {
        try await withRecalibrationEpochsRestored {
            let harness = try await makeHarness(days: 4)
            let twoDaysAgo = harness.dayKeys[1]
            let twoDaysAgoStart = firstDayStart + 86_400
            let afternoon = Date(timeIntervalSince1970: TimeInterval(twoDaysAgoStart + 15 * 3_600 + 1_800))
            let partialPass = await pass(harness, maxDays: 1, at: afternoon)
            XCTAssertTrue(partialPass)
            let afterAfternoon = try await stored(harness)
            let partial = try XCTUnwrap(afterAfternoon[twoDaysAgo]?.activeKcalEst)

            let yesterday = harness.dayKeys[2]
            let justAfterMidnight = Date(timeIntervalSince1970: TimeInterval(twoDaysAgoStart + 2 * 86_400 + 600))
            let exactYesterday = try exactSource(Repository.whoopSource, day: yesterday, createdAt: justAfterMidnight)
            let exact = await pass(harness, maxDays: 1, startOffset: 1, at: justAfterMidnight,
                                   sourceContext: exactYesterday)
            XCTAssertTrue(exact)
            let yesterdayFill = try await harness.store.metricSeries(
                deviceId: harness.computedId, key: IntelligenceEngine.calorieFillEndMetricKey,
                from: yesterday, to: yesterday)
            XCTAssertEqual(yesterdayFill.first?.value, Double(twoDaysAgoStart + 2 * 86_400),
                           "the exact pass finished yesterday")

            let productionPass = await pass(harness, maxDays: 1, at: justAfterMidnight.addingTimeInterval(600))
            XCTAssertTrue(productionPass)
            let afterProductionPass = try await stored(harness)
            let finished = try XCTUnwrap(afterProductionPass[twoDaysAgo]?.activeKcalEst)
            XCTAssertGreaterThan(finished, partial)
            let fillEnd = try await harness.store.metricSeries(
                deviceId: harness.computedId, key: IntelligenceEngine.calorieFillEndMetricKey,
                from: twoDaysAgo, to: twoDaysAgo)
            XCTAssertEqual(fillEnd.first?.value, Double(twoDaysAgoStart + 86_400), "filled through midnight")
        }
    }

    /// Review round 4 (5): each scored day stores how long the strap recorded valid heart rate, the coverage the
    /// shared calorie resolver weighs the strap total by. A fixture day with a next night has readings around the
    /// clock: its own night and day until 23:00, then the next night from 23:00.
    func testEachScoredDayStoresTheStrapWornTime() async throws {
        try await withRecalibrationEpochsRestored {
            let harness = try await makeHarness(days: 3)
            let completed = await pass(harness, maxDays: 3)
            XCTAssertTrue(completed)
            let worn = try await harness.store.metricSeries(
                deviceId: harness.computedId, key: IntelligenceEngine.strapWornSecondsMetricKey,
                from: harness.dayKeys[1], to: harness.dayKeys[1])
            XCTAssertEqual(worn.first?.value, 24 * 3_600)
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
