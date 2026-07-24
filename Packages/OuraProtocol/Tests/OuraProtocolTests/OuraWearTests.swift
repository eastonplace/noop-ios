import XCTest
@testable import OuraProtocol

final class OuraWearTests: XCTestCase {
    private func state(_ timestamp: UInt32, _ text: String) -> OuraState {
        OuraState(ringTimestamp: timestamp, stateCode: 0, text: text)
    }

    func testChargerStartStopStringMatching() {
        XCTAssertTrue(OuraWear.isChargerStart(state(1, "chg. detected")))
        XCTAssertTrue(OuraWear.isChargerStop(state(1, "chg. stopped")))
        XCTAssertFalse(OuraWear.isChargerStart(state(1, "hr enable")))
        XCTAssertFalse(OuraWear.isChargerStop(state(1, "orientation")))
        XCTAssertFalse(OuraWear.isChargerStart(state(1, "fea off")))
        XCTAssertFalse(OuraWear.isChargerStop(state(1, "motion det")))
        XCTAssertFalse(OuraWear.isChargerStart(
            OuraState(ringTimestamp: 1, stateCode: 8, text: nil)
        ))
    }

    func testLiveTrackerPulseMeansWorn() {
        let tracker = OuraWearTracker()
        XCTAssertEqual(tracker.current, .unknown)
        tracker.note(state: state(1, "chg. detected"))
        XCTAssertEqual(tracker.current, .charging)
        tracker.note(state: state(2, "chg. stopped"))
        XCTAssertEqual(tracker.current, .off)
        tracker.notePulse()
        XCTAssertEqual(tracker.current, .worn)
        tracker.note(state: state(3, "chg. detected"))
        XCTAssertEqual(tracker.current, .charging)
        tracker.reset()
        XCTAssertEqual(tracker.current, .unknown)
    }

    func testLivePulseTimeoutDowngradesOnlyWornState() {
        let tracker = OuraWearTracker()
        tracker.noteLivePulseTimeout()
        XCTAssertEqual(tracker.current, .unknown)
        tracker.notePulse()
        tracker.noteLivePulseTimeout()
        XCTAssertEqual(tracker.current, .off)
        tracker.note(state: state(9, "chg. detected"))
        tracker.noteLivePulseTimeout()
        XCTAssertEqual(tracker.current, .charging)
    }
}
