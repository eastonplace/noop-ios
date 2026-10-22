import XCTest
import WhoopProtocol
@testable import NOOP

@MainActor
final class WorkoutReceiptFreshnessTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_600_000)

    func testWorkoutFreshnessUsesTheObservedSampleTime() {
        let workout = AppModel.ActiveWorkout(start: start, sport: "Running", maxHR: 190)
        let observed = start.addingTimeInterval(10)

        XCTAssertTrue(workout.ingest(HRSample(ts: Int(observed.timeIntervalSince1970), bpm: 120)))

        XCTAssertEqual(workout.lastReadingAt, observed)
    }

    func testPausedReadingKeepsItsObservedTimeWithoutAddingAWorkoutSample() {
        let workout = AppModel.ActiveWorkout(start: start, sport: "Running", maxHR: 190)
        workout.setPaused(true, at: start.addingTimeInterval(5))
        let observed = start.addingTimeInterval(10)

        XCTAssertFalse(workout.ingest(HRSample(ts: Int(observed.timeIntervalSince1970), bpm: 120)))

        XCTAssertEqual(workout.lastReadingAt, observed)
        XCTAssertTrue(workout.samples.isEmpty)
    }

    func testLatePausedReadingCannotMoveFreshnessOrTheDisplayBackward() {
        let workout = AppModel.ActiveWorkout(start: start, sport: "Running", maxHR: 190)
        workout.noteReading(120, at: start.addingTimeInterval(10))

        workout.noteReading(80, at: start.addingTimeInterval(9))

        XCTAssertEqual(workout.lastReadingAt, start.addingTimeInterval(10))
        XCTAssertEqual(workout.currentBPM, 120)
    }
}
