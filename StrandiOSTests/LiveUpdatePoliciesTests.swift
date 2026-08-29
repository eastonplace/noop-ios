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
}
#endif
