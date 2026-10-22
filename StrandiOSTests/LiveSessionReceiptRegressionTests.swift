#if targetEnvironment(simulator)
import XCTest
import StrandAnalytics
@testable import NOOP

@MainActor
final class LiveSessionReceiptRegressionTests: XCTestCase {
    func testSilentConnectedCachedHRBecomesStaleAndEndsWithoutMoreCoachingOrAccrual() throws {
        ActiveWorkoutPersistence.clear()
        defer { ActiveWorkoutPersistence.flushPendingWrites(); ActiveWorkoutPersistence.clear() }
        let model = AppModel(startRuntimeTasks: false)
        let runner = LiveSessionRunner()
        runner.start(model: model, repo: model.repo, ble: model.ble, profile: model.profile)
        let source = LiveHeartRateSource(deviceId: model.repo.deviceId, peripheralID: UUID(), connectionGeneration: 1)
        model.live.activateHeartRateSource(source)
        let band = try XCTUnwrap(runner.baseBand)
        let observed = Date()
        let second = Int(observed.timeIntervalSince1970)
        let bpm = Int((band.floorBpm + band.ceilingBpm) / 2)
        model.live.receiveHeartRate(bpm: bpm, observedAt: observed, source: source, transport: .standard)
        XCTAssertEqual(model.live.heartRate, bpm)
        XCTAssertTrue(try XCTUnwrap(runner.output).sampleArrived)

        for tick in 1...10 { runner.tick(now: second + tick) }
        XCTAssertEqual(runner.output?.status, .stale)
        let accrued = runner.output?.inBandSeconds
        for tick in 11...650 { runner.tick(now: second + tick) }

        XCTAssertNotNil(runner.finalRow)
        XCTAssertEqual(runner.output?.inBandSeconds, accrued)
        XCTAssertEqual(runner.pushCount, 0)
        XCTAssertEqual(runner.easeCount, 0)
        XCTAssertEqual(model.live.heartRate, bpm, "a cached display value is not a new observation")
    }

    func testReceiptPipelineCapturesEqualBPMAtObservedSeconds() throws {
        ActiveWorkoutPersistence.clear()
        defer { ActiveWorkoutPersistence.flushPendingWrites(); ActiveWorkoutPersistence.clear() }
        let model = AppModel(startRuntimeTasks: false)
        let start = Date(timeIntervalSince1970: 1_792_600_000)
        let workout = AppModel.ActiveWorkout(start: start, sport: "Running", maxHR: 190)
        model.activeWorkout = workout
        let source = LiveHeartRateSource(deviceId: model.repo.deviceId, peripheralID: UUID(), connectionGeneration: 1)
        model.live.activateHeartRateSource(source)

        for second in 0..<60 {
            let observed = start.addingTimeInterval(Double(second))
            model.live.receiveHeartRate(bpm: 100, observedAt: observed, source: source,
                                        transport: .standard, now: observed)
        }

        XCTAssertEqual(workout.samples.count, 60)
        XCTAssertEqual(workout.samples.first?.ts, Int(start.timeIntervalSince1970))
        XCTAssertEqual(workout.lastReadingAt, start.addingTimeInterval(59))
        XCTAssertEqual(model.bpm, 100)
        model.activeWorkout = nil
    }

    func testDisconnectedViewLeaseSurvivesReconnectAndCannotReleaseAnotherConsumer() {
        ActiveWorkoutPersistence.clear()
        defer { ActiveWorkoutPersistence.flushPendingWrites(); ActiveWorkoutPersistence.clear() }
        let model = AppModel(startRuntimeTasks: false)
        XCTAssertFalse(model.live.connected)
        let view = model.acquireRealtimeHR(for: .visible)
        let recording = model.acquireRealtimeHR(for: .workout)

        model.rearmRealtimeIfWanted()
        model.rearmRealtimeIfWanted()
        model.releaseRealtimeHR(view)
        model.releaseRealtimeHR(view)

        XCTAssertTrue(model.live.liveFeedActive)
        model.releaseRealtimeHR(recording)
        XCTAssertFalse(model.live.liveFeedActive, "reconnect must not acquire extra ownership")
    }
}
#endif
