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
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
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
        let history = (1...7).map { daysBeforeWake in
            dailyMetric(
                day: Repository.localDayKey(
                    Date(timeIntervalSince1970: TimeInterval(newEnd - daysBeforeWake * 86_400))),
                restingHr: 53 + daysBeforeWake % 3,
                avgHrv: 55 + Double(daysBeforeWake))
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
            deviceId: "my-whoop")

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
