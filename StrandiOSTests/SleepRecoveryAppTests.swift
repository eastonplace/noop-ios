import XCTest
import WhoopProtocol
import WhoopStore
@testable import NOOP

@MainActor
final class SleepRecoveryAppTests: XCTestCase {
    private func dailyMetric(day: String, restingHr: Int = 54, avgHrv: Double = 56) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: 420,
            efficiency: 0.88,
            deepMin: 70,
            remMin: 90,
            lightMin: 260,
            disturbances: 3,
            restingHr: restingHr,
            avgHrv: avgHrv,
            recovery: 70,
            strain: 12,
            exerciseCount: 1,
            steps: 5_000,
            strainVersion: 2)
    }

    func testOnlySleepEmptyStateRoutesToRecoveryCard() {
        XCTAssertTrue(MissedSleepRecoveryRouting.shouldReplaceEmptyState(
            "No nights here yet. Import your WHOOP export to see sleep."))
        XCTAssertFalse(MissedSleepRecoveryRouting.shouldReplaceEmptyState(
            "No workouts here yet."))
        XCTAssertFalse(MissedSleepRecoveryRouting.shouldReplaceEmptyState(
            "No nights stored for the selected range."))
    }

    func testDefaultMissedSleepSeedIsEightHoursAndNeverFutureDated() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 26, hour: 12, minute: 30)))

        let seed = MissedSleepWindowSeed.lastNight(now: now, calendar: calendar)

        XCTAssertEqual(seed.end.timeIntervalSince(seed.start), 8 * 3_600, accuracy: 1)
        XCTAssertLessThanOrEqual(seed.end, now)
        XCTAssertEqual(calendar.component(.hour, from: seed.end), 9)
    }

    func testEarlyMorningSeedEndsAtNowInsteadOfFutureNineAM() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 26, hour: 6, minute: 15)))

        let seed = MissedSleepWindowSeed.lastNight(now: now, calendar: calendar)

        XCTAssertEqual(seed.end.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(seed.end.timeIntervalSince(seed.start), 8 * 3_600, accuracy: 1)
    }

    func testOnlyCompleteAndPartialOutcomesDismissTheEditor() {
        let complete = MissedSleepRecoverySaveResult(
            status: .complete, title: "", message: "", confidence: 0.9,
            sessionStart: 1, sessionEnd: 2)
        let partial = MissedSleepRecoverySaveResult(
            status: .partial, title: "", message: "", confidence: 0.5,
            sessionStart: 1, sessionEnd: 2)
        let insufficient = MissedSleepRecoverySaveResult(
            status: .insufficientData, title: "", message: "", confidence: 0,
            sessionStart: nil, sessionEnd: nil)
        let conflict = MissedSleepRecoverySaveResult(
            status: .overlapConflict, title: "", message: "", confidence: 0.8,
            sessionStart: nil, sessionEnd: nil)

        XCTAssertTrue(complete.savedSession)
        XCTAssertTrue(partial.savedSession)
        XCTAssertFalse(insufficient.savedSession)
        XCTAssertFalse(conflict.savedSession)
    }

    func testEditingRecoveredSessionReprocessesAndRekeysProtectedOverride() async throws {
        try await assertEditingRecoveredSession(activeSourceId: "my-whoop")
    }

    func testEditingCanonicalRecoveredSessionAfterRepairRekeysCanonicalOverride() async throws {
        try await assertEditingRecoveredSession(activeSourceId: "whoop-readded")
    }

    private func assertEditingRecoveredSession(activeSourceId: String) async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        repo.adoptActiveDeviceId(activeSourceId)
        let computedId = "my-whoop-noop"
        let now = Int(Date().timeIntervalSince1970)
        let oldStart = now - 5 * 3_600
        let oldEnd = oldStart + 3_600
        let newStart = oldStart + 60
        let newEnd = oldEnd - 60
        let wakeDate = Date(timeIntervalSince1970: TimeInterval(newEnd))
        let wakeDay = Repository.localDayKey(wakeDate)

        // Seed enough real history for the reprocessed recovery to have a usable
        // Charge context and a non-neutral duration-consistency value.
        var history: [DailyMetric] = []
        for daysBeforeWake in 1...7 {
            let historyTimestamp = newEnd - daysBeforeWake * 86_400
            let historyDate = Date(timeIntervalSince1970: TimeInterval(historyTimestamp))
            let historyDay = Repository.localDayKey(historyDate)
            history.append(dailyMetric(
                day: historyDay,
                restingHr: 53 + daysBeforeWake % 3,
                avgHrv: 55 + Double(daysBeforeWake)))
        }
        try await store.upsertDailyMetrics(history, deviceId: computedId)

        let oldStages = "[{\"start\":\(oldStart),\"end\":\(oldEnd),\"stage\":\"light\"}]"
        let original = CachedSleepSession(
            startTs: oldStart,
            endTs: oldEnd,
            efficiency: 0.88,
            restingHr: 52,
            avgHrv: 61,
            stagesJSON: oldStages,
            userEdited: true,
            startTsAdjusted: nil)
        let originalOverride = SleepRecoveryDailyOverride(
            day: wakeDay,
            sessionStartTs: oldStart,
            totalSleepMin: 420,
            efficiency: 0.88,
            deepMin: 70,
            remMin: 90,
            lightMin: 260,
            disturbances: 3,
            restingHr: 52,
            avgHrv: 61,
            recovery: 70,
            restScore: 80,
            chargeWeightedSumWithoutSleep: 1,
            chargeWeightWithoutSleep: 2,
            chargeBaselineUsable: true,
            sleepNeedHours: 8,
            sleepConsistency: 0.8,
            updatedAt: now)
        let originalAudit = SleepRecoveryAuditRecord(
            id: "original-recovery",
            source: "manual_window",
            requestedStartTs: oldStart,
            requestedEndTs: oldEnd,
            outcome: "complete",
            confidence: 0.9,
            reason: "bounded_reanalysis",
            resultStartTs: oldStart,
            resultEndTs: oldEnd,
            stagesAvailable: true,
            restingHr: 52,
            avgHrv: 61,
            algorithmVersion: "sleep-window-recovery-v1",
            createdAt: now,
            updatedAt: now)
        _ = try await store.replaceWithManualSleepRecovery(
            original,
            deviceId: computedId,
            audit: originalAudit,
            dailyOverride: originalOverride,
            daily: dailyMetric(day: wakeDay))

        let seconds = Array(newStart...newEnd)
        try await store.insert(
            Streams(
                hr: seconds.map { HRSample(ts: $0, bpm: 50) },
                rr: seconds.map { RRInterval(ts: $0, rrMs: 900 + ($0.isMultiple(of: 2) ? 20 : 0)) },
                gravity: seconds.map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }),
            deviceId: activeSourceId)

        await repo.editSleepTimes(
            detectedStartTs: oldStart,
            oldEndTs: oldEnd,
            storedStagesJSON: oldStages,
            newStartTs: newStart,
            newEndTs: newEnd)

        let oldOverride = try await store.sleepRecoveryDailyOverride(
            deviceId: computedId,
            sessionStartTs: oldStart)
        let newOverride = try await store.sleepRecoveryDailyOverride(
            deviceId: computedId,
            sessionStartTs: newStart)
        XCTAssertNil(oldOverride)
        let rekeyed = try XCTUnwrap(newOverride)
        XCTAssertTrue(rekeyed.chargeBaselineUsable)
        XCTAssertNotNil(rekeyed.chargeWeightedSumWithoutSleep)
        XCTAssertNotNil(rekeyed.chargeWeightWithoutSleep)
        XCTAssertEqual(rekeyed.sleepNeedHours, 8)
        let consistency = try XCTUnwrap(rekeyed.sleepConsistency)
        XCTAssertEqual(consistency, 1, accuracy: 0.0001)
        let sessions = try await store.sleepSessions(
            deviceId: computedId,
            from: oldStart - 1,
            to: oldEnd + 1,
            limit: 10)
        XCTAssertEqual(sessions.map(\.startTs), [newStart])
    }
}

