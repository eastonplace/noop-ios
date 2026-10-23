import XCTest
import Foundation
import WhoopStore
import WhoopProtocol
@testable import NOOP

/// #814 READ SPINE + UNION MODEL: after a remove+re-add the strap gets a FRESH registry id ("whoop-<uuid>"),
/// so the Collector writes today's LIVE raw under THAT id. The read side follows the registry's active id so
/// that live data surfaces (`adoptActiveDeviceId` moves the active-strap READ id), AND it reads the UNION of
/// the active strap with the canonical "my-whoop" so history imported/computed earlier under the canonical id
/// is NOT orphaned by the move. These tests pin the contract: the active-strap id follows the re-add, the
/// re-added strap's live data surfaces, and the canonical history STILL surfaces alongside it.
final class ReadSpineActiveDeviceTests: XCTestCase {

    private let canonicalId = "my-whoop"
    private let newId = "whoop-ABC123"   // the id a re-added strap gets (AddDeviceWizard: "whoop-<uuid>")

    private func dailyMetric(day: String, recovery: Double) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 100, lightMin: 230,
                    disturbances: 2, restingHr: 52, avgHrv: 70, recovery: recovery, strain: 8, exerciseCount: 0,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: 14, steps: nil, activeKcalEst: nil)
    }

    private func rolloverFixtures(calendar: Calendar) throws -> [(firstSample: Date, expectedDay: Date)] {
        var fixtures: [(firstSample: Date, expectedDay: Date)] = []
        // The 300- and 600-sample windows finish before, straddle, or start after the 04:00 rollover.
        for (hour, minute, expectedDay) in [(3, 50, 21), (3, 58, 22), (4, 5, 22)] {
            let first = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 22,
                                                                        hour: hour, minute: minute)))
            let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: expectedDay)))
            fixtures.append((first, expected))
        }
        return fixtures
    }

    /// Independent calendar expectation for the last actual seeded sample, without Repository's day helpers.
    private func expectedLatestDay(_ samples: [HRSample], calendar: Calendar) throws -> Date {
        let last = Date(timeIntervalSince1970: TimeInterval(try XCTUnwrap(samples.last).ts))
        let midnight = calendar.startOfDay(for: last)
        let offset = calendar.component(.hour, from: last) < 4 ? -1 : 0
        return try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: midnight))
    }

    /// The core regression: re-point the active-strap read id to the re-added strap, then the read deviceId
    /// equals the WRITE (Collector) id, and a latest-data lookup finds the LIVE data written under the NEW id.
    /// The lookup now unions, so the most-recent day across BOTH ids wins (the fresh today, not the stale day).
    @MainActor
    func testReadFollowsActiveIdAfterReAdd() async throws {
        let calendar = Calendar.current
        for fixture in try rolloverFixtures(calendar: calendar) {
            let store = try await WhoopStore.inMemory()
            try await store.upsertDevice(id: canonicalId, mac: nil, name: "WHOOP")
            try await store.upsertDevice(id: newId, mac: nil, name: "WHOOP")

            // Stale canonical data sits months in the past; the fresh window belongs to the re-added strap.
            let staleStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -120, to: fixture.firstSample))
            let staleBase = Int(staleStart.timeIntervalSince1970)
            let freshBase = Int(fixture.firstSample.timeIntervalSince1970)
            let staleSamples = (0..<300).map { HRSample(ts: staleBase + $0, bpm: 50) }
            let freshSamples = (0..<300).map { HRSample(ts: freshBase + $0, bpm: 70) }
            try await store.insert(Streams(hr: staleSamples), deviceId: canonicalId)
            try await store.insert(Streams(hr: freshSamples), deviceId: newId)

            let repo = Repository(deviceId: canonicalId)
            repo.setStoreForTesting(store)

            // Seeded with the canonical id, the latest data is the stale canonical day.
            let staleExpected = try expectedLatestDay(staleSamples, calendar: calendar)
            let explicitStaleDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -120, to: fixture.expectedDay))
            XCTAssertEqual(staleExpected, explicitStaleDay)
            let staleLatest = await repo.latestDataDayStart()
            XCTAssertEqual(staleLatest, staleExpected,
                           "before re-point the read model sees only the canonical namespace")

            // Re-add → re-point. The active-strap read id now equals the write id.
            let moved = repo.adoptActiveDeviceId(newId)
            XCTAssertTrue(moved, "adopting a different active id must move the active-strap read id")
            XCTAssertEqual(repo.deviceId, newId, "active-strap read id must equal the write (Collector) id after re-add")

            // The union picks the last fresh sample across both ids, even when its window straddles 04:00.
            let freshExpected = try expectedLatestDay(freshSamples, calendar: calendar)
            XCTAssertEqual(freshExpected, fixture.expectedDay)
            let freshLatest = await repo.latestDataDayStart()
            XCTAssertEqual(freshLatest, freshExpected,
                           "after re-point the auto-land reads today's live data under the new id, not the stale day")
            XCTAssertNotEqual(freshLatest, staleLatest, "Today must not snap back to the stale namespace's day")
        }
    }

    /// UNION MODEL update: the HR facades now read the UNION of the active strap + canonical, so a re-added
    /// strap's LIVE samples AND the canonical history's samples both surface (history is NOT orphaned). Within
    /// a shared window both appear; the dedup keeps the active strap's sample on any overlapping ts.
    @MainActor
    func testHrFacadesUnionActiveAndCanonicalAfterReAdd() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonicalId, mac: nil, name: "WHOOP")
        try await store.upsertDevice(id: newId, mac: nil, name: "WHOOP")

        // Distinct, NON-overlapping time windows: canonical history earlier, the re-added strap's live later.
        let base = 1_780_000_000
        try await store.insert(Streams(hr: (0..<300).map { HRSample(ts: base + $0, bpm: 50) }), deviceId: canonicalId)
        try await store.insert(Streams(hr: (0..<300).map { HRSample(ts: base + 10_000 + $0, bpm: 88) }), deviceId: newId)

        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)
        repo.adoptActiveDeviceId(newId)

        let samples = await repo.hrSamples(from: base, to: base + 11_000)
        XCTAssertEqual(samples.count, 600, "the union must return BOTH the canonical history and the live samples")
        XCTAssertTrue(samples.contains { $0.bpm == 88 }, "the re-added strap's live samples must surface")
        XCTAssertTrue(samples.contains { $0.bpm == 50 }, "the canonical history must NOT be orphaned by the re-add")
    }

    /// Empty ids cannot activate a live source. Once the canonical source is explicitly active, adopting
    /// its unchanged id is a no-op and the single-device read union stays on "my-whoop".
    @MainActor
    func testAdoptIsNoOpForEmptyOrUnchangedId() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)
        // A seeded read namespace is distinct from an admitted live owner. The first explicit adoption
        // establishes that owner even when its id equals the canonical read namespace.
        XCTAssertEqual(repo.liveSourceState, .none)
        XCTAssertFalse(repo.adoptActiveDeviceId(""), "empty id must not activate a live source")
        XCTAssertFalse(repo.adoptActiveDeviceId("   "), "whitespace must not activate a live source")
        XCTAssertEqual(repo.liveSourceState, .none)
        XCTAssertTrue(repo.adoptActiveDeviceId(canonicalId), "first adoption must establish live ownership")
        XCTAssertEqual(repo.liveSourceState.id, canonicalId)
        let activatedState = repo.liveSourceState
        XCTAssertFalse(repo.adoptActiveDeviceId(canonicalId), "same id must not move")
        XCTAssertFalse(repo.adoptActiveDeviceId(""), "empty id must not move")
        XCTAssertFalse(repo.adoptActiveDeviceId("   "), "whitespace-only id must not move")
        XCTAssertEqual(repo.deviceId, canonicalId)
        XCTAssertEqual(repo.liveSourceState, activatedState, "no-op adoption must preserve the source fence")
    }

    /// The computed ("-noop") sibling: the union reads BOTH the active strap's computed sibling AND the
    /// canonical computed sibling, so a day scored under the canonical id before a re-add still surfaces, and
    /// a day scored under the re-added strap's sibling also surfaces.
    @MainActor
    func testComputedRowsUnionAfterReAdd() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonicalId, mac: nil, name: "WHOOP")
        try await store.upsertDevice(id: newId, mac: nil, name: "WHOOP")

        // One computed day banked under the CANONICAL sibling (older), one under the re-added strap's sibling.
        let todayKey = Repository.localDayKey(Date())
        let yKey = Repository.localDayKey(Date().addingTimeInterval(-3 * 86_400))
        _ = try await store.upsertDailyMetrics([dailyMetric(day: yKey, recovery: 60)], deviceId: canonicalId + "-noop")
        _ = try await store.upsertDailyMetrics([dailyMetric(day: todayKey, recovery: 66)], deviceId: newId + "-noop")

        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)
        repo.adoptActiveDeviceId(newId)
        await repo.refresh()

        XCTAssertNotNil(repo.days.first(where: { $0.day == todayKey }),
                        "the re-added strap's computed day must surface")
        XCTAssertNotNil(repo.days.first(where: { $0.day == yKey }),
                        "the canonical computed history must NOT be orphaned by the re-add")
    }

    /// THE union-model regression (#814 follow-up): import history under the CANONICAL "my-whoop", THEN
    /// re-add a strap so the active id becomes "whoop-uuid" and write LIVE HR under it. Assert (i) the
    /// imported canonical days STILL surface in refresh(), (ii) the new live HR under the re-added id also
    /// surfaces, and (iii) Today does NOT snap to a stale day (the auto-land anchor is the fresh live day).
    @MainActor
    func testImportedHistoryUnderCanonicalSurvivesReAddWithLiveData() async throws {
        let calendar = Calendar.current
        for fixture in try rolloverFixtures(calendar: calendar) {
            let store = try await WhoopStore.inMemory()
            try await store.upsertDevice(id: canonicalId, mac: nil, name: "WHOOP")

            // (1) Import history lands under the CANONICAL id (this is the STABLE import target).
            // Three earlier calendar days are anchored to the same fixed window as the live samples.
            let importedDays = try (3...5).map { offset -> DailyMetric in
                let date = try XCTUnwrap(calendar.date(byAdding: .day, value: -offset, to: fixture.firstSample))
                let day = Repository.localDayKey(date, calendar: calendar)
                return dailyMetric(day: day, recovery: 55 + Double(offset))
            }
            _ = try await store.upsertDailyMetrics(importedDays, deviceId: canonicalId)

            let repo = Repository(deviceId: canonicalId)
            repo.setStoreForTesting(store)
            // Keep the rolling refresh window on the fixture, with every live sample behind its clock.
            repo.setTodayHealthSnapshotTestNow(fixture.firstSample.addingTimeInterval(90 * 60))
            await repo.refresh()
            XCTAssertEqual(repo.days.count, importedDays.count, "the canonical import is the baseline before any re-add")

            // (2) Re-add a strap: the Collector writes fresh LIVE raw under its new id.
            // The import target STAYS canonical (we do NOT move it).
            try await store.upsertDevice(id: newId, mac: nil, name: "WHOOP")
            let liveBase = Int(fixture.firstSample.timeIntervalSince1970)
            let seededLive = (0..<600).map { HRSample(ts: liveBase + $0, bpm: 72) }
            try await store.insert(Streams(hr: seededLive), deviceId: newId)
            repo.adoptActiveDeviceId(newId)
            await repo.refresh()

            // (i) the imported canonical days STILL surface.
            for d in importedDays {
                XCTAssertNotNil(repo.days.first(where: { $0.day == d.day }),
                                "imported canonical day \(d.day) must still surface after the re-add")
            }

            // (ii) the re-added strap's live HR surfaces under the new id.
            let liveSamples = await repo.hrSamples(from: liveBase, to: liveBase + 600)
            XCTAssertTrue(liveSamples.contains { $0.bpm == 72 }, "the re-added strap's live HR must surface")

            // (iii) Today anchors on the last actual live sample's day, not the stale imported days.
            let expected = try expectedLatestDay(seededLive, calendar: calendar)
            XCTAssertEqual(expected, fixture.expectedDay)
            let landDay = await repo.latestDataDayStart()
            XCTAssertEqual(landDay, expected,
                           "Today must anchor on the fresh live day, not a stale imported day")
        }
    }

    // MARK: - #316 / @63 step activity-class union (the Steps tile icon)

    /// Pure union pick: `latestActivityClass` returns the non-nil class on the greatest-ts sample across the
    /// per-id lists, resolves a ts tie in favour of the FIRST list (active strap), and passes an empty union
    /// through as nil. A nil-class sample never masks an earlier real class.
    func testLatestActivityClassUnionPickAndTieBreak() {
        // Single list reduces to "last non-nil class in that list": ts 30 is nil, so ts 20's walk (1) wins.
        let single = [[
            StepSample(ts: 10, counter: 1, activityClass: 0),
            StepSample(ts: 20, counter: 2, activityClass: 1),
            StepSample(ts: 30, counter: 3, activityClass: nil),
        ]]
        XCTAssertEqual(Repository.latestActivityClass(single), 1,
                       "the latest NON-NIL class wins; a trailing nil-class sample does not blank the icon")

        // Two lists, greatest ts across the union wins: active strap's ts=100 run (2) beats canonical ts=90.
        let active = [StepSample(ts: 100, counter: 5, activityClass: 2)]
        let canonical = [StepSample(ts: 90, counter: 4, activityClass: 0)]
        XCTAssertEqual(Repository.latestActivityClass([active, canonical]), 2,
                       "the greatest-ts classed sample across the union wins")

        // Exact ts tie: the FIRST list (active strap) wins, matching the union's active-wins rule.
        let activeTie = [StepSample(ts: 200, counter: 6, activityClass: 1)]
        let canonicalTie = [StepSample(ts: 200, counter: 7, activityClass: 0)]
        XCTAssertEqual(Repository.latestActivityClass([activeTie, canonicalTie]), 1,
                       "on a ts tie the active strap's class wins")

        // An empty union passes through as nil (no icon), never a crash.
        XCTAssertNil(Repository.latestActivityClass([[], []]), "an empty union hides the icon")
    }

    /// End-to-end #904/#908 family: a re-added strap banks its live STEP samples (carrying @63 activityClass)
    /// under its OWN fresh id, exactly like HR. A read pinned to the canonical "my-whoop" finds NO class (the
    /// tile icon vanishes); `stepActivityClassLatest` reads the union and surfaces the re-added strap's class.
    @MainActor
    func testStepActivityClassUnionSurfacesReAddedStrapClass() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonicalId, mac: nil, name: "WHOOP")
        try await store.upsertDevice(id: newId, mac: nil, name: "WHOOP")

        // Today's live step samples land under the re-added strap's fresh id; the latest carries class 2 (run).
        // The canonical "my-whoop" namespace has NO steps today (imports never drift to the active id).
        let base = 1_780_000_000
        let liveSteps = (0..<20).map { StepSample(ts: base + $0, counter: $0, activityClass: $0 == 19 ? 2 : 1) }
        try await store.insert(Streams(steps: liveSteps), deviceId: newId)

        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)

        // Before the re-add the read model is the canonical namespace only, which has no step class today.
        let pinned = await repo.stepActivityClassLatest(from: base, to: base + 100)
        XCTAssertNil(pinned, "with only the canonical id active, a re-added strap's step class is not yet reachable")

        // Re-add → the active-strap read id follows, and the union surfaces the re-added strap's latest class.
        repo.adoptActiveDeviceId(newId)
        let surfaced = await repo.stepActivityClassLatest(from: base, to: base + 100)
        XCTAssertEqual(surfaced, 2,
                       "the union must surface the re-added strap's live activity class, not an empty pinned read")
    }
}
