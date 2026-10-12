import XCTest
@testable import NOOP

final class WorkoutPrefsTests: XCTestCase {
    func testKeepAwakeIsOnByDefaultAndTheKeyIsTheOneEveryScreenReads() {
        XCTAssertTrue(WorkoutPrefs.keepScreenOnDefault)
        XCTAssertEqual(WorkoutPrefs.keepScreenOnKey, "workoutKeepScreenOn")
    }

    func testLowPowerModeAlwaysTurnsKeepAwakeOff() {
        XCTAssertTrue(WorkoutPrefs.keepsScreenOn(preference: true, lowPowerMode: false))
        XCTAssertFalse(WorkoutPrefs.keepsScreenOn(preference: true, lowPowerMode: true))
        XCTAssertFalse(WorkoutPrefs.keepsScreenOn(preference: false, lowPowerMode: false))
        XCTAssertFalse(WorkoutPrefs.keepsScreenOn(preference: false, lowPowerMode: true))
    }
}
