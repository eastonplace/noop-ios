import XCTest
import WhoopStore
@testable import NOOP

/// DL-03: editing, deleting or adding a nap on any night but last night never rescored that day, because the
/// edit flows only ask for the one-day `analyzeRecent()`. The mutators now enqueue the affected days and a
/// background drain rescores them from that day through today.
@MainActor
final class RepositoryEditRescoreTests: XCTestCase {
    override func setUp() async throws {
        _ = EditedDayRescoreQueue.shared.take()
    }

    override func tearDown() async throws {
        _ = EditedDayRescoreQueue.shared.take()
    }

    private func newYorkCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        return calendar
    }

    func testEditThreeNightsAgoRescoresFromThatDayThroughToday() throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let threeNightsAgoWake = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 7)))

        let request = try XCTUnwrap(IntelligenceAnalysisRequest.editedDays(
            containingTimestamps: [Int(threeNightsAgoWake.timeIntervalSince1970), Int(now.timeIntervalSince1970)],
            now: now, calendar: calendar))
        XCTAssertEqual(request.startOffset, 0)
        XCTAssertEqual(request.maxDays, 4, "Oct 9 through Oct 12: the edited day and every later carry")
        XCTAssertTrue(request.force)
        XCTAssertTrue(request.refreshRepository)
    }

    func testEditedDayWindowCountsCalendarDaysAcrossFallBack() throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9)))
        let wake = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23)))
        let request = try XCTUnwrap(IntelligenceAnalysisRequest.editedDays(
            containingTimestamps: [Int(wake.timeIntervalSince1970)], now: now, calendar: calendar))
        XCTAssertEqual(request.maxDays, 3)
    }

    func testFutureOrEmptyEditsNeverWidenPastToday() throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let request = try XCTUnwrap(IntelligenceAnalysisRequest.editedDays(
            containingTimestamps: [Int(now.timeIntervalSince1970) + 86_400], now: now, calendar: calendar))
        XCTAssertEqual(request.maxDays, 1)
        XCTAssertNil(IntelligenceAnalysisRequest.editedDays(containingTimestamps: [Int](), now: now))
    }

    func testDeletingAnOlderNightQueuesItsWakeDayForRescore() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let wake = Int(Date().timeIntervalSince1970) - 3 * 86_400
        _ = try await store.insertManualSleepSession(
            deviceId: Repository.whoopSource + "-noop", startTs: wake - 8 * 3_600, endTs: wake,
            efficiency: 0.9, stagesJSON: "[]")

        _ = await repository.deleteSleepSession(detectedStartTs: wake - 8 * 3_600, endTs: wake)

        XCTAssertEqual(EditedDayRescoreQueue.shared.timestamps, [wake])
    }

    func testAddingANapQueuesItsDay() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let end = Int(Date().timeIntervalSince1970) - 2 * 86_400

        await repository.addManualNap(startTs: end - 2_700, endTs: end)

        XCTAssertEqual(EditedDayRescoreQueue.shared.timestamps, [end])
        XCTAssertEqual(EditedDayRescoreQueue.shared.take(), [end])
        XCTAssertTrue(EditedDayRescoreQueue.shared.timestamps.isEmpty, "the pass drains what it rescored")
    }

    // MARK: - Background drain

    private func drainQueue(now: Date, calendar: Calendar,
                            backgrounded: Bool = false) -> EditedDayRescoreQueue {
        EditedDayRescoreQueue(defaults: nil, debounce: .zero, now: { now }, calendar: { calendar },
                              isBackgrounded: { backgrounded })
    }

    /// Review finding (unchunked forced batch): an edit months back ran as one forced, uncancellable request
    /// over the whole range while the editor waited. The drain now runs at most 30 days per pass, oldest first.
    func testALongEditedRangeDrainsInThirtyDayChunksOldestFirst() async throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let edited = try XCTUnwrap(calendar.date(byAdding: .day, value: -69, to: now))
        let queue = drainQueue(now: now, calendar: calendar)
        let recorder = EditedDayAnalyzeRecorder()
        queue.register(recorder) { request in
            recorder.requests.append(request)
            return true
        }

        queue.enqueue([Int(edited.timeIntervalSince1970)])
        queue.scheduleDrain()
        await queue.waitForDrain()

        XCTAssertEqual(recorder.requests.map(\.startOffset), [40, 10, 0], "oldest chunk first")
        XCTAssertEqual(recorder.requests.map(\.maxDays), [30, 30, 10], "70 days in passes of at most 30")
        XCTAssertTrue(recorder.requests.allSatisfy(\.force))
        XCTAssertTrue(queue.timestamps.isEmpty)
        XCTAssertFalse(queue.isDraining)
    }

    func testCancellingMidDrainStopsAtTheChunkBoundaryAndKeepsTheRestQueued() async throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let edited = try XCTUnwrap(calendar.date(byAdding: .day, value: -69, to: now))
        let queue = drainQueue(now: now, calendar: calendar)
        let recorder = EditedDayAnalyzeRecorder()
        queue.register(recorder) { [unowned queue] request in
            recorder.requests.append(request)
            queue.cancel() // BG expiry lands while the first chunk runs
            return true
        }

        queue.enqueue([Int(edited.timeIntervalSince1970)])
        queue.scheduleDrain()
        await queue.waitForDrain()

        XCTAssertEqual(recorder.requests.count, 1)
        let rest = try XCTUnwrap(IntelligenceAnalysisRequest.editedDays(
            containingTimestamps: queue.timestamps, now: now, calendar: calendar))
        XCTAssertEqual(rest.maxDays, 40, "the 40 days after the finished chunk stay queued")
        XCTAssertFalse(queue.isDraining)
    }

    func testTheDrainWaitsWhileTheAppIsInTheBackground() async throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let queue = drainQueue(now: now, calendar: calendar, backgrounded: true)
        let recorder = EditedDayAnalyzeRecorder()
        queue.register(recorder) { request in
            recorder.requests.append(request)
            return true
        }
        let edited = Int(now.timeIntervalSince1970) - 5 * 86_400

        queue.enqueue([edited])
        queue.scheduleDrain()
        await queue.waitForDrain()

        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertEqual(queue.timestamps, [edited])
    }

    func testTheDrainPublishesOnceOverTheWholeRescoredRange() async throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let edited = try XCTUnwrap(calendar.date(byAdding: .day, value: -69, to: now))
        let queue = drainQueue(now: now, calendar: calendar)
        let recorder = EditedDayAnalyzeRecorder()
        queue.register(recorder) { request in
            recorder.requests.append(request)
            return true
        }

        queue.enqueue([Int(edited.timeIntervalSince1970)]) { days in recorder.published.append(days) }
        queue.scheduleDrain()
        await queue.waitForDrain()

        XCTAssertEqual(recorder.requests.count, 3)
        XCTAssertFalse(recorder.requests.contains(where: \.refreshRepository), "chunks don't publish one by one")
        XCTAssertEqual(recorder.published, [70], "one publish from the oldest rescored day through today")
    }

    /// Review finding (rescored older days never reach the 30-day caches): the engine's closing refresh is
    /// current-day and the DL-01 splice keeps older cached days, so a rescored night five days back kept its old
    /// Recovery in Home until some unrelated 30-day refresh.
    func testARescoredOlderDayReachesTheThirtyDayDashboard() async throws {
        let store = try await WhoopStore.inMemory()
        let computedId = Repository.whoopSource + "-noop"
        let now = Date()
        let keys = (0..<30).map { Repository.localDayKey(Repository.dateByAddingCalendarDays(-$0, to: now)) }
        func row(_ day: String, recovery: Double) -> DailyMetric {
            DailyMetric(day: day, totalSleepMin: 440, efficiency: 0.9, deepMin: 90, remMin: 100, lightMin: 250,
                        disturbances: 3, restingHr: 52, avgHrv: 63, recovery: recovery, strain: 60,
                        exerciseCount: 1, strainVersion: 2)
        }
        try await store.upsertDailyMetrics(keys.map { row($0, recovery: 70) }, deviceId: computedId)
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let queue = EditedDayRescoreQueue(defaults: nil, debounce: .zero, isBackgrounded: { false })
        repository.editedDayRescoreQueue = queue
        let loaded = await repository.refresh(days: 30)
        XCTAssertTrue(loaded)
        // The rescore (stubbed here) rewrites the edited day's computed row and publishes nothing itself.
        queue.register(self) { _ in
            _ = try? await store.upsertDailyMetrics([row(keys[5], recovery: 41)], deviceId: computedId)
            return true
        }
        let napEnd = Int(Repository.dateByAddingCalendarDays(-5, to: now).timeIntervalSince1970)

        await repository.addManualNap(startTs: napEnd - 2_700, endTs: napEnd)
        queue.scheduleDrain()
        await queue.waitForDrain()

        XCTAssertEqual(repository.days.first { $0.day == keys[5] }?.recovery, 41,
                       "the rescored day five nights back stayed stale in the 30-day cache")
        XCTAssertEqual(repository.days.count, 30)
    }

    // MARK: - Every enqueue drains, and the queue persists

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "RepositoryEditRescoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    /// Review finding (queue lost on kill, workout paths never drained): the workout delete, dismiss, relabel
    /// and bulk-delete flows and the auto-detect save never call analyzeRecent(), and the queue lived in memory.
    func testAnEnqueueAloneDrainsWithoutAnyAnalyzeRecentCall() async throws {
        let queue = EditedDayRescoreQueue(defaults: nil, debounce: .milliseconds(1), isBackgrounded: { false })
        let recorder = EditedDayAnalyzeRecorder()
        queue.register(recorder) { request in
            recorder.requests.append(request)
            return true
        }

        queue.enqueue([Int(Date().timeIntervalSince1970) - 3 * 86_400])
        await queue.waitForDrain()

        XCTAssertEqual(recorder.requests.map(\.maxDays), [4])
        XCTAssertTrue(queue.timestamps.isEmpty)
    }

    func testQueuedDaysSurviveARelaunchAndDrainOnceTheEngineRegisters() async throws {
        let defaults = try isolatedDefaults()
        let edited = Int(Date().timeIntervalSince1970) - 2 * 86_400
        let beforeKill = EditedDayRescoreQueue(defaults: defaults, storageKey: "queue", debounce: .zero,
                                               isBackgrounded: { false })
        beforeKill.enqueue([edited]) // no engine registered yet, so nothing drains

        let afterRelaunch = EditedDayRescoreQueue(defaults: defaults, storageKey: "queue", debounce: .zero,
                                                  isBackgrounded: { false })
        XCTAssertEqual(afterRelaunch.timestamps, [edited])
        let recorder = EditedDayAnalyzeRecorder()
        afterRelaunch.register(recorder) { request in
            recorder.requests.append(request)
            return true
        }
        await afterRelaunch.waitForDrain()

        XCTAssertEqual(recorder.requests.map(\.maxDays), [3])
        XCTAssertTrue(afterRelaunch.timestamps.isEmpty)
        XCTAssertEqual(defaults.array(forKey: "queue") as? [Int], [])
    }

    func testEveryWorkoutMutatorQueuesItsDay() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let queue = EditedDayRescoreQueue(defaults: nil, isBackgrounded: { false })
        repository.editedDayRescoreQueue = queue
        let base = Int(Date().timeIntervalSince1970) - 10 * 86_400
        func workout(_ offset: Int, source: String) -> WorkoutRow {
            WorkoutRow(startTs: base + offset, endTs: base + offset + 1_800, sport: "Running", source: source,
                       durationS: 1_800, energyKcal: nil, avgHr: 140, maxHr: nil, strain: nil, distanceM: nil,
                       zonesJSON: nil, notes: nil, strainVersion: nil)
        }
        let saved = workout(0, source: "manual")
        let deleted = workout(10_000, source: "manual")
        let dismissed = workout(20_000, source: Repository.whoopSource + "-noop")
        let relabelled = workout(30_000, source: Repository.whoopSource + "-noop")
        let bulk = [workout(40_000, source: "manual"), workout(50_000, source: Repository.whoopSource + "-noop")]

        await repository.saveManualWorkout(saved)
        XCTAssertEqual(queue.timestamps, [saved.endTs])
        await repository.deleteWorkout(deleted)
        await repository.dismissDetected(dismissed)
        await repository.relabelDetected(relabelled, sport: "Cycling")
        await repository.bulkDeleteWorkouts(bulk)

        XCTAssertEqual(queue.timestamps,
                       Set([saved, deleted, dismissed, relabelled].map(\.endTs) + bulk.map(\.endTs)))
    }

    func testComputedDailyRowsReadThePersistedNoopRows() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let rows = ["2026-10-08", "2026-10-09", "2026-10-10"].map {
            DailyMetric(day: $0, totalSleepMin: 440, efficiency: 0.9, deepMin: 90, remMin: 100,
                        lightMin: 250, disturbances: 3, restingHr: 52, avgHrv: 63, recovery: 70,
                        strain: 60, exerciseCount: 1, strainVersion: 2)
        }
        try await store.upsertDailyMetrics(rows, deviceId: Repository.whoopSource + "-noop")
        try await store.upsertDailyMetrics([rows[0]], deviceId: Repository.whoopSource)

        let read = try await repository.computedDailyRows(fromDay: "2026-10-09", throughDay: "2026-10-12")
        XCTAssertEqual(read.map(\.day), ["2026-10-09", "2026-10-10"])
    }
}

@MainActor
private final class EditedDayAnalyzeRecorder {
    var requests: [IntelligenceAnalysisRequest] = []
    var published: [Int] = []
}
