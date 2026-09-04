import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import NOOP

final class SleepHeartRateContrastSectionTests: XCTestCase {
    func testPlanUsesPreviousMainSleepAndExcludesRecordedNap() throws {
        let previousMain = sleep(start: 0, end: 8 * 3_600)
        let nap = sleep(start: 14 * 3_600, end: 15 * 3_600)
        let current = sleep(start: 24 * 3_600, end: 32 * 3_600)

        let plan = try XCTUnwrap(SleepHeartRateWindowPlan.make(
            sleepStart: current.effectiveStartTs,
            sleepEnd: current.endTs,
            sessions: [nap, current, previousMain],
            habitualMidsleepSec: nil,
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        ))

        XCTAssertEqual(plan.wakeStart, previousMain.endTs)
        XCTAssertEqual(plan.wakeEnd, current.effectiveStartTs)
        XCTAssertEqual(plan.excludedWakeSleep, [
            .init(start: nap.effectiveStartTs, end: nap.endTs)
        ])
    }

    func testPlanFailsClosedWhenPreviousSleepIsTooOld() {
        let previous = sleep(start: 0, end: 8 * 3_600)
        let current = sleep(start: 50 * 3_600, end: 58 * 3_600)
        guard let utc = TimeZone(secondsFromGMT: 0) else {
            XCTFail("UTC time zone must exist")
            return
        }

        XCTAssertNil(SleepHeartRateWindowPlan.make(
            sleepStart: current.effectiveStartTs,
            sleepEnd: current.endTs,
            sessions: [previous, current],
            habitualMidsleepSec: nil,
            timeZone: utc
        ))
    }

    func testFixedGridKeepsMissingMinutesAndRemovesSleepEpochs() {
        let buckets = [
            HRBucket(ts: 60, bpm: 61),
            HRBucket(ts: 120, bpm: 62),
            HRBucket(ts: 240, bpm: 64),
        ]

        let grid = SleepHeartRateWindowPlan.fixedGrid(
            buckets: buckets,
            from: 30,
            to: 330,
            excluding: [.init(start: 120, end: 180)]
        )

        XCTAssertEqual(grid.count, 3)
        XCTAssertEqual(grid[0], 61)
        XCTAssertNil(grid[1])
        XCTAssertEqual(grid[2], 64)
    }

    func testLoadKeyChangesWhenCompleteSessionsOrHabitualTimingArrive() {
        let initial = SleepHeartRateLoadKey(
            sleepStart: 100, sleepEnd: 200, sourceId: "my-whoop", repositoryRevision: 7,
            sessionsRevision: 0, habitualMidsleepSec: nil
        )
        let completeSessions = SleepHeartRateLoadKey(
            sleepStart: 100, sleepEnd: 200, sourceId: "my-whoop", repositoryRevision: 7,
            sessionsRevision: 1, habitualMidsleepSec: nil
        )
        let learnedTiming = SleepHeartRateLoadKey(
            sleepStart: 100, sleepEnd: 200, sourceId: "my-whoop", repositoryRevision: 7,
            sessionsRevision: 1, habitualMidsleepSec: 3 * 3_600
        )

        XCTAssertNotEqual(initial, completeSessions)
        XCTAssertNotEqual(completeSessions, learnedTiming)
    }

    func testComparisonFailsClosedWhenActiveAndCanonicalSourcesCouldMix() {
        XCTAssertEqual(Repository.onlyDistinctSource(["my-whoop"]), "my-whoop")
        XCTAssertEqual(Repository.onlyDistinctSource(["my-whoop", "my-whoop"]), "my-whoop")
        XCTAssertNil(Repository.onlyDistinctSource(["whoop-repaired", "my-whoop"]))
        XCTAssertNil(Repository.onlyDistinctSource([]))
    }

    func testPreSleepObservationRequiresExactPersistedSleepBounds() {
        XCTAssertTrue(PreSleepHeartRateFeedbackSection.observationBoundsMatch(
            storedStart: 1_000,
            storedEnd: 20_000,
            currentStart: 1_000,
            currentEnd: 20_000
        ))
        XCTAssertFalse(PreSleepHeartRateFeedbackSection.observationBoundsMatch(
            storedStart: 1_000,
            storedEnd: 20_000,
            currentStart: 1_600,
            currentEnd: 20_000
        ))
        XCTAssertFalse(PreSleepHeartRateFeedbackSection.observationBoundsMatch(
            storedStart: nil,
            storedEnd: nil,
            currentStart: 1_000,
            currentEnd: 20_000
        ))
    }

