import XCTest
import Foundation
@testable import NOOP

#if os(iOS)
final class LiveUpdatePoliciesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testWidgetLiveContextAllowsForegroundAndBackgroundWorkoutPublication() {
        XCTAssertTrue(WidgetLivePublicationContext.shouldPublish(
            sceneIsActive: true, hasActiveWorkout: false))
        XCTAssertTrue(WidgetLivePublicationContext.shouldPublish(
            sceneIsActive: false, hasActiveWorkout: true))
    }

    func testWidgetLiveContextRejectsIncidentalBackgroundSensorWake() {
        XCTAssertFalse(WidgetLivePublicationContext.shouldPublish(
            sceneIsActive: false, hasActiveWorkout: false))
    }

    func testWidgetPolicyForcesFirstPublicationWhenNoSnapshotExists() {
        XCTAssertTrue(WidgetLivePublishPolicy.shouldPublish(
            previous: nil,
            next: snapshot(bpm: 80, sparkline: nil),
            lastPublishedAt: .distantPast,
            now: t0))
    }

    func testWidgetPolicySkipsByteEquivalentLivePayload() {
        let previous = snapshot(bpm: 80, sparkline: [78, 79, 80])
        let next = previous.mergingLive(
            bpm: 80, batteryPct: 80, bonded: true, storedStrain: 50,
            hrSparkline: [78, 79, 80], updated: t0.addingTimeInterval(120))

        XCTAssertFalse(WidgetLivePublishPolicy.shouldPublish(
            previous: previous, next: next, lastPublishedAt: t0,
            now: t0.addingTimeInterval(120)))
    }

    func testWidgetPolicyCoalescesHighFrequencyWorkoutAndStrainChurn() {
        let previous = snapshot(bpm: 120, sparkline: [116, 118, 120])
        let next = previous.mergingLive(
            bpm: 123, batteryPct: 80, bonded: true, storedStrain: 51,
            hrSparkline: [118, 120, 123], updated: t0.addingTimeInterval(2))

        XCTAssertFalse(WidgetLivePublishPolicy.shouldPublish(
            previous: previous, next: next, lastPublishedAt: t0,
            now: t0.addingTimeInterval(2), highFrequencyInterval: 60))
        XCTAssertTrue(WidgetLivePublishPolicy.shouldPublish(
            previous: previous, next: next, lastPublishedAt: t0,
            now: t0.addingTimeInterval(60), highFrequencyInterval: 60))
    }

    func testWidgetPolicyIgnoresSubDisplayPrecisionStrainNoise() {
        let previous = snapshot(bpm: 80, sparkline: nil, effort: 10.01)
        let next = snapshot(bpm: 80, sparkline: nil, effort: 10.04)

        XCTAssertFalse(WidgetLivePublishPolicy.shouldPublish(
            previous: previous, next: next, lastPublishedAt: t0,
            now: t0.addingTimeInterval(120)))
    }

    func testWidgetPolicyPublishesUrgentAndWorkoutModeChangesImmediately() {
        let previous = snapshot(bpm: 80, sparkline: nil)
        let connectedChange = previous.mergingLive(
            bpm: 80, batteryPct: 80, bonded: false, storedStrain: 50,
            updated: t0.addingTimeInterval(1))
        XCTAssertTrue(WidgetLivePublishPolicy.shouldPublish(
            previous: previous, next: connectedChange, lastPublishedAt: t0,
            now: t0.addingTimeInterval(1)))

        let batteryChange = previous.mergingLive(
            bpm: 80, batteryPct: 79, bonded: true, storedStrain: 50,
            updated: t0.addingTimeInterval(1))
        XCTAssertTrue(WidgetLivePublishPolicy.shouldPublish(
            previous: previous, next: batteryChange, lastPublishedAt: t0,
            now: t0.addingTimeInterval(1)))

        let workoutStart = previous.mergingLive(
            bpm: 100, batteryPct: 80, bonded: true, storedStrain: 50,
            hrSparkline: [95, 100], updated: t0.addingTimeInterval(1))
        XCTAssertTrue(WidgetLivePublishPolicy.shouldPublish(
            previous: previous, next: workoutStart, lastPublishedAt: t0,
            now: t0.addingTimeInterval(1)))

        var workoutEnd = workoutStart
        workoutEnd.hrSparkline = nil
        XCTAssertTrue(WidgetLivePublishPolicy.shouldPublish(
            previous: workoutStart, next: workoutEnd, lastPublishedAt: t0,
            now: t0.addingTimeInterval(1)))
    }

    func testWidgetPolicyRecoversFromWallClockRollback() {
        let previous = snapshot(bpm: 80, sparkline: nil)
        let next = snapshot(bpm: 81, sparkline: nil)

        XCTAssertTrue(WidgetLivePublishPolicy.shouldPublish(
            previous: previous, next: next,
            lastPublishedAt: t0.addingTimeInterval(300),
            now: t0,
            highFrequencyInterval: 60))
    }

    func testFullWidgetPolicyIgnoresTimestampOnlyUntilHeartbeat() {
        let previous = snapshot(bpm: 80, sparkline: nil)
        var next = previous
        next.updated = t0.addingTimeInterval(60)

        XCTAssertTrue(previous.hasSameRenderedContent(as: next))
        XCTAssertFalse(WidgetFullPublishPolicy.shouldPublish(
            previous: previous,
            next: next,
            lastPublishedAt: t0,
            now: t0.addingTimeInterval(899),
            unchangedHeartbeatInterval: 900))
        XCTAssertTrue(WidgetFullPublishPolicy.shouldPublish(
            previous: previous,
            next: next,
            lastPublishedAt: t0,
            now: t0.addingTimeInterval(900),
            unchangedHeartbeatInterval: 900))
    }

    func testFullWidgetPolicyPublishesChangedRenderedContentImmediately() {
        let previous = snapshot(bpm: 80, sparkline: nil)
        var next = previous
        next.rest = 83
        next.updated = t0.addingTimeInterval(1)

        XCTAssertFalse(previous.hasSameRenderedContent(as: next))
        XCTAssertTrue(WidgetFullPublishPolicy.shouldPublish(
            previous: previous,
            next: next,
            lastPublishedAt: t0,
            now: t0.addingTimeInterval(1)))
    }

    func testFullWidgetPolicyRecoversFromWallClockRollback() {
        let previous = snapshot(bpm: 80, sparkline: nil)
        var next = previous
        next.updated = t0
        XCTAssertTrue(WidgetFullPublishPolicy.shouldPublish(
            previous: previous,
            next: next,
            lastPublishedAt: t0.addingTimeInterval(300),
            now: t0))
    }

    func testLiveActivityPushPolicyRetainsTwoSecondCadenceForSameMode() {
        XCTAssertFalse(LiveActivityPushPolicy.shouldPush(
            activityExists: true,
            currentModeIsWorkout: true,
            desiredModeIsWorkout: true,
            lastPushedAt: t0,
            now: t0.addingTimeInterval(1.99)))
        XCTAssertTrue(LiveActivityPushPolicy.shouldPush(
            activityExists: true,
            currentModeIsWorkout: true,
            desiredModeIsWorkout: true,
            lastPushedAt: t0,
            now: t0.addingTimeInterval(2)))
    }

    func testLiveActivityPushPolicyBypassesThrottleForStartAndFinishEdges() {
        XCTAssertTrue(LiveActivityPushPolicy.shouldPush(
            activityExists: true,
            currentModeIsWorkout: false,
            desiredModeIsWorkout: true,
            lastPushedAt: t0,
            now: t0.addingTimeInterval(0.1)))
        XCTAssertTrue(LiveActivityPushPolicy.shouldPush(
            activityExists: true,
            currentModeIsWorkout: true,
            desiredModeIsWorkout: false,
            lastPushedAt: t0,
            now: t0.addingTimeInterval(0.1)))
    }

    func testLiveActivityPushPolicyRecoversFromWallClockRollback() {
        XCTAssertTrue(LiveActivityPushPolicy.shouldPush(
            activityExists: true,
            currentModeIsWorkout: false,
            desiredModeIsWorkout: false,
            lastPushedAt: t0.addingTimeInterval(300),
            now: t0))
    }

    func testLiveActivityProjectionPolicyBuildsOnlyForActiveWorkout() {
        XCTAssertFalse(LiveActivityWorkoutProjectionPolicy.shouldRebuild(
            workoutIsActive: false,
            hasCachedWorkout: true,
            lastBuiltAt: t0,
            now: t0.addingTimeInterval(20)))
        XCTAssertTrue(LiveActivityWorkoutProjectionPolicy.shouldRebuild(
            workoutIsActive: true,
            hasCachedWorkout: false,
            lastBuiltAt: t0,
            now: t0.addingTimeInterval(1)))
        XCTAssertFalse(LiveActivityWorkoutProjectionPolicy.shouldRebuild(
            workoutIsActive: true,
            hasCachedWorkout: true,
            lastBuiltAt: t0,
            now: t0.addingTimeInterval(9),
            rebuildInterval: 10))
        XCTAssertTrue(LiveActivityWorkoutProjectionPolicy.shouldRebuild(
            workoutIsActive: true,
            hasCachedWorkout: true,
            lastBuiltAt: t0,
            now: t0.addingTimeInterval(10),
            rebuildInterval: 10))
    }

    func testLiveActivityProjectionPolicyRecoversFromWallClockRollback() {
        XCTAssertTrue(LiveActivityWorkoutProjectionPolicy.shouldRebuild(
            workoutIsActive: true,
            hasCachedWorkout: true,
            lastBuiltAt: t0.addingTimeInterval(300),
            now: t0,
            rebuildInterval: 10))
    }

    func testThirtyMinuteOneHertzSimulationKeepsPublicationWorkBounded() throws {
        var previous: WidgetSnapshot?
        var lastWidgetPublish = Date.distantPast
        var widgetPublishes = 0
        var activityPushes = 0
        var lastActivityPush = Date.distantPast
        var activityExists = false
        var cachedProjection = false
        var lastProjectionBuild = Date.distantPast
        var projectionBuilds = 0

        for second in 0..<1_800 {
            let now = t0.addingTimeInterval(TimeInterval(second))
            let bpm = 120 + (second % 17)
            let next = snapshot(bpm: bpm, sparkline: [bpm - 2, bpm - 1, bpm])
            if WidgetLivePublishPolicy.shouldPublish(
                previous: previous,
                next: next,
                lastPublishedAt: lastWidgetPublish,
                now: now
            ) {
                widgetPublishes += 1
                previous = next
                lastWidgetPublish = now
            }

            if LiveActivityPushPolicy.shouldPush(
                activityExists: activityExists,
                currentModeIsWorkout: activityExists ? true : nil,
                desiredModeIsWorkout: true,
                lastPushedAt: lastActivityPush,
                now: now
            ) {
                activityPushes += 1
                activityExists = true
                lastActivityPush = now
            }

            if LiveActivityWorkoutProjectionPolicy.shouldRebuild(
                workoutIsActive: true,
                hasCachedWorkout: cachedProjection,
                lastBuiltAt: lastProjectionBuild,
                now: now
            ) {
                projectionBuilds += 1
                cachedProjection = true
                lastProjectionBuild = now
            }
        }

        let finishTime = t0.addingTimeInterval(1_800)
        var finished = try XCTUnwrap(previous)
        finished.hrSparkline = nil
        if WidgetLivePublishPolicy.shouldPublish(
            previous: previous,
            next: finished,
            lastPublishedAt: lastWidgetPublish,
            now: finishTime
        ) {
            widgetPublishes += 1
        }
        if LiveActivityPushPolicy.shouldPush(
            activityExists: true,
            currentModeIsWorkout: true,
            desiredModeIsWorkout: false,
            lastPushedAt: lastActivityPush,
            now: finishTime
        ) {
            activityPushes += 1
        }

        XCTAssertEqual(widgetPublishes, 31, "30 minute start + one/minute cadence + immediate finish")
        XCTAssertEqual(activityPushes, 901, "start + one push every two seconds + immediate finish")
        XCTAssertEqual(projectionBuilds, 180, "one expensive projection every ten seconds")
        XCTAssertFalse(LiveActivityWorkoutProjectionPolicy.shouldRebuild(
            workoutIsActive: false,
            hasCachedWorkout: cachedProjection,
            lastBuiltAt: lastProjectionBuild,
            now: finishTime))
    }

    func testWidgetSnapshotSaveReportsMissingDefaults() {
        XCTAssertFalse(snapshot(bpm: 80, sparkline: nil).save(to: nil))
    }

    func testWidgetSnapshotSaveWritesAndRoundTripsInIsolatedSuite() throws {
        let suite = "test.widget.snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let value = snapshot(bpm: 87, sparkline: [80, 84, 87])
        XCTAssertTrue(value.save(to: defaults))
        let data = try XCTUnwrap(defaults.data(forKey: WidgetSnapshot.storageKey))
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: data), value)
    }

    // MARK: Pause edge

    func testAnEdgeIsPendingUntilAWriteBuiltAfterItGoesOut() {
        var latch = PauseEdgeLatch()
        XCTAssertFalse(latch.isPending)
        latch.noteEdge()
        XCTAssertTrue(latch.isPending)
        latch.delivered(builtAt: latch.generation)
        XCTAssertFalse(latch.isPending)
    }

    /// The race itself: a write is built (the workout is running), suspends at `await activity.update`, the person taps
    /// Pause, and the write returns. It carried the old state, so the edge the tap raised must still be pending, or the
    /// write that follows would be throttled away and the Lock Screen would keep a running clock under a paused workout.
    func testAWriteInFlightWhenTheEdgeArrivesDoesNotClearIt() {
        var latch = PauseEdgeLatch()
        let builtAt = latch.generation          // state built from the running workout
        latch.noteEdge()                        // Pause tapped during the await
        latch.delivered(builtAt: builtAt)       // the in-flight write returns
        XCTAssertTrue(latch.isPending, "the paused state has not been written yet")

        let rebuiltAt = latch.generation        // the follow-up write builds from the paused workout
        latch.delivered(builtAt: rebuiltAt)
        XCTAssertFalse(latch.isPending)
    }

    func testPauseThenResumeDuringOneWriteStaysPendingUntilTheLastEdgeIsCarried() {
        var latch = PauseEdgeLatch()
        let builtAt = latch.generation
        latch.noteEdge()                        // Pause
        latch.noteEdge()                        // Resume, quickly after
        latch.delivered(builtAt: builtAt)
        XCTAssertTrue(latch.isPending)
        let middle = latch.generation
        latch.noteEdge()                        // another tap while the second write is in flight
        latch.delivered(builtAt: middle)
        XCTAssertTrue(latch.isPending, "an edge newer than the write's state is still owed")
        latch.delivered(builtAt: latch.generation)
        XCTAssertFalse(latch.isPending)
    }

    func testResetForgetsWhatIsOwedToAnActivityThatIsGone() {
        var latch = PauseEdgeLatch()
        latch.noteEdge()
        latch.reset()
        XCTAssertFalse(latch.isPending)
    }

    // MARK: Heart rate on the activity

    func testAWorkoutKeepsItsLastReadingWhenTheStrapIsNotConnected() {
        XCTAssertEqual(LiveActivityHeartRate.value(workoutIsActive: true, workoutBPM: 152, connected: false, passiveBPM: nil), 152)
        XCTAssertEqual(LiveActivityHeartRate.value(workoutIsActive: true, workoutBPM: 152, connected: true, passiveBPM: 99), 152,
                       "the workout's own reading, not the passive one")
        XCTAssertNil(LiveActivityHeartRate.value(workoutIsActive: true, workoutBPM: nil, connected: true, passiveBPM: 99),
                     "no reading yet is a dash, never another source's number")
    }

    func testWithNoWorkoutAnUnconnectedStrapHasNoReading() {
        XCTAssertNil(LiveActivityHeartRate.value(workoutIsActive: false, workoutBPM: nil, connected: false, passiveBPM: 80))
        XCTAssertEqual(LiveActivityHeartRate.value(workoutIsActive: false, workoutBPM: nil, connected: true, passiveBPM: 80), 80)
    }

    private func snapshot(bpm: Int?, sparkline: [Int]?, effort: Double = 10.5) -> WidgetSnapshot {
        WidgetSnapshot(
            recovery: 70,
            bpm: bpm,
            batteryPct: 80,
            bonded: true,
            updated: t0,
            effort: effort,
            rest: 82,
            hrv: 60,
            restingHr: 51,
            hrSparkline: sparkline)
    }

    // MARK: The cached workout state and the quiet-strap verdict

    private func workoutState() -> WorkoutLiveActivityState {
        WorkoutLiveActivityState(sport: "Running", startedAt: t0, strain: 6.8, strainBuilding: false, calories: 400,
                                 hrTrace: [140, 142], zoneSeconds: [0, 0, 0, 0, 0])
    }

    private func written(_ write: LiveActivityWorkoutStateCache.Write) throws -> WorkoutLiveActivityState {
        // ORG-8: a wrong write is a failure, not a skip.
        guard case .state(let state) = write else {
            return try XCTUnwrap(nil as WorkoutLiveActivityState?, "expected a workout state, got \(write)")
        }
        return state
    }

    func testTheCachedStateIsReusedForTenSecondsButTheVerdictIsAskedAgainForEveryWrite() throws {
        var cache = LiveActivityWorkoutStateCache()
        var builds = 0
        var quiet = true
        let build: () -> WorkoutLiveActivityState? = { builds += 1; return self.workoutState() }
        let first = try written(cache.stateForWrite(workoutIsActive: true, now: t0, build: build, heartRateIsStale: { quiet }))
        XCTAssertEqual(builds, 1)
        XCTAssertTrue(first.heartRateIsStale)
        // The strap comes back 3 s later; the projection is reused (10 s), the verdict is not.
        quiet = false
        let recovered = try written(cache.stateForWrite(workoutIsActive: true, now: t0.addingTimeInterval(3), build: build,
                                                        heartRateIsStale: { quiet }))
        XCTAssertEqual(builds, 1, "the expensive projection is not rebuilt inside its window")
        XCTAssertFalse(recovered.heartRateIsStale, "the heart is undimmed at the first write after the strap is back")
        // And it goes quiet again 4 s after that, still inside the same window.
        quiet = true
        let flipped = try written(cache.stateForWrite(workoutIsActive: true, now: t0.addingTimeInterval(7), build: build,
                                                      heartRateIsStale: { quiet }))
        XCTAssertEqual(builds, 1)
        XCTAssertTrue(flipped.heartRateIsStale, "a flip in the other direction is not held back either")
        // Past ten seconds the projection is rebuilt, as before.
        _ = cache.stateForWrite(workoutIsActive: true, now: t0.addingTimeInterval(11), build: build, heartRateIsStale: { quiet })
        XCTAssertEqual(builds, 2)
    }

    func testTheVerdictIsAskedOncePerWriteAndNeverWhenThereIsNoWorkout() throws {
        var cache = LiveActivityWorkoutStateCache()
        var asked = 0
        let ask: () -> Bool = { asked += 1; return false }
        XCTAssertEqual(asked, 0, "handing the closure over asks nothing: a queued update carries the question, not an answer")
        _ = cache.stateForWrite(workoutIsActive: true, now: t0, build: { self.workoutState() }, heartRateIsStale: ask)
        _ = cache.stateForWrite(workoutIsActive: true, now: t0.addingTimeInterval(2), build: { self.workoutState() },
                                heartRateIsStale: ask)
        XCTAssertEqual(asked, 2)
        guard case .noWorkout = cache.stateForWrite(workoutIsActive: false, now: t0.addingTimeInterval(3),
                                                    build: { self.workoutState() }, heartRateIsStale: ask) else {
            return XCTFail("outside a workout there is no state to write")
        }
        XCTAssertEqual(asked, 2)
        XCTAssertNil(cache.state, "leaving workout mode drops the cache")
    }

    func testAPauseEdgeOrANilProjectionRebuildsOrIsNotApplicable() throws {
        var cache = LiveActivityWorkoutStateCache()
        var builds = 0
        let build: () -> WorkoutLiveActivityState? = { builds += 1; return self.workoutState() }
        _ = cache.stateForWrite(workoutIsActive: true, now: t0, build: build, heartRateIsStale: { false })
        cache.clear()                                       // a pause edge (noteWorkoutPauseEdge)
        _ = cache.stateForWrite(workoutIsActive: true, now: t0.addingTimeInterval(1), build: build, heartRateIsStale: { false })
        XCTAssertEqual(builds, 2, "an edge forces a rebuild even inside the window")
        guard case .unavailable = cache.stateForWrite(workoutIsActive: true, now: t0.addingTimeInterval(20),
                                                      build: { nil }, heartRateIsStale: { false }) else {
            return XCTFail("a workout that cannot be projected is not applicable")
        }
        XCTAssertNil(cache.state)
    }
}
#endif
