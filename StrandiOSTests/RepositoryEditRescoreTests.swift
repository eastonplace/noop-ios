import XCTest
import UIKit
import WhoopStore
@testable import NOOP

/// DL-03: editing, deleting or adding a nap on any night but last night never rescored that day, because the
/// edit flows only ask for the one-day `analyzeRecent()`. The mutators now enqueue the affected days and a
/// background drain rescores them from that day through today.
@MainActor
final class RepositoryEditRescoreTests: XCTestCase {

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

        XCTAssertEqual(repository.editedDayRescoreQueue.timestamps, [wake])
        XCTAssertFalse(repository.editedDayRescoreQueue === EditedDayRescoreQueue.shared,
                       "a test edit reached the host app's shared queue")
    }

    func testAddingANapQueuesItsDay() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let end = Int(Date().timeIntervalSince1970) - 2 * 86_400

        await repository.addManualNap(startTs: end - 2_700, endTs: end)

        XCTAssertEqual(repository.editedDayRescoreQueue.timestamps, [end])
    }

    // MARK: - Background drain

    /// An in-memory queue on a virtual clock: its sleeps (debounce, backoff timer) advance the clock at once.
    private func drainQueue(now: Date, calendar: Calendar,
                            backgrounded: Bool = false) -> EditedDayRescoreQueue {
        let clock = EditedDayAnalyzeRecorder()
        clock.now = now
        return virtualClockQueue(clock, calendar: calendar, backgrounded: { backgrounded })
    }

    private func virtualClockQueue(_ clock: EditedDayAnalyzeRecorder, calendar: Calendar,
                                   defaults: UserDefaults? = nil, storageKey: String = "queue",
                                   backgrounded: @escaping @MainActor () -> Bool = { false },
                                   build: String = EditedDayRescoreQueue.currentBuild)
        -> EditedDayRescoreQueue {
        EditedDayRescoreQueue(defaults: defaults, storageKey: storageKey, debounce: .zero, now: { clock.now },
                              calendar: { calendar }, isBackgrounded: backgrounded,
                              sleep: { clock.now = clock.now.addingTimeInterval(Self.seconds($0)) },
                              build: build)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Waits until no drain is pending or running, following the timers drains arm for each other.
    private func settle(_ queue: EditedDayRescoreQueue) async {
        for _ in 0..<50 {
            await queue.waitForDrain()
            if !queue.isDraining { return }
        }
        XCTFail("the drain never settled")
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

    /// Review finding (cancelled drain never publishes): chunk 1 finished, BG expiry cancelled chunk 2, the
    /// publish was skipped, and the next drain published only its own 10 days.
    func testADrainCancelledBeforeItsPublishHandsItsRescoredDaysToTheNextDrain() async throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let edited = try XCTUnwrap(calendar.date(byAdding: .day, value: -39, to: now))
        let queue = drainQueue(now: now, calendar: calendar)
        let recorder = EditedDayAnalyzeRecorder()
        queue.register(recorder) { [unowned queue] request in
            recorder.requests.append(request)
            guard recorder.requests.count == 2 else { return true }
            queue.cancel() // BG expiry while chunk 2 runs; the chunk stops incomplete
            return false
        }

        queue.enqueue([Int(edited.timeIntervalSince1970)]) { days in recorder.published.append(days) }
        await queue.waitForDrain()
        XCTAssertEqual(recorder.requests.map(\.maxDays), [30, 10])
        XCTAssertTrue(recorder.published.isEmpty, "a cancelled drain doesn't publish")

        queue.scheduleDrain()
        await queue.waitForDrain()

        XCTAssertEqual(recorder.requests.map(\.maxDays), [30, 10, 10])
        XCTAssertEqual(recorder.published, [40], "the first drain's 30 rescored days were never published")
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
    /// current-day and the DL-01 splice keeps older cached days, so a rescored day five days back kept its old
    /// Recovery in Home until some unrelated 30-day refresh. A workout delete runs no refresh of its own, so
    /// only the drain's publish can deliver the rescored row.
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
        let start = Int(Repository.dateByAddingCalendarDays(-5, to: now).timeIntervalSince1970)
        let workout = WorkoutRow(startTs: start, endTs: start + 1_800, sport: "Running", source: "manual",
                                 durationS: 1_800, energyKcal: nil, avgHr: 140, maxHr: nil, strain: nil,
                                 distanceM: nil, zonesJSON: nil, notes: nil, strainVersion: nil)
        _ = try await store.upsertWorkouts([workout], deviceId: Repository.whoopSource)

        await repository.deleteWorkout(workout)
        await queue.waitForDrain()

        XCTAssertEqual(repository.days.first { $0.day == keys[5] }?.recovery, 41,
                       "the rescored day five days back stayed stale in the 30-day cache")
        XCTAssertEqual(repository.days.count, 30)
    }

    /// Review finding (untested drain): a failed pass must keep the edited days queued, and the next drain
    /// must pick them up.
    func testAFailedChunkKeepsTheEditedDaysQueuedForTheNextDrain() async throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let recorder = EditedDayAnalyzeRecorder()
        recorder.now = now
        let queue = virtualClockQueue(recorder, calendar: calendar)
        queue.register(recorder) { [unowned queue] request in
            recorder.requests.append(request)
            recorder.times.append(recorder.now)
            if recorder.requests.count == 2 { recorder.snapshot = queue.timestamps }
            return recorder.requests.count > 1 // the first pass fails
        }
        let edited = try [-6, -1].map {
            Int(try XCTUnwrap(calendar.date(byAdding: .day, value: $0, to: now)).timeIntervalSince1970)
        }

        queue.enqueue(edited) { days in recorder.published.append(days) }
        await settle(queue)

        XCTAssertEqual(recorder.requests.map(\.maxDays), [7, 7])
        XCTAssertEqual(recorder.snapshot, Set(edited), "a failed pass dropped the edited days")
        XCTAssertEqual(recorder.times.last?.timeIntervalSince(now), EditedDayRescoreQueue.retryBaseDelay,
                       "the retry runs when the 2-minute backoff ends, from the drain's own timer")
        XCTAssertTrue(queue.timestamps.isEmpty)
        XCTAssertEqual(recorder.published, [7], "only the completed pass publishes")
    }

    /// Review finding (failing chunk retried forever): a chunk that kept failing re-ran on every live analysis
    /// with no backoff and held back every newer edited day behind it.
    func testAFailingRangeBacksOffThenParksSoNewerDaysStillDrain() async throws {
        let calendar = try newYorkCalendar()
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let defaults = try isolatedDefaults()
        let recorder = EditedDayAnalyzeRecorder()
        recorder.now = start
        let queue = virtualClockQueue(recorder, calendar: calendar, defaults: defaults)
        queue.register(recorder) { request in
            recorder.requests.append(request)
            recorder.times.append(recorder.now)
            return request.startOffset == 0 // the old range keeps failing; recent days are fine
        }
        let old = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -39, to: start)).timeIntervalSince1970)
        let recent = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: start)).timeIntervalSince1970)

        queue.enqueue([old, recent])
        await settle(queue) // no live analysis or manual kick: the drain arms its own timers

        XCTAssertEqual(recorder.requests.map(\.startOffset), [10, 10, 10, 0],
                       "three tries of the old chunk, then the newer day drains past the parked range")
        XCTAssertEqual(recorder.times.prefix(3).map { $0.timeIntervalSince(start) }, [0, 120, 360],
                       "each retry waits out its backoff (2 min, then 4)")
        XCTAssertEqual(recorder.requests.last?.maxDays, 3)
        XCTAssertEqual(queue.parkedTimestamps, [old])
        XCTAssertEqual(queue.timestamps, [old])
        let relaunched = virtualClockQueue(recorder, calendar: calendar, defaults: defaults)
        XCTAssertEqual(relaunched.parkedTimestamps, [old], "the parked state persists")

        queue.cancel()
        queue.enqueue([old]) // a new edit of that night un-parks it
        XCTAssertTrue(queue.parkedTimestamps.isEmpty)
        queue.cancel()
    }

    /// Review finding (parking had no way back): a transient failure parked an edit for good. A park now ends
    /// at load when the app build changed or after a day.
    func testAParkedRangeComesBackAfterAnAppUpdateOrADay() async throws {
        let calendar = try newYorkCalendar()
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let defaults = try isolatedDefaults()
        let clock = EditedDayAnalyzeRecorder()
        clock.now = start
        let failing = virtualClockQueue(clock, calendar: calendar, defaults: defaults, build: "100")
        failing.register(clock) { _ in false }
        let night = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -45, to: start)).timeIntervalSince1970)
        failing.enqueue([night])
        await settle(failing)
        XCTAssertEqual(failing.parkedTimestamps, [night])
        let parkedAt = clock.now

        func relaunch(build: String, after interval: TimeInterval) -> EditedDayRescoreQueue {
            let later = EditedDayAnalyzeRecorder()
            later.now = parkedAt.addingTimeInterval(interval)
            return virtualClockQueue(later, calendar: calendar, defaults: defaults, build: build)
        }
        XCTAssertEqual(relaunch(build: "100", after: 3_600).parkedTimestamps, [night], "same build, an hour later")
        let updated = relaunch(build: "101", after: 60)
        XCTAssertTrue(updated.parkedTimestamps.isEmpty, "an app update retries the parked range")
        XCTAssertEqual(updated.timestamps, [night])
        // The update's load persisted the un-park; park it again under build 100 to check the age rule.
        failing.cancel()
        let refail = virtualClockQueue(clock, calendar: calendar, defaults: defaults, build: "100")
        refail.register(clock) { _ in false }
        await settle(refail)
        XCTAssertEqual(refail.parkedTimestamps, [night])
        let dayLater = relaunch(build: "100", after: clock.now.timeIntervalSince(parkedAt) + 25 * 3_600)
        XCTAssertTrue(dayLater.parkedTimestamps.isEmpty, "a park older than a day is retried")
    }

    func testAParkExpiresInALiveProcessOnTheNextDrainRequest() async throws {
        let calendar = try newYorkCalendar()
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let clock = EditedDayAnalyzeRecorder()
        clock.now = start
        let queue = virtualClockQueue(clock, calendar: calendar)
        queue.register(clock) { request in
            clock.requests.append(request)
            return clock.requests.count > EditedDayRescoreQueue.maximumFailures // fails until the range parks
        }
        let night = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -45, to: start)).timeIntervalSince1970)
        queue.enqueue([night])
        await settle(queue)
        XCTAssertEqual(queue.parkedTimestamps, [night])
        let parkedAt = clock.now

        clock.now = parkedAt.addingTimeInterval(3_600)
        queue.scheduleDrain() // e.g. the app becoming active an hour later
        await settle(queue)
        XCTAssertEqual(queue.parkedTimestamps, [night], "an hour-old park holds")

        clock.now = parkedAt.addingTimeInterval(25 * 3_600)
        queue.scheduleDrain() // the same process, a day later
        await settle(queue)
        XCTAssertTrue(queue.timestamps.isEmpty, "the expired park drained without a relaunch")
        XCTAssertEqual(clock.requests.count, EditedDayRescoreQueue.maximumFailures + 1)
    }

    func testAParkDatedInTheFutureCountsAsExpired() async throws {
        let calendar = try newYorkCalendar()
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let defaults = try isolatedDefaults()
        let clock = EditedDayAnalyzeRecorder()
        clock.now = start.addingTimeInterval(7 * 86_400) // the wall clock was set a week ahead
        let failing = virtualClockQueue(clock, calendar: calendar, defaults: defaults)
        failing.register(clock) { _ in false }
        let night = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -45, to: start)).timeIntervalSince1970)
        failing.enqueue([night])
        await settle(failing)
        XCTAssertEqual(failing.parkedTimestamps, [night])
        failing.cancel()

        let corrected = EditedDayAnalyzeRecorder()
        corrected.now = start
        let relaunched = virtualClockQueue(corrected, calendar: calendar, defaults: defaults)
        XCTAssertTrue(relaunched.parkedTimestamps.isEmpty, "the clock moved back, so the park expired")
        XCTAssertEqual(relaunched.timestamps, [night])
    }

    func testAParkedEntryInsideALaterCompletedChunkIsDropped() async throws {
        let calendar = try newYorkCalendar()
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let recorder = EditedDayAnalyzeRecorder()
        recorder.now = start
        let queue = virtualClockQueue(recorder, calendar: calendar)
        queue.register(recorder) { request in
            recorder.requests.append(request)
            return request.maxDays != 21 // the range from 20 days back fails
        }
        let parked = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -20, to: start)).timeIntervalSince1970)
        queue.enqueue([parked])
        await settle(queue)
        XCTAssertEqual(queue.parkedTimestamps, [parked])

        let older = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -25, to: start)).timeIntervalSince1970)
        queue.enqueue([older]) // an older edit's range covers the parked day and completes
        await settle(queue)

        XCTAssertEqual(recorder.requests.last?.maxDays, 26)
        XCTAssertTrue(queue.timestamps.isEmpty, "the parked day was rescored by the later chunk but kept queued")
    }

    /// Review findings (no wake-up after a backoff): an edit made while an older range backed off waited for an
    /// unrelated analysis once the backoff ended; a backoff persisted under a clock that later moved back
    /// blocked every drain until the wall clock caught up.
    func testAnEditMadeDuringABackoffDrainsWhenTheBackoffEnds() async throws {
        let calendar = try newYorkCalendar()
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let recorder = EditedDayAnalyzeRecorder()
        recorder.now = start
        let queue = virtualClockQueue(recorder, calendar: calendar)
        let workoutDay = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: start)).timeIntervalSince1970)
        queue.register(recorder) { [unowned queue] request in
            recorder.requests.append(request)
            recorder.times.append(recorder.now)
            guard recorder.requests.count == 1 else { return true }
            queue.enqueue([workoutDay]) // a workout delete lands during the old range's first, failing pass
            return false
        }
        let old = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -9, to: start)).timeIntervalSince1970)

        queue.enqueue([old])
        await settle(queue)

        XCTAssertEqual(recorder.times.map { $0.timeIntervalSince(start) }, [0, 120])
        XCTAssertEqual(recorder.requests.map(\.maxDays), [10, 10], "the retry covers the workout day too")
        XCTAssertTrue(queue.timestamps.isEmpty)
    }

    func testABackoffFromAClockThatMovedBackCountsAsExpired() async throws {
        let calendar = try newYorkCalendar()
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let defaults = try isolatedDefaults()
        let ahead = EditedDayAnalyzeRecorder()
        ahead.now = start.addingTimeInterval(3 * 86_400) // the device clock ran three days ahead
        let before = virtualClockQueue(ahead, calendar: calendar, defaults: defaults,
                                       backgrounded: { ahead.backgrounded })
        before.register(ahead) { _ in
            ahead.backgrounded = true // leave the failure and its backoff persisted, nothing more
            return false
        }
        let edited = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: start)).timeIntervalSince1970)
        before.enqueue([edited])
        await settle(before)

        let corrected = EditedDayAnalyzeRecorder()
        corrected.now = start
        let after = virtualClockQueue(corrected, calendar: calendar, defaults: defaults)
        after.register(corrected) { request in
            corrected.requests.append(request)
            corrected.times.append(corrected.now)
            return true
        }
        await settle(after)

        XCTAssertEqual(corrected.times, [start], "a backoff three days out blocked the drain")
        XCTAssertTrue(after.timestamps.isEmpty)
    }

    /// Review finding (re-enqueue erased): the same timestamp enqueued again while its chunk ran (an undo, a
    /// re-edit of the same night) was removed with the chunk's snapshot, although the pass read its inputs before
    /// that edit.
    func testAnEditToTheSameNightMidChunkIsRescoredByALaterChunk() async throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let queue = drainQueue(now: now, calendar: calendar)
        let recorder = EditedDayAnalyzeRecorder()
        let night = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -6, to: now)).timeIntervalSince1970)
        queue.register(recorder) { [unowned queue] request in
            if recorder.requests.isEmpty { queue.enqueue([night]) } // the user taps Undo while the pass runs
            recorder.requests.append(request)
            return true
        }

        queue.enqueue([night])
        await queue.waitForDrain()

        XCTAssertEqual(recorder.requests.map(\.maxDays), [7, 7], "the undone night was never rescored")
        XCTAssertTrue(queue.timestamps.isEmpty)
    }

    func testAnEditArrivingMidChunkIsDrainedTooNotDropped() async throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let queue = drainQueue(now: now, calendar: calendar)
        let recorder = EditedDayAnalyzeRecorder()
        let older = Int(now.timeIntervalSince1970) - 20 * 86_400
        queue.register(recorder) { [unowned queue] request in
            if recorder.requests.isEmpty { queue.enqueue([older]) } // the user edits an older night meanwhile
            recorder.requests.append(request)
            return true
        }

        queue.enqueue([Int(now.timeIntervalSince1970) - 2 * 86_400])
        await queue.waitForDrain()

        XCTAssertEqual(recorder.requests.map(\.maxDays), [3, 21])
        XCTAssertTrue(queue.timestamps.isEmpty)
    }

    /// Review finding (lost wake-up): an edit enqueued while a finished drain was still publishing found the
    /// drain in flight, scheduled nothing, and waited for the next unrelated analysis.
    func testAnEditDuringTheClosingPublishStartsAnotherDrain() async throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let queue = drainQueue(now: now, calendar: calendar)
        let recorder = EditedDayAnalyzeRecorder()
        queue.register(recorder) { request in
            recorder.requests.append(request)
            return true
        }
        let workoutDay = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -12, to: now)).timeIntervalSince1970)

        queue.enqueue([Int(now.timeIntervalSince1970) - 3_600]) { [unowned queue] days in
            if recorder.published.isEmpty { queue.enqueue([workoutDay]) } // a workout delete during the publish
            recorder.published.append(days)
        }
        await queue.waitForDrain()
        await queue.waitForDrain() // the rerun the publish-window edit asked for

        XCTAssertEqual(recorder.requests.map(\.maxDays), [1, 13], "the edit during the publish was stranded")
        XCTAssertEqual(recorder.published, [1, 13])
        XCTAssertTrue(queue.timestamps.isEmpty)
    }

    func testOnlyTheBackgroundPausesTheDrain() {
        XCTAssertFalse(EditedDayRescoreQueue.pausesDrain(in: .inactive), "Control Center or the app switcher")
        XCTAssertFalse(EditedDayRescoreQueue.pausesDrain(in: .active))
        XCTAssertTrue(EditedDayRescoreQueue.pausesDrain(in: .background))
    }

    func testADrainPausedInTheBackgroundResumesWhenTheAppBecomesActive() async throws {
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let center = NotificationCenter()
        let recorder = EditedDayAnalyzeRecorder()
        recorder.backgrounded = true
        let queue = EditedDayRescoreQueue(defaults: nil, debounce: .zero, now: { now }, calendar: { calendar },
                                          isBackgrounded: { recorder.backgrounded }, activationCenter: center)
        queue.register(recorder) { request in
            recorder.requests.append(request)
            return true
        }

        queue.enqueue([Int(now.timeIntervalSince1970) - 3_600])
        await queue.waitForDrain()
        XCTAssertTrue(recorder.requests.isEmpty)

        recorder.backgrounded = false
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<500 where recorder.requests.isEmpty { try await Task.sleep(nanoseconds: 2_000_000) }
        await queue.waitForDrain()

        XCTAssertEqual(recorder.requests.map(\.maxDays), [1])
        XCTAssertTrue(queue.timestamps.isEmpty)
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
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let queue = EditedDayRescoreQueue(defaults: nil, debounce: .milliseconds(1), now: { now },
                                          calendar: { calendar }, isBackgrounded: { false })
        let recorder = EditedDayAnalyzeRecorder()
        queue.register(recorder) { request in
            recorder.requests.append(request)
            return true
        }

        queue.enqueue([Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: now)).timeIntervalSince1970)])
        await queue.waitForDrain()

        XCTAssertEqual(recorder.requests.map(\.maxDays), [4])
        XCTAssertTrue(queue.timestamps.isEmpty)
    }

    func testQueuedDaysSurviveARelaunchAndDrainOnceTheEngineRegisters() async throws {
        let defaults = try isolatedDefaults()
        let calendar = try newYorkCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let edited = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: now)).timeIntervalSince1970)
        let beforeKill = EditedDayRescoreQueue(defaults: defaults, storageKey: "queue", debounce: .zero,
                                               now: { now }, calendar: { calendar }, isBackgrounded: { false })
        beforeKill.enqueue([edited]) // no engine registered yet, so nothing drains

        let afterRelaunch = EditedDayRescoreQueue(defaults: defaults, storageKey: "queue", debounce: .zero,
                                                  now: { now }, calendar: { calendar }, isBackgrounded: { false })
        XCTAssertEqual(afterRelaunch.timestamps, [edited])
        let recorder = EditedDayAnalyzeRecorder()
        afterRelaunch.register(recorder) { request in
            recorder.requests.append(request)
            return true
        }
        await afterRelaunch.waitForDrain()

        XCTAssertEqual(recorder.requests.map(\.maxDays), [3])
        XCTAssertTrue(afterRelaunch.timestamps.isEmpty)
        let afterNextLaunch = EditedDayRescoreQueue(defaults: defaults, storageKey: "queue", debounce: .zero,
                                                    isBackgrounded: { false })
        XCTAssertTrue(afterNextLaunch.timestamps.isEmpty, "the drained entry stays drained across launches")
    }

    func testTheFirstReleasesPersistedQueueStillLoads() throws {
        let defaults = try isolatedDefaults()
        defaults.set([1_790_000_000, 1_790_086_400], forKey: "queue.v1") // the original bare [Int] format
        let upgraded = EditedDayRescoreQueue(defaults: defaults, storageKey: "queue", isBackgrounded: { false })
        XCTAssertEqual(upgraded.timestamps, [1_790_000_000, 1_790_086_400])

        upgraded.enqueue([1_790_172_800])
        let reloaded = EditedDayRescoreQueue(defaults: defaults, storageKey: "queue", isBackgrounded: { false })
        XCTAssertEqual(reloaded.timestamps, [1_790_000_000, 1_790_086_400, 1_790_172_800])
    }

    func testAnOlderBuildInstalledInPlaceSeesThePendingDaysAndTheRoundTripKeepsTheirState() async throws {
        let calendar = try newYorkCalendar()
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))
        let defaults = try isolatedDefaults()
        let clock = EditedDayAnalyzeRecorder()
        clock.now = start
        let failing = virtualClockQueue(clock, calendar: calendar, defaults: defaults, build: "100")
        failing.register(clock) { _ in false }
        let parked = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -45, to: start)).timeIntervalSince1970)
        failing.enqueue([parked])
        await settle(failing)
        failing.cancel()
        let noEngine = virtualClockQueue(clock, calendar: calendar, defaults: defaults, build: "100")
        let pending = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: start)).timeIntervalSince1970)
        noEngine.enqueue([pending])
        XCTAssertNotNil(defaults.data(forKey: "queue.v2"))
        XCTAssertEqual(defaults.array(forKey: "queue.v1") as? [Int], [parked, pending],
                       "an older build reads the bare list and sees both pending days")

        // The older build rescored `pending`, then queued a new edit, writing only its bare list.
        let added = Int(try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: start)).timeIntervalSince1970)
        defaults.set([parked, added], forKey: "queue.v1")

        let reinstalled = virtualClockQueue(clock, calendar: calendar, defaults: defaults, build: "100")
        XCTAssertEqual(reinstalled.timestamps, [parked, added])
        XCTAssertEqual(reinstalled.parkedTimestamps, [parked], "the v2 record still carries the park")
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
    var completes = true
    var backgrounded = false
    var now = Date()
    var times: [Date] = []
    var snapshot: Set<Int> = []
}