extension SleepRecoveryAppTests {
    func testRecoveryPreservesMultipleBeatsInOneSecondAndRefreshesSavedVitals() async throws {
        try await assertSavedVitalsRefresh(activeSourceId: "my-whoop")
    }

    func testCanonicalRecoveryRefreshesFromReaddedStrapWithoutLeakingOwnedRows() async throws {
        try await assertSavedVitalsRefresh(activeSourceId: "whoop-readded")
    }

    private func assertSavedVitalsRefresh(activeSourceId: String) async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let start = Int(Date().timeIntervalSince1970) - 7200
        let end = start + 3600
        let hr = (0..<3600).map { HRSample(ts: start + $0, bpm: 60) }
        _ = try await store.insert(Streams(hr: hr), deviceId: "my-whoop")
        let initial = await repo.recoverMissedSleep(startTs: start, endTs: end)
        XCTAssertTrue(initial.savedSession)
        repo.adoptActiveDeviceId(activeSourceId)
        let rr = (0..<3600).flatMap { offset in
            [RRInterval(ts: start + offset, rrMs: 700, sourceOrdinal: 0),
             RRInterval(ts: start + offset, rrMs: 750, sourceOrdinal: 1)]
        }
        _ = try await store.insert(Streams(rr: rr), deviceId: activeSourceId)
        let edited = await repo.selfHealEditedStages(sourceId: activeSourceId, from: start - 1, to: end + 1)
        if activeSourceId != "my-whoop" {
            XCTAssertTrue(edited.isEmpty, "Canonical recovery must not become an edit owned by the active strap")
        }
        let saved = try await store.sleepRecoveryDailyOverride(deviceId: "my-whoop-noop", sessionStartTs: start)
        XCTAssertEqual(saved?.avgHrv ?? -1, 50, accuracy: 0.001,
                       "New raw beats must refresh the override, retaining every beat within each second")
        let rerecovered = await repo.recoverMissedSleep(startTs: start, endTs: end, replacingStartTs: start)
        XCTAssertTrue(rerecovered.savedSession)
        let reread = try await store.sleepRecoveryDailyOverride(deviceId: "my-whoop-noop", sessionStartTs: start)
        XCTAssertEqual(reread?.avgHrv ?? -1, 50, accuracy: 0.001)
        let raw = try await store.rrIntervals(deviceId: activeSourceId, from: start, to: end, limit: 10_000)
        XCTAssertEqual(raw.count, 7200)
    }

    private func seedLegacyRecovery(store: WhoopStore, start: Int, end: Int) async throws {
        let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(end)))
        let session = CachedSleepSession(
            startTs: start, endTs: end, efficiency: 0.88, restingHr: 52, avgHrv: 61,
            stagesJSON: "[{\"start\":\(start),\"end\":\(end),\"stage\":\"light\"}]",
            userEdited: true, startTsAdjusted: nil)
        let overlay = SleepRecoveryDailyOverride(
            day: day, sessionStartTs: start, totalSleepMin: 60, efficiency: 0.88,
            deepMin: 10, remMin: 10, lightMin: 40, disturbances: 1,
            restingHr: 52, avgHrv: 61, recovery: 99, restScore: 80,
            chargeWeightedSumWithoutSleep: 1, chargeWeightWithoutSleep: 2,
            chargeBaselineUsable: true, updatedAt: end)
        let audit = SleepRecoveryAuditRecord(
            id: "legacy-\(start)", source: "manual_window", requestedStartTs: start,
            requestedEndTs: end, outcome: "complete", confidence: 0.9,
            reason: "bounded_reanalysis", resultStartTs: start, resultEndTs: end,
            stagesAvailable: true, restingHr: 52, avgHrv: 61,
            algorithmVersion: "sleep-window-recovery-v1", createdAt: end, updatedAt: end)
        _ = try await store.replaceWithManualSleepRecovery(
            session, deviceId: "my-whoop-noop", audit: audit,
            dailyOverride: overlay, daily: dailyMetric(day: day))
    }

    func testRejectedUnchangedRecoveryClearsProtectedMetricsAndPreservesBounds() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let start = Int(Date().timeIntervalSince1970) - 7200
        let end = start + 3600
        let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(end)))
        try await seedLegacyRecovery(store: store, start: start, end: end)
        let edited = await repo.selfHealEditedStages(sourceId: "my-whoop", from: start - 1, to: end + 1)

        let row = try XCTUnwrap(edited.first)
        XCTAssertEqual(row.startTs, start)
        XCTAssertEqual(row.endTs, end)
        XCTAssertTrue(row.userEdited)
        XCTAssertNil(row.stagesJSON)
        XCTAssertNil(row.restingHr)
        XCTAssertNil(row.avgHrv)
        let overlay = try await store.sleepRecoveryDailyOverride(deviceId: "my-whoop-noop", sessionStartTs: start)
        XCTAssertNotNil(overlay, "Keep provenance so later raw data can refresh this same window")
        XCTAssertNil(overlay?.recovery)
        XCTAssertNil(overlay?.restScore)
        XCTAssertNil(overlay?.chargeWeightedSumWithoutSleep)
        XCTAssertNil(overlay?.chargeWeightWithoutSleep)
        XCTAssertEqual(overlay?.chargeBaselineUsable, false)

        try await store.upsertDailyMetrics([dailyMetric(day: day)], deviceId: "my-whoop-noop")
        let daily = try await store.dailyMetrics(deviceId: "my-whoop-noop", from: day, to: day)
        XCTAssertNil(daily.first?.recovery, "A later ordinary score cannot revive the rejected override")
        XCTAssertNil(daily.first?.avgHrv)
        XCTAssertEqual(daily.first?.strain, 12)
        XCTAssertEqual(daily.first?.steps, 5_000)
        let rest = try await store.metricSeries(deviceId: "my-whoop-noop", key: "sleep_performance", from: day, to: day)
        XCTAssertTrue(rest.isEmpty)
    }

    func testRejectedChangedWindowPreservesExistingRecovery() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let start = Int(Date().timeIntervalSince1970) - 7200
        let end = start + 3600
        try await seedLegacyRecovery(store: store, start: start, end: end)

        let result = await repo.recoverMissedSleep(
            startTs: start + 60, endTs: end - 60, replacingStartTs: start, publishAfterSave: false)
        XCTAssertFalse(result.savedSession)
        let overlay = try await store.sleepRecoveryDailyOverride(deviceId: "my-whoop-noop", sessionStartTs: start)
        XCTAssertEqual(overlay?.recovery, 99)
        let rows = try await store.sleepSessions(deviceId: "my-whoop-noop", from: start - 1, to: end + 1, limit: 10)
        XCTAssertEqual(rows.first?.startTs, start)
        XCTAssertEqual(rows.first?.endTs, end)
        XCTAssertNotNil(rows.first?.stagesJSON)
    }

    func testExactSourceHealingLeavesCanonicalRecoveryUntouched() async throws {
        let store = try await WhoopStore.inMemory()
        // Exact maintenance creates a source-local repository without adopting a live descriptor.
        let repo = Repository(deviceId: "whoop-readded")
        repo.setStoreForTesting(store)
        let start = Int(Date().timeIntervalSince1970) - 7200
        let end = start + 3600
        try await seedLegacyRecovery(store: store, start: start, end: end)

        let edited = await repo.selfHealEditedStages(sourceId: "whoop-readded", from: start - 1, to: end + 1)
        XCTAssertTrue(edited.isEmpty)
        let overlay = try await store.sleepRecoveryDailyOverride(deviceId: "my-whoop-noop", sessionStartTs: start)
        XCTAssertEqual(overlay?.recovery, 99)
    }
}
