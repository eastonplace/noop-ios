#if targetEnvironment(simulator)
import XCTest
import Combine
@testable import NOOP

/// The workout's Live Activity is requested by the Start edge's drive. ActivityKit grants a request only while the app is in
/// front, so that drive has to be a workout drive: if it reads the model before the workout is assigned, the workout's
/// request waits for a later reading, often after the phone is locked.
@MainActor
final class LiveActivityStartEdgeTests: XCTestCase {
    private var subscriptions: Set<AnyCancellable> = []

    override func setUp() async throws {
        ActiveWorkoutPersistence.clear()
        ActiveGpsWorkoutPersistence.clear()
        ActiveWorkoutPauseStore.clear()
    }

    override func tearDown() async throws {
        subscriptions.removeAll()
        ActiveWorkoutPersistence.clear()
        ActiveGpsWorkoutPersistence.clear()
        ActiveWorkoutPauseStore.clear()
    }

    /// Let everything already queued on the main queue run.
    private func spinMainQueue() {
        let turn = expectation(description: "main queue turn")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 5)
    }

    /// What a drive at this moment would tell the activity: is a workout running, and is there a workout state to show.
    private func driveSees(_ model: AppModel, _ liveActivity: LiveActivityController,
                           _ projections: WorkoutLiveProjectionCache) -> Bool {
        let feed = LiveActivityFeed.current(model: model, projections: projections, liveActivity: liveActivity)
        return feed.workoutIsActive && feed.workoutState() != nil
    }

    /// Subscribed the way the app subscribes (`onReceive` delivers synchronously), driving through `afterAssignment`.
    func testTheStartEdgeAndTheFirstReadingDriveAWorkout() {
        let model = AppModel()
        let liveActivity = LiveActivityController()
        let projections = WorkoutLiveProjectionCache()
        var edgeDrives: [Bool] = []
        var readingDrives: [Bool] = []
        WorkoutLifecycleProjection.edges(of: model)
            .sink { _ in
                WorkoutLifecycleProjection.afterAssignment {
                    edgeDrives.append(self.driveSees(model, liveActivity, projections))
                }
            }
            .store(in: &subscriptions)
        WorkoutLifecycleProjection.readings(of: model)
            .sink { _ in
                WorkoutLifecycleProjection.afterAssignment {
                    readingDrives.append(self.driveSees(model, liveActivity, projections))
                }
            }
            .store(in: &subscriptions)
        spinMainQueue()
        readingDrives.removeAll()   // the reading of "no workout" sent on subscribing

        model.startWorkout(sport: "Strength Training")
        XCTAssertNotNil(model.activeWorkout, "the workout started")
        XCTAssertEqual(edgeDrives, [], "nothing is driven from inside the assignment")
        spinMainQueue()

        XCTAssertEqual(edgeDrives, [true], "the Start edge drives the workout")
        XCTAssertEqual(readingDrives.first, true, "and so does the first reading")
        XCTAssertTrue(model.discardWorkout())
    }

    /// Why the edges are delivered a turn later: `@Published` sends from `willSet`, so a synchronous subscriber, as
    /// `onReceive` is, still finds the model without the workout. This is what the Start edge used to drive.
    func testASynchronousStartEdgeStillSeesNoWorkout() {
        let model = AppModel()
        let liveActivity = LiveActivityController()
        let projections = WorkoutLiveProjectionCache()
        var drives: [Bool] = []
        model.$activeWorkout
            .map(WorkoutLifecycleProjection.identity)
            .removeDuplicates()
            .dropFirst()
            .sink { _ in drives.append(self.driveSees(model, liveActivity, projections)) }
            .store(in: &subscriptions)

        model.startWorkout(sport: "Strength Training")
        XCTAssertNotNil(model.activeWorkout)
        XCTAssertEqual(drives, [false], "inside willSet the model still holds no workout")
        XCTAssertTrue(model.discardWorkout())
    }
}
#endif