    @MainActor
    func testPreSleepHistoryKeepsOnlyRowsMatchingAuthoritativePrimaryBounds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let firstWake = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 1, hour: 8
        )))
        let secondWake = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstWake))
        let firstEnd = Int(firstWake.timeIntervalSince1970)
        let secondEnd = Int(secondWake.timeIntervalSince1970)
        let firstStart = firstEnd - 7 * 3_600
        let secondStart = secondEnd - 8 * 3_600
        let firstDay = Repository.localDayKey(firstWake, calendar: calendar)
        let secondDay = Repository.localDayKey(secondWake, calendar: calendar)
        let missingDay = "2026-08-03"

        let readings = PreSleepHeartRateFeedbackSection.validHistoricalReadings(
            means: [
                (day: firstDay, value: 61),
                (day: secondDay, value: 62),
                (day: missingDay, value: 63),
            ],
            storedStarts: [
                firstDay: Double(firstStart),
                secondDay: Double(secondStart - 15 * 60),
                missingDay: Double(secondStart),
            ],
            storedEnds: [
                firstDay: Double(firstEnd),
                secondDay: Double(secondEnd),
                missingDay: Double(secondEnd),
            ],
            sessions: [
                sleep(start: firstStart, end: firstEnd),
                sleep(start: secondStart, end: secondEnd),
            ],
            habitualMidsleepSec: nil,
            calendar: calendar
        )

        XCTAssertEqual(readings, [
            PreSleepHeartRateFeedback.HistoricalReading(day: firstDay, meanBpm: 61)
        ])
    }

    @MainActor
    func testHistoricalSleepEditInvalidatesOldAndNewWakeDaysAcrossNamespaces() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)

        let calendar = Calendar.current
        let historicalDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -25, to: Date()))
        let historicalDayStart = calendar.startOfDay(for: historicalDate)
        let oldWakeDate = try XCTUnwrap(calendar.date(
            byAdding: .minute, value: 23 * 60 + 50, to: historicalDayStart
        ))
        let newWakeDate = try XCTUnwrap(calendar.date(byAdding: .minute, value: 20, to: oldWakeDate))
        let oldEnd = Int(oldWakeDate.timeIntervalSince1970)
        let newEnd = Int(newWakeDate.timeIntervalSince1970)
        let detectedStart = oldEnd - 8 * 3_600
        let editedStart = detectedStart + 15 * 60
        let oldDay = Repository.localDayKey(oldWakeDate, calendar: calendar)
        let newDay = Repository.localDayKey(newWakeDate, calendar: calendar)
        let preservedDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: oldWakeDate))
        let preservedDay = Repository.localDayKey(preservedDate, calendar: calendar)
        XCTAssertNotEqual(oldDay, newDay)

        _ = try await store.upsertSleepSessions([
            CachedSleepSession(
                startTs: detectedStart,
                endTs: oldEnd,
                efficiency: 0.9,
                restingHr: 52,
                avgHrv: 60,
                stagesJSON: nil
            )
        ], deviceId: Repository.whoopSource + "-noop")

        let affectedPoints = [oldDay, newDay].flatMap { day in
            PreSleepHeartRateFeedback.metricKeys.map { key in
                MetricPoint(day: day, key: key, value: 64)
            }
        }
        let preservedPoints = PreSleepHeartRateFeedback.metricKeys.map {
            MetricPoint(day: preservedDay, key: $0, value: 63)
        }
        for sourceId in [Repository.whoopSource + "-noop", "orphan-noop"] {
            _ = try await store.upsertMetricSeries(
                affectedPoints + preservedPoints + [
                    MetricPoint(day: oldDay, key: "sleep_performance", value: 82)
                ],
                deviceId: sourceId
            )
        }

        await repository.editSleepTimes(
            detectedStartTs: detectedStart,
            oldEndTs: oldEnd,
            storedStagesJSON: nil,
            newStartTs: editedStart,
            newEndTs: newEnd
        )

        for sourceId in [Repository.whoopSource + "-noop", "orphan-noop"] {
            for day in [oldDay, newDay] {
                for key in PreSleepHeartRateFeedback.metricKeys {
                    let rows = try await store.metricSeries(
                        deviceId: sourceId, key: key, from: day, to: day
                    )
                    XCTAssertTrue(rows.isEmpty, "stale \(key) survived for \(sourceId) on \(day)")
                }
            }
            for key in PreSleepHeartRateFeedback.metricKeys {
                let rows = try await store.metricSeries(
                    deviceId: sourceId, key: key, from: preservedDay, to: preservedDay
                )
                XCTAssertEqual(rows.map(\.value), [63], "unaffected history changed for \(sourceId)")
            }
            let unrelated = try await store.metricSeries(
                deviceId: sourceId, key: "sleep_performance", from: oldDay, to: oldDay
            )
            XCTAssertEqual(unrelated.map(\.value), [82])
        }

        let edited = try await store.sleepSessions(
            deviceId: Repository.whoopSource + "-noop",
            from: detectedStart - 1,
            to: newEnd + 1,
            limit: 10
        )
        XCTAssertEqual(edited.count, 1)
        XCTAssertEqual(edited.first?.effectiveStartTs, editedStart)
        XCTAssertEqual(edited.first?.endTs, newEnd)
        XCTAssertEqual(edited.first?.userEdited, true)
    }

    @MainActor
    func testHistoricalSleepDeleteAndUndoInvalidateWakeDayAcrossNamespaces() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)

        let calendar = Calendar.current
        let historicalDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -25, to: Date()))
        let wakeDate = try XCTUnwrap(calendar.date(
            byAdding: .hour, value: 8, to: calendar.startOfDay(for: historicalDate)
        ))
        let wake = Int(wakeDate.timeIntervalSince1970)
        let start = wake - 7 * 3_600
        let wakeDay = Repository.localDayKey(wakeDate, calendar: calendar)
        let sources = [Repository.whoopSource + "-noop", "orphan-noop"]

        _ = try await store.upsertSleepSessions([
            CachedSleepSession(
                startTs: start,
                endTs: wake,
                efficiency: 0.9,
                restingHr: 52,
                avgHrv: 60,
                stagesJSON: nil,
                userEdited: true
            )
        ], deviceId: Repository.whoopSource + "-noop")
        try await seedPreSleepFeedback(store: store, days: [wakeDay], sources: sources)

        let deleted = await repository.deleteSleepSession(
            detectedStartTs: start,
            endTs: wake
        )
        let snapshot = try XCTUnwrap(deleted)
        try await assertPreSleepFeedbackAbsent(
            store: store,
            days: [wakeDay],
            sources: sources
        )

        // Simulate a late writer landing after delete. Undo is itself a session-set mutation and must scrub
        // that row before restoring the original boundary.
        try await seedPreSleepFeedback(store: store, days: [wakeDay], sources: sources)
        await repository.undoDeleteSleepSession(snapshot)
        try await assertPreSleepFeedbackAbsent(
            store: store,
            days: [wakeDay],
            sources: sources
        )
        let restored = try await store.sleepSessions(
            deviceId: Repository.whoopSource + "-noop",
            from: start - 1,
            to: wake + 1,
            limit: 10
        )
        XCTAssertEqual(restored.map(\.startTs), [start])
        XCTAssertEqual(restored.first?.endTs, wake)
    }

    @MainActor
    func testHistoricalManualNapInvalidatesWakeDayAcrossNamespaces() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)

        let calendar = Calendar.current
        let historicalDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -25, to: Date()))
        let dayStart = calendar.startOfDay(for: historicalDate)
        let startDate = try XCTUnwrap(calendar.date(byAdding: .hour, value: 13, to: dayStart))
        let endDate = try XCTUnwrap(calendar.date(byAdding: .minute, value: 75, to: startDate))
        let start = Int(startDate.timeIntervalSince1970)
        let end = Int(endDate.timeIntervalSince1970)
        let wakeDay = Repository.localDayKey(endDate, calendar: calendar)
        let sources = [Repository.whoopSource + "-noop", "orphan-noop"]
        try await seedPreSleepFeedback(store: store, days: [wakeDay], sources: sources)

        await repository.addManualNap(startTs: start, endTs: end)

        try await assertPreSleepFeedbackAbsent(
            store: store,
            days: [wakeDay],
            sources: sources
        )
        let inserted = try await store.sleepSessions(
            deviceId: Repository.whoopSource + "-noop",
            from: start - 1,
            to: end + 1,
            limit: 10
        )
        XCTAssertEqual(inserted.map(\.startTs), [start])
        XCTAssertEqual(inserted.first?.endTs, end)
        XCTAssertEqual(inserted.first?.userEdited, true)
    }

    @MainActor
    func testStandaloneHistoricalRecoveryInvalidatesRemovedAndNewWakeDaysAcrossNamespaces() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)

        let calendar = Calendar.current
        let historicalDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -25, to: Date()))
        let dayStart = calendar.startOfDay(for: historicalDate)
        let oldEndDate = try XCTUnwrap(calendar.date(
            byAdding: .minute, value: 23 * 60 + 50, to: dayStart
        ))
        let newEndDate = try XCTUnwrap(calendar.date(byAdding: .minute, value: 30, to: oldEndDate))
        let oldEnd = Int(oldEndDate.timeIntervalSince1970)
        let newEnd = Int(newEndDate.timeIntervalSince1970)
        let newStart = oldEnd - 6 * 3_600
        let oldStart = newStart - 15 * 60
        let oldDay = Repository.localDayKey(oldEndDate, calendar: calendar)
        let newDay = Repository.localDayKey(newEndDate, calendar: calendar)
        let sources = [Repository.whoopSource + "-noop", "orphan-noop"]
        XCTAssertNotEqual(oldDay, newDay)

        _ = try await store.upsertSleepSessions([
            CachedSleepSession(
                startTs: oldStart,
                endTs: oldEnd,
                efficiency: 0.9,
                restingHr: 52,
                avgHrv: 60,
                stagesJSON: nil
            )
        ], deviceId: Repository.whoopSource + "-noop")
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: newStart + 60, bpm: 55)]),
            deviceId: Repository.whoopSource
        )
        try await seedPreSleepFeedback(
            store: store,
            days: [oldDay, newDay],
            sources: sources
        )

        let result = await repository.recoverMissedSleep(startTs: newStart, endTs: newEnd)

        XCTAssertTrue(result.savedSession)
        try await assertPreSleepFeedbackAbsent(
            store: store,
            days: [oldDay, newDay],
            sources: sources
        )
        let sessions = try await store.sleepSessions(
            deviceId: Repository.whoopSource + "-noop",
            from: oldStart - 1,
            to: newEnd + 1,
            limit: 10
        )
        XCTAssertFalse(sessions.contains { $0.startTs == oldStart })
        XCTAssertTrue(sessions.contains { $0.startTs == newStart && $0.endTs == newEnd })
    }

    @MainActor
    private func seedPreSleepFeedback(
        store: WhoopStore,
        days: [String],
        sources: [String]
    ) async throws {
        let points = days.flatMap { day in
            PreSleepHeartRateFeedback.metricKeys.enumerated().map { index, key in
                MetricPoint(day: day, key: key, value: Double(60 + index))
            }
        }
        for source in sources {
            _ = try await store.upsertMetricSeries(
                points + [MetricPoint(day: days[0], key: "sleep_performance", value: 82)],
                deviceId: source
            )
        }
    }

    @MainActor
    private func assertPreSleepFeedbackAbsent(
        store: WhoopStore,
        days: [String],
        sources: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for source in sources {
            for day in days {
                for key in PreSleepHeartRateFeedback.metricKeys {
                    let rows = try await store.metricSeries(
                        deviceId: source,
                        key: key,
                        from: day,
                        to: day
                    )
                    XCTAssertTrue(
                        rows.isEmpty,
                        "stale \(key) survived for \(source) on \(day)",
                        file: file,
                        line: line
                    )
                }
            }
            let unrelated = try await store.metricSeries(
                deviceId: source,
                key: "sleep_performance",
                from: days[0],
                to: days[0]
            )
            XCTAssertEqual(unrelated.map(\.value), [82], file: file, line: line)
        }
    }

    private func sleep(start: Int, end: Int) -> CachedSleepSession {
        CachedSleepSession(
            startTs: start,
            endTs: end,
            efficiency: 0.9,
            restingHr: 52,
            avgHrv: 60,
            stagesJSON: nil
        )
    }
}
